$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repoRoot 'src\WordPressSshDeploy.psm1') -Force
. (Join-Path $repoRoot 'deploy.config.example.ps1')
$exampleConfiguration = $DeployConfig

function New-PullConfiguration {
	$config = $exampleConfiguration.Clone()
	$config.PullEnabled = $true
	return $config
}

# The public example uses the same table count for push and pull. Exact-count regressions
# stay invisible on identical numbers, so these helpers force the pull count apart from it.
function New-PullExactCountConfiguration {
	$config = New-PullConfiguration
	$config.ExpectedPullDbTableCount = 17
	return $config
}

function New-ExactCountPullPlan([System.Collections.IDictionary] $Configuration) {
	return New-PullPlan $Configuration 'pull-db' '20260812-000000' (Join-Path ([IO.Path]::GetTempPath()) 'pull-plan-root') -Confirmed
}

function Get-ErrorMessage([scriptblock] $Action) {
	try { & $Action; return '' } catch { return $_.Exception.Message }
}

function New-GzipFile([string] $Path, [byte[]] $Content) {
	$target = $null
	$gzip = $null
	try {
		$target = [IO.File]::Create($Path)
		$gzip = New-Object IO.Compression.GZipStream($target, [IO.Compression.CompressionMode]::Compress)
		$gzip.Write($Content, 0, $Content.Length)
	} finally {
		if ($gzip) { $gzip.Dispose() }
		if ($target) { $target.Dispose() }
	}
}

function New-TarHeaderBlock([string] $Name, [long] $Size, [string] $TypeFlag) {
	$block = New-Object byte[] 512
	$ascii = [Text.Encoding]::ASCII
	$nameBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Name)
	[Array]::Copy($nameBytes, 0, $block, 0, [Math]::Min($nameBytes.Length, 100))
	$fields = @(
		@(100, '0000644'), @(108, '0000000'), @(116, '0000000'),
		@(124, ([Convert]::ToString($Size, 8)).PadLeft(11, '0')),
		@(136, '00000000000'), @(257, 'ustar'), @(263, '00')
	)
	foreach ($field in $fields) {
		$bytes = $ascii.GetBytes([string] $field[1])
		[Array]::Copy($bytes, 0, $block, [int] $field[0], $bytes.Length)
	}
	$block[156] = [byte] [char] $TypeFlag
	for ($index = 148; $index -lt 156; $index++) { $block[$index] = [byte] 32 }
	$sum = 0
	foreach ($byte in $block) { $sum += $byte }
	$checksum = $ascii.GetBytes(([Convert]::ToString($sum, 8)).PadLeft(6, '0'))
	[Array]::Copy($checksum, 0, $block, 148, $checksum.Length)
	$block[154] = 0
	$block[155] = [byte] 32
	return $block
}

function New-TarFile([string] $Path, [object[]] $Entries) {
	$stream = [IO.File]::Create($Path)
	try {
		foreach ($entry in $Entries) {
			$content = if ($entry.Content) { [Text.Encoding]::ASCII.GetBytes($entry.Content) } else { New-Object byte[] 0 }
			$header = New-TarHeaderBlock $entry.Name $content.Length $entry.TypeFlag
			$stream.Write($header, 0, 512)
			if ($content.Length -gt 0) {
				$padded = New-Object byte[] ([Math]::Ceiling($content.Length / 512.0) * 512)
				[Array]::Copy($content, $padded, $content.Length)
				$stream.Write($padded, 0, $padded.Length)
			}
		}
		$trailer = New-Object byte[] 1024
		$stream.Write($trailer, 0, 1024)
	} finally {
		$stream.Dispose()
	}
}

function New-SqlDumpFile([string] $Path, [string] $Prefix, [int] $TableCount, [string[]] $ExtraTables) {
	$lines = @('-- MySQL dump 10.13')
	for ($index = 1; $index -le $TableCount; $index++) {
		$lines += "CREATE TABLE ``$Prefix`table$index`` (id int);".Replace('`table', 'table')
	}
	foreach ($extra in $ExtraTables) { $lines += "CREATE TABLE ``$extra`` (id int);" }
	[IO.File]::WriteAllText($Path, ($lines -join "`n"), (New-Object Text.UTF8Encoding($false)))
}

