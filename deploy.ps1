[CmdletBinding()]
param(
	[Parameter(Position = 0)] [string] $Message = '',
	[ValidateSet('full', 'code', 'db', 'code-db', 'uploads', 'plugins', 'mu-plugins', 'components')] [string] $Mode = 'code',
	[ValidateSet('code', 'db', 'uploads', 'plugins', 'mu-plugins')] [string[]] $Components = @(),
	[ValidateSet('auto', 'full')] [string] $UploadsTransferMode = 'auto',
	[switch] $ConfirmUploadsDeletes,
	[switch] $ConfirmUploadsFullSnapshot,
	[switch] $SkipGit,
	[switch] $SkipUploads,
	[switch] $PrepareGitSource,
	[switch] $PreflightOnly,
	[string] $LocalLinuxUnzipPath = '/usr/bin/unzip',
	[switch] $StageBellaRunnerCandidate,
	[string] $RunnerCandidatePath,
	[string] $InstallerCandidatePath
)

$ErrorActionPreference = 'Stop'

$stageOnlyParameters = @('StageBellaRunnerCandidate', 'RunnerCandidatePath', 'InstallerCandidatePath')
if ($StageBellaRunnerCandidate) {
	$unexpectedStageParameters = @($PSBoundParameters.Keys | Where-Object { $_ -notin $stageOnlyParameters })
	if ($unexpectedStageParameters.Count -gt 0) { throw "-StageBellaRunnerCandidate cannot be combined with: $($unexpectedStageParameters -join ', ')." }
	if ([string]::IsNullOrWhiteSpace($RunnerCandidatePath) -or [string]::IsNullOrWhiteSpace($InstallerCandidatePath)) {
		throw '-StageBellaRunnerCandidate requires both -RunnerCandidatePath and -InstallerCandidatePath.'
	}
} elseif ($PSBoundParameters.ContainsKey('RunnerCandidatePath') -or $PSBoundParameters.ContainsKey('InstallerCandidatePath')) {
	throw 'Runner candidate paths require -StageBellaRunnerCandidate.'
}

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
function Resolve-SelectedComponents([string] $SelectedMode, [string[]] $ExplicitComponents) {
	$known = @('code', 'db', 'uploads', 'plugins', 'mu-plugins')
	if ($ExplicitComponents.Count -gt 0 -or $SelectedMode -eq 'components') {
		if ($ExplicitComponents.Count -eq 0) { throw 'Components mode requires at least one selected component.' }
		$seen = @{}
		foreach ($component in $ExplicitComponents) {
			$normalized = ([string] $component).Trim().ToLowerInvariant()
			if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized -notin $known) { throw "Unknown selected component: $component" }
			if ($seen.ContainsKey($normalized)) { throw "Duplicate selected component: $normalized" }
			$seen[$normalized] = $true
		}
		return @($known | Where-Object { $seen.ContainsKey($_) })
	}
	return @($known | Where-Object { Test-ModeComponent $SelectedMode $_ })
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
. (Join-Path $repoRoot 'tools\UploadsPackageValidation.ps1')
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
$selectedComponents = @(Resolve-SelectedComponents $Mode $Components)
if ($Components.Count -gt 0) { $Mode = 'components' }
Assert-DeployModeAllowed -Environment $DeployConfig.Environment -Mode $Mode -AllowProductionFull $allowProductionFull -AllowedDeployModes $allowedModes
if ($DeployConfig.Environment -eq 'production' -and $Mode -eq 'components' -and (Test-DeployComponentsRequireProductionFullOptIn -Components $selectedComponents) -and -not $allowProductionFull) {
	throw 'Production component selection requires an explicit AllowProductionFull profile opt-in.'
}
$hasCode = $selectedComponents -contains 'code'
$hasDatabase = $selectedComponents -contains 'db'
$hasUploads = $selectedComponents -contains 'uploads'
$hasPlugins = $selectedComponents -contains 'plugins'
$hasMuPlugins = $selectedComponents -contains 'mu-plugins'
if ($PrepareGitSource) {
	if ($Mode -ne 'code' -or $Components.Count -gt 0 -or $PreflightOnly -or $SkipGit -or $SkipUploads -or $ConfirmUploadsDeletes -or $ConfirmUploadsFullSnapshot -or $UploadsTransferMode -ne 'auto') {
		throw '-PrepareGitSource is a source-only action; do not combine it with deploy or uploads options.'
	}
	if ([string]::IsNullOrWhiteSpace($Message)) { throw '-PrepareGitSource requires a non-empty -Message for the source commit.' }
	if (-not $DeployConfig.SourceGitPath -or -not $DeployConfig.SourceGitBranch) { throw 'SourceGitPath and SourceGitBranch must be configured for -PrepareGitSource.' }
} elseif ($Message) {
	throw 'Message is accepted only with -PrepareGitSource. Use that mode to sync local WordPress source, commit, and push before deployment.'
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
$uploadsPlan = $null
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

function Sync-LocalSourceToGit {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $CommitMessage)

	$toolStatus = @(Invoke-CommandOutput $DeployConfig.GitPath @('status', '--porcelain', '--untracked-files=all') $repoRoot)
	if ($toolStatus.Count -gt 0) { throw 'Deployment-tool checkout is dirty. No site source was changed.' }
	$toolHead = [string](Invoke-CommandOutput $DeployConfig.GitPath @('rev-parse', 'HEAD') $repoRoot)
	$toolUpstream = [string](Invoke-CommandOutput $DeployConfig.GitPath @('rev-parse', '@{u}') $repoRoot)
	if ($toolHead.Trim() -cne $toolUpstream.Trim()) { throw 'Deployment-tool checkout is not synchronized with its upstream.' }

	$sourceRoot = [string] $DeployConfig.SourceGitPath
	Assert-Path $sourceRoot 'Site Git source repository'
	$resolvedSourceRoot = (Resolve-Path -LiteralPath $sourceRoot).Path.TrimEnd('\')
	$resolvedToolRoot = (Resolve-Path -LiteralPath $repoRoot).Path.TrimEnd('\')
	if ($resolvedSourceRoot -ieq $resolvedToolRoot) { throw 'SourceGitPath must point to the site Git repository, not the deployment-tool checkout.' }
	$branch = [string](Invoke-CommandOutput $DeployConfig.GitPath @('branch', '--show-current') $sourceRoot)
	if ($branch.Trim() -cne [string] $DeployConfig.SourceGitBranch) {
		throw "Site Git source branch mismatch: expected '$($DeployConfig.SourceGitBranch)', found '$($branch.Trim())'."
	}
	$upstream = [string](Invoke-CommandOutput $DeployConfig.GitPath @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}') $sourceRoot)
	if ($upstream.Trim() -cne "origin/$($DeployConfig.SourceGitBranch)") {
		throw "Site Git source upstream mismatch: expected 'origin/$($DeployConfig.SourceGitBranch)', found '$($upstream.Trim())'."
	}

	Invoke-CheckedCommand $DeployConfig.GitPath @('fetch', '--quiet') $sourceRoot
	$head = [string](Invoke-CommandOutput $DeployConfig.GitPath @('rev-parse', 'HEAD') $sourceRoot)
	$upstreamHead = [string](Invoke-CommandOutput $DeployConfig.GitPath @('rev-parse', '@{u}') $sourceRoot)
	if ($head.Trim() -cne $upstreamHead.Trim()) {
		throw 'Site Git source is not exactly synchronized with origin before local-source preparation.'
	}
	$preStaged = @(Invoke-CommandOutput $DeployConfig.GitPath @('diff', '--cached', '--name-only') $sourceRoot)
	if ($preStaged.Count -gt 0) {
		throw 'Site Git source has pre-staged changes. Nothing was added or committed.'
	}

	$sourcePaths = @($DeployConfig.SyncPaths) + @($DeployConfig.PluginSyncPaths) + @($DeployConfig.MuPluginSyncPaths)
	$localManifest = @(Get-DeploymentSourceManifest -RootPath $DeployConfig.LocalWpPath -RelativePaths $sourcePaths)
	$gitManifest = @(Get-DeploymentSourceManifest -RootPath $sourceRoot -RelativePaths $sourcePaths)
	$comparison = Compare-UploadsManifests $gitManifest $localManifest
	if (@($comparison.Deleted).Count -gt 0) {
		$sampleDeleted = @($comparison.Deleted | Select-Object -First 5) -join ', '
		throw "Local source is missing tracked deployment files ($sampleDeleted). Automatic source preparation never deletes Git files."
	}
	$changedEntries = @($comparison.Added) + @($comparison.Changed)
	if ($changedEntries.Count -eq 0) {
		Write-Ok 'Local deployment source already matches the site Git repository; no commit needed.'
		return
	}

	$changedPaths = @($changedEntries | ForEach-Object { [string]$_.Path } | Sort-Object -Unique)
	foreach ($relativePath in $changedPaths) {
		if (-not (Test-UploadsManifestPath $relativePath)) { throw "Unsafe local source path: $relativePath" }
		$relativeWindowsPath = $relativePath.Replace('/', '\')
		$localFile = Join-Path $DeployConfig.LocalWpPath $relativeWindowsPath
		$gitFile = Join-Path $sourceRoot $relativeWindowsPath
		if (-not (Test-Path -LiteralPath $localFile -PathType Leaf)) { throw "Local source file not found: $relativePath" }
		New-Item -ItemType Directory -Force -Path (Split-Path -Parent $gitFile) | Out-Null
		Copy-Item -LiteralPath $localFile -Destination $gitFile -Force
	}

	Invoke-CheckedCommand $DeployConfig.GitPath (@('add', '--') + $changedPaths) $sourceRoot
	$stagedPaths = @(
		Invoke-CommandOutput $DeployConfig.GitPath @('diff', '--cached', '--name-only') $sourceRoot |
		ForEach-Object { ([string]$_).Replace('\', '/') }
	)
	$expectedStaged = @($changedPaths | Sort-Object -Unique)
	$unexpectedStaged = @($stagedPaths | Where-Object { $_ -notin $expectedStaged })
	if ($unexpectedStaged.Count -gt 0) {
		throw "Unexpected staged source paths: $($unexpectedStaged -join ', '). Nothing was committed."
	}
	Invoke-CheckedCommand $DeployConfig.GitPath @('diff', '--cached', '--check') $sourceRoot
	$stagedDiff = @(Invoke-CommandOutput $DeployConfig.GitPath @('diff', '--cached', '--name-only') $sourceRoot)
	$sourceAfterCopy = @(Get-DeploymentSourceManifest -RootPath $sourceRoot -RelativePaths $sourcePaths)
	$copyComparison = Compare-UploadsManifests $sourceAfterCopy $localManifest
	if ((@($copyComparison.Added).Count + @($copyComparison.Changed).Count + @($copyComparison.Deleted).Count) -ne 0) {
		throw 'Local WordPress source and site Git working tree still differ after the allowlisted copy.'
	}
	if ($stagedDiff.Count -eq 0) {
		Write-Ok 'Git already contains the normalized local source; no commit needed.'
		return
	}

	Write-Step ("Commit local source changes: {0}" -f ($changedPaths -join ', '))
	Invoke-CheckedCommand $DeployConfig.GitPath @('commit', '-m', $CommitMessage) $sourceRoot
	Invoke-CheckedCommand $DeployConfig.GitPath @('push') $sourceRoot
	$head = [string](Invoke-CommandOutput $DeployConfig.GitPath @('rev-parse', 'HEAD') $sourceRoot)
	$upstreamHead = [string](Invoke-CommandOutput $DeployConfig.GitPath @('rev-parse', '@{u}') $sourceRoot)
	if ($head.Trim() -cne $upstreamHead.Trim()) { throw 'Site source commit was created, but origin confirmation did not match HEAD.' }
	$afterManifest = @(Get-DeploymentSourceManifest -RootPath $sourceRoot -RelativePaths $sourcePaths)
	$afterComparison = Compare-UploadsManifests $afterManifest $localManifest
	if ((@($afterComparison.Added).Count + @($afterComparison.Changed).Count + @($afterComparison.Deleted).Count) -ne 0) {
		throw 'Local WordPress source still differs from the pushed site Git source.'
	}
	Write-Ok ("Local source committed and pushed: {0}" -f $head.Trim())
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
		$previousNativeErrorPreference = $ErrorActionPreference
		try { $ErrorActionPreference = 'Continue'; $output = @(& $FilePath @Arguments 2>&1); $exitCode = $LASTEXITCODE }
		finally { $ErrorActionPreference = $previousNativeErrorPreference }
		$output | ForEach-Object { Write-Host ([string]$_) }
		return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join "`n") }
	} finally { Pop-Location }
}

function Assert-BellaRunnerStageProfile {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration)

	$remoteUrl = ([string]$Configuration.RemoteUrl).Trim().TrimEnd('/')
	if (([string]$Configuration.Environment) -ine 'production' -or
		([string]$Configuration.SshUser) -ine 'root' -or
		$remoteUrl -ine 'https://bella-maria.com' -or
		([string]$Configuration.ExpectedRemoteDomain) -ine 'bella-maria.com' -or
		([string]$Configuration.RemoteTmpPath) -cne '/root/.wordpress-ssh-deploy/bella-maria/tmp') {
		throw 'Runner staging is restricted to the Bella Maria Production root profile and its configured temporary directory.'
	}
}

function Get-BellaRunnerCandidateFileHash {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $Path,
		[Parameter(Mandatory = $true)] [string] $ExpectedName,
		[switch] $RequireExpectedName
	)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Runner candidate file not found: $Path" }
	$item = Get-Item -LiteralPath $Path -Force
	if ($RequireExpectedName -and $item.Name -cne $ExpectedName) { throw "Unexpected candidate filename: $($item.Name); expected $ExpectedName." }
	if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Runner candidate must not be a reparse point: $Path" }
	return (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Invoke-BellaRunnerCandidateStage {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $RunnerCandidatePath,
		[Parameter(Mandatory = $true)] [string] $InstallerCandidatePath,
		[Parameter(Mandatory = $true)] [string] $RemoteTmpPath,
		[Parameter(Mandatory = $true)] [string] $Target,
		[Parameter(Mandatory = $true)] [string[]] $ScpArguments,
		[Parameter(Mandatory = $true)] [string] $WorkingDirectory
	)

	$candidates = @(
		[pscustomobject]@{ SourcePath = $RunnerCandidatePath; ExpectedName = 'server-deploy.sh'; RemoteSuffix = 'server-deploy.sh.new'; ExpectedHash = '22FE072BFEF6C9637FA7B23467B8AFF5E454A572A58EF387C2053108D5B3D467'; LocalReadbackName = 'server-deploy.sh.new'; ActualHash = '' },
		[pscustomobject]@{ SourcePath = $InstallerCandidatePath; ExpectedName = 'bella-runner-install.sh'; RemoteSuffix = 'bella-runner-install.sh'; ExpectedHash = '898AD0410257435B3174E4A9FDAA9D74698B673B77C06EF0B388F2103DE5B98B'; LocalReadbackName = 'bella-runner-install.sh'; ActualHash = '' }
	)

	foreach ($candidate in $candidates) {
		$candidate.ActualHash = Get-BellaRunnerCandidateFileHash -Path $candidate.SourcePath -ExpectedName $candidate.ExpectedName -RequireExpectedName
		if ($candidate.ActualHash -cne $candidate.ExpectedHash) {
			throw "Local candidate SHA-256 mismatch for $($candidate.ExpectedName): expected $($candidate.ExpectedHash), found $($candidate.ActualHash). No transfer was attempted."
		}
	}

	$stageId = [Guid]::NewGuid().ToString('N')
	$runnerRemotePath = "$RemoteTmpPath/bella-runner-stage-$stageId-$($candidates[0].RemoteSuffix)"
	$installerRemotePath = "$RemoteTmpPath/bella-runner-stage-$stageId-$($candidates[1].RemoteSuffix)"
	$candidates[0] | Add-Member -NotePropertyName RemotePath -NotePropertyValue $runnerRemotePath
	$candidates[1] | Add-Member -NotePropertyName RemotePath -NotePropertyValue $installerRemotePath

	$readbackDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "bella-runner-stage-$stageId"
	if (Test-Path -LiteralPath $readbackDirectory) { throw 'Could not allocate a unique local runner staging verification directory.' }
	New-Item -ItemType Directory -Path $readbackDirectory -ErrorAction Stop | Out-Null
	try {
		foreach ($candidate in $candidates) {
			Invoke-CheckedCommandRetry 'scp' ($ScpArguments + @($candidate.SourcePath, "$Target`:$($candidate.RemotePath)")) $WorkingDirectory
		}
		foreach ($candidate in $candidates) {
			$readbackPath = Join-Path $readbackDirectory $candidate.LocalReadbackName
			Invoke-CheckedCommandRetry 'scp' ($ScpArguments + @("$Target`:$($candidate.RemotePath)", $readbackPath)) $WorkingDirectory
			$readbackHash = Get-BellaRunnerCandidateFileHash -Path $readbackPath -ExpectedName $candidate.LocalReadbackName
			if ($readbackHash -cne $candidate.ExpectedHash) {
				throw "Read-back SHA-256 mismatch for $($candidate.ExpectedName): expected $($candidate.ExpectedHash), found $readbackHash."
			}
		}
	} catch {
		throw "Bella runner staging failed. Remote candidates may remain and were not removed: $runnerRemotePath ; $installerRemotePath. Cause: $($_.Exception.Message)"
	} finally {
		if (Test-Path -LiteralPath $readbackDirectory) { Remove-Item -LiteralPath $readbackDirectory -Recurse -Force -ErrorAction SilentlyContinue }
	}

	Write-Host "RUNNER_REMOTE_PATH=$runnerRemotePath"
	Write-Host "RUNNER_SHA256=$($candidates[0].ExpectedHash)"
	Write-Host "INSTALLER_REMOTE_PATH=$installerRemotePath"
	Write-Host "INSTALLER_SHA256=$($candidates[1].ExpectedHash)"
	return [pscustomobject]@{
		StageId = $stageId
		RunnerRemotePath = $runnerRemotePath
		RunnerSha256 = $candidates[0].ExpectedHash
		InstallerRemotePath = $installerRemotePath
		InstallerSha256 = $candidates[1].ExpectedHash
	}
}

if ($StageBellaRunnerCandidate) {
	Assert-BellaRunnerStageProfile -Configuration $DeployConfig
	Invoke-BellaRunnerCandidateStage -RunnerCandidatePath $RunnerCandidatePath -InstallerCandidatePath $InstallerCandidatePath -RemoteTmpPath ([string]$DeployConfig.RemoteTmpPath) -Target $target -ScpArguments $scpArgs -WorkingDirectory $repoRoot | Out-Null
	return
}

try {
	Write-Step 'Local preflight'
	Assert-Path $DeployConfig.LocalWpPath 'Local WordPress'
	Assert-Path (Join-Path $DeployConfig.LocalWpPath 'wp-config.php') 'wp-config.php'
	if ($hasCode -or $hasPlugins -or $hasMuPlugins) { Assert-Path $DeployConfig.GitPath 'Git' }
	if ($PrepareGitSource) {
		Write-Step 'Prepare the approved local WordPress source for Git'
		Sync-LocalSourceToGit -CommitMessage $Message
		return
	}
	if ($hasDatabase) {
		Assert-Path $DeployConfig.MysqldumpPath 'mysqldump'
	}
	if ($hasUploads) { Assert-Path $DeployConfig.LocalUploadsPath 'Uploads' }
	if ($Mode -eq 'full') {
		Write-Step 'Verify full deployment source freshness'
		$sourcePaths = @($DeployConfig.SyncPaths) + @($DeployConfig.PluginSyncPaths) + @($DeployConfig.MuPluginSyncPaths)
		try {
			$localSourceManifest = @(Get-DeploymentSourceManifest -RootPath $DeployConfig.LocalWpPath -RelativePaths $sourcePaths)
			$sourceGitRoot = if ($DeployConfig.SourceGitPath) { [string]$DeployConfig.SourceGitPath } else { $repoRoot }
			$deploymentSourceManifest = @(Get-DeploymentSourceManifest -RootPath $sourceGitRoot -RelativePaths $sourcePaths)
			$sourceComparison = Compare-UploadsManifests $deploymentSourceManifest $localSourceManifest
			$sourceChanges = @($sourceComparison.Added) + @($sourceComparison.Changed) + @($sourceComparison.Deleted)
			if ($sourceChanges.Count -gt 0) {
				$sample = @($sourceChanges | Select-Object -First 5 | ForEach-Object { $_.Path }) -join ', '
				Write-Warning ("FULL SOURCE WARNING: local source differs from deployment source ({0} path changes). Sample: {1}" -f $sourceChanges.Count, $sample)
				throw 'Full deploy stopped: synchronize, commit and push the current local source before retrying.'
			}
			Write-Ok 'Full deployment source matches the current local WordPress tree.'
		} catch {
			if ($_.Exception.Message -like 'Full deploy stopped:*') { throw }
			throw "Full deploy source freshness check failed: $($_.Exception.Message)"
		}
	}
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
		$uploadsPlan = Resolve-UploadsTransferPlan -TransferMode $UploadsTransferMode -BaselinePath $uploadsManifestState -CurrentManifest $currentUploadsManifest -ConfirmDeletes:$ConfirmUploadsDeletes -ConfirmFullSnapshot:$ConfirmUploadsFullSnapshot
		if ($uploadsPlan.UseDelta) {
			New-UploadsDeltaPackage -SourceDirectory $DeployConfig.LocalUploadsPath -CurrentManifest $currentUploadsManifest -BaselineManifest $uploadsPlan.Baseline -DestinationZip $uploadsDeltaZip | Out-Null
			Convert-UploadsDeltaDeleteListToLf $uploadsDeltaZip
			$useUploadsDelta = $true
			$uploadsTransferKind = 'delta'
			$comparison = $uploadsPlan.Comparison
			Write-Ok ("Uploads delta prepared: added={0}, changed={1}, deleted={2}, bytes={3}" -f $comparison.Added.Count, $comparison.Changed.Count, $comparison.Deleted.Count, (Get-Item -LiteralPath $uploadsDeltaZip).Length)
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
		if ($DeployConfig.SourceGitPath) {
			Assert-Path $DeployConfig.SourceGitPath 'Site Git source repository'
			$sourceBranch = [string](Invoke-CommandOutput $DeployConfig.GitPath @('branch', '--show-current') $DeployConfig.SourceGitPath)
			if ($sourceBranch.Trim() -cne [string]$DeployConfig.SourceGitBranch) { throw 'Site source branch does not match the approved deployment branch.' }
			$sourceHead = [string](Invoke-CommandOutput $DeployConfig.GitPath @('rev-parse', 'HEAD') $DeployConfig.SourceGitPath)
			$sourceUpstream = [string](Invoke-CommandOutput $DeployConfig.GitPath @('rev-parse', '@{u}') $DeployConfig.SourceGitPath)
			if ($sourceHead.Trim() -cne $sourceUpstream.Trim()) { throw 'Site source HEAD does not match its upstream.' }
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
	if ($hasUploads) {
		Write-Step 'Validate uploads package locally before transferring any payload'
		$packageCheck = if ($useUploadsDelta) {
			Assert-UploadsPackage -ZipPath $uploadsDeltaZip -ManifestPath $uploadsManifest -Delta -ExpectedPayload @($uploadsPlan.Comparison.Added + $uploadsPlan.Comparison.Changed) -ExpectedDeletes @($uploadsPlan.Comparison.Deleted)
		} else { Assert-UploadsPackage -ZipPath $uploadsZip -ManifestPath $uploadsManifest }
		$linuxArguments = @{ ZipPath=$(if ($useUploadsDelta) { $uploadsDeltaZip } else { $uploadsZip }); ManifestPath=$uploadsManifest; LogPath=(Join-Path $buildDir 'uploads-linux-validation.log'); UnzipPath=$LocalLinuxUnzipPath }
		if ($useUploadsDelta) { $linuxArguments.Delta=$true; $linuxArguments.ExpectedPayload=@($uploadsPlan.Comparison.Added + $uploadsPlan.Comparison.Changed) }
		Invoke-LocalLinuxUploadsCheck @linuxArguments
		$packageCheck.LinuxUnzipVerified = $true
		$packageCheck | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $buildDir 'uploads-local-validation.json') -Encoding UTF8
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
	$remoteCommand = New-RemoteDeployCommand $DeployConfig $Mode $sqlArg $uploadsArg $uploadsDeltaArg $uploadsManifestArg $selectedComponents
	$diagnosticDirectory = Join-Path $repoRoot '.deploy/logs'
	New-Item -ItemType Directory -Force -Path $diagnosticDirectory | Out-Null
	$result = Invoke-RemoteCommandCapture 'ssh' ($sshArgs + @($target, $remoteCommand)) $repoRoot
	Save-RemoteDeploymentDiagnostic -Result $result -LogPath (Join-Path $diagnosticDirectory "remote-$stamp.log")
	if ($result.ExitCode -ne 0) {
		if ($result.Output -match 'UPLOADS_DELTA_FALLBACK_REQUIRED') { throw 'Uploads deploy stopped: remote baseline is missing or drifted. Review the remote manifest and rerun an explicit full snapshot only after approval.' }
		throw "Command failed ($($result.ExitCode)): ssh; full output retained in $diagnosticDirectory"
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
