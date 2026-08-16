[CmdletBinding()]
param(
	[Parameter(Position = 0)] [string] $Message = '',
	[ValidateSet('full', 'code', 'db', 'pull-db', 'pull-files', 'pull-full', 'apply-pull')] [string] $Mode = 'code',
	[switch] $SkipGit,
	[switch] $SkipUploads,
	[switch] $PreflightOnly,
	[switch] $DryRun,
	[switch] $Confirm,
	[switch] $Mirror,
	[switch] $ReplaceProtected,
	[switch] $ConfirmProtected,
	[switch] $AllowProductionPull,
	[string] $PullWorkspace = '',
	[string] $ConfigPath = '',
	[string] $ProfilesDirectory = ''
)

$ErrorActionPreference = 'Stop'

function Write-Step([string] $Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string] $Text) { Write-Host "OK  $Text" -ForegroundColor Green }
function Assert-Path([string] $Path, [string] $Label) {
	if (-not (Test-Path -LiteralPath $Path)) { throw "$Label not found: $Path" }
}
function New-Zip([string] $SourceDirectory, [string] $DestinationZip) {
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	if (Test-Path -LiteralPath $DestinationZip) { Remove-Item -LiteralPath $DestinationZip -Force }
	[System.IO.Compression.ZipFile]::CreateFromDirectory(
		$SourceDirectory, $DestinationZip, [System.IO.Compression.CompressionLevel]::Optimal, $false
	)
}

function New-ProtectedArchive([string] $StageDirectory, [string] $DestinationZip) {
	if (-not $DeployConfig.Contains('ProtectedSyncPaths') -or @($DeployConfig.ProtectedSyncPaths).Count -eq 0) {
		throw 'Protected replacement requires ProtectedSyncPaths in deploy.config.ps1.'
	}
	New-Item -ItemType Directory -Force -Path $StageDirectory | Out-Null
	foreach ($relative in @($DeployConfig.ProtectedSyncPaths)) {
		$source = Join-Path $DeployConfig.LocalWpPath $relative
		Assert-Path $source "Protected local file ($relative)"
		$destination = Join-Path $StageDirectory $relative
		New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
		Copy-Item -LiteralPath $source -Destination $destination -Force
	}
	New-Zip $StageDirectory $DestinationZip
	Assert-ZipArchiveFile $DestinationZip
}

function Invoke-LocalMysqlDump([string] $Path, [string] $DatabaseName = $DeployConfig.LocalDbName) {
	if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Local database backup path is empty.' }
	if ([string]::IsNullOrWhiteSpace($DatabaseName) -or $DatabaseName -notmatch '^[A-Za-z0-9_]+$') { throw 'Local database name is invalid.' }
	$dbArgs = @("--host=$($DeployConfig.LocalDbHost)", "--user=$($DeployConfig.LocalDbUser)", '--single-transaction', '--quick', '--hex-blob', '--default-character-set=utf8mb4', ('--result-file=' + $Path), $DatabaseName)
	$previousPassword = $env:MYSQL_PWD
	try {
		if ($DeployConfig.LocalDbPassword) { $env:MYSQL_PWD = $DeployConfig.LocalDbPassword }
		else { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue }
        Invoke-CheckedCommand $DeployConfig.MysqldumpPath $dbArgs $codeRepositoryRoot
	} finally {
		if ($null -eq $previousPassword) { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue }
		else { $env:MYSQL_PWD = $previousPassword }
	}
}

