$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repoRoot 'src\WordPressSshDeploy.psm1') -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('uploads-manifest-test-' + [guid]::NewGuid().ToString('N'))
$uploads = Join-Path $root 'uploads'
$baselinePath = Join-Path $root 'baseline.tsv'
$manifestPath = Join-Path $root 'current.tsv'
$deltaPath = Join-Path $root 'delta.zip'

Describe 'Uploads manifest and delta package' {
	BeforeEach {
		if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
		New-Item -ItemType Directory -Force -Path (Join-Path $uploads '2026/09') | Out-Null
		[IO.File]::WriteAllText((Join-Path $uploads '2026/09/one.jpg'), 'one')
		[IO.File]::WriteAllText((Join-Path $uploads 'old.jpg'), 'old')
	}
	AfterEach { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } }

	It 'creates a sorted manifest with POSIX paths and hashes' {
		$manifest = @(Get-UploadsManifest $uploads)
		$manifest.Count | Should Be 2
		$manifest[0].Path | Should Be '2026/09/one.jpg'
		$manifest[0].Sha256 | Should Be ((Get-FileHash (Join-Path $uploads '2026/09/one.jpg') -Algorithm SHA256).Hash.ToLowerInvariant())
		Write-UploadsManifest $manifest $manifestPath
		@(Read-UploadsManifest $manifestPath).Count | Should Be 2
	}

	It 'detects zero-change, add, change, delete and rename' {
		$baseline = @(Get-UploadsManifest $uploads)
		$comparison = Compare-UploadsManifests $baseline $baseline
		$comparison.Added.Count | Should Be 0
		$comparison.Changed.Count | Should Be 0
		$comparison.Deleted.Count | Should Be 0
		[IO.File]::WriteAllText((Join-Path $uploads 'new.jpg'), 'new')
		[IO.File]::WriteAllText((Join-Path $uploads '2026/09/one.jpg'), 'changed')
		Remove-Item -LiteralPath (Join-Path $uploads 'old.jpg') -Force
		Move-Item -LiteralPath (Join-Path $uploads 'new.jpg') -Destination (Join-Path $uploads 'renamed.jpg')
		$current = @(Get-UploadsManifest $uploads)
		$comparison = Compare-UploadsManifests $baseline $current
		@($comparison.Added | Select-Object -ExpandProperty Path) -contains 'renamed.jpg' | Should Be $true
		@($comparison.Changed | Select-Object -ExpandProperty Path) -contains '2026/09/one.jpg' | Should Be $true
		@($comparison.Deleted) -contains 'old.jpg' | Should Be $true
	}

	It 'creates a small delta package containing only changed files and metadata' {
		$baseline = @(Get-UploadsManifest $uploads)
		$current = @(Get-UploadsManifest $uploads)
		Write-UploadsManifest $baseline $baselinePath
		[IO.File]::WriteAllText((Join-Path $uploads '2026/09/two.jpg'), 'two')
		$current = @(Get-UploadsManifest $uploads)
		$result = New-UploadsDeltaPackage -SourceDirectory $uploads -CurrentManifest $current -BaselineManifest $baseline -DestinationZip $deltaPath
		$result.Added.Count | Should Be 1
		Add-Type -AssemblyName System.IO.Compression.FileSystem
		$archive = [IO.Compression.ZipFile]::OpenRead($deltaPath)
		try {
			@($archive.Entries | Select-Object -ExpandProperty FullName) -contains 'manifest.tsv' | Should Be $true
			@($archive.Entries | Select-Object -ExpandProperty FullName) -contains 'delete.list' | Should Be $true
		} finally { $archive.Dispose() }
	}

	It 'rejects unsafe manifest paths' {
		[IO.File]::WriteAllText($manifestPath, ('{0}{1}1{1}a/../b.jpg' -f ('0' * 64), [char]9))
		$thrown = $false; try { Read-UploadsManifest $manifestPath | Out-Null } catch { $thrown = $true }; $thrown | Should Be $true
		[IO.File]::WriteAllText($manifestPath, ('{0}{1}1{1}/absolute.jpg' -f ('0' * 64), [char]9))
		$thrown = $false; try { Read-UploadsManifest $manifestPath | Out-Null } catch { $thrown = $true }; $thrown | Should Be $true
	}

	It 'keeps remote drift fail-closed without an automatic full snapshot fallback' {
		$deploy = Get-Content (Join-Path $repoRoot 'deploy.ps1') -Raw
		$server = Get-Content (Join-Path $repoRoot 'server-deploy.sh') -Raw
		$deploy | Should Match 'UPLOADS_DELTA_FALLBACK_REQUIRED'
		$deploy | Should Match 'remote baseline is missing or drifted'
		$deploy | Should Match 'Uploads delta preflight stopped'
		$deploy | Should Match 'ConfirmUploadsDeletes'
		$server | Should Match 'UPLOADS_DELTA_FALLBACK_REQUIRED'
		$server | Should Match 'commit_uploads_manifest'
	}

	It 'requires explicit confirmation before packaging local upload deletions' {
		$deploy = Get-Content (Join-Path $repoRoot 'deploy.ps1') -Raw
		$deploy | Should Match 'UPLOADS DELETE WARNING'
		$deploy | Should Match 'rerun with -ConfirmUploadsDeletes'
	}

	It 'detects stale full-deploy source before any remote command' {
		$localRoot = Join-Path $root 'local-wp'
		$sourceRoot = Join-Path $root 'deployment-source'
		foreach ($base in @($localRoot, $sourceRoot)) {
			New-Item -ItemType Directory -Force -Path (Join-Path $base 'wp-content/themes/bella-maria-child') | Out-Null
			New-Item -ItemType Directory -Force -Path (Join-Path $base 'wp-content/plugins/example') | Out-Null
			New-Item -ItemType Directory -Force -Path (Join-Path $base 'wp-content/mu-plugins') | Out-Null
		}
		[IO.File]::WriteAllText((Join-Path $localRoot 'wp-content/themes/bella-maria-child/style.css'), 'same')
		[IO.File]::WriteAllText((Join-Path $sourceRoot 'wp-content/themes/bella-maria-child/style.css'), 'same')
		[IO.File]::WriteAllText((Join-Path $localRoot 'wp-content/plugins/example/plugin.php'), 'same')
		[IO.File]::WriteAllText((Join-Path $sourceRoot 'wp-content/plugins/example/plugin.php'), 'same')
		[IO.File]::WriteAllText((Join-Path $localRoot 'wp-content/mu-plugins/loader.php'), 'same')
		[IO.File]::WriteAllText((Join-Path $sourceRoot 'wp-content/mu-plugins/loader.php'), 'same')
		$paths = @('wp-content/themes/bella-maria-child', 'wp-content/plugins/example', 'wp-content/mu-plugins/loader.php')
		$baseline = @(Get-DeploymentSourceManifest -RootPath $sourceRoot -RelativePaths $paths)
		$current = @(Get-DeploymentSourceManifest -RootPath $localRoot -RelativePaths $paths)
		(Compare-UploadsManifests $baseline $current).Changed.Count | Should Be 0
		[IO.File]::WriteAllText((Join-Path $localRoot 'wp-content/themes/bella-maria-child/style.css'), 'stale')
		$changed = Compare-UploadsManifests $baseline @(Get-DeploymentSourceManifest -RootPath $localRoot -RelativePaths $paths)
		$changed.Changed.Count | Should Be 1
		$deploy = Get-Content (Join-Path $repoRoot 'deploy.ps1') -Raw
		$deploy | Should Match 'Full deploy stopped: synchronize, commit and push'
	}
}
