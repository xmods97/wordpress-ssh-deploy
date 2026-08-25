[CmdletBinding()]
param(
    [string] $ReleaseId = 'bella-maria-v2026.08.25.01',
    [string] $LocalWpPath = 'D:\laragon\www\bella-maria.local',
    [string] $ReleaseRoot = 'D:\OneDrive\Документы\Scripts of deploy\.bella-maria-deploy-prep',
    [string] $PhpPath = 'D:\laragon\bin\php\php-8.3.30-Win32-vs16-x64\php.exe',
    [string] $WpCliPath = 'D:\wordpress-ssh-deploy\tools\wp-cli.phar',
    [string] $MysqlBinPath = 'D:\laragon\bin\mysql\mysql-8.4.3-winx64\bin'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Path([string] $Path, [string] $Label) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Label not found: $Path" }
}

function Get-Sha256([string] $Path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-RelativePath([string] $Root, [string] $Path) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes root: $Path"
    }
    $pathFull.Substring($rootFull.Length).Replace('\', '/')
}

function Invoke-WpCli([string[]] $Arguments) {
    & $PhpPath $WpCliPath "--path=$LocalWpPath" @Arguments
    if ($LASTEXITCODE -ne 0) { throw "WP-CLI failed: $($Arguments -join ' ')" }
}

Assert-Path $LocalWpPath 'Local WordPress'
Assert-Path (Join-Path $LocalWpPath 'wp-config.php') 'Local wp-config.php'
Assert-Path $PhpPath 'PHP'
Assert-Path $WpCliPath 'WP-CLI phar'
Assert-Path (Join-Path $MysqlBinPath 'mysql.exe') 'MySQL'
Assert-Path (Join-Path $MysqlBinPath 'mysqldump.exe') 'mysqldump'
$env:Path = "$MysqlBinPath;$env:Path"

$uploadsSource = Join-Path $LocalWpPath 'wp-content\uploads'
$childSource = Join-Path $LocalWpPath 'wp-content\themes\bella-maria-child'
Assert-Path $uploadsSource 'Canonical uploads'
Assert-Path $childSource 'Canonical child theme'
Assert-Path $ReleaseRoot 'Release root'

$releasePath = Join-Path $ReleaseRoot $ReleaseId
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stagingPath = "$releasePath.__staging__$stamp"
if (Test-Path -LiteralPath $releasePath) { throw "Release already exists: $releasePath" }
if (Test-Path -LiteralPath $stagingPath) { throw "Staging path already exists: $stagingPath" }

$excludedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
[void] $excludedNames.Add('webp-converter-for-media-test.png')
[void] $excludedNames.Add('webp-converter-for-media-test.png2')
$excludedDirectories = @('et-cache', 'cache', 'upgrade', 'upgrade-temp-backup')