function Invoke-LocalMysqlImport([string] $Path, [string] $DatabaseName = $DeployConfig.LocalDbName) {
	if ([string]::IsNullOrWhiteSpace($DatabaseName) -or $DatabaseName -notmatch '^[A-Za-z0-9_]+$') { throw 'Local database name is invalid.' }
	$mysqlArgs = @(
		"--host=$($DeployConfig.LocalDbHost)",
		"--user=$($DeployConfig.LocalDbUser)",
		'--default-character-set=utf8mb4',
		$DatabaseName
	)
	$environment = @{}
	if ($DeployConfig.LocalDbPassword) { $environment.MYSQL_PWD = [string] $DeployConfig.LocalDbPassword }
	Invoke-NativeProcessWithFileInput -FilePath $DeployConfig.MysqlPath -Arguments $mysqlArgs -InputPath $Path -EnvironmentVariables $environment | Out-Null
}

function Invoke-LocalWpCli([string[]] $Arguments) {
	& $DeployConfig.LocalPhpPath $DeployConfig.LocalWpCliPath "--path=$($DeployConfig.LocalWpPath)" @Arguments
	if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $($DeployConfig.LocalWpCliPath)" }
}

function Write-RunLog([string] $Event, [hashtable] $Data = @{}) {
	if ([string]::IsNullOrWhiteSpace($script:RunLogPath)) { return }
	$record = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); siteId = $siteId; event = $Event; data = $Data }
	$record | ConvertTo-Json -Compress -Depth 8 | Add-Content -LiteralPath $script:RunLogPath -Encoding UTF8
}

function Invoke-LocalBackupRetention([string] $BackupDirectory) {
	if (-not (Test-Path -LiteralPath $BackupDirectory -PathType Container)) { return }
	$keep = if ($DeployConfig.Contains('KeepLocalBackups')) { [int] $DeployConfig.KeepLocalBackups } else { [int] $DeployConfig.KeepBackups }
	$ageDays = if ($DeployConfig.Contains('KeepBackupDays')) { [int] $DeployConfig.KeepBackupDays } else { 0 }
	$maxBytes = if ($DeployConfig.Contains('MaxBackupSizeMB')) { [long] $DeployConfig.MaxBackupSizeMB * 1MB } else { 0 }
	$plan = Get-LocalBackupRetentionPlan -BackupDirectory $BackupDirectory -Keep $keep -KeepDays $ageDays -MaxBytes $maxBytes
	foreach ($group in @($plan.Remove)) {
		foreach ($item in @($group.Items)) { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop }
		Write-RunLog 'local-backup-removed' @{ stamp = $group.Stamp; bytes = $group.Bytes }
	}
}

function Assert-PreservedLocalCore {
	$corePolicy = if ($DeployConfig.Contains('CorePolicy')) { [string] $DeployConfig.CorePolicy } else { 'preserve-local-core' }
	if ($corePolicy -ne 'preserve-local-core') {
		throw "CorePolicy '$corePolicy' is not executable. Use preserve-local-core for the one working local WordPress copy."
	}
	foreach ($relative in @('index.php', 'wp-admin', 'wp-includes', 'wp-load.php', 'wp-settings.php', 'wp-login.php')) {
		Assert-Path (Join-Path $DeployConfig.LocalWpPath $relative) "Working local WordPress core ($relative)"
	}
	if ($DeployConfig.Contains('ExpectedWordPressCoreVersion') -and -not [string]::IsNullOrWhiteSpace([string] $DeployConfig.ExpectedWordPressCoreVersion)) {
		$actualVersion = ([string] (Invoke-LocalWpCli @('core', 'version'))).Trim()
		if ($actualVersion -ne [string] $DeployConfig.ExpectedWordPressCoreVersion) {
			throw "Working local WordPress core version '$actualVersion' does not match ExpectedWordPressCoreVersion."
		}
	}
}

