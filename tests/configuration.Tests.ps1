$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repoRoot 'src\WordPressSshDeploy.psm1') -Force
. (Join-Path $repoRoot 'deploy.config.example.ps1')
$validConfiguration = $DeployConfig

Describe 'Deploy configuration validation' {
	It 'accepts the public example' {
		@(Get-DeployConfigurationErrors $validConfiguration).Count | Should Be 0
	}

	It 'accepts all supported environment names' {
		foreach ($environment in @('development', 'staging', 'production')) {
			$config = $validConfiguration.Clone()
			$config.Environment = $environment
			@(Get-DeployConfigurationErrors $config).Count | Should Be 0
		}
	}

	It 'rejects an unknown environment' {
		$config = $validConfiguration.Clone()
		$config.Environment = 'qa'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'Environment must be'
	}

	It 'rejects unknown and missing keys' {
		$config = $validConfiguration.Clone()
		$config.TypoValue = 'value'
		$config.Remove('RemoteUrl')
		$errors = (Get-DeployConfigurationErrors $config) -join "`n"
		$errors | Should Match 'Unknown configuration key: TypoValue'
		$errors | Should Match 'Missing configuration value: RemoteUrl'
	}

	It 'rejects a remote URL with a different domain' {
		$config = $validConfiguration.Clone()
		$config.RemoteUrl = 'https://other.example.com'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'ExpectedRemoteDomain'
	}

	It 'rejects unsafe SyncPaths values' {
		foreach ($path in @('.', '..', '../theme', '/absolute', 'folder/../theme', '.git', 'wp-config.php', 'folder\theme')) {
			$config = $validConfiguration.Clone()
			$config.SyncPaths = @($path)
			(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'Unsafe SyncPaths'
		}
	}

	It 'rejects duplicate SyncPaths without case sensitivity' {
		$config = $validConfiguration.Clone()
		$config.SyncPaths = @('wp-content/themes/example-theme', 'WP-CONTENT/THEMES/EXAMPLE-THEME')
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'Duplicate SyncPaths'
	}

	It 'rejects a runner inside the writable repository' {
		$config = $validConfiguration.Clone()
		$config.RemoteRunnerPath = '/srv/repos/example-site/server-deploy.sh'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'RemoteRunnerPath must be outside'
	}

	It 'rejects string values for integer fields' {
		$config = $validConfiguration.Clone()
		$config.SshPort = '22'
		$config.KeepBackups = '10'
		$errors = (Get-DeployConfigurationErrors $config) -join "`n"
		$errors | Should Match 'SshPort must be an integer'
		$errors | Should Match 'KeepBackups must be an integer'
	}

	It 'requires bounded integer free-space thresholds' {
		$config = $validConfiguration.Clone()
		$config.MinimumLocalFreeSpaceMB = 0
		$config.MinimumRemoteFreeSpaceMB = '1024'
		$errors = (Get-DeployConfigurationErrors $config) -join "`n"
		$errors | Should Match 'MinimumLocalFreeSpaceMB must be an integer'
		$errors | Should Match 'MinimumRemoteFreeSpaceMB must be an integer'
	}
}
