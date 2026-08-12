[CmdletBinding()]
param(
	[Parameter(Position = 0)] [string] $Message = '',
	[ValidateSet('full', 'code', 'db', 'pull-db', 'pull-files', 'pull-full')] [string] $Mode = 'code',
	[switch] $SkipGit,
	[switch] $SkipUploads,
	[switch] $PreflightOnly,
	[switch] $DryRun,
	[switch] $Confirm,
	[switch] $Mirror
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

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path $repoRoot 'src\WordPressSshDeploy.psm1'
$configPath = Join-Path $repoRoot 'deploy.config.ps1'
if (-not (Test-Path -LiteralPath $modulePath)) {
	throw 'Missing src\WordPressSshDeploy.psm1.'
}
if (-not (Test-Path -LiteralPath $configPath)) {
	throw 'Missing deploy.config.ps1. Copy deploy.config.example.ps1 and fill in your values.'
}
Import-Module $modulePath -Force
. $configPath
if (-not $DeployConfig) { throw 'deploy.config.ps1 must define $DeployConfig.' }
Assert-DeployConfiguration -Configuration $DeployConfig
Assert-DeployModeAllowed -Environment $DeployConfig.Environment -Mode $Mode
$isPull = $Mode -in (Get-PullModeNames)
if ($Message) {
	throw 'Automatic Git commit/push was removed. Commit and push separately, then run deploy without Message.'
}
if ($SkipGit -and $Mode -ne 'db') {
	throw '-SkipGit is supported only for db mode. Code deployment requires a clean, pushed Git checkout.'
}
if (-not $isPull -and ($DryRun -or $Confirm -or $Mirror)) {
	throw '-DryRun, -Confirm, and -Mirror apply only to pull modes.'
}
if ($isPull -and ($SkipGit -or $SkipUploads -or $PreflightOnly)) {
	throw '-SkipGit, -SkipUploads, and -PreflightOnly apply only to push modes.'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$buildDir = Join-Path $repoRoot ".deploy\$stamp"
$sqlPath = Join-Path $buildDir 'local-db.sql'
$uploadsZip = Join-Path $buildDir 'uploads.zip'
$remoteSql = "$($DeployConfig.RemoteTmpPath)/local-db-$stamp.sql"
$remoteUploads = "$($DeployConfig.RemoteTmpPath)/uploads-$stamp.zip"
$target = "$($DeployConfig.SshUser)@$($DeployConfig.SshHost)"
$remoteCleanupNeeded = $false
$sshArgs = @('-p', [string]$DeployConfig.SshPort)
$scpArgs = @('-P', [string]$DeployConfig.SshPort)
if ($DeployConfig.SshKeyPath) {
	$sshArgs += @('-i', $DeployConfig.SshKeyPath, '-o', 'IdentitiesOnly=yes')
	$scpArgs += @('-i', $DeployConfig.SshKeyPath, '-o', 'IdentitiesOnly=yes')
}

if ($isPull) {
	# Pull never writes to the working local database or the working WordPress files.
	# It downloads verified artifacts into a side-by-side workspace and stops there;
	# activating them is a separate, manual decision.
	$plan = New-PullPlan -Configuration $DeployConfig -Mode $Mode -Stamp $stamp -WorkspaceRoot $repoRoot -DryRun:$DryRun -Confirmed:$Confirm -Mirror:$Mirror

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
	Assert-AvailableDiskSpace $repoRoot ([long] $DeployConfig.MinimumLocalFreeSpaceMB * 1MB) 'Local pull workspace'

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
			Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, (New-RemotePullCommand $DeployConfig 'pull-db' $plan.RemoteDbArtifact))) $repoRoot

			Write-Step 'Download and verify the database export'
			Invoke-CheckedCommand 'scp' ($scpArgs + @("$target`:$($plan.RemoteDbArtifact)", $plan.LocalDbArchive)) $repoRoot
			$createdTransferFiles += $plan.LocalDbArchive
			$null = Assert-GzipFile $plan.LocalDbArchive
			Expand-GzipFile $plan.LocalDbArchive $plan.LocalDbSql
			Assert-SqlDumpFile $plan.LocalDbSql
			$null = Assert-SqlDumpTableSet $plan.LocalDbSql $plan.ExpectedTablePrefix $plan.ExpectedTableCount
			Write-Ok "Database export verified: $($plan.LocalDbSql)"
		}

		if ($plan.IncludeFiles) {
			Write-Step 'Export remote files'
			$createdRemoteArtifacts += $plan.RemoteFilesArtifact
			Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, (New-RemotePullCommand $DeployConfig 'pull-files' $plan.RemoteFilesArtifact $plan.PullPaths))) $repoRoot

			Write-Step 'Download and verify the file archive'
			Invoke-CheckedCommand 'scp' ($scpArgs + @("$target`:$($plan.RemoteFilesArtifact)", $plan.LocalFilesArchive)) $repoRoot
			$createdTransferFiles += $plan.LocalFilesArchive
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

		Write-Host "`nPull artifacts prepared side-by-side; working local site was not replaced." -ForegroundColor Green
		Write-Host "Workspace: $($plan.Workspace)"
		if ($plan.IncludeDatabase) {
			Write-Host "Import into '$($plan.DatabaseTarget)' manually when you decide to activate it. The working database '$($plan.WorkingDatabase)' was not touched."
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
				Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, "rm -f $(ConvertTo-ShSingleQuotedString $artifact)")) $repoRoot
			} catch {
				Write-Warning "Remote pull artifact cleanup could not be confirmed: $artifact"
			}
		}
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
	Assert-AvailableDiskSpace $repoRoot $requiredLocalBytes 'Local deployment workspace'
	New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

	if ($Mode -ne 'db') {
		Write-Step 'Verify Git checkout'
		$status = @(Invoke-CommandOutput $DeployConfig.GitPath @('status','--porcelain','--untracked-files=all') $repoRoot)
		if ($status.Count -gt 0) {
			throw 'Git checkout has uncommitted or untracked changes. Commit them separately before deploy.'
		}
		$localHead = [string](Invoke-CommandOutput $DeployConfig.GitPath @('rev-parse','HEAD') $repoRoot)
		$upstreamHead = [string](Invoke-CommandOutput $DeployConfig.GitPath @('rev-parse','@{u}') $repoRoot)
		if ($localHead.Trim() -ne $upstreamHead.Trim()) {
			throw 'Local HEAD does not match its upstream. Push or synchronize Git separately before deploy.'
		}
	}

	if ($PreflightOnly) {
		Write-Step 'Remote preflight'
		Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, (New-RemoteDeployCommand $DeployConfig 'preflight'))) $repoRoot
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
			Invoke-CheckedCommand $DeployConfig.MysqldumpPath $dbArgs $repoRoot
			Assert-SqlDumpFile $sqlPath
			Normalize-SqlDumpTablePrefix $sqlPath $DeployConfig.ExpectedDbTablePrefix $DeployConfig.ExpectedDbTableCount
			$sqlBytes = (Get-Item -LiteralPath $sqlPath).Length
			Assert-AvailableDiskSpace $repoRoot ($requiredLocalBytes + [long]$sqlBytes) 'Local deployment workspace after SQL export'
		} finally {
			if ($null -eq $previousMysqlPassword) { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue }
			else { $env:MYSQL_PWD = $previousMysqlPassword }
		}
		if (-not $SkipUploads) {
			Write-Step 'Pack uploads'
			New-Zip $DeployConfig.LocalUploadsPath $uploadsZip
			Assert-ZipArchiveFile $uploadsZip
		}
		Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, "mkdir -p $(ConvertTo-ShSingleQuotedString $DeployConfig.RemoteTmpPath)")) $repoRoot
		$remoteCleanupNeeded = $true
		Invoke-CheckedCommand 'scp' ($scpArgs + @($sqlPath, "$target`:$remoteSql")) $repoRoot
		if (-not $SkipUploads) { Invoke-CheckedCommand 'scp' ($scpArgs + @($uploadsZip, "$target`:$remoteUploads")) $repoRoot }
	}

	Write-Step 'Run remote deployment'
	$sqlArg = if ($Mode -ne 'code') { $remoteSql } else { '' }
	$uploadsArg = if ($Mode -ne 'code' -and -not $SkipUploads) { $remoteUploads } else { '' }
	Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, (New-RemoteDeployCommand $DeployConfig $Mode $sqlArg $uploadsArg))) $repoRoot
	$remoteCleanupNeeded = $false

	Write-Host "`nDeploy completed: $($DeployConfig.LocalUrl) -> $($DeployConfig.RemoteUrl)" -ForegroundColor Green
} finally {
	if ($remoteCleanupNeeded) {
		try {
			$cleanupCommand = "rm -f $(ConvertTo-ShSingleQuotedString $remoteSql) $(ConvertTo-ShSingleQuotedString $remoteUploads)"
			Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, $cleanupCommand)) $repoRoot
		} catch {
			Write-Warning 'Remote temporary file cleanup could not be confirmed. Run preflight after SSH is restored.'
		}
	}
	if (Test-Path -LiteralPath $buildDir) {
		Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue
	}
}
