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

	It 'rejects a non-Boolean production full-mode opt-in' {
		$config = $validConfiguration.Clone()
		$config.AllowProductionFull = 'true'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'AllowProductionFull must be a Boolean'
	}

	It 'accepts legacy SCP only as a Boolean profile opt-in' {
		$config = $validConfiguration.Clone()
		$config.UseLegacyScp = $true
		@(Get-DeployConfigurationErrors $config).Count | Should Be 0
		$config.UseLegacyScp = 'true'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'UseLegacyScp must be a Boolean'
	}

	It 'accepts the typed profile metadata and pull policy keys' {
		$config = $validConfiguration.Clone()
		$config.SiteId = 'example-site'
		$config.DisplayName = 'Example site'
		$config.GitRemoteName = 'origin'
		$config.GitBranch = 'main'
		$config.CodeRepositoryPath = 'C:\Sites\example-site'
		$config.WorkRoot = 'C:\Deploy\example-site'
		$config.MysqlPath = 'C:\laragon\bin\mysql.exe'
		$config.LocalPhpPath = 'C:\laragon\bin\php.exe'
		$config.LocalWpCliPath = 'C:\tools\wp-cli.phar'
		$config.ExpectedDbTablePrefix = 'wp_'
		$config.ExpectedDbTableCount = 19
		$config.ExpectedPullDbTableCount = 19
		$config.ExpectedWordPressCoreVersion = '7.0.4'
		$config.FullSyncPaths = @('wp-content/themes')
		$config.ProtectedSyncPaths = @('wp-config.php', '.htaccess')
		$config.PullEnabled = $true
		$config.AllowProductionPull = $true
		$config.LocalBackupDirectory = 'C:\Deploy\example-site\backups'
		$config.AllowedPullPaths = @('wp-content/uploads')
		$config.FullPullPaths = @('wp-content/uploads')
		$config.ExcludedPullPaths = @('wp-content/cache')
		$config.RequirePullConfirmation = $true
		$config.KeepLocalBackups = 5
		$config.KeepBackupDays = 30
		$config.MaxBackupSizeMB = 10240
		$config.MinimumPullDbTableCount = 19
		$config.AllowDestructiveLocalReplace = $false
		$config.CorePolicy = 'preserve-local-core'
		@(Get-DeployConfigurationErrors $config).Count | Should Be 0

		$config.ExpectedDbTablePrefix = 'wp-'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'ExpectedDbTablePrefix contains unsupported characters'
	}

	It 'requires the database prefix and exact table count together' {
		$config = $validConfiguration.Clone()
		$config.ExpectedDbTablePrefix = 'wp_'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'ExpectedDbTablePrefix and ExpectedDbTableCount must be configured together'
		$config.Remove('ExpectedDbTablePrefix')
		$config.ExpectedDbTableCount = 19
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'ExpectedDbTablePrefix and ExpectedDbTableCount must be configured together'
	}

	It 'applies safety and duplicate checks to profile path arrays' {
		$config = $validConfiguration.Clone()
		$config.FullSyncPaths = @('.git')
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'Unsafe FullSyncPaths value'
		$config.FullSyncPaths = @('wp-content/uploads', 'WP-CONTENT/UPLOADS')
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'Duplicate FullSyncPaths value'
		$config.FullSyncPaths = @('wp-content/uploads')
		$config.ProtectedSyncPaths = @('wp-config.php', '.git')
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'Unsafe ProtectedSyncPaths value'
	}

	It 'rejects path control characters without throwing and blocks option-like Git names' {
		foreach ($path in @("wp-content|x", "wp-content`r`nx")) {
			$config = $validConfiguration.Clone()
			$config.FullSyncPaths = @($path)
			$errors = $null
			try { $errors = (Get-DeployConfigurationErrors $config) -join "`n" } catch { throw 'Path validation must fail closed without throwing.' }
			$errors | Should Match 'Unsafe FullSyncPaths value'
		}

		$config = $validConfiguration.Clone()
		$config.GitRemoteName = '--upload-pack'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'GitRemoteName contains unsupported characters'
		$config.GitRemoteName = 'origin'
		$config.GitBranch = '--upload-pack'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'GitBranch contains unsupported characters'
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