Describe 'Pull configuration schema' {
	It 'keeps a push-only configuration valid without any pull key' {
		$config = $exampleConfiguration.Clone()
		foreach ($key in @('PullEnabled', 'LocalBackupDirectory', 'AllowedPullPaths', 'ExcludedPullPaths', 'RequirePullConfirmation', 'AllowDestructiveLocalReplace', 'LocalPhpPath', 'LocalWpCliPath', 'MysqlPath')) {
			$config.Remove($key)
		}
		@(Get-DeployConfigurationErrors $config).Count | Should Be 0
	}

	It 'accepts the example once pull is enabled' {
		@(Get-DeployConfigurationErrors (New-PullConfiguration)).Count | Should Be 0
	}

	It 'rejects the obsolete minimum pull table count setting' {
		$config = New-PullConfiguration
		$config.MinimumPullDbTableCount = 12
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'Unknown configuration key: MinimumPullDbTableCount'
	}

	It 'uses the dedicated full pull path list for pull-full' {
		$config = New-PullConfiguration
		$config.FullPullPaths = @('wp-admin', 'wp-content/uploads')
		$plan = New-PullPlan $config 'pull-full' '20260812-000000' (Join-Path ([IO.Path]::GetTempPath()) 'pull-plan-root') -DryRun
		$plan.PullPathSource | Should Be 'FullPullPaths'
		$plan.PullPaths | Should Be @('wp-admin', 'wp-content/uploads')
	}

	It 'uses the site-specific workspace and content/media pull classes' {
		$plan = New-PullPlan (New-PullConfiguration) 'pull-full' '20260812-000000' (Join-Path ([IO.Path]::GetTempPath()) 'multi-site-root') -DryRun -Confirmed
		$plan.Workspace | Should Match '\\.pull\\example-site\\20260812-000000$'
		$plan.PullPathSource | Should Be 'PullContentPaths+PullMediaPaths'
		$plan.PullPaths | Should Be @('wp-content/themes', 'wp-content/plugins', 'wp-content/mu-plugins', 'wp-content/uploads')
	}

	It 'creates and verifies a profile-bound pull manifest with artifact hashes' {
		$config = New-PullConfiguration
		$root = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
		$plan = New-PullPlan $config 'pull-full' '20260812-000000' $root -DryRun -Confirmed
		try {
		New-Item -ItemType Directory -Force -Path $plan.Workspace | Out-Null
		New-GzipFile $plan.LocalDbArchive ([Text.Encoding]::UTF8.GetBytes('database-artifact'))
		New-GzipFile $plan.LocalFilesArchive ([Text.Encoding]::UTF8.GetBytes('files-artifact'))
		Set-Content -LiteralPath $plan.LocalDbSql -Value 'CREATE TABLE `wp_posts` (id int);' -NoNewline
		New-Item -ItemType Directory -Force -Path (Join-Path $plan.FilesStagingDirectory 'wp-content/uploads') | Out-Null
		Set-Content -LiteralPath (Join-Path $plan.FilesStagingDirectory 'wp-content/uploads/marker.txt') -Value 'original' -NoNewline
		$null = New-PullManifest $config $plan $plan.ManifestPath
		(Assert-PullManifest $config $plan.ManifestPath $plan).SiteId | Should Be 'example-site'
		[IO.File]::AppendAllText($plan.LocalFilesArchive, 'tamper')
		(Get-ErrorMessage { Assert-PullManifest $config $plan.ManifestPath $plan }) | Should Match 'hash does not match'
		} finally {
			if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
		}
	}

	It 'refuses extracted SQL or files changed after the manifest was created' {
		$config = New-PullConfiguration
		$root = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
		$plan = New-PullPlan $config 'pull-full' '20260812-000000' $root -DryRun -Confirmed
		try {
			New-Item -ItemType Directory -Force -Path $plan.Workspace, (Join-Path $plan.FilesStagingDirectory 'wp-content/uploads') | Out-Null
			New-GzipFile $plan.LocalDbArchive ([Text.Encoding]::UTF8.GetBytes('database-archive'))
			New-GzipFile $plan.LocalFilesArchive ([Text.Encoding]::UTF8.GetBytes('files-archive'))
			Set-Content -LiteralPath $plan.LocalDbSql -Value 'CREATE TABLE `wp_posts` (id int);' -NoNewline
			Set-Content -LiteralPath (Join-Path $plan.FilesStagingDirectory 'wp-content/uploads/marker.txt') -Value 'original' -NoNewline
			$null = New-PullManifest $config $plan $plan.ManifestPath
			Add-Content -LiteralPath $plan.LocalDbSql -Value 'tamper'
			(Get-ErrorMessage { Assert-PullManifest $config $plan.ManifestPath $plan }) | Should Match 'Extracted pull database SQL hash does not match'
			Set-Content -LiteralPath $plan.LocalDbSql -Value 'CREATE TABLE `wp_posts` (id int);' -NoNewline
			Set-Content -LiteralPath (Join-Path $plan.FilesStagingDirectory 'wp-content/uploads/marker.txt') -Value 'tamper' -NoNewline
			(Get-ErrorMessage { Assert-PullManifest $config $plan.ManifestPath $plan }) | Should Match 'Extracted pull files hash does not match'
		} finally {
			if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
		}
	}

	It 'never schedules the newest complete local backup group for deletion' {
		$root = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
		try {
			New-Item -ItemType Directory -Force -Path $root | Out-Null
			foreach ($stamp in @('20260101-000000', '20260102-000000', '20260103-000000')) {
				Set-Content -LiteralPath (Join-Path $root "local-db-$stamp.sql") -Value $stamp -NoNewline
				New-Item -ItemType Directory -Force -Path (Join-Path $root "files-$stamp") | Out-Null
			}
			$plan = Get-LocalBackupRetentionPlan -BackupDirectory $root -Keep 1 -KeepDays 1 -MaxBytes 1 -Now ([datetime]'2026-02-01')
			(@($plan.Remove | ForEach-Object { $_.Stamp }) -contains '20260103-000000') | Should Be $false
			(@($plan.Kept | ForEach-Object { $_.Stamp }) -contains '20260103-000000') | Should Be $true
			$sizePlan = Get-LocalBackupRetentionPlan -BackupDirectory $root -Keep 3 -KeepDays 0 -MaxBytes 1 -Now ([datetime]'2026-01-04')
			(@($sizePlan.Remove | ForEach-Object { $_.Stamp }) -contains '20260103-000000') | Should Be $false
			(@($sizePlan.Kept | ForEach-Object { $_.Stamp }) -contains '20260103-000000') | Should Be $true
		} finally {
			if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
		}
	}

	It 'rejects a non-boolean pull switch' {
		$config = $exampleConfiguration.Clone()
		$config.PullEnabled = 'yes'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'PullEnabled must be a boolean'
	}

	It 'refuses a pull for production without the private opt-in' {
		$config = New-PullConfiguration
		$config.Environment = 'production'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'Production pull requires AllowProductionPull'
	}

	It 'accepts only an explicitly configured production pull profile' {
		$config = New-PullConfiguration
		$config.Environment = 'production'
		$config.AllowProductionPull = $true
		@(Get-DeployConfigurationErrors $config).Count | Should Be 0
		(Get-ErrorMessage { Assert-DeployModeAllowed -Environment 'production' -Mode 'pull-full' }) |
			Should Match 'requires the explicit -AllowProductionPull switch'
		Get-ErrorMessage { Assert-DeployModeAllowed -Environment 'production' -Mode 'pull-full' -AllowProductionPull } | Should Be ''
	}

	It 'does not allow the production opt-in on a non-production profile' {
		$config = New-PullConfiguration
		$config.AllowProductionPull = $true
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'may be true only for a production read-only pull profile'
	}

	It 'uses one working local database for a separately confirmed apply' {
		$config = New-PullConfiguration
		$config.Contains('LocalDatabaseTarget') | Should Be $false
		$plan = New-ApplyPullPlan $config (Join-Path ([IO.Path]::GetTempPath()) ".pull\$($config.SiteId)\20260812-000000") ([IO.Path]::GetTempPath()) -DryRun
		$plan.WorkingDatabase | Should Be $config.LocalDbName
	}

	It 'rejects the removed secondary local database setting' {
		$config = New-PullConfiguration
		$config.LocalDatabaseTarget = 'legacy_target'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'Unknown configuration key: LocalDatabaseTarget'
	}

	It 'requires every pull key once pull is enabled' {
		foreach ($key in @('LocalBackupDirectory', 'LocalPhpPath', 'LocalWpCliPath', 'MysqlPath', 'AllowedPullPaths')) {
			$config = New-PullConfiguration
			$config.Remove($key)
			(Get-DeployConfigurationErrors $config) -join "`n" |
				Should Match "Missing configuration value while PullEnabled is true: $key"
		}
	}

	It 'rejects unsafe, duplicate, and permanently excluded pull paths' {
		$config = New-PullConfiguration
		$config.AllowedPullPaths = @('../etc/passwd', 'C:\absolute', 'wp-content/uploads', 'WP-CONTENT/UPLOADS')
		$errors = (Get-DeployConfigurationErrors $config) -join "`n"
		$errors | Should Match 'Unsafe AllowedPullPaths value'
		$errors | Should Match 'Duplicate AllowedPullPaths value'

		$config = New-PullConfiguration
		$config.AllowedPullPaths = @('wp-config.php')
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'Unsafe AllowedPullPaths value'

		$config = New-PullConfiguration
		$config.AllowedPullPaths = @('wp-content/cache')
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'permanently excluded and cannot be pulled'
	}

	It 'requires the local backup directory to sit outside WordPress' {
		$config = New-PullConfiguration
		$config.LocalBackupDirectory = Join-Path $config.LocalWpPath 'backups'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'LocalBackupDirectory must be outside LocalWpPath'
	}

	It 'refuses destructive replacement without confirmation' {
		$config = New-PullConfiguration
		$config.AllowDestructiveLocalReplace = $true
		$config.RequirePullConfirmation = $false
		(Get-DeployConfigurationErrors $config) -join "`n" |
			Should Match 'AllowDestructiveLocalReplace requires RequirePullConfirmation to stay true'
	}
}