$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $toolRoot 'src\WordPressSshDeploy.psm1'
$configPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
	throw 'Explicit -ConfigPath is required. Select a site profile through menu.ps1 or pass the profile path directly.'
} elseif ([IO.Path]::IsPathRooted($ConfigPath)) {
	[IO.Path]::GetFullPath($ConfigPath)
} else {
	[IO.Path]::GetFullPath((Join-Path $toolRoot $ConfigPath))
}
if (-not (Test-Path -LiteralPath $modulePath)) {
	throw 'Missing src\WordPressSshDeploy.psm1.'
}
if (-not (Test-Path -LiteralPath $configPath)) {
	throw "Configuration file was not found: $configPath"
}
Import-Module $modulePath -Force
. $configPath
if (-not $DeployConfig) { throw 'deploy.config.ps1 must define $DeployConfig.' }
Assert-DeployConfiguration -Configuration $DeployConfig
$profileDirectory = Split-Path -Parent $configPath
$canonicalProfilesDirectory = if ([string]::IsNullOrWhiteSpace($ProfilesDirectory)) { $profileDirectory } else { [IO.Path]::GetFullPath($ProfilesDirectory) }
Assert-ProfileIsolation -Configuration $DeployConfig -ProfilePath $configPath -ProfilesDirectory $profileDirectory -CanonicalProfilesDirectory $canonicalProfilesDirectory
$codeRepositoryRoot = [IO.Path]::GetFullPath([string] $DeployConfig.CodeRepositoryPath).TrimEnd('\', '/')
$workRoot = [IO.Path]::GetFullPath([string] $DeployConfig.WorkRoot).TrimEnd('\', '/')
$siteId = Get-ProfileSiteId $DeployConfig
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
$script:RunLogPath = Join-Path (Join-Path $workRoot 'logs') "$siteId.jsonl"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:RunLogPath) | Out-Null
Write-RunLog 'start' @{ mode = $Mode; dryRun = [bool] $DryRun }
Assert-DeployModeAllowed -Environment $DeployConfig.Environment -Mode $Mode -AllowProductionPull:$AllowProductionPull
$isPull = $Mode -in (Get-PullModeNames)
$isApplyPull = $Mode -eq 'apply-pull'
if ($Message) {
	throw 'Automatic Git commit/push was removed. Commit and push separately, then run deploy without Message.'
}
if ($SkipGit -and $Mode -ne 'db') {
	throw '-SkipGit is supported only for db mode. Code deployment requires a clean, pushed Git checkout.'
}
if (-not $isPull -and -not $isApplyPull -and ($DryRun -or $Confirm -or $Mirror)) {
	throw '-DryRun, -Confirm, and -Mirror apply only to pull modes.'
}
if (($isPull -or $isApplyPull) -and ($SkipGit -or $SkipUploads -or $PreflightOnly)) {
	throw '-SkipGit, -SkipUploads, and -PreflightOnly apply only to push modes.'
}
if ($AllowProductionPull -and -not ($isPull -or $isApplyPull)) {
	throw '-AllowProductionPull applies only to pull modes and local apply-pull.'
}
if ($isApplyPull -and ($Mirror -or $ReplaceProtected -or $ConfirmProtected)) {
	throw '-Mirror, -ReplaceProtected, and -ConfirmProtected do not apply to apply-pull.'
}
if (-not ($Mode -in @('full', 'apply-pull')) -and ($ReplaceProtected -or $ConfirmProtected)) {
	throw '-ReplaceProtected and -ConfirmProtected apply only to full mode.'
}
if ($ConfirmProtected -and -not $ReplaceProtected) {
	throw '-ConfirmProtected requires -ReplaceProtected.'
}
if ($ReplaceProtected -and -not $ConfirmProtected) {
	throw 'Protected replacement requires both -ReplaceProtected and -ConfirmProtected.'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$buildDir = Join-Path (Join-Path $workRoot '.deploy') $siteId
$buildDir = Join-Path $buildDir $stamp
$sqlPath = Join-Path $buildDir 'local-db.sql'
$uploadsZip = Join-Path $buildDir 'uploads.zip'
$protectedStage = Join-Path $buildDir 'protected'
$protectedZip = Join-Path $buildDir 'protected.zip'
$remoteSql = "$($DeployConfig.RemoteTmpPath)/local-db-$stamp.sql"
$remoteUploads = "$($DeployConfig.RemoteTmpPath)/uploads-$stamp.zip"
$remoteProtected = "$($DeployConfig.RemoteTmpPath)/protected-$stamp.zip"
$target = "$($DeployConfig.SshUser)@$($DeployConfig.SshHost)"
$remoteCleanupNeeded = $false
$sshArgs = @('-p', [string]$DeployConfig.SshPort)
# Forced-command wrappers need legacy SCP mode; OpenSSH 9 otherwise prefers
# the SFTP subsystem, which cannot be constrained by the wrapper protocol.
$scpArgs = if ($DeployConfig.Contains('UseLegacyScp') -and $DeployConfig.UseLegacyScp) {
	@('-O', '-P', [string]$DeployConfig.SshPort)
} else {
	@('-P', [string]$DeployConfig.SshPort)
}
if ($DeployConfig.SshKeyPath) {
	$sshArgs += @('-i', $DeployConfig.SshKeyPath, '-o', 'IdentitiesOnly=yes')
	$scpArgs += @('-i', $DeployConfig.SshKeyPath, '-o', 'IdentitiesOnly=yes')
}

if ($isPull) {
	# Pull never writes to the working local database or the working WordPress files.
	# It downloads verified artifacts into a side-by-side workspace and stops there;
	# activating them is a separate, manual decision.
    $plan = New-PullPlan -Configuration $DeployConfig -Mode $Mode -Stamp $stamp -WorkspaceRoot $workRoot -DryRun:$DryRun -Confirmed:$Confirm -Mirror:$Mirror -AllowProductionPull:$AllowProductionPull

	Write-Step "Pull plan ($Mode)"
	Get-PullSummaryLines $plan | ForEach-Object { Write-Host "    $_" }
	if ($plan.IsDryRun) {
		Write-Ok 'Dry run: nothing was downloaded, written, imported, or deleted.'
		return
	}

	Write-Step 'Local preflight'
	Assert-Path $DeployConfig.LocalWpPath 'Local WordPress'
	if (-not (Test-Path -LiteralPath $plan.LocalBackupDirectory -PathType Container)) {
		New-Item -ItemType Directory -Force -Path $plan.LocalBackupDirectory | Out-Null
	}
    Assert-AvailableDiskSpace $workRoot ([long] $DeployConfig.MinimumLocalFreeSpaceMB * 1MB) 'Local pull workspace'

	# Only paths this run creates are recorded, so cleanup can never reach an artifact
	# that existed beforehand.
	$createdRemoteArtifacts = @()
	$createdTransferFiles = @()
	$workspaceCreated = $false
	try {
		New-Item -ItemType Directory -Force -Path $plan.Workspace | Out-Null
		$workspaceCreated = $true

		if ($plan.IncludeDatabase) {
			Write-Step 'Create and export remote database backup'
			$createdRemoteArtifacts += $plan.RemoteDbArtifact
            Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, (New-RemotePullCommand $DeployConfig 'pull-db' $plan.RemoteDbArtifact))) $workRoot

			Write-Step 'Download and verify the database export'
            Invoke-CheckedCommand 'scp' ($scpArgs + @("$target`:$($plan.RemoteDbArtifact)", $plan.LocalDbArchive)) $workRoot
			$null = Assert-GzipFile $plan.LocalDbArchive
			Expand-GzipFile $plan.LocalDbArchive $plan.LocalDbSql
			Assert-SqlDumpFile $plan.LocalDbSql
		$null = Assert-SqlDumpTableSet $plan.LocalDbSql $plan.ExpectedTablePrefix $plan.ExpectedTableCount -MinimumTableCount $plan.MinimumTableCount
			Write-Ok "Database export verified: $($plan.LocalDbSql)"
		}

		if ($plan.IncludeFiles) {
			Write-Step 'Export remote files'
			$createdRemoteArtifacts += $plan.RemoteFilesArtifact
            Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, (New-RemotePullCommand $DeployConfig 'pull-files' $plan.RemoteFilesArtifact $plan.PullPaths))) $workRoot

			Write-Step 'Download and verify the file archive'
            Invoke-CheckedCommand 'scp' ($scpArgs + @("$target`:$($plan.RemoteFilesArtifact)", $plan.LocalFilesArchive)) $workRoot
			$null = Assert-GzipFile $plan.LocalFilesArchive
			$tarPath = Join-Path $plan.Workspace 'files.tar'
			Expand-GzipFile $plan.LocalFilesArchive $tarPath
			$createdTransferFiles += $tarPath
			# The listing is checked in full before a single byte is extracted.
			$null = Assert-PullArchiveEntries (Get-TarEntryList $tarPath) $plan.PullPaths -ExcludedPaths $plan.ExcludedPaths
			New-Item -ItemType Directory -Force -Path $plan.FilesStagingDirectory | Out-Null
			$null = Expand-TarArchive $tarPath $plan.FilesStagingDirectory
			Write-Ok "Files staged additively: $($plan.FilesStagingDirectory)"
		}
		$null = New-PullManifest -Configuration $DeployConfig -Plan $plan -ManifestPath $plan.ManifestPath
		Write-RunLog 'pull-manifest-created' @{ stamp = $plan.Stamp; mode = $plan.Mode; pathCount = @($plan.PullPaths).Count }

		Write-Host "`nPull artifacts prepared side-by-side; working local site was not replaced." -ForegroundColor Green
		Write-Host "Workspace: $($plan.Workspace)"
		if ($plan.IncludeDatabase) {
			Write-Host "The downloaded database is not active yet. A separate confirmed apply will back up and replace the working local database '$($plan.WorkingDatabase)'."
		}
		if ($plan.IncludeFiles) {
			Write-Host 'Copy staged files into the working site manually. No working file was replaced or deleted.'
		}
	} catch {
		Write-Warning 'Pull failed. No local database, working file, or remote backup was changed; nothing was rolled back automatically.'
		if ($workspaceCreated) {
			Write-Warning "Partial artifacts were left for inspection in $($plan.Workspace). Remove that directory yourself once you no longer need it."
		}
		throw
	} finally {
		# Transfer copies are reproducible, so they go. Verified artifacts, the remote
		# backup, and everything that existed before this run are left alone.
		foreach ($file in $createdTransferFiles) {
			if ($file -and (Test-Path -LiteralPath $file -PathType Leaf)) {
				Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
			}
		}
		foreach ($artifact in $createdRemoteArtifacts) {
			try {
                Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, "rm -f $(ConvertTo-ShSingleQuotedString $artifact)")) $workRoot
			} catch {
				Write-Warning "Remote pull artifact cleanup could not be confirmed: $artifact"
			}
		}
		Write-RunLog 'pull-finished' @{ stamp = $plan.Stamp; mode = $plan.Mode }
	}
	return
}

