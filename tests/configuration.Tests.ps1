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

	It 'rejects an unsafe expected database table prefix' {
		$config = $validConfiguration.Clone()
		$config.ExpectedDbTablePrefix = 'wp-unsafe'
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'ExpectedDbTablePrefix'
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

Describe 'SQL table-prefix validation' {
	It 'accepts SQL that creates only the expected prefix' {
		$file = [IO.Path]::GetTempFileName()
		try {
			[IO.File]::WriteAllText($file, "CREATE TABLE ``wp_options`` (id int);`nCREATE TABLE ``wp_posts`` (id int);", (New-Object Text.UTF8Encoding($false)))
			{ Assert-SqlDumpTablePrefix $file 'wp_' } | Should Not Throw
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'rejects a SQL table prefix with a different case or name' {
		$file = [IO.Path]::GetTempFileName()
		try {
			[IO.File]::WriteAllText($file, 'CREATE TABLE `kqsmtmooh_options` (id int);', (New-Object Text.UTF8Encoding($false)))
			$message = ''
			try { Assert-SqlDumpTablePrefix $file 'kqSmtmoOH_' } catch { $message = $_.Exception.Message }
			$message | Should Match 'SQL dump table prefix mismatch'
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'normalizes the Windows table prefix only for the expected table set' {
		$file = [IO.Path]::GetTempFileName()
		try {
			$sql = (1..12 | ForEach-Object { "CREATE TABLE ``kqsmtmooh_table$_`` (id int);" }) -join "`n"
			[IO.File]::WriteAllText($file, $sql, (New-Object Text.UTF8Encoding($false)))
			Normalize-SqlDumpTablePrefix $file 'kqSmtmoOH_' 12
			$content = [IO.File]::ReadAllText($file)
			$content | Should Not Match '``kqsmtmooh_'
			$content.Contains('`kqSmtmoOH_table12') | Should Be $true
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'rejects a Windows dump with a foreign table identifier' {
		$file = [IO.Path]::GetTempFileName()
		try {
			$sql = (1..11 | ForEach-Object { "CREATE TABLE ``kqsmtmooh_table$_`` (id int);" }) -join "`n"
			$sql += "`nCREATE TABLE ``other_table`` (id int);"
			[IO.File]::WriteAllText($file, $sql, (New-Object Text.UTF8Encoding($false)))
			$message = ''
			try { Normalize-SqlDumpTablePrefix $file 'kqSmtmoOH_' 12 } catch { $message = $_.Exception.Message }
			$message | Should Match 'unexpected table identifiers'
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}
}
