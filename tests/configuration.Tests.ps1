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

	It 'accepts separate full and protected sync paths' {
		$config = $validConfiguration.Clone()
		$config.FullSyncPaths = @('wp-content/themes/example-theme', 'wp-content/plugins/example-plugin')
		$config.ProtectedSyncPaths = @('wp-config.php')
		@(Get-DeployConfigurationErrors $config).Count | Should Be 0
	}

	It 'rejects protected paths outside the explicit protected list rules' {
		$config = $validConfiguration.Clone()
		$config.ProtectedSyncPaths = @('../secrets', '.git/config')
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'Unsafe ProtectedSyncPaths value'
	}

	It 'does not allow a protected path in the ordinary full sync list' {
		$config = $validConfiguration.Clone()
		$config.FullSyncPaths = @('wp-config.php')
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'Unsafe FullSyncPaths value'
		$config.FullSyncPaths = @('wp-content')
		$config.ProtectedSyncPaths = @('wp-content/private.php')
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'overlaps ProtectedSyncPaths'
	}

	It 'does not allow a protected descendant in the ordinary code sync list' {
		$config = $validConfiguration.Clone()
		$config.SyncPaths = @('wp-content')
		$config.ProtectedSyncPaths = @('wp-content/private.php')
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'SyncPaths overlaps ProtectedSyncPaths'
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

	It 'requires the expected database table count' {
		$config = $validConfiguration.Clone()
		$config.Remove('ExpectedDbTableCount')
		(Get-DeployConfigurationErrors $config) -join "`n" | Should Match 'Missing configuration value: ExpectedDbTableCount'
	}

	It 'rejects a zero, negative, or non-integer expected table count' {
		foreach ($value in @(0, -1, '12', 12.5)) {
			$config = $validConfiguration.Clone()
			$config.ExpectedDbTableCount = $value
			(Get-DeployConfigurationErrors $config) -join "`n" |
				Should Match 'ExpectedDbTableCount must be an integer greater than or equal to 1'
		}
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
			[IO.File]::WriteAllText($file, 'CREATE TABLE `zxqrtvwy_options` (id int);', (New-Object Text.UTF8Encoding($false)))
			$message = ''
			try { Assert-SqlDumpTablePrefix $file 'zxQrTvWy_' } catch { $message = $_.Exception.Message }
			$message | Should Match 'SQL dump table prefix mismatch'
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'normalizes the Windows table prefix only for the expected table set' {
		$file = [IO.Path]::GetTempFileName()
		try {
			$sql = (1..12 | ForEach-Object { "CREATE TABLE ``zxqrtvwy_table$_`` (id int);" }) -join "`n"
			[IO.File]::WriteAllText($file, $sql, (New-Object Text.UTF8Encoding($false)))
			Normalize-SqlDumpTablePrefix $file 'zxQrTvWy_' 12
			$content = [IO.File]::ReadAllText($file)
			$content.Contains('`zxqrtvwy_') | Should Be $false
			$content.Contains('`zxQrTvWy_table12') | Should Be $true
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'rejects a Windows dump with a foreign table identifier' {
		$file = [IO.Path]::GetTempFileName()
		try {
			$sql = (1..11 | ForEach-Object { "CREATE TABLE ``zxqrtvwy_table$_`` (id int);" }) -join "`n"
			$sql += "`nCREATE TABLE ``other_table`` (id int);"
			[IO.File]::WriteAllText($file, $sql, (New-Object Text.UTF8Encoding($false)))
			$message = ''
			try { Normalize-SqlDumpTablePrefix $file 'zxQrTvWy_' 12 } catch { $message = $_.Exception.Message }
			$message | Should Match 'unexpected table identifiers'
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'rejects a dump whose table count differs from the expected count' {
		$file = [IO.Path]::GetTempFileName()
		try {
			$sql = (1..13 | ForEach-Object { "CREATE TABLE ``zxqrtvwy_table$_`` (id int);" }) -join "`n"
			[IO.File]::WriteAllText($file, $sql, (New-Object Text.UTF8Encoding($false)))
			$message = ''
			try { Normalize-SqlDumpTablePrefix $file 'zxQrTvWy_' 12 } catch { $message = $_.Exception.Message }
			$message | Should Match 'SQL dump table count mismatch'
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'preserves non-UTF8 bytes byte-for-byte while normalizing' {
		$file = [IO.Path]::GetTempFileName()
		try {
			$sql = (1..12 | ForEach-Object { "CREATE TABLE ``zxqrtvwy_table$_`` (id int);" }) -join "`n"
			$sql += "`nINSERT INTO ``zxqrtvwy_table1`` VALUES ('"
			$payload = [Text.Encoding]::ASCII.GetBytes($sql)
			$tail = [Text.Encoding]::ASCII.GetBytes("');")
			[IO.File]::WriteAllBytes($file, [byte[]] ($payload + @([byte] 0xA9) + $tail))
			$before = [IO.File]::ReadAllBytes($file)

			Normalize-SqlDumpTablePrefix $file 'zxQrTvWy_' 12

			$after = [IO.File]::ReadAllBytes($file)
			$after.Length | Should Be $before.Length
			($after -contains 0xA9) | Should Be $true
			([BitConverter]::ToString($after) -match 'EF-BF-BD') | Should Be $false

			# Every differing byte must be an ASCII case flip; nothing else may change.
			$unexpected = 0
			for ($index = 0; $index -lt $before.Length; $index++) {
				if ($before[$index] -eq $after[$index]) { continue }
				if ([Math]::Abs([int] $before[$index] - [int] $after[$index]) -ne 32) { $unexpected++ }
			}
			$unexpected | Should Be 0

			$text = ([Text.Encoding]::GetEncoding(28591)).GetString($after)
			$text.Contains('`zxQrTvWy_table1') | Should Be $true
			$text.Contains('`zxqrtvwy_') | Should Be $false
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'does not rewrite the prefix inside a string literal or a comment' {
		$file = [IO.Path]::GetTempFileName()
		try {
			$sql = (1..12 | ForEach-Object { "CREATE TABLE ``zxqrtvwy_table$_`` (id int);" }) -join "`n"
			$sql += "`n-- Table structure for table ``zxqrtvwy_table1``"
			$sql += "`nINSERT INTO ``zxqrtvwy_table1`` VALUES ('SELECT * FROM ``zxqrtvwy_posts``');"
			[IO.File]::WriteAllText($file, $sql, (New-Object Text.UTF8Encoding($false)))

			Normalize-SqlDumpTablePrefix $file 'zxQrTvWy_' 12

			$content = [IO.File]::ReadAllText($file)
			$content.Contains('INSERT INTO `zxQrTvWy_table1`') | Should Be $true
			$content.Contains('FROM `zxqrtvwy_posts`') | Should Be $true
			$content.Contains('-- Table structure for table `zxqrtvwy_table1`') | Should Be $true
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'does not rewrite the prefix inside a multi-line block comment' {
		$file = [IO.Path]::GetTempFileName()
		try {
			$sql = (1..12 | ForEach-Object { "CREATE TABLE ``zxqrtvwy_table$_`` (id int);" }) -join "`n"
			$sql += "`n/* block comment opened here"
			$sql += "`n   mentions ``zxqrtvwy_table1`` on a later line"
			$sql += "`n   and ``zxqrtvwy_posts`` again before closing */"
			$sql += "`nDROP TABLE IF EXISTS ``zxqrtvwy_table1``;"
			[IO.File]::WriteAllText($file, $sql, (New-Object Text.UTF8Encoding($false)))

			Normalize-SqlDumpTablePrefix $file 'zxQrTvWy_' 12

			$content = [IO.File]::ReadAllText($file)
			$content.Contains('mentions `zxqrtvwy_table1` on a later line') | Should Be $true
			$content.Contains('and `zxqrtvwy_posts` again before closing */') | Should Be $true
			$content.Contains('DROP TABLE IF EXISTS `zxQrTvWy_table1`;') | Should Be $true
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}

	It 'still rewrites identifiers inside executable conditional comments' {
		$file = [IO.Path]::GetTempFileName()
		try {
			$sql = '/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;'
			$sql += "`n" + ((1..12 | ForEach-Object { "CREATE TABLE ``zxqrtvwy_table$_`` (id int);" }) -join "`n")
			$sql += "`n/*!40000 ALTER TABLE ``zxqrtvwy_table1`` DISABLE KEYS */;"
			$sql += "`nLOCK TABLES ``zxqrtvwy_table2`` WRITE;"
			[IO.File]::WriteAllText($file, $sql, (New-Object Text.UTF8Encoding($false)))

			Normalize-SqlDumpTablePrefix $file 'zxQrTvWy_' 12

			$content = [IO.File]::ReadAllText($file)
			$content.Contains('/*!40000 ALTER TABLE `zxQrTvWy_table1` DISABLE KEYS */;') | Should Be $true
			$content.Contains('LOCK TABLES `zxQrTvWy_table2` WRITE;') | Should Be $true
			$content.Contains('`zxqrtvwy_') | Should Be $false
		} finally {
			Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
		}
	}
}