if ($isApplyPull) {
    $plan = New-ApplyPullPlan -Configuration $DeployConfig -Workspace $PullWorkspace -WorkspaceRoot $workRoot -DryRun:$DryRun -Confirmed:$Confirm
	Write-Step 'Apply pulled workspace plan'
	Get-ApplyPullSummaryLines $plan | ForEach-Object { Write-Host "    $_" }
	if ($plan.IsDryRun) {
		Write-Ok 'Dry run: local database and working files were not changed.'
		return
	}

	Assert-Path $DeployConfig.LocalWpPath 'Local WordPress'
	Assert-Path (Join-Path $DeployConfig.LocalWpPath 'wp-config.php') 'wp-config.php'
	Assert-Path $plan.DatabaseSql 'Pulled database SQL'
	Assert-Path $plan.FilesRoot 'Pulled files directory'
	$null = Assert-PullManifest -Configuration $DeployConfig -ManifestPath $plan.ManifestPath -Plan $plan
	Assert-PreservedLocalCore
	Assert-ApplyPullWorkspace -FilesRoot $plan.FilesRoot -PullPaths $plan.PullPaths -ExcludedPaths @($DeployConfig.ExcludedPullPaths)
	New-Item -ItemType Directory -Force -Path $plan.LocalBackupDirectory | Out-Null
	$applyStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
	$dbBackup = Join-Path $plan.LocalBackupDirectory "local-db-$applyStamp.sql"
	$filesBackup = Join-Path $plan.LocalBackupDirectory "files-$applyStamp"
	$dbBackupReady = $false
	$dbImportStarted = $false
	$fileSwaps = @()
	try {
		Write-Step 'Backup local database and configured pull paths'
		Invoke-LocalMysqlDump $dbBackup $plan.WorkingDatabase
		Assert-SqlDumpFile $dbBackup
		$dbBackupReady = $true
		New-Item -ItemType Directory -Force -Path $filesBackup | Out-Null
		foreach ($relative in @($plan.PullPaths)) {
			$target = Join-Path $DeployConfig.LocalWpPath $relative
			$backup = Join-Path $filesBackup $relative
			if (Test-Path -LiteralPath $target) {
				New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
				Copy-Item -LiteralPath $target -Destination $backup -Recurse -Force
			}
		}

		Assert-SqlDumpFile $plan.DatabaseSql
		$null = Assert-SqlDumpTableSet $plan.DatabaseSql $plan.ExpectedTablePrefix $plan.ExpectedTableCount -MinimumTableCount $plan.MinimumTableCount
		$localPrefix = ([string] (Invoke-LocalWpCli @('config', 'get', 'table_prefix', '--type=variable'))).Trim()
		if (-not [string]::Equals($localPrefix, [string] $DeployConfig.ExpectedDbTablePrefix, [StringComparison]::Ordinal)) {
			throw "Local WordPress table prefix does not match ExpectedDbTablePrefix: $localPrefix"
		}
		Write-Step 'Import pulled database and map server URL to local URL'
		$dbImportStarted = $true
		Invoke-LocalMysqlImport $plan.DatabaseSql $plan.WorkingDatabase
		Invoke-LocalWpCli @('search-replace', $plan.RemoteUrl, $plan.LocalUrl, '--all-tables', '--precise', '--recurse-objects', '--skip-columns=guid')
		Invoke-LocalWpCli @('option', 'update', 'home', $plan.LocalUrl)
		Invoke-LocalWpCli @('option', 'update', 'siteurl', $plan.LocalUrl)
		Invoke-LocalWpCli @('cache', 'flush')

		Write-Step 'Replace all configured pulled paths'
		foreach ($relative in @($plan.PullPaths)) {
			$source = Join-Path $plan.FilesRoot $relative
			$target = Join-Path $DeployConfig.LocalWpPath $relative
			if (-not (Test-Path -LiteralPath $source)) {
				throw "Pulled path is missing from the verified workspace: $relative"
			}
			$new = "$target.__new__.$applyStamp"
			$old = "$target.__old__.$applyStamp"
			Remove-Item -LiteralPath $new, $old -Recurse -Force -ErrorAction SilentlyContinue
			New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
			if (Test-Path -LiteralPath $source -PathType Container) {
				New-Item -ItemType Directory -Force -Path $new | Out-Null
				Get-ChildItem -LiteralPath $source -Force | ForEach-Object {
					Copy-Item -LiteralPath $_.FullName -Destination $new -Recurse -Force
				}
			} else {
				Copy-Item -LiteralPath $source -Destination $new -Force
			}
			$hadTarget = Test-Path -LiteralPath $target
			if ($hadTarget) { Move-Item -LiteralPath $target -Destination $old }
			try {
				Move-Item -LiteralPath $new -Destination $target
			} catch {
				if ($hadTarget -and (Test-Path -LiteralPath $old)) { Move-Item -LiteralPath $old -Destination $target -Force }
				throw
			}
			$fileSwaps += [pscustomobject] @{ Target = $target; Old = $old; HadTarget = $hadTarget }
		}
		foreach ($swap in $fileSwaps) {
			if ($swap.HadTarget -and (Test-Path -LiteralPath $swap.Old)) { Remove-Item -LiteralPath $swap.Old -Recurse -Force }
		}

		Write-Ok 'Pulled database and all configured files applied locally; local URL mapping completed.'
		Write-RunLog 'apply-pull-finished' @{ stamp = $applyStamp; databaseReplaced = $true; pathCount = @($plan.PullPaths).Count }
	} catch {
		Write-Warning 'Local pull apply failed; attempting to restore the local database and pulled paths backup.'
		if ($fileSwaps.Count -gt 0) { Restore-FileSwaps $fileSwaps }
		if ($dbBackupReady -and $dbImportStarted -and (Test-Path -LiteralPath $dbBackup -PathType Leaf)) {
			try { Invoke-LocalMysqlImport $dbBackup $plan.WorkingDatabase } catch { Write-Warning 'Local database restore failed; preserve the backup for manual recovery.' }
		}
		throw
	}
	try {
		Invoke-LocalBackupRetention $plan.LocalBackupDirectory
	} catch {
		Write-Warning 'The local apply succeeded, but backup retention could not be completed. No rollback is attempted after a successful apply.'
		Write-RunLog 'local-backup-retention-failed' @{ stamp = $applyStamp }
	}
	return
}

