$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repoRoot 'src\WordPressSshDeploy.psm1') -Force

Describe 'Release package integrity gates' {
	It 'rejects database and uploads content changes after manifest creation' {
		$root = Join-Path ([IO.Path]::GetTempPath()) ('release-' + [guid]::NewGuid().ToString('N'))
		New-Item -ItemType Directory -Path $root | Out-Null
		try {
			$sql = Join-Path $root 'database.sql'
			@('-- MySQL dump fixture with enough bytes for the local dump gate', 'CREATE TABLE `wp_demo` (`id` int);') | Set-Content -LiteralPath $sql -Encoding utf8
			$uploadSource = Join-Path $root 'upload-source'
			New-Item -ItemType Directory -Path $uploadSource | Out-Null
			[IO.File]::WriteAllText((Join-Path $uploadSource 'file.txt'), 'one', (New-Object Text.UTF8Encoding($false)))
			Add-Type -AssemblyName System.IO.Compression.FileSystem
			$uploads = Join-Path $root 'uploads.zip'
			[IO.Compression.ZipFile]::CreateFromDirectory($uploadSource, $uploads)
			$sqlSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $sql).Hash
			$uploadsSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $uploads).Hash
			[ordered]@{ source = [ordered]@{ canonicalSource = $true }; database = [ordered]@{ rawDumpSha256 = $sqlSha; tablePrefix = 'wp_'; exactTableCount = 1 } } |
				ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'release-manifest.json') -Encoding utf8
			@([ordered]@{ path = 'uploads.zip'; sha256 = $uploadsSha }) | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'artifact-hashes.json') -Encoding utf8
			$config = @{ ExpectedDbTablePrefix = 'wp_'; ExpectedDbTableCount = 1 }
			{ Assert-ReleasePackage $root $config $true } | Should Not Throw
			$manifestText = Get-Content -Raw -LiteralPath (Join-Path $root 'release-manifest.json')
			$manifestWithoutSha = $manifestText | ConvertFrom-Json
			$manifestWithoutSha.database.PSObject.Properties.Remove('rawDumpSha256')
			$manifestWithoutSha | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'release-manifest.json') -Encoding utf8
			$message = ''
			try { Assert-ReleasePackage $root $config $true } catch { $message = $_.Exception.Message }
			$message | Should Match 'database SHA is missing'
			[IO.File]::WriteAllText((Join-Path $root 'release-manifest.json'), $manifestText, (New-Object Text.UTF8Encoding($false)))
			$artifactHashesPath = Join-Path $root 'artifact-hashes.json'
			$artifactHashesText = Get-Content -Raw -LiteralPath $artifactHashesPath
			'[]' | Set-Content -LiteralPath $artifactHashesPath -Encoding utf8
			$message = ''
			try { Assert-ReleasePackage $root $config $true } catch { $message = $_.Exception.Message }
			$message | Should Match 'uploads SHA is missing'
			[IO.File]::WriteAllText($artifactHashesPath, $artifactHashesText, (New-Object Text.UTF8Encoding($false)))

			Add-Content -LiteralPath $sql -Value 'INSERT INTO `wp_demo` VALUES (1);'
			$thrown = $false
			try { Assert-ReleasePackage $root $config $true } catch { $thrown = $true }
			$thrown | Should Be $true
			[IO.File]::WriteAllText((Join-Path $uploadSource 'file.txt'), 'two', (New-Object Text.UTF8Encoding($false)))
			Remove-Item -LiteralPath $uploads -Force
			[IO.Compression.ZipFile]::CreateFromDirectory($uploadSource, $uploads)
			$thrown = $false
			try { Assert-ReleasePackage $root $config $true } catch { $thrown = $true }
			$thrown | Should Be $true
		} finally {
			Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
		}
	}
}
