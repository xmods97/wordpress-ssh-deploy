$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repoRoot 'src\WordPressSshDeploy.psm1') -Force
. (Join-Path $repoRoot 'deploy.config.example.ps1')

Assert-DeployConfiguration -Configuration $DeployConfig
Write-Output 'Valid example: OK'

$cases = @()

$badEnvironment = $DeployConfig.Clone()
$badEnvironment.Environment = 'qa'
$cases += ,@($badEnvironment, 'Environment must be')

$badDomain = $DeployConfig.Clone()
$badDomain.ExpectedRemoteDomain = 'other.example.com'
$cases += ,@($badDomain, 'does not match ExpectedRemoteDomain')

$badSync = $DeployConfig.Clone()
$badSync.SyncPaths = @('.')
$cases += ,@($badSync, 'Unsafe SyncPaths')

$badTablePrefix = $DeployConfig.Clone()
$badTablePrefix.ExpectedDbTablePrefix = 'wp-unsafe'
$cases += ,@($badTablePrefix, 'ExpectedDbTablePrefix')

$unknown = $DeployConfig.Clone()
$unknown.TypoValue = 'x'
$cases += ,@($unknown, 'Unknown configuration key')

$stringPort = $DeployConfig.Clone()
$stringPort.SshPort = '22'
$cases += ,@($stringPort, 'SshPort must be an integer')

$nestedTemporaryPath = $DeployConfig.Clone()
$nestedTemporaryPath.RemoteTmpPath = '/var/www/staging.example.com/.deploy'
$cases += ,@($nestedTemporaryPath, 'RemoteTmpPath must not be inside RemoteWpPath')

$runnerInsideRepository = $DeployConfig.Clone()
$runnerInsideRepository.RemoteRunnerPath = '/srv/repos/example-site/server-deploy.sh'
$cases += ,@($runnerInsideRepository, 'RemoteRunnerPath must be outside')

foreach ($case in $cases) {
	$messages = @(Get-DeployConfigurationErrors -Configuration $case[0])
	if (-not ($messages -match $case[1])) {
		throw "Expected validation failure not found: $($case[1])"
	}
}
Write-Output 'Invalid cases rejected: 8/8'

$nonDictionary = @(Get-DeployConfigurationErrors -Configuration ([pscustomobject] @{}))
if (-not ($nonDictionary -match 'IDictionary')) {
	throw 'Non-dictionary validation failed.'
}
Write-Output 'Type validation: OK'

Assert-DeployModeAllowed -Environment development -Mode full
Assert-DeployModeAllowed -Environment staging -Mode db
Assert-DeployModeAllowed -Environment production -Mode code

foreach ($forbiddenMode in @('db', 'full')) {
	try {
		Assert-DeployModeAllowed -Environment production -Mode $forbiddenMode
		throw "Production mode was not rejected: $forbiddenMode"
	} catch {
		if ($_.Exception.Message -notmatch 'forbidden for production') {
			throw
		}
	}
}
Write-Output 'Production mode policy: OK'
