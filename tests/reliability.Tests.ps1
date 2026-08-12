$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repoRoot 'src\WordPressSshDeploy.psm1') -Force
$serverSource = Get-Content -LiteralPath (Join-Path $repoRoot 'server-deploy.sh') -Raw

Describe 'Local artifact validation' {
	It 'accepts a structured SQL dump and rejects an incomplete file' {
		$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
		New-Item -ItemType Directory -Path $tempDirectory | Out-Null
		try {
			$valid = Join-Path $tempDirectory 'valid.sql'
			$invalid = Join-Path $tempDirectory 'invalid.sql'
			@('-- MySQL dump 10.13  Distrib fixture','-- Table structure for table `wp_options`','CREATE TABLE `wp_options` (`id` bigint);','INSERT INTO `wp_options` VALUES (1);') | Set-Content -LiteralPath $valid -Encoding ASCII
			Set-Content -LiteralPath $invalid -Value 'not a dump' -Encoding ASCII
			{ Assert-SqlDumpFile $valid } | Should Not Throw
			{ Assert-SqlDumpFile $invalid } | Should Throw 'empty or unexpectedly small'
		} finally {
			Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
		}
	}

	It 'reads every ZIP entry and rejects a truncated archive' {
		$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
		$source = Join-Path $tempDirectory 'source'
		New-Item -ItemType Directory -Path $source -Force | Out-Null
		try {
			Set-Content -LiteralPath (Join-Path $source 'file.txt') -Value 'fixture' -Encoding ASCII
			$valid = Join-Path $tempDirectory 'valid.zip'
			$invalid = Join-Path $tempDirectory 'invalid.zip'
			Add-Type -AssemblyName System.IO.Compression.FileSystem
			[IO.Compression.ZipFile]::CreateFromDirectory($source, $valid)
			[IO.File]::WriteAllBytes($invalid, ([IO.File]::ReadAllBytes($valid)[0..15]))
			{ Assert-ZipArchiveFile $valid } | Should Not Throw
			{ Assert-ZipArchiveFile $invalid } | Should Throw 'integrity check failed'
		} finally {
			Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
		}
	}

	It 'measures directory content and rejects impossible free-space requirements' {
		$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
		New-Item -ItemType Directory -Path $tempDirectory | Out-Null
		try {
			[IO.File]::WriteAllBytes((Join-Path $tempDirectory 'bytes.bin'), (New-Object byte[] 128))
			(Get-DirectoryContentSizeBytes $tempDirectory) | Should Be 128
			{ Assert-AvailableDiskSpace $tempDirectory 1 'Fixture disk' } | Should Not Throw
			{ Assert-AvailableDiskSpace $tempDirectory ([long]::MaxValue) 'Fixture disk' } | Should Throw 'does not have enough free space'
		} finally {
			Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
		}
	}
}

Describe 'Remote replacement and rollback guards' {
	It 'uses staged directories for code and uploads replacement' {
		$serverSource | Should Match 'target_path\.__new__\.\$timestamp'
		$serverSource | Should Match 'Atomic code replacement failed'
		$serverSource | Should Match 'Atomic uploads replacement failed'
	}

	It 'validates SQL and ZIP before destructive operations' {
		$serverSource | Should Match 'assert_sql_dump "\$SQL_FILE"'
		$serverSource | Should Match 'unzip -tq "\$UPLOADS_ZIP"'
	}

	It 'contains an automatic database rollback path' {
		$serverSource | Should Match 'mysql_import_file "\$BACKUP_FILE"'
		$serverSource | Should Match 'rollback completed'
	}

	It 'does not depend on non-POSIX xargs -r' {
		$serverSource | Should Not Match 'xargs -r'
	}
}