Describe 'Pull mode gating' {
	It 'requires the explicit switch for every production pull mode' {
		foreach ($mode in (Get-PullModeNames)) {
			$message = Get-ErrorMessage { Assert-DeployModeAllowed -Environment 'production' -Mode $mode }
			$message | Should Match 'requires the explicit -AllowProductionPull switch'
		}
	}

	It 'permits only the one-local-copy core policy' {
		$config = New-PullConfiguration
		$config.CorePolicy = 'download-matching'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'CorePolicy must be preserve-local-core'
	}

	It 'requires the production switch for local apply-pull' {
		(Get-ErrorMessage { Assert-DeployModeAllowed -Environment 'production' -Mode 'apply-pull' }) |
			Should Match 'requires the explicit -AllowProductionPull switch'
		Get-ErrorMessage { Assert-DeployModeAllowed -Environment 'production' -Mode 'apply-pull' -AllowProductionPull } | Should Be ''
	}

	It 'refuses a pull mode while pull is disabled' {
		$config = $exampleConfiguration.Clone()
		$config.PullEnabled = $false
		$message = Get-ErrorMessage { Assert-PullAllowed -Configuration $config -Mode 'pull-db' }
		$message | Should Match 'Pull is disabled'
	}

	It 'requires an exact remote pull table count' {
		$config = New-PullConfiguration
		$config.Remove('ExpectedPullDbTableCount')
		(Get-DeployConfigurationErrors $config) -join "`n" |
			Should Match 'Missing configuration value while PullEnabled is true: ExpectedPullDbTableCount'
	}

	It 'carries the exact pull table count into the plan instead of the push count' {
		$config = New-PullExactCountConfiguration
		# The two counts must stay different, otherwise a swapped source is undetectable.
		$config.ExpectedDbTableCount | Should Be 12
		$config.ExpectedPullDbTableCount | Should Be 17
		@(Get-DeployConfigurationErrors $config).Count | Should Be 0

		$plan = New-ExactCountPullPlan $config
		$plan.ExpectedTableCount | Should Be 17
		$plan.MinimumTableCount | Should Be 17
		$plan.ExpectedTableCount | Should Not Be $config.ExpectedDbTableCount
		$plan.MinimumTableCount | Should Not Be $config.ExpectedDbTableCount
	}

	It 'carries the exact pull table count into the apply-pull plan' {
		$config = New-PullExactCountConfiguration
		$workspaceRoot = Join-Path ([IO.Path]::GetTempPath()) ("apply-plan-root-" + [Guid]::NewGuid().ToString('N'))
		$workspace = Join-Path $workspaceRoot ".pull\$($config.SiteId)\20260812-000000"
		$applyPlan = New-ApplyPullPlan $config $workspace $workspaceRoot -DryRun
		$applyPlan.ExpectedTableCount | Should Be 17
		$applyPlan.MinimumTableCount | Should Be 17
		$applyPlan.ExpectedTableCount | Should Not Be $config.ExpectedDbTableCount
		$applyPlan.MinimumTableCount | Should Not Be $config.ExpectedDbTableCount

		$file = [IO.Path]::GetTempFileName()
		try {
			New-SqlDumpFile $file $applyPlan.ExpectedTablePrefix 17 @()
			@(Assert-SqlDumpTableSet $file $applyPlan.ExpectedTablePrefix $applyPlan.ExpectedTableCount -MinimumTableCount $applyPlan.MinimumTableCount).Count |
				Should Be 17
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'refuses a manifest whose exact table-count fields were mutated' {
		$config = New-PullExactCountConfiguration
		$root = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
		$plan = New-PullPlan $config 'pull-full' '20260812-000000' $root -DryRun -Confirmed
		try {
			New-Item -ItemType Directory -Force -Path $plan.Workspace, (Join-Path $plan.FilesStagingDirectory 'wp-content/uploads') | Out-Null
			New-GzipFile $plan.LocalDbArchive ([Text.Encoding]::UTF8.GetBytes('database-archive'))
			New-GzipFile $plan.LocalFilesArchive ([Text.Encoding]::UTF8.GetBytes('files-archive'))
			Set-Content -LiteralPath $plan.LocalDbSql -Value 'CREATE TABLE `wp_posts` (id int);' -NoNewline
			Set-Content -LiteralPath (Join-Path $plan.FilesStagingDirectory 'wp-content/uploads/marker.txt') -Value 'original' -NoNewline
			$manifest = New-PullManifest $config $plan $plan.ManifestPath

			$manifest.ExpectedDbTableCount = $config.ExpectedDbTableCount
			$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $plan.ManifestPath -Encoding UTF8
			(Get-ErrorMessage { Assert-PullManifest $config $plan.ManifestPath $plan }) |
				Should Match 'database table count does not match'

			$manifest.ExpectedDbTableCount = $plan.ExpectedTableCount
			$manifest.MinimumDbTableCount = $config.ExpectedDbTableCount
			$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $plan.ManifestPath -Encoding UTF8
			(Get-ErrorMessage { Assert-PullManifest $config $plan.ManifestPath $plan }) |
				Should Match 'database sanity threshold does not match'
		} finally {
			if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
		}
	}

	It 'accepts only the exact pulled table count and refuses one table less or more' {
		$config = New-PullExactCountConfiguration
		$plan = New-ExactCountPullPlan $config
		$file = [IO.Path]::GetTempFileName()
		try {
			New-SqlDumpFile $file $plan.ExpectedTablePrefix 17 @()
			@(Assert-SqlDumpTableSet $file $plan.ExpectedTablePrefix $plan.ExpectedTableCount -MinimumTableCount $plan.MinimumTableCount).Count |
				Should Be 17

			New-SqlDumpFile $file $plan.ExpectedTablePrefix 16 @()
			(Get-ErrorMessage { Assert-SqlDumpTableSet $file $plan.ExpectedTablePrefix $plan.ExpectedTableCount -MinimumTableCount $plan.MinimumTableCount }) |
				Should Match 'expected 17, found 16'

			New-SqlDumpFile $file $plan.ExpectedTablePrefix 18 @()
			(Get-ErrorMessage { Assert-SqlDumpTableSet $file $plan.ExpectedTablePrefix $plan.ExpectedTableCount -MinimumTableCount $plan.MinimumTableCount }) |
				Should Match 'expected 17, found 18'
		} finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
	}

	It 'refuses a pulled dump when only the exact count or only the internal minimum is mutated' {
		$config = New-PullExactCountConfiguration
		$plan = New-ExactCountPullPlan $config
		$file = [IO.Path]::GetTempFileName()
		try {
			# Mutation A: only ExpectedTableCount falls back to the push count. A correct pull must be refused.
			New-SqlDumpFile $file $plan.ExpectedTablePrefix 17 @()
			(Get-ErrorMessage { Assert-SqlDumpTableSet $file $plan.ExpectedTablePrefix $config.ExpectedDbTableCount -MinimumTableCount $plan.MinimumTableCount }) |
				Should Match 'expected 12, found 17'

			# Mutation B: only MinimumTableCount drops to the removed floor. It must not rescue a short dump.
			New-SqlDumpFile $file $plan.ExpectedTablePrefix 16 @()
			(Get-ErrorMessage { Assert-SqlDumpTableSet $file $plan.ExpectedTablePrefix $plan.ExpectedTableCount -MinimumTableCount 12 }) |
				Should Match 'expected 17, found 16'
		} finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
	}

	It 'keeps the push export count separate from the pull table count' {
		$config = New-PullExactCountConfiguration
		$file = [IO.Path]::GetTempFileName()
		try {
			# A pull-sized dump must not satisfy the push-side exact count.
			New-SqlDumpFile $file $config.ExpectedDbTablePrefix 17 @()
			(Get-ErrorMessage { Normalize-SqlDumpTablePrefix $file $config.ExpectedDbTablePrefix $config.ExpectedDbTableCount }) |
				Should Match 'expected 12, found 17'

			# A push-sized dump must not satisfy the pull-side exact count.
			New-SqlDumpFile $file $config.ExpectedDbTablePrefix 12 @()
			(Get-ErrorMessage { Assert-SqlDumpTableSet $file $config.ExpectedDbTablePrefix $config.ExpectedPullDbTableCount -MinimumTableCount $config.ExpectedPullDbTableCount }) |
				Should Match 'expected 17, found 12'
		} finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
	}

	It 'refuses pull-db and pull-full without confirmation' {
		foreach ($mode in @('pull-db', 'pull-full')) {
			$message = Get-ErrorMessage { Assert-PullAllowed -Configuration (New-PullConfiguration) -Mode $mode }
			$message | Should Match "Mode '$mode' writes to local data and requires -Confirm"
		}
	}

	It 'allows a confirmed pull-db and an unconfirmed dry run' {
		Get-ErrorMessage { Assert-PullAllowed -Configuration (New-PullConfiguration) -Mode 'pull-db' -Confirmed } | Should Be ''
		Get-ErrorMessage { Assert-PullAllowed -Configuration (New-PullConfiguration) -Mode 'pull-db' -DryRun } | Should Be ''
	}

	It 'allows additive pull-files without confirmation' {
		Get-ErrorMessage { Assert-PullAllowed -Configuration (New-PullConfiguration) -Mode 'pull-files' } | Should Be ''
	}

	It 'refuses mirror without the destructive switch and refuses to run it even with the switch' {
		$message = Get-ErrorMessage { Assert-PullAllowed -Configuration (New-PullConfiguration) -Mode 'pull-files' -Mirror -Confirmed }
		$message | Should Match 'Mirror pull requires AllowDestructiveLocalReplace'

		$config = New-PullConfiguration
		$config.AllowDestructiveLocalReplace = $true
		$message = Get-ErrorMessage { Assert-PullAllowed -Configuration $config -Mode 'pull-files' -Mirror -Confirmed }
		$message | Should Match 'Mirror pull is not implemented'
	}
}

Describe 'Pull path policy' {
	It 'rejects traversal, absolute, and secret paths' {
		foreach ($path in @('../etc/passwd', '/etc/passwd', 'C:\secrets', 'wp-config.php', 'wp-config.php.bak', '.git/config', '.env', 'wp-content/.ssh/id_ed25519', 'wp-content/uploads/backup.pem', 'wp-content/cache/x', 'node_modules/pkg')) {
			Test-PullPathAllowed $path | Should Be $false
		}
	}

	It 'accepts an ordinary content path' {
		Test-PullPathAllowed 'wp-content/uploads' | Should Be $true
		Test-PullPathAllowed 'wp-content/uploads/2026/01/image.jpg' | Should Be $true
	}

	It 'honours configured exclusions' {
		Test-PullPathAllowed 'wp-content/uploads/private/secret.txt' -ExcludedPaths @('wp-content/uploads/private') | Should Be $false
		Test-PullPathAllowed 'wp-content/uploads/public/ok.txt' -ExcludedPaths @('wp-content/uploads/private') | Should Be $true
	}
}

Describe 'Pull artifact verification' {
	It 'accepts a valid gzip artifact and reports its expanded size' {
		$file = [IO.Path]::GetTempFileName()
		try {
			New-GzipFile $file ([Text.Encoding]::ASCII.GetBytes('x' * 4096))
			(Assert-GzipFile $file) | Should Be 4096
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'rejects a file that is not gzip' {
		$file = [IO.Path]::GetTempFileName()
		try {
			[IO.File]::WriteAllBytes($file, [Text.Encoding]::ASCII.GetBytes('x' * 512))
			(Get-ErrorMessage { Assert-GzipFile $file }) | Should Match 'not a deflate gzip stream'
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'rejects a truncated gzip artifact' {
		$file = [IO.Path]::GetTempFileName()
		try {
			# Random content stays incompressible, so the truncated archive is still large
			# enough to reach the integrity check rather than the minimum-size guard.
			$payload = New-Object byte[] 65536
			(New-Object Random 20260812).NextBytes($payload)
			New-GzipFile $file $payload
			$bytes = [IO.File]::ReadAllBytes($file)
			[IO.File]::WriteAllBytes($file, $bytes[0..([int]($bytes.Length / 2))])
			(Get-ErrorMessage { Assert-GzipFile $file }) | Should Match 'gzip integrity check'
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'expands a gzip artifact byte-for-byte' {
		$source = [IO.Path]::GetTempFileName()
		$target = [IO.Path]::GetTempFileName()
		try {
			$payload = [Text.Encoding]::ASCII.GetBytes('-- MySQL dump 10.13' + "`n" + 'CREATE TABLE `wp_x` (id int);')
			New-GzipFile $source $payload
			Expand-GzipFile $source $target
			[Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) | Should Be ([Convert]::ToBase64String($payload))
		} finally {
			Remove-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
			Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
		}
	}

	It 'accepts a dump whose table set matches exactly' {
		$file = [IO.Path]::GetTempFileName()
		try {
			New-SqlDumpFile $file 'wp_' 12 @()
			@(Assert-SqlDumpTableSet $file 'wp_' 12).Count | Should Be 12
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'rejects a wrong table count, a foreign prefix, and a mixed-case prefix' {
		$file = [IO.Path]::GetTempFileName()
		try {
			New-SqlDumpFile $file 'wp_' 11 @()
			(Get-ErrorMessage { Assert-SqlDumpTableSet $file 'wp_' 12 }) | Should Match 'table count mismatch'

			New-SqlDumpFile $file 'wp_' 11 @('other_table')
			(Get-ErrorMessage { Assert-SqlDumpTableSet $file 'wp_' 12 }) | Should Match 'unexpected table identifiers'

			New-SqlDumpFile $file 'zxqrtvwy_' 12 @()
			(Get-ErrorMessage { Assert-SqlDumpTableSet $file 'zxQrTvWy_' 12 }) | Should Match 'unexpected table identifiers'
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}
}

Describe 'Pull archive listing safety' {
	It 'keeps UTF-8 names from ordinary tar headers' {
		$file = [IO.Path]::GetTempFileName()
		try {
			$unicodeName = 'wp-content/uploads/' + ([string] [char]0x444) + [char]0x43e + [char]0x442 + [char]0x43e + '.png'
			New-TarFile $file @(@{ Name = $unicodeName; TypeFlag = '0'; Content = 'x' })
			(Get-TarEntryList $file)[0].Name | Should Be $unicodeName
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'lists ordinary entries with their sizes' {
		$file = [IO.Path]::GetTempFileName()
		try {
			New-TarFile $file @(
				@{ Name = 'wp-content/uploads/'; TypeFlag = '5'; Content = '' },
				@{ Name = 'wp-content/uploads/a.txt'; TypeFlag = '0'; Content = 'hello' }
			)
			$entries = @(Get-TarEntryList $file)
			$entries.Count | Should Be 2
			($entries | Where-Object { $_.Name -eq 'wp-content/uploads/a.txt' }).Size | Should Be 5
			(Assert-PullArchiveEntries $entries @('wp-content/uploads')) | Should Be 2
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'rejects traversal, absolute, symlink, excluded, and out-of-scope entries' {
		$cases = @(
			@{ Entry = @{ Name = 'wp-content/uploads/../../etc/passwd'; TypeFlag = '0'; Content = 'x' }; Match = 'not allowed to be pulled' },
			@{ Entry = @{ Name = '/etc/passwd'; TypeFlag = '0'; Content = 'x' }; Match = 'not allowed to be pulled' },
			@{ Entry = @{ Name = 'wp-content/uploads/link'; TypeFlag = '2'; Content = '' }; Match = 'unsupported entry type' },
			@{ Entry = @{ Name = 'wp-config.php'; TypeFlag = '0'; Content = 'x' }; Match = 'not allowed to be pulled' },
			@{ Entry = @{ Name = 'wp-content/themes/other.txt'; TypeFlag = '0'; Content = 'x' }; Match = 'outside AllowedPullPaths' }
		)
		foreach ($case in $cases) {
			$file = [IO.Path]::GetTempFileName()
			try {
				New-TarFile $file @($case.Entry)
				$entries = @(Get-TarEntryList $file)
				(Get-ErrorMessage { Assert-PullArchiveEntries $entries @('wp-content/uploads') }) | Should Match $case.Match
			} finally {
				Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
			}
		}
	}

	It 'rejects an entry excluded by configuration' {
		$file = [IO.Path]::GetTempFileName()
		try {
			New-TarFile $file @(@{ Name = 'wp-content/uploads/private/key.txt'; TypeFlag = '0'; Content = 'x' })
			$entries = @(Get-TarEntryList $file)
			(Get-ErrorMessage { Assert-PullArchiveEntries $entries @('wp-content/uploads') -ExcludedPaths @('wp-content/uploads/private') }) |
				Should Match 'not allowed to be pulled'
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'rejects an empty archive' {
		(Get-ErrorMessage { Assert-PullArchiveEntries @() @('wp-content/uploads') }) | Should Match 'contains no entries'
	}
}

Describe 'Remote pull command' {
	It 'quotes every value and carries the pull mode' {
		$command = New-RemotePullCommand (New-PullConfiguration) 'pull-files' '/srv/tmp/example-deploy/pull-files-1.tar.gz' @('wp-content/uploads')
		$command | Should Match "DEPLOY_MODE='pull-files'"
		$command | Should Match "PULL_ARTIFACT='/srv/tmp/example-deploy/pull-files-1.tar.gz'"
		$command | Should Match "PULL_PATHS='wp-content/uploads'"
		$command | Should Match "SQL_FILE=''"
	}

	It 'refuses an unsafe artifact path and an excluded pull path' {
		$config = New-PullConfiguration
		(Get-ErrorMessage { New-RemotePullCommand $config 'pull-db' '/srv/tmp/../etc/artifact.gz' }) |
			Should Match 'Pull artifact path must be'
		(Get-ErrorMessage { New-RemotePullCommand $config 'pull-files' '/srv/tmp/example-deploy/a.tar.gz' @('wp-config.php') }) |
			Should Match 'Pull path is not allowed'
		(Get-ErrorMessage { New-RemotePullCommand $config 'pull-files' '/srv/tmp/example-deploy/a.tar.gz' @() }) |
			Should Match 'requires at least one allowed path'
	}
}

Describe 'Pull plan' {
	$workspaceRoot = Join-Path ([IO.Path]::GetTempPath()) 'pull-plan-root'

	It 'builds a plan for every pull mode without touching the disk' {
		foreach ($mode in (Get-PullModeNames)) {
			$plan = New-PullPlan (New-PullConfiguration) $mode '20260812-000000' $workspaceRoot -DryRun
			$plan.Mode | Should Be $mode
			$plan.IsDryRun | Should Be $true
			(Test-Path -LiteralPath $plan.Workspace) | Should Be $false
		}
		(Test-Path -LiteralPath $workspaceRoot) | Should Be $false
	}

	It 'selects artifacts that match the mode' {
		$db = New-PullPlan (New-PullConfiguration) 'pull-db' '20260812-000000' $workspaceRoot -Confirmed
		$db.IncludeDatabase | Should Be $true
		$db.IncludeFiles | Should Be $false
		$db.FilesStagingDirectory | Should Be ''

		$files = New-PullPlan (New-PullConfiguration) 'pull-files' '20260812-000000' $workspaceRoot
		$files.IncludeDatabase | Should Be $false
		(@($files.PSObject.Properties.Name) -contains 'DatabaseTarget') | Should Be $false
		$files.RemoteDbArtifact | Should Be ''

		$full = New-PullPlan (New-PullConfiguration) 'pull-full' '20260812-000000' $workspaceRoot -Confirmed
		$full.IncludeDatabase | Should Be $true
		$full.IncludeFiles | Should Be $true
	}

	It 'keeps download side-by-side and reserves the working local database for apply' {
		$plan = New-PullPlan (New-PullConfiguration) 'pull-full' '20260812-000000' $workspaceRoot -Confirmed
		$plan.WorkingDatabase | Should Be 'wordpress'
		(@($plan.PSObject.Properties.Name) -contains 'DatabaseTarget') | Should Be $false
	}

	It 'keeps the workspace outside the working WordPress copy' {
		$config = New-PullConfiguration
		$plan = New-PullPlan $config 'pull-files' '20260812-000000' $workspaceRoot
		$plan.Workspace.StartsWith($config.LocalWpPath, [StringComparison]::OrdinalIgnoreCase) | Should Be $false

		(Get-ErrorMessage { New-PullPlan $config 'pull-files' '20260812-000000' (Join-Path $config.LocalWpPath 'work') }) |
			Should Match 'Pull workspace must be outside LocalWpPath'
	}

	It 'applies exclusions and refuses a plan with nothing left to pull' {
		$config = New-PullConfiguration
		$config.ExcludedPullPaths = @('wp-content/uploads')
		(Get-ErrorMessage { New-PullPlan $config 'pull-files' '20260812-000000' $workspaceRoot }) |
			Should Match 'No pull path survived the exclusion rules'
	}

	It 'enforces confirmation, mirror, and production rules before any path is resolved' {
		(Get-ErrorMessage { New-PullPlan (New-PullConfiguration) 'pull-db' '20260812-000000' $workspaceRoot }) |
			Should Match 'requires -Confirm'

		$config = New-PullConfiguration
		$config.AllowDestructiveLocalReplace = $true
		(Get-ErrorMessage { New-PullPlan $config 'pull-files' '20260812-000000' $workspaceRoot -Mirror -Confirmed }) |
			Should Match 'Mirror pull is not implemented'

		$config = New-PullConfiguration
		$config.Environment = 'production'
		(Get-ErrorMessage { New-PullPlan $config 'pull-db' '20260812-000000' $workspaceRoot -Confirmed }) |
			Should Match 'requires the explicit -AllowProductionPull switch'
	}

	It 'rejects an unsafe run stamp' {
		(Get-ErrorMessage { New-PullPlan (New-PullConfiguration) 'pull-files' '../escape' $workspaceRoot }) |
			Should Match 'stamp contains unsupported characters'
	}

	It 'summarises download and one-local-copy apply boundaries' {
		$summary = (Get-PullSummaryLines (New-PullPlan (New-PullConfiguration) 'pull-full' '20260812-000000' $workspaceRoot -Confirmed)) -join "`n"
		$summary | Should Match 'never written by download'
		$summary | Should Match 'replaced only by a separate confirmed apply after backup'
		$summary | Should Match 'working files untouched'
	}
}

Describe 'Pull archive extraction' {
	It 'extracts verified entries into the staging directory only' {
		$archive = [IO.Path]::GetTempFileName()
		$destination = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
		try {
			New-Item -ItemType Directory -Force -Path $destination | Out-Null
			New-TarFile $archive @(
				@{ Name = 'wp-content/uploads/'; TypeFlag = '5'; Content = '' },
				@{ Name = 'wp-content/uploads/a.txt'; TypeFlag = '0'; Content = 'hello' }
			)
			(Expand-TarArchive $archive $destination) | Should Be 1
			$extracted = Join-Path $destination 'wp-content\uploads\a.txt'
			(Test-Path -LiteralPath $extracted) | Should Be $true
			[IO.File]::ReadAllText($extracted) | Should Be 'hello'
		} finally {
			Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
			Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
		}
	}

	It 'refuses traversal and symlink entries even when validation was skipped' {
		foreach ($entry in @(
			@{ Entry = @{ Name = '../escaped.txt'; TypeFlag = '0'; Content = 'x' }; Match = 'resolves outside the extraction directory' },
			@{ Entry = @{ Name = 'wp-content/uploads/link'; TypeFlag = '2'; Content = '' }; Match = 'unsupported entry type' }
		)) {
			$archive = [IO.Path]::GetTempFileName()
			$destination = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
			try {
				New-Item -ItemType Directory -Force -Path $destination | Out-Null
				New-TarFile $archive @($entry.Entry)
				(Get-ErrorMessage { Expand-TarArchive $archive $destination }) | Should Match $entry.Match
				@(Get-ChildItem -LiteralPath $destination -Recurse -File).Count | Should Be 0
			} finally {
				Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
				Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
			}
		}
	}
}

Describe 'deploy.ps1 pull wiring' {
	$deployScript = Join-Path $repoRoot 'deploy.ps1'
	$deploy = Get-Content $deployScript -Raw
	$tokens = $null
	$parseErrors = $null
	$ast = [System.Management.Automation.Language.Parser]::ParseFile($deployScript, [ref] $tokens, [ref] $parseErrors)

	It 'parses without errors' {
		@($parseErrors).Count | Should Be 0
	}

	It 'offers the pull modes and keeps every push mode' {
		$modeParameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' }
		$validate = $modeParameter.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
		$values = @($validate.PositionalArguments | ForEach-Object { $_.Value })
		foreach ($mode in @('code', 'db', 'full', 'pull-db', 'pull-files', 'pull-full', 'apply-pull')) {
			$values -contains $mode | Should Be $true
		}
	}

	It 'declares the pull switches' {
		$names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
		foreach ($switch in @('DryRun', 'Confirm', 'Mirror', 'ReplaceProtected', 'ConfirmProtected', 'PullWorkspace', 'ConfigPath')) {
			$names -contains $switch | Should Be $true
		}
	}

	It 'requires an explicit config and supports a separate site config path' {
		$deploy | Should Match 'Explicit -ConfigPath is required'
		$deploy | Should Match 'Join-Path'
		$deploy | Should Match 'IsPathRooted'
		$deploy | Should Match 'Configuration file was not found'
	}

	It 'resolves GNU long-name metadata without treating it as a file entry' {
		$file = [IO.Path]::GetTempFileName()
		$destination = Join-Path ([IO.Path]::GetTempPath()) ('pull-long-name-' + [guid]::NewGuid().ToString('N'))
		$longName = 'wp-content/uploads/' + ('nested-' * 18) + 'asset.txt'
		try {
			New-TarFile $file @(
				@{ Name = '././@LongLink'; TypeFlag = 'L'; Content = $longName + [char] 0 },
				@{ Name = 'truncated'; TypeFlag = '0'; Content = 'hello' }
			)
			$entries = @(Get-TarEntryList $file)
			$entries.Count | Should Be 1
			$entries[0].Name | Should Be $longName
			(Assert-PullArchiveEntries $entries @('wp-content/uploads')) | Should Be 1

			New-Item -ItemType Directory -Path $destination | Out-Null
			(Expand-TarArchive $file $destination) | Should Be 1
			(Get-Content -LiteralPath (Join-Path $destination ($longName -replace '/', '\')) -Raw) | Should Be 'hello'
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
			Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
		}
	}

	It 'requires a paired protected replacement confirmation' {
		$deploy | Should Match 'Protected replacement requires both -ReplaceProtected and -ConfirmProtected'
		$deploy | Should Match 'ConfirmProtected requires -ReplaceProtected'
	}

	It 'refuses pull switches for push modes and push switches for pull modes' {
		$deploy | Should Match '-DryRun, -Confirm, and -Mirror apply only to pull modes'
		$deploy | Should Match '-SkipGit, -SkipUploads, and -PreflightOnly apply only to push modes'
	}

	It 'gates the pull before the first remote call and returns on a dry run' {
		$planIndex = $deploy.IndexOf('New-PullPlan -Configuration')
		$dryRunIndex = $deploy.IndexOf('Dry run: nothing was downloaded')
		$firstSsh = $deploy.IndexOf("Invoke-CheckedCommand 'ssh' (`$sshArgs + @(`$target, (New-RemotePullCommand")
		$planIndex | Should BeGreaterThan 0
		$firstSsh | Should BeGreaterThan $planIndex
		$dryRunIndex | Should BeGreaterThan $planIndex
		$firstSsh | Should BeGreaterThan $dryRunIndex
	}

	It 'verifies every downloaded artifact before it is used' {
		$pullBlock = [regex]::Match($deploy, '(?s)if \(\$isPull\) \{.*?\r?\n\treturn\r?\n\}').Value
		$pullBlock | Should Not BeNullOrEmpty
		$pullBlock | Should Match 'Assert-GzipFile'
		$pullBlock | Should Match 'Expand-GzipFile'
		$pullBlock | Should Match 'Assert-SqlDumpFile'
		$pullBlock | Should Match 'Assert-SqlDumpTableSet'
		$pullBlock | Should Match 'Assert-PullArchiveEntries \(Get-TarEntryList'
		$pullBlock.IndexOf('Assert-PullArchiveEntries') | Should BeLessThan $pullBlock.IndexOf('Expand-TarArchive')
	}

	It 'never writes to the working local database and never imports SQL' {
		$pullBlock = [regex]::Match($deploy, '(?s)if \(\$isPull\) \{.*?\r?\n\treturn\r?\n\}').Value
		$pullBlock | Should Not BeNullOrEmpty
		$pullBlock | Should Not Match 'LocalDbName'
		$pullBlock | Should Not Match 'MysqlPath'
		$pullBlock | Should Not Match 'mysql'
		$pullBlock | Should Match 'working local site was not replaced'
	}

	It 'stages files instead of replacing the working copy' {
		$pullBlock = [regex]::Match($deploy, '(?s)if \(\$isPull\) \{.*?\r?\n\treturn\r?\n\}').Value
		$pullBlock | Should Not BeNullOrEmpty
		$pullBlock | Should Match 'Expand-TarArchive \$tarPath \$plan\.FilesStagingDirectory'
		$pullBlock | Should Not Match 'LocalUploadsPath'
		$pullBlock | Should Not Match 'Remove-Item -LiteralPath \$DeployConfig'
	}

	It 'cleans up only what the run created and rolls nothing back' {
		$pullBlock = [regex]::Match($deploy, '(?s)if \(\$isPull\) \{.*?\r?\n\treturn\r?\n\}').Value
		$pullBlock | Should Not BeNullOrEmpty
		$pullBlock | Should Match '\} finally \{'
		$pullBlock | Should Match 'foreach \(\$file in \$createdTransferFiles\)'
		$pullBlock | Should Match 'foreach \(\$artifact in \$createdRemoteArtifacts\)'
		$pullBlock | Should Match 'nothing was rolled back automatically'
		$pullBlock | Should Not Match 'Remove-Item -LiteralPath \$plan\.Workspace'
	}

	It 'keeps the push pipeline untouched' {
		$deploy | Should Match "Assert-DeployModeAllowed -Environment \`$DeployConfig\.Environment -Mode \`$Mode"
		$deploy | Should Match 'Automatic Git commit/push was removed'
		$deploy | Should Match '-SkipGit is supported only for db mode'
		$deploy | Should Match "Normalize-SqlDumpTablePrefix \`$sqlPath"
		$deploy | Should Match 'Deploy completed:'
	}

	It 'applies every configured pull path with a local backup before replacement' {
		$applyBlock = [regex]::Match($deploy, '(?s)if \(\$isApplyPull\) \{.*?\r?\n\treturn\r?\n\}').Value
		$applyBlock | Should Match 'Invoke-LocalMysqlDump \$dbBackup'
		$applyBlock | Should Match 'Invoke-LocalMysqlDump \$dbBackup \$plan\.WorkingDatabase'
		$applyBlock | Should Match 'Invoke-LocalMysqlImport \$plan\.DatabaseSql \$plan\.WorkingDatabase'
		$applyBlock | Should Match 'Invoke-LocalMysqlImport \$dbBackup \$plan\.WorkingDatabase'
		$deploy | Should Match '\(\x27--result-file=\x27 \+ \$Path\)'
		$applyBlock | Should Match 'foreach \(\$relative in @\(\$plan\.PullPaths\)\)'
		$applyBlock | Should Match 'Pulled path is missing from the verified workspace'
		$applyBlock | Should Match 'attempting to restore the local database and pulled paths backup'
		$applyBlock | Should Match 'dbImportStarted'
		$applyBlock | Should Match "config', 'get', 'table_prefix'"
		$applyBlock | Should Match 'Local WordPress table prefix does not match ExpectedDbTablePrefix'
		$applyBlock | Should Not Match 'Invoke-WithRollback'
		$applyBlock | Should Match 'No rollback is attempted after a successful apply'
		$applyBlock | Should Match 'Assert-PreservedLocalCore'
		$applyBlock | Should Not Match 'LocalCorePath'
		$deploy | Should Match "Invoke-LocalWpCli @\('core', 'version'\)"
	}

	It 'builds a safe apply-pull plan under .pull' {
		$config = New-PullConfiguration
		$workspaceRoot = Join-Path ([IO.Path]::GetTempPath()) 'apply-plan-root'
		$plan = New-ApplyPullPlan $config (Join-Path $workspaceRoot ".pull\$($config.SiteId)\20260812-000000") $workspaceRoot -DryRun
		$plan.Mode | Should Be 'apply-pull'
		$plan.WorkingDatabase | Should Be $config.LocalDbName
		(Get-ErrorMessage { New-ApplyPullPlan $config (Join-Path $config.LocalWpPath 'x') $workspaceRoot -DryRun }) |
			Should Match 'outside LocalWpPath'
	}

	It 'streams SQL input as unchanged bytes to a native process' {
		$root = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
		$consumer = Join-Path $root 'read-stdin.ps1'
		$input = Join-Path $root 'input.sql'
		$output = Join-Path $root 'output.bin'
		$previousInputEncoding = [Console]::InputEncoding
		try {
			New-Item -ItemType Directory -Force -Path $root | Out-Null
			[IO.File]::WriteAllText($consumer, '$bytes = New-Object byte[] 4096; $stream = [Console]::OpenStandardInput(); $count = $stream.Read($bytes, 0, $bytes.Length); [IO.File]::WriteAllBytes($args[0], [byte[]] $bytes[0..($count - 1)])', (New-Object Text.UTF8Encoding($false)))
			$expected = [byte[]] @(0, 0xA9, 0xFF, 0x0A, 0x00, 0x7F)
			[IO.File]::WriteAllBytes($input, $expected)
			[Console]::InputEncoding = New-Object Text.UTF8Encoding($true)
			Invoke-NativeProcessWithFileInput (Get-Command powershell.exe).Source @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $consumer, $output) $input | Out-Null
			[BitConverter]::ToString([IO.File]::ReadAllBytes($output)) | Should Be ([BitConverter]::ToString($expected))
		} finally {
			[Console]::InputEncoding = $previousInputEncoding
			Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
		}
	}

	It 'uses ordinal comparison for the local WordPress table prefix' {
		$script = Get-Content -LiteralPath (Join-Path $repoRoot 'deploy.ps1') -Raw
		$script | Should Match 'StringComparison\]::Ordinal'
		$script | Should Not Match '\$localPrefix\s+-ne\s+\[string\]'
	}

	It 'restores file swaps in reverse order without Select-Object Reverse' {
		$root = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
		try {
			New-Item -ItemType Directory -Force -Path $root | Out-Null
			$first = Join-Path $root 'first.txt'; $second = Join-Path $root 'second.txt'
			$firstOld = Join-Path $root 'first.old'; $secondOld = Join-Path $root 'second.old'
			Set-Content -LiteralPath $first -Value 'new-first'; Set-Content -LiteralPath $second -Value 'new-second'
			Set-Content -LiteralPath $firstOld -Value 'old-first'; Set-Content -LiteralPath $secondOld -Value 'old-second'
			$swaps = @(
				[pscustomobject] @{ Target = $first; Old = $firstOld; HadTarget = $true },
				[pscustomobject] @{ Target = $second; Old = $secondOld; HadTarget = $true }
			)
			Restore-FileSwaps $swaps
			(Get-Content $first -Raw).Trim() | Should Be 'old-first'
			(Get-Content $second -Raw).Trim() | Should Be 'old-second'
		} finally {
			Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
		}
	}

	It 'revalidates the staged files before apply' {
		$root = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
		$files = Join-Path $root 'files'
		try {
			New-Item -ItemType Directory -Force -Path (Join-Path $files 'wp-content/uploads') | Out-Null
			Set-Content -LiteralPath (Join-Path $files 'wp-content/uploads/marker.txt') -Value 'ok'
			{ Assert-ApplyPullWorkspace $files @('wp-content/uploads') } | Should Not Throw
			(Get-ErrorMessage { Assert-ApplyPullWorkspace $files @('wp-content/themes') }) | Should Match 'missing'
		} finally {
			Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
		}
	}

	It 'does not use the Windows PowerShell 5.1 reverse pipeline for apply rollback' {
		$deploy | Should Not Match 'Select-Object -Reverse'
		$deploy | Should Match 'Restore-FileSwaps \$fileSwaps'
		$deploy | Should Match '\$fileSwaps\.Count -gt 0'
		$deploy | Should Match 'dbBackupReady'
	}
}

Describe 'Pull tests never reach a server' {
	It 'invokes no command that could reach a server or a database' {
		# Checked through the syntax tree rather than the raw text, so a command name that
		# only appears inside a string assertion cannot be mistaken for a real call.
		$suitePath = Join-Path $repoRoot 'tests\pull.Tests.ps1'
		$suiteTokens = $null
		$suiteErrors = $null
		$suiteAst = [System.Management.Automation.Language.Parser]::ParseFile($suitePath, [ref] $suiteTokens, [ref] $suiteErrors)
		$commands = @($suiteAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
			ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
		foreach ($forbidden in @('ssh', 'scp', 'mysql', 'mysqldump', 'Invoke-CheckedCommand', 'Invoke-CommandOutput', 'Start-Process')) {
			($commands -contains $forbidden) | Should Be $false
		}
	}
}

Describe 'Remote runner pull safety' {
	$runner = Get-Content (Join-Path $repoRoot 'server-deploy.sh') -Raw

	It 'accepts the pull modes and refuses them for production' {
		$runner | Should Match 'preflight\|code\|db\|full\|pull-db\|pull-files'
		$runner | Should Match 'Production pull requires explicit read-only opt-in'
	}

	It 'never imports, rotates backups, or rewrites WordPress while pulling' {
		$pullSection = [regex]::Match($runner, '(?s)\tpull-db\).*?esac').Value
		$pullSection | Should Not Match 'import_database'
		$pullSection | Should Not Match 'cleanup_backups'
		$pullSection | Should Not Match 'cleanup_wordpress'
		$pullSection | Should Match 'export_database_for_pull'
		$pullSection | Should Match 'export_files_for_pull'
	}

	It 'validates the pull artifact path and the requested pull paths' {
		$runner | Should Match 'assert_temp_file "\$PULL_ARTIFACT" PULL_ARTIFACT'
		$runner | Should Match 'assert_pull_path'
		$runner | Should Match 'gzip -t "\$PULL_ARTIFACT"'
	}

	It 'keeps the pull export read-only for the WordPress database' {
		$exportSection = [regex]::Match($runner, '(?s)export_database_for_pull\(\).*?\n\}').Value
		$exportSection | Should Match 'backup_database_for_pull'
		$exportSection | Should Not Match '(?m)^\s*backup_database\s*$'
		$exportSection | Should Match 'assert_sql_dump_table_prefix'
		$exportSection | Should Not Match 'mysql_import_file'
		$exportSection | Should Not Match 'rm -f'
	}

	It 'restricts pull SQL export to the active prefix table list' {
		$pullBackup = [regex]::Match($runner, '(?s)backup_database_for_pull\(\).*?\n\}').Value
		$pullBackup | Should Match 'db tables --all-tables-with-prefix --format=csv'
		$pullBackup | Should Match 'SERVER_EXPECTED_DB_TABLE_PREFIX'
		$pullBackup | Should Match 'wp_cli db export'
		$pullBackup | Should Match '--tables="\$table_list"'
		$pullBackup | Should Not Match 'mysqldump'
		$pullBackup | Should Match 'unsafe identifier'
	}

	It 'requires a separately approved protected archive and backs up before replacement' {
		$runner | Should Match 'PROTECTED_ARCHIVE'
		$runner | Should Match 'stage_protected_files'
		$runner | Should Match 'PROTECTED_BACKUP_READY'
		$runner | Should Match 'Protected replacement requires explicit confirmation'
	}

	It 'checks both ordinary and full path lists against server policy' {
		$runner | Should Match '\[ "\$SYNC_PATHS" = "\$SERVER_SYNC_PATHS" \]'
		$runner | Should Match '\[ "\$FULL_SYNC_PATHS" = "\$SERVER_FULL_SYNC_PATHS" \]'
		$runner | Should Match 'ACTIVE_SYNC_PATHS'
	}

	It 'never permits protected paths through ordinary sync' {
		$runner | Should Match 'Protected path is not allowed in ordinary sync paths'
	}

	It 'replaces protected files only after database import' {
		$importIndex = $runner.IndexOf("`n`t`timport_database`n")
		$protectedIndex = $runner.LastIndexOf('copy_protected_files')
		$cleanupIndex = $runner.IndexOf("`n`t`tcleanup_wordpress`n")
		$importIndex | Should BeGreaterThan -1
		$cleanupIndex | Should BeGreaterThan $importIndex
		$protectedIndex | Should BeGreaterThan $importIndex
		$protectedIndex | Should BeGreaterThan $cleanupIndex
	}
}