New-Item -ItemType Directory -Path $stagingPath | Out-Null
try {
    $payloadRoot = Join-Path $stagingPath 'payload'
    $payloadUploads = Join-Path $payloadRoot 'wp-content\uploads'
    $payloadThemes = Join-Path $payloadRoot 'wp-content\themes'
    New-Item -ItemType Directory -Force -Path $payloadUploads, $payloadThemes | Out-Null

    Copy-Item -LiteralPath $childSource -Destination $payloadThemes -Recurse -Force
    $childTarget = Join-Path $payloadThemes 'bella-maria-child'

    $mediaManifest = [Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $uploadsSource -File -Recurse -Force | Sort-Object FullName) {
        $relative = Get-RelativePath $uploadsSource $file.FullName
        $segments = $relative -split '/'
        $skip = $file.Extension -ieq '.mov' -or $excludedNames.Contains($file.Name) -or @($segments | Where-Object { $_ -in $excludedDirectories }).Count -gt 0
        if ($skip) { continue }
        $destination = Join-Path $payloadUploads ($relative.Replace('/', '\'))
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        $mediaManifest.Add([pscustomobject]@{
            path = "payload/wp-content/uploads/$relative"
            bytes = (Get-Item -LiteralPath $destination).Length
            sha256 = Get-Sha256 $destination
        })
    }
    $mediaManifest | Export-Csv -LiteralPath (Join-Path $stagingPath 'media-manifest.csv') -NoTypeInformation -Encoding utf8

    $childManifest = Get-ChildItem -LiteralPath $childTarget -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{
            path = "payload/wp-content/themes/bella-maria-child/$(Get-RelativePath $childTarget $_.FullName)"
            bytes = $_.Length
            sha256 = Get-Sha256 $_.FullName
        }
    }
    $childManifest | Export-Csv -LiteralPath (Join-Path $stagingPath 'child-theme-manifest.csv') -NoTypeInformation -Encoding utf8

    $localDump = Join-Path $stagingPath 'database.sql'
    Invoke-WpCli @('db', 'export', $localDump) | Out-Null
    $dumpText = [IO.File]::ReadAllText($localDump)
    $allDumpTableCount = [regex]::Matches($dumpText, '(?m)^CREATE TABLE `[^`]+`').Count
    $dumpTableCount = [regex]::Matches($dumpText, '(?m)^CREATE TABLE `wpmq_[^`]+`').Count
    if ($allDumpTableCount -ne 19 -or $dumpTableCount -ne 19) {
        throw "Unexpected raw dump table count: total=$allDumpTableCount wpmq_=$dumpTableCount"
    }
    $localUrlOccurrences = [regex]::Matches($dumpText, [regex]::Escape('http://bella-maria.local.test')).Count
    $localHostOccurrences = [regex]::Matches($dumpText, [regex]::Escape('bella-maria.local.test')).Count
    if ($localHostOccurrences -ne $localUrlOccurrences) {
        throw "Unexpected local URL forms: host=$localHostOccurrences http=$localUrlOccurrences"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($payloadUploads, (Join-Path $stagingPath 'uploads.zip'), [IO.Compression.CompressionLevel]::Optimal, $false)
    [IO.Compression.ZipFile]::CreateFromDirectory($childTarget, (Join-Path $stagingPath 'bella-maria-child.zip'), [IO.Compression.CompressionLevel]::Optimal, $false)

    Set-Content -LiteralPath (Join-Path $stagingPath 'RELEASE_ID') -Value $ReleaseId -NoNewline -Encoding utf8
    @(
        "Release ID: $ReleaseId"
        ''
        'This package is rebuilt from the current Laragon canonical DB, child theme and uploads.'
        'database.sql is the raw canonical local dump with all 19 wpmq_ tables.'
        'The Bella runner performs WordPress-aware local-to-production URL rewrite after import and rolls back on rewrite or verification failure.'
        'uploads.zip excludes MOV source, cache/et-cache/upgrade paths and explicit QA test images.'
        'Production operational rows are backed up by the runner before the explicitly approved full import.'
        'Remote-only production media deletion remains subject to a fresh exact mirror manifest and separate deploy approval.'
    ) | Set-Content -LiteralPath (Join-Path $stagingPath 'RELEASE-README.md') -Encoding utf8
    @(
        "Release $ReleaseId is local-only until a separately approved production deploy checkpoint."
        'No production deletion is authorized from this file alone.'
        'Exact remote-only deletion targets require a fresh remote uploads manifest comparison.'
    ) | Set-Content -LiteralPath (Join-Path $stagingPath 'media-deletion-manifest.pending.txt') -Encoding utf8

    $releaseManifest = [ordered]@{
        releaseId = $ReleaseId
        builtAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        source = [ordered]@{
            localWpPath = $LocalWpPath
            canonicalSource = $true
            gitRepository = 'https://github.com/xmods97/bella-maria.com.git'
            gitCommit = '245e8821b62cc34c8e8677d4a368081e5201c1d5'
            remoteBranch = 'codex/bella-maria-v2026-08-23-02'
        }
        previousRelease = [ordered]@{
            releaseId = 'bella-maria-v2026.08.23.02'
            status = 'invalid-not-deployable'
            packagePath = (Join-Path $ReleaseRoot 'bella-maria-v2026.08.23.02')
        }
        database = [ordered]@{
            rawCanonicalDump = 'database.sql'
            rawDumpSha256 = Get-Sha256 $localDump
            tablePrefix = 'wpmq_'
            exactTableCount = $dumpTableCount
            localUrlOccurrences = $localUrlOccurrences
            urlRewrite = 'server-side WordPress-aware rewrite after import; guid excluded; rollback on failure'
            importPolicy = 'full-local-canonical-by-explicit-user-decision'
        }
        media = [ordered]@{
            root = 'payload/wp-content/uploads'
            files = $mediaManifest.Count
            bytes = [long](($mediaManifest | Measure-Object -Property bytes -Sum).Sum)
            manifest = 'media-manifest.csv'
            manifestSha256 = Get-Sha256 (Join-Path $stagingPath 'media-manifest.csv')
            excluded = @('*.mov', 'wp-content/et-cache', 'wp-content/cache', 'wp-content/upgrade', 'wp-content/upgrade-temp-backup', 'webp-converter-for-media-test.png', 'webp-converter-for-media-test.png2')
            deletionPolicy = 'exact mirror only after remote manifest, backup and final deploy checkpoint'
        }
        assets = [ordered]@{
            childThemeFiles = $childManifest.Count
            childThemeBytes = [long](($childManifest | Measure-Object -Property bytes -Sum).Sum)
            childThemeManifest = 'child-theme-manifest.csv'
        }
        checksumsFile = 'checksums.sha256'
    }
    $releaseManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stagingPath 'release-manifest.json') -Encoding utf8

    $artifactPaths = @('bella-maria-child.zip', 'child-theme-manifest.csv', 'database.sql', 'media-deletion-manifest.pending.txt', 'media-manifest.csv', 'RELEASE_ID', 'release-manifest.json', 'RELEASE-README.md', 'uploads.zip')
    $artifacts = foreach ($path in $artifactPaths) {
        $full = Join-Path $stagingPath $path
        [ordered]@{ path = $path; size = (Get-Item -LiteralPath $full).Length; sha256 = Get-Sha256 $full }
    }
    $artifacts | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stagingPath 'artifact-hashes.json') -Encoding utf8

    $checksumLines = Get-ChildItem -LiteralPath $stagingPath -File -Recurse -Force | Where-Object { $_.Name -ne 'checksums.sha256' } | ForEach-Object {
        "$(Get-Sha256 $_.FullName)  $(Get-RelativePath $stagingPath $_.FullName)"
    } | Sort-Object
    $checksumLines | Set-Content -LiteralPath (Join-Path $stagingPath 'checksums.sha256') -Encoding utf8

    Move-Item -LiteralPath $stagingPath -Destination $releasePath
    "RAW_RELEASE_BUILD_OK id=$ReleaseId path=$releasePath media_files=$($mediaManifest.Count) db_tables=$dumpTableCount local_url_occurrences=$localUrlOccurrences"
} catch {
    throw
} finally {
    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
}