try {
	Write-Step 'Local preflight'
	Assert-Path $DeployConfig.LocalWpPath 'Local WordPress'
	Assert-Path (Join-Path $DeployConfig.LocalWpPath 'wp-config.php') 'wp-config.php'
	if ($Mode -ne 'db') { Assert-Path $DeployConfig.GitPath 'Git' }
	if ($Mode -ne 'code') {
		Assert-Path $DeployConfig.MysqldumpPath 'mysqldump'
		if (-not $SkipUploads) { Assert-Path $DeployConfig.LocalUploadsPath 'Uploads' }
	}
	$requiredLocalBytes = [long] $DeployConfig.MinimumLocalFreeSpaceMB * 1MB
	if ($Mode -ne 'code' -and -not $SkipUploads) {
		$requiredLocalBytes += Get-DirectoryContentSizeBytes $DeployConfig.LocalUploadsPath
	}
    Assert-AvailableDiskSpace $workRoot $requiredLocalBytes 'Local deployment workspace'
	New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

	if ($Mode -ne 'db') {
		Write-Step 'Verify Git checkout'
        $status = @(Invoke-CommandOutput $DeployConfig.GitPath @('status','--porcelain','--untracked-files=all') $codeRepositoryRoot)
		if ($status.Count -gt 0) {
			throw 'Git checkout has uncommitted or untracked changes. Commit them separately before deploy.'
		}
        $localHead = [string](Invoke-CommandOutput $DeployConfig.GitPath @('rev-parse','HEAD') $codeRepositoryRoot)
        $upstreamHead = [string](Invoke-CommandOutput $DeployConfig.GitPath @('rev-parse','@{u}') $codeRepositoryRoot)
		if ($localHead.Trim() -ne $upstreamHead.Trim()) {
			throw 'Local HEAD does not match its upstream. Push or synchronize Git separately before deploy.'
		}
	}

	if ($PreflightOnly) {
		Write-Step 'Remote preflight'
        Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, (New-RemoteDeployCommand $DeployConfig 'preflight'))) $workRoot
		Write-Ok 'Preflight completed'
		return
	}

	if ($Mode -ne 'code') {
		Write-Step 'Export database'
		$dbArgs = @("--host=$($DeployConfig.LocalDbHost)","--user=$($DeployConfig.LocalDbUser)","--result-file=$sqlPath",'--single-transaction','--quick','--hex-blob','--default-character-set=utf8mb4',$DeployConfig.LocalDbName)
		$previousMysqlPassword = $env:MYSQL_PWD
		try {
			if ($DeployConfig.LocalDbPassword) { $env:MYSQL_PWD = $DeployConfig.LocalDbPassword }
			else { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue }
            Invoke-CheckedCommand $DeployConfig.MysqldumpPath $dbArgs $codeRepositoryRoot
			Assert-SqlDumpFile $sqlPath
			Normalize-SqlDumpTablePrefix $sqlPath $DeployConfig.ExpectedDbTablePrefix $DeployConfig.ExpectedDbTableCount
			$sqlBytes = (Get-Item -LiteralPath $sqlPath).Length
            Assert-AvailableDiskSpace $workRoot ($requiredLocalBytes + [long]$sqlBytes) 'Local deployment workspace after SQL export'
		} finally {
			if ($null -eq $previousMysqlPassword) { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue }
			else { $env:MYSQL_PWD = $previousMysqlPassword }
		}
		if (-not $SkipUploads) {
			Write-Step 'Pack uploads'
			New-Zip $DeployConfig.LocalUploadsPath $uploadsZip
			Assert-ZipArchiveFile $uploadsZip
		}
		if ($Mode -eq 'full' -and $ReplaceProtected) {
			Write-Step 'Pack explicitly approved protected files'
			New-ProtectedArchive $protectedStage $protectedZip
		}
        Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, "mkdir -p $(ConvertTo-ShSingleQuotedString $DeployConfig.RemoteTmpPath)")) $workRoot
		$remoteCleanupNeeded = $true
        Invoke-CheckedCommand 'scp' ($scpArgs + @($sqlPath, "$target`:$remoteSql")) $workRoot
        if (-not $SkipUploads) { Invoke-CheckedCommand 'scp' ($scpArgs + @($uploadsZip, "$target`:$remoteUploads")) $workRoot }
        if ($Mode -eq 'full' -and $ReplaceProtected) { Invoke-CheckedCommand 'scp' ($scpArgs + @($protectedZip, "$target`:$remoteProtected")) $workRoot }
	}

	Write-Step 'Run remote deployment'
	$sqlArg = if ($Mode -ne 'code') { $remoteSql } else { '' }
	$uploadsArg = if ($Mode -ne 'code' -and -not $SkipUploads) { $remoteUploads } else { '' }
	$protectedArg = if ($Mode -eq 'full' -and $ReplaceProtected) { $remoteProtected } else { '' }
	$syncPaths = @($DeployConfig.SyncPaths)
	$fullSyncPaths = if ($DeployConfig.Contains('FullSyncPaths')) { @($DeployConfig.FullSyncPaths) } else { @($DeployConfig.SyncPaths) }
    Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, (New-RemoteDeployCommand $DeployConfig $Mode $sqlArg $uploadsArg -SyncPaths $syncPaths -FullSyncPaths $fullSyncPaths -ProtectedArchiveFile $protectedArg -ReplaceProtected:$ReplaceProtected))) $workRoot
	$remoteCleanupNeeded = $false

	Write-Host "`nDeploy completed: $($DeployConfig.LocalUrl) -> $($DeployConfig.RemoteUrl)" -ForegroundColor Green
} finally {
	if ($remoteCleanupNeeded) {
		try {
			$cleanupCommand = "rm -f $(ConvertTo-ShSingleQuotedString $remoteSql) $(ConvertTo-ShSingleQuotedString $remoteUploads) $(ConvertTo-ShSingleQuotedString $remoteProtected)"
            Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, $cleanupCommand)) $workRoot
		} catch {
			Write-Warning 'Remote temporary file cleanup could not be confirmed. Run preflight after SSH is restored.'
		}
	}
	if (Test-Path -LiteralPath $buildDir) {
		Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue
	}
}
