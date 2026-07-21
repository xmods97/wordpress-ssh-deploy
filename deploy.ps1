[CmdletBinding()]
param(
	[Parameter(Position = 0)] [string] $Message = '',
	[ValidateSet('full', 'code', 'db')] [string] $Mode = 'full',
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
function Invoke-Checked([string] $FilePath, [string[]] $Arguments, [string] $WorkingDirectory) {
	Push-Location $WorkingDirectory
	try {
		& $FilePath @Arguments
		if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $FilePath" }
	} finally { Pop-Location }
}
function Invoke-Output([string] $FilePath, [string[]] $Arguments, [string] $WorkingDirectory) {
	Push-Location $WorkingDirectory
	try {
		$output = & $FilePath @Arguments 2>&1
		if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $FilePath" }
		return $output
	} finally { Pop-Location }
}
function New-Zip([string] $SourceDirectory, [string] $DestinationZip) {
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	if (Test-Path -LiteralPath $DestinationZip) { Remove-Item -LiteralPath $DestinationZip -Force }
	[System.IO.Compression.ZipFile]::CreateFromDirectory(
		$SourceDirectory, $DestinationZip, [System.IO.Compression.CompressionLevel]::Optimal, $false
	)
}
function Quote-Sh([string] $Value) {
	$singleQuote = [string][char]39
	$escaped = $Value.Replace($singleQuote, $singleQuote + '"' + $singleQuote + '"' + $singleQuote)
	return $singleQuote + $escaped + $singleQuote
}

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $repoRoot 'deploy.config.ps1'
if (-not (Test-Path -LiteralPath $configPath)) {
	throw 'Missing deploy.config.ps1. Copy deploy.config.example.ps1 and fill in your values.'
}
. $configPath
if (-not $DeployConfig) { throw 'deploy.config.ps1 must define $DeployConfig.' }

$required = @('LocalWpPath','LocalUrl','LocalDbName','LocalDbUser','LocalDbHost','MysqldumpPath','GitPath','SshUser','SshHost','SshPort','RemoteUrl','RemoteWpPath','RemoteRepoPath','RemoteTmpPath','RemoteBackups','ExpectedRemoteWpPath','ExpectedRemoteDbName','SyncPaths')
foreach ($key in $required) {
	if (-not $DeployConfig[$key]) { throw "Missing configuration value: $key" }
}
if ($DeployConfig.RemoteWpPath -ne $DeployConfig.ExpectedRemoteWpPath) {
	throw 'RemoteWpPath does not match ExpectedRemoteWpPath.'
}
foreach ($path in $DeployConfig.SyncPaths) {
	if ([IO.Path]::IsPathRooted($path) -or $path -match '(^|[\\/])\.\.([\\/]|$)') {
		throw "SyncPaths must contain safe repository-relative paths: $path"
	}
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$buildDir = Join-Path $repoRoot ".deploy\$stamp"
$sqlPath = Join-Path $buildDir 'local-db.sql'
$uploadsZip = Join-Path $buildDir 'uploads.zip'
$remoteSql = "$($DeployConfig.RemoteTmpPath)/local-db-$stamp.sql"
$remoteUploads = "$($DeployConfig.RemoteTmpPath)/uploads-$stamp.zip"
$remoteScript = "$($DeployConfig.RemoteRepoPath)/server-deploy.sh"
$target = "$($DeployConfig.SshUser)@$($DeployConfig.SshHost)"
$sshArgs = @('-p', [string]$DeployConfig.SshPort)
$scpArgs = @('-P', [string]$DeployConfig.SshPort)
if ($DeployConfig.SshKeyPath) {
	$sshArgs += @('-i', $DeployConfig.SshKeyPath, '-o', 'IdentitiesOnly=yes')
	$scpArgs += @('-i', $DeployConfig.SshKeyPath, '-o', 'IdentitiesOnly=yes')
}

Write-Step 'Local preflight'
Assert-Path $DeployConfig.LocalWpPath 'Local WordPress'
Assert-Path $DeployConfig.MysqldumpPath 'mysqldump'
Assert-Path $DeployConfig.GitPath 'Git'
Assert-Path (Join-Path $DeployConfig.LocalWpPath 'wp-config.php') 'wp-config.php'
if ($Mode -ne 'code' -and -not $SkipUploads) { Assert-Path $DeployConfig.LocalUploadsPath 'Uploads' }
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$envPairs = @{
	LOCAL_URL=$DeployConfig.LocalUrl; REMOTE_URL=$DeployConfig.RemoteUrl
	WP_DIR=$DeployConfig.RemoteWpPath; REPO_DIR=$DeployConfig.RemoteRepoPath
	BACKUP_DIR=$DeployConfig.RemoteBackups; KEEP_BACKUPS=$DeployConfig.KeepBackups
	GIT_SSH_KEY=$DeployConfig.RemoteGitSshKey; PHP_BIN=$DeployConfig.RemotePhpPath
	WP_CLI_BIN=$DeployConfig.RemoteWpCliPath; EXPECTED_WP_DIR=$DeployConfig.ExpectedRemoteWpPath
	EXPECTED_DB_NAME=$DeployConfig.ExpectedRemoteDbName
	SYNC_PATHS=($DeployConfig.SyncPaths -join ',')
}
function New-RemoteCommand([string] $DeployMode, [string] $SqlFile = '', [string] $UploadsFile = '') {
	$parts = @()
	foreach ($item in $envPairs.GetEnumerator()) { $parts += "$($item.Key)=$(Quote-Sh ([string]$item.Value))" }
	$parts += "DEPLOY_MODE=$(Quote-Sh $DeployMode)"
	$parts += "SQL_FILE=$(Quote-Sh $SqlFile)"
	$parts += "UPLOADS_ZIP=$(Quote-Sh $UploadsFile)"
	$parts += "sh $(Quote-Sh $remoteScript)"
	return $parts -join ' '
}

if ($PreflightOnly) {
	Write-Step 'Remote preflight'
	Invoke-Checked 'ssh' ($sshArgs + @($target, (New-RemoteCommand 'preflight'))) $repoRoot
	Remove-Item -LiteralPath $buildDir -Recurse -Force
	Write-Ok 'Preflight completed'
	return
}

if (-not $SkipGit -and $Mode -ne 'db') {
	Write-Step 'Commit and push code'
	$status = Invoke-Output $DeployConfig.GitPath @('status','--short') $repoRoot
	if ($status) {
		if (-not $Message) { throw 'Git has changes. Pass a commit message or use -SkipGit.' }
		Invoke-Checked $DeployConfig.GitPath @('add','.') $repoRoot
		Invoke-Checked $DeployConfig.GitPath @('commit','-m',$Message) $repoRoot
		Invoke-Checked $DeployConfig.GitPath @('push') $repoRoot
	}
}

if ($Mode -ne 'code') {
	Write-Step 'Export database'
	$dbArgs = @("--host=$($DeployConfig.LocalDbHost)","--user=$($DeployConfig.LocalDbUser)","--result-file=$sqlPath",'--single-transaction','--quick','--default-character-set=utf8mb4',$DeployConfig.LocalDbName)
	if ($DeployConfig.LocalDbPassword) { $dbArgs = @("--password=$($DeployConfig.LocalDbPassword)") + $dbArgs }
	Invoke-Checked $DeployConfig.MysqldumpPath $dbArgs $repoRoot
	if (-not $SkipUploads) { Write-Step 'Pack uploads'; New-Zip $DeployConfig.LocalUploadsPath $uploadsZip }
	Invoke-Checked 'ssh' ($sshArgs + @($target, "mkdir -p $(Quote-Sh $DeployConfig.RemoteTmpPath) $(Quote-Sh $DeployConfig.RemoteBackups)")) $repoRoot
	Invoke-Checked 'scp' ($scpArgs + @($sqlPath, "$target`:$remoteSql")) $repoRoot
	if (-not $SkipUploads) { Invoke-Checked 'scp' ($scpArgs + @($uploadsZip, "$target`:$remoteUploads")) $repoRoot }
}

Write-Step 'Run remote deployment'
$sqlArg = if ($Mode -ne 'code') { $remoteSql } else { '' }
$uploadsArg = if ($Mode -ne 'code' -and -not $SkipUploads) { $remoteUploads } else { '' }
$pull = "cd $(Quote-Sh $DeployConfig.RemoteRepoPath) && GIT_SSH_COMMAND=$(Quote-Sh "ssh -i $($DeployConfig.RemoteGitSshKey) -o IdentitiesOnly=yes") git pull --ff-only origin main && "
Invoke-Checked 'ssh' ($sshArgs + @($target, $pull + (New-RemoteCommand $Mode $sqlArg $uploadsArg))) $repoRoot

Remove-Item -LiteralPath $buildDir -Recurse -Force
Write-Host "`nDeploy completed: $($DeployConfig.LocalUrl) -> $($DeployConfig.RemoteUrl)" -ForegroundColor Green
