$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repoRoot 'src\WordPressSshDeploy.psm1') -Force
. (Join-Path $repoRoot 'deploy.config.example.ps1')
$exampleConfiguration = $DeployConfig

function New-PullConfiguration {
	$config = $exampleConfiguration.Clone()
	$config.PullEnabled = $true
	return $config
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
	$nameBytes = $ascii.GetBytes($Name)
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
		foreach ($key in @('PullEnabled', 'LocalDatabaseTarget', 'LocalBackupDirectory', 'AllowedPullPaths', 'ExcludedPullPaths', 'RequirePullConfirmation', 'AllowDestructiveLocalReplace', 'LocalPhpPath', 'LocalWpCliPath', 'MysqlPath')) {
			$config.Remove($key)
		}
		@(Get-DeployConfigurationErrors $config).Count | Should Be 0
	}

	It 'accepts the example once pull is enabled' {
		@(Get-DeployConfigurationErrors (New-PullConfiguration)).Count | Should Be 0
	}

	It 'rejects a non-boolean pull switch' {
		$config = $exampleConfiguration.Clone()
		$config.PullEnabled = 'yes'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'PullEnabled must be a boolean'
	}

	It 'refuses pull for production' {
		$config = New-PullConfiguration
		$config.Environment = 'production'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'PullEnabled must be false for production'
	}

	It 'refuses a pull target equal to the working local database' {
		$config = New-PullConfiguration
		$config.LocalDatabaseTarget = $config.LocalDbName
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'LocalDatabaseTarget must differ from LocalDbName'
	}

	It 'requires every pull key once pull is enabled' {
		foreach ($key in @('LocalDatabaseTarget', 'LocalBackupDirectory', 'LocalPhpPath', 'LocalWpCliPath', 'MysqlPath', 'AllowedPullPaths')) {
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
	It 'forbids every pull mode for production' {
		foreach ($mode in (Get-PullModeNames)) {
			$message = Get-ErrorMessage { Assert-DeployModeAllowed -Environment 'production' -Mode $mode }
			$message | Should Match 'Pulling from production is never allowed'
		}
	}

	It 'refuses a pull mode while pull is disabled' {
		$config = $exampleConfiguration.Clone()
		$config.PullEnabled = $false
		$message = Get-ErrorMessage { Assert-PullAllowed -Configuration $config -Mode 'pull-db' }
		$message | Should Match 'Pull is disabled'
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
		$files.DatabaseTarget | Should Be ''
		$files.RemoteDbArtifact | Should Be ''

		$full = New-PullPlan (New-PullConfiguration) 'pull-full' '20260812-000000' $workspaceRoot -Confirmed
		$full.IncludeDatabase | Should Be $true
		$full.IncludeFiles | Should Be $true
	}

	It 'never targets the working local database' {
		$plan = New-PullPlan (New-PullConfiguration) 'pull-full' '20260812-000000' $workspaceRoot -Confirmed
		$plan.DatabaseTarget | Should Not Be $plan.WorkingDatabase
		$plan.DatabaseTarget | Should Be 'wordpress_pulled'
		$plan.WorkingDatabase | Should Be 'wordpress'
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
			Should Match 'Pulling from production is never allowed'
	}

	It 'rejects an unsafe run stamp' {
		(Get-ErrorMessage { New-PullPlan (New-PullConfiguration) 'pull-files' '../escape' $workspaceRoot }) |
			Should Match 'stamp contains unsupported characters'
	}

	It 'summarises the plan without leaking the working database as a target' {
		$summary = (Get-PullSummaryLines (New-PullPlan (New-PullConfiguration) 'pull-full' '20260812-000000' $workspaceRoot -Confirmed)) -join "`n"
		$summary | Should Match 'never written by pull'
		$summary | Should Match 'prepared side-by-side, not activated'
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
		foreach ($mode in @('code', 'db', 'full', 'pull-db', 'pull-files', 'pull-full')) {
			$values -contains $mode | Should Be $true
		}
	}

	It 'declares the pull switches' {
		$names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
		foreach ($switch in @('DryRun', 'Confirm', 'Mirror')) {
			$names -contains $switch | Should Be $true
		}
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
		$runner | Should Match 'Pulling from production is forbidden'
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
		$exportSection | Should Match 'backup_database'
		$exportSection | Should Match 'assert_sql_dump_table_prefix'
		$exportSection | Should Not Match 'mysql_import_file'
		$exportSection | Should Not Match 'rm -f'
	}
}
