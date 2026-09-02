[CmdletBinding()]
param(
	[Parameter(Position = 0)] [string] $Message = '',
	[ValidateSet('full', 'code', 'db', 'code-db', 'uploads', 'plugins', 'mu-plugins')] [string] $Mode = 'code',
	[ValidateSet('auto', 'full')] [string] $UploadsTransferMode = 'auto',
	[switch] $SkipGit,
	[switch] $SkipUploads,
	[switch] $PreflightOnly
)

$ErrorActionPreference = 'Stop'

function Write-Step([string] $Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string] $Text) { Write-Host "OK  $Text" -ForegroundColor Green }
function Assert-Path([string] $Path, [string] $Label) {
	if (-not (Test-Path -LiteralPath $Path)) { throw "$Label not found: $Path" }
}
function Invoke-CheckedCommandRetry {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $FilePath,
		[Parameter(Mandatory = $true)] [string[]] $Arguments,
		[Parameter(Mandatory = $true)] [string] $WorkingDirectory,
		[int] $Attempts = 3,
		[int] $DelaySeconds = 5
	)

	if ($Attempts -lt 1) { throw 'Retry attempts must be at least 1.' }
	$lastError = $null
	for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
		try {
			Invoke-CheckedCommand $FilePath $Arguments $WorkingDirectory
			return
		} catch {
			$lastError = $_
			if ($attempt -lt $Attempts) {
				Write-Warning "Command failed on attempt $attempt/$Attempts; retrying in $DelaySeconds seconds."
				Start-Sleep -Seconds $DelaySeconds
			}
		}
	}
	throw $lastError
}
function New-Zip([string] $SourceDirectory, [string] $DestinationZip) {
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	if (Test-Path -LiteralPath $DestinationZip) { Remove-Item -LiteralPath $DestinationZip -Force }
	[System.IO.Compression.ZipFile]::CreateFromDirectory(
		$SourceDirectory, $DestinationZip, [System.IO.Compression.CompressionLevel]::Optimal, $false
	)
}
function Test-ModeComponent([string] $SelectedMode, [string] $Component) {
	$matrix = @{
		code = @('code'); db = @('db'); 'code-db' = @('code','db'); uploads = @('uploads'); plugins = @('plugins'); 'mu-plugins' = @('mu-plugins'); full = @('code','db','uploads','plugins','mu-plugins')
	}
	return $matrix[$SelectedMode] -contains $Component
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
$allowProductionFull = $DeployConfig.AllowProductionFull -is [bool] -and $DeployConfig.AllowProductionFull
$allowedModes = if ($DeployConfig.Contains('AllowedDeployModes')) {
	@($DeployConfig.AllowedDeployModes)
} elseif ($DeployConfig.Environment -eq 'production') {
	if ($allowProductionFull) { @('preflight', 'code', 'full') } else { @('preflight', 'code') }
} else {
	@('preflight', 'code', 'db', 'full')
}
Assert-DeployModeAllowed -Environment $DeployConfig.Environment -Mode $Mode -AllowProductionFull $allowProductionFull -AllowedDeployModes $allowedModes
$hasCode = Test-ModeComponent $Mode 'code'
$hasDatabase = Test-ModeComponent $Mode 'db'
$hasUploads = Test-ModeComponent $Mode 'uploads'
$hasPlugins = Test-ModeComponent $Mode 'plugins'
$hasMuPlugins = Test-ModeComponent $Mode 'mu-plugins'
if ($Message) {
	throw 'Automatic Git commit/push was removed. Commit and push separately, then run deploy without Message.'
}
if ($SkipUploads) {
	throw '-SkipUploads is retired. Use code-db for code plus database without uploads.'
}
if ($SkipGit -and ($hasCode -or $hasPlugins -or $hasMuPlugins)) {
	throw '-SkipGit is not supported for code, plugins or mu-plugins. These components require a clean, pushed Git checkout.'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$buildDir = Join-Path $repoRoot ".deploy\$stamp"
$sqlPath = Join-Path $buildDir 'local-db.sql'
$uploadsZip = Join-Path $buildDir 'uploads.zip'
$remoteSql = "$($DeployConfig.RemoteTmpPath)/local-db-$stamp.sql"
$remoteUploads = "$($DeployConfig.RemoteTmpPath)/uploads-$stamp.zip"
$remoteUploadsDelta = "$($DeployConfig.RemoteTmpPath)/uploads-delta-$stamp.zip"
$remoteUploadsManifest = "$($DeployConfig.RemoteTmpPath)/uploads-manifest-$stamp.tsv"
$uploadsManifest = Join-Path $buildDir 'uploads-manifest.tsv'
$uploadsDeltaZip = Join-Path $buildDir 'uploads-delta.zip'
$uploadsManifestState = Join-Path $repoRoot ('.deploy-state\uploads-' + (($DeployConfig.ExpectedRemoteDomain -replace '[^A-Za-z0-9._-]', '_')) + '.tsv')
$target = "$($DeployConfig.SshUser)@$($DeployConfig.SshHost)"
$remoteCleanupNeeded = $false
$localArtifactsCommitted = $false
$uploadsTransferKind = 'full'
$useUploadsDelta = $false
$currentUploadsManifest = @()
$sshArgs = @('-p', [string]$DeployConfig.SshPort, '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=10', '-o', 'ConnectTimeout=20')
$scpArgs = @('-O', '-P', [string]$DeployConfig.SshPort, '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=10', '-o', 'ConnectTimeout=20')
if ($DeployConfig.SshKeyPath) {
	$sshArgs += @('-i', $DeployConfig.SshKeyPath, '-o', 'IdentitiesOnly=yes')
	$scpArgs += @('-i', $DeployConfig.SshKeyPath, '-o', 'IdentitiesOnly=yes')
}

function Publish-UploadsManifestState([string] $SourcePath, [string] $DestinationPath) {
	$parent = Split-Path -Parent $DestinationPath
	if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
	$temp = "$DestinationPath.new.$PID"
	try {
		Copy-Item -LiteralPath $SourcePath -Destination $temp -Force
		Move-Item -LiteralPath $temp -Destination $DestinationPath -Force
	} finally {
		if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
	}
}

function Invoke-RemoteCommandCapture {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $FilePath,
		[Parameter(Mandatory = $true)] [string[]] $Arguments,
		[Parameter(Mandatory = $true)] [string] $WorkingDirectory
	)
	Push-Location $WorkingDirectory
	try {
		$output = @(& $FilePath @Arguments 2>&1)
		$exitCode = $LASTEXITCODE
		$output | ForEach-Object { Write-Host ([string]$_) }
		return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join "`n") }
	} finally { Pop-Location }
}

