[CmdletBinding()]
param(
	[Parameter(Position = 0)] [string] $Message = '',
	[ValidateSet('full', 'code', 'db', 'code-db', 'uploads', 'plugins', 'mu-plugins')] [string] $Mode = 'code',
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
$target = "$($DeployConfig.SshUser)@$($DeployConfig.SshHost)"
$remoteCleanupNeeded = $false
$sshArgs = @('-p', [string]$DeployConfig.SshPort)
$scpArgs = @('-P', [string]$DeployConfig.SshPort)
if ($DeployConfig.SshKeyPath) {
	$sshArgs += @('-i', $DeployConfig.SshKeyPath, '-o', 'IdentitiesOnly=yes')
	$scpArgs += @('-i', $DeployConfig.SshKeyPath, '-o', 'IdentitiesOnly=yes')
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
		Write-Step 'Pack uploads'
		New-Zip $DeployConfig.LocalUploadsPath $uploadsZip
		Assert-ZipArchiveFile $uploadsZip
	}
	if ($hasDatabase -or $hasUploads) {
		Invoke-CheckedCommand 'ssh' ($sshArgs + @($target, "mkdir -p $(ConvertTo-ShSingleQuotedString $DeployConfig.RemoteTmpPath)")) $repoRoot
		$remoteCleanupNeeded = $true
		if ($hasDatabase) { Invoke-CheckedCommand 'scp' ($scpArgs + @($sqlPath, "$target`:$remoteSql")) $repoRoot }
		if ($hasUploads) { Invoke-CheckedCommand 'scp' ($scpArgs + @($uploadsZip, "$target`:$remoteUploads")) $repoRoot }
	}

	Write-Step 'Run remote deployment'
	$sqlArg = if ($hasDatabase) { $remoteSql } else { '' }
	$uploadsArg = if ($hasUploads) { $remoteUploads } else { '' }
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