try {
	Write-Step 'Local preflight'
	Assert-Path $DeployConfig.LocalWpPath 'Local WordPress'
	Assert-Path (Join-Path $DeployConfig.LocalWpPath 'wp-config.php') 'wp-config.php'
	if ($hasCode -or $hasPlugins -or $hasMuPlugins) { Assert-Path $DeployConfig.GitPath 'Git' }
	if ($hasDatabase) {
		Assert-Path $DeployConfig.MysqldumpPath 'mysqldump'
	}
	if ($hasUploads) { Assert-Path $DeployConfig.LocalUploadsPath 'Uploads' }
	$requiredLocalBytes = [long] $DeployConfig.MinimumLocalFreeSpaceMB * 1MB
	if ($hasUploads) {
		$requiredLocalBytes += Get-DirectoryContentSizeBytes $DeployConfig.LocalUploadsPath
	}
	Assert-AvailableDiskSpace $repoRoot $requiredLocalBytes 'Local deployment workspace'
	New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
	if ($hasUploads) {
		Write-Step 'Build uploads manifest'
		$currentUploadsManifest = @(Get-UploadsManifest $DeployConfig.LocalUploadsPath)
		Write-UploadsManifest $currentUploadsManifest $uploadsManifest
		if ($UploadsTransferMode -eq 'auto' -and (Test-Path -LiteralPath $uploadsManifestState -PathType Leaf)) {
			try {
				$baselineUploadsManifest = @(Read-UploadsManifest $uploadsManifestState)
				$comparison = Compare-UploadsManifests $baselineUploadsManifest $currentUploadsManifest
				New-UploadsDeltaPackage -SourceDirectory $DeployConfig.LocalUploadsPath -CurrentManifest $currentUploadsManifest -BaselineManifest $baselineUploadsManifest -DestinationZip $uploadsDeltaZip | Out-Null
				$useUploadsDelta = $true
				$uploadsTransferKind = 'delta'
				Write-Ok ("Uploads delta prepared: added={0}, changed={1}, deleted={2}, bytes={3}" -f $comparison.Added.Count, $comparison.Changed.Count, $comparison.Deleted.Count, (Get-Item -LiteralPath $uploadsDeltaZip).Length)
			} catch {
				Write-Warning "Uploads baseline is invalid; falling back to full snapshot: $($_.Exception.Message)"
				$useUploadsDelta = $false
				$uploadsTransferKind = 'full'
			}
		}
	}

	if ($hasCode -or $hasPlugins -or $hasMuPlugins) {
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

	if ($hasDatabase -or $hasUploads) {
		New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
	}
	if ($hasDatabase) {
		Write-Step 'Export database'
		$dbArgs = @("--host=$($DeployConfig.LocalDbHost)","--user=$($DeployConfig.LocalDbUser)","--result-file=$sqlPath",'--single-transaction','--quick','--default-character-set=utf8mb4',$DeployConfig.LocalDbName)
		$previousMysqlPassword = $env:MYSQL_PWD
		try {
			if ($DeployConfig.LocalDbPassword) { $env:MYSQL_PWD = $DeployConfig.LocalDbPassword }
			else { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue }
			Invoke-CheckedCommand $DeployConfig.MysqldumpPath $dbArgs $repoRoot
			Assert-SqlDumpFile $sqlPath
		} finally {
			if ($null -eq $previousMysqlPassword) { Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue }
			else { $env:MYSQL_PWD = $previousMysqlPassword }
		}
	}
	if ($hasUploads) {
		if (-not $useUploadsDelta) {
			Write-Step 'Pack full uploads snapshot'
			New-Zip $DeployConfig.LocalUploadsPath $uploadsZip
			Assert-ZipArchiveFile $uploadsZip
		}
	}
	if ($hasDatabase -or $hasUploads) {
		Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, "mkdir -p $(ConvertTo-ShSingleQuotedString $DeployConfig.RemoteTmpPath)")) $repoRoot
		$remoteCleanupNeeded = $true
		if ($hasDatabase) { Invoke-CheckedCommand 'scp' ($scpArgs + @($sqlPath, "$target`:$remoteSql")) $repoRoot }
		if ($hasUploads) {
			$uploadsSource = if ($useUploadsDelta) { $uploadsDeltaZip } else { $uploadsZip }
			$uploadsDestination = if ($useUploadsDelta) { $remoteUploadsDelta } else { $remoteUploads }
			Invoke-CheckedCommandRetry 'scp' ($scpArgs + @($uploadsSource, "$target`:$uploadsDestination")) $repoRoot
			Invoke-CheckedCommand 'scp' ($scpArgs + @($uploadsManifest, "$target`:$remoteUploadsManifest")) $repoRoot
		}
	}

	Write-Step 'Run remote deployment'
	$sqlArg = if ($hasDatabase) { $remoteSql } else { '' }
	$uploadsArg = if ($hasUploads -and -not $useUploadsDelta) { $remoteUploads } else { '' }
	$uploadsDeltaArg = if ($hasUploads -and $useUploadsDelta) { $remoteUploadsDelta } else { '' }
	$uploadsManifestArg = if ($hasUploads) { $remoteUploadsManifest } else { '' }
	$remoteCommand = New-RemoteDeployCommand $DeployConfig $Mode $sqlArg $uploadsArg $uploadsDeltaArg $uploadsManifestArg
	if ($hasUploads -and $useUploadsDelta) {
		$result = Invoke-RemoteCommandCapture 'ssh' ($sshArgs + @($target, $remoteCommand)) $repoRoot
		if ($result.ExitCode -ne 0) {
			if ($result.Output -notmatch 'UPLOADS_DELTA_FALLBACK_REQUIRED') { throw "Command failed ($($result.ExitCode)): ssh" }
			Write-Warning 'Remote uploads baseline/drift requires full snapshot fallback.'
			$useUploadsDelta = $false
			$uploadsTransferKind = 'full'
			$uploadsDeltaArg = ''
			New-Zip $DeployConfig.LocalUploadsPath $uploadsZip
			Assert-ZipArchiveFile $uploadsZip
			Invoke-CheckedCommandRetry 'scp' ($scpArgs + @($uploadsZip, "$target`:$remoteUploads")) $repoRoot
			$remoteCommand = New-RemoteDeployCommand $DeployConfig $Mode $sqlArg $remoteUploads $uploadsDeltaArg $uploadsManifestArg
			Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, $remoteCommand)) $repoRoot
		}
	} else {
		Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, $remoteCommand)) $repoRoot
	}
	$remoteCleanupNeeded = $false
	$localArtifactsCommitted = $true
	if ($hasUploads) { Publish-UploadsManifestState $uploadsManifest $uploadsManifestState }

	Write-Host "`nDeploy completed: $($DeployConfig.LocalUrl) -> $($DeployConfig.RemoteUrl)" -ForegroundColor Green
} finally {
	if ($remoteCleanupNeeded) {
		try {
			$cleanupCommand = "rm -f $(ConvertTo-ShSingleQuotedString $remoteSql) $(ConvertTo-ShSingleQuotedString $remoteUploads) $(ConvertTo-ShSingleQuotedString $remoteUploadsDelta) $(ConvertTo-ShSingleQuotedString $remoteUploadsManifest)"
			Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, $cleanupCommand)) $repoRoot
		} catch {
			Write-Warning 'Remote temporary file cleanup could not be confirmed. Run preflight after SSH is restored.'
		}
	}
	if (Test-Path -LiteralPath $buildDir) {
		if ($localArtifactsCommitted -or -not ($hasDatabase -or $hasUploads)) {
			Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue
		} else {
			Write-Warning "Local deployment artifacts retained at $buildDir because remote deployment did not complete."
		}
	}
}
