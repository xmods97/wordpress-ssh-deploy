$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $repoRoot 'src/WordPressSshDeploy.psm1') -Force
. (Join-Path $repoRoot 'tools/UploadsPackageValidation.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Assert-FixtureRejected([scriptblock]$Action) {
    $rejected=$false
    try { & $Action | Out-Null } catch { $rejected=$true }
    $rejected | Should Be $true
}

Describe 'Local uploads package gate' {
    BeforeEach {
        $script:zipPath=Join-Path $TestDrive 'uploads.zip'
        $script:manifestPath=Join-Path $TestDrive 'manifest.tsv'
        $script:payload=[Text.Encoding]::UTF8.GetBytes('fixture')
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $script:digest=([BitConverter]::ToString($sha.ComputeHash($script:payload))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        if (Test-Path $script:zipPath) { Remove-Item -LiteralPath $script:zipPath }
        [IO.File]::WriteAllText($script:manifestPath,"$script:digest`t7`t2025/Без-имени.png`r`n",(New-Object Text.UTF8Encoding($false)))
    }
    function Write-FixtureZip([string[]]$Names) {
        $archive=[IO.Compression.ZipFile]::Open($script:zipPath,[IO.Compression.ZipArchiveMode]::Create)
        try { foreach($name in $Names){ $entry=$archive.CreateEntry($name); $s=$entry.Open();try{$s.Write($script:payload,0,$script:payload.Length)}finally{$s.Dispose()} } }finally{$archive.Dispose()}
    }
    It 'accepts CRLF and UTF-8 Cyrillic filenames' {
        Write-FixtureZip @('2025/Без-имени.png')
        (Assert-UploadsPackage $script:zipPath $script:manifestPath).Files | Should Be 1
    }
    It 'rejects extra/missing paths' {
        Write-FixtureZip @('other.png')
        Assert-FixtureRejected { Assert-UploadsPackage $script:zipPath $script:manifestPath }
    }
    It 'rejects duplicate ZIP entries' {
        Write-FixtureZip @('2025/Без-имени.png','2025/Без-имени.png')
        Assert-FixtureRejected { Assert-UploadsPackage $script:zipPath $script:manifestPath }
    }
    It 'rejects traversal paths' {
        Write-FixtureZip @('../escape')
        Assert-FixtureRejected { Assert-UploadsPackage $script:zipPath $script:manifestPath }
    }
    It 'rejects SHA mismatch' {
        Write-FixtureZip @('2025/Без-имени.png')
        [IO.File]::WriteAllText($script:manifestPath,(('0'*64)+"`t7`t2025/Без-имени.png`n"),(New-Object Text.UTF8Encoding($false)))
        Assert-FixtureRejected { Assert-UploadsPackage $script:zipPath $script:manifestPath }
    }
    It 'rejects size mismatch and symlink metadata' {
        Write-FixtureZip @('2025/Без-имени.png')
        [IO.File]::WriteAllText($script:manifestPath,"$script:digest`t8`t2025/Без-имени.png`n",(New-Object Text.UTF8Encoding($false)))
        Assert-FixtureRejected { Assert-UploadsPackage $script:zipPath $script:manifestPath }
        [IO.File]::WriteAllText($script:manifestPath,"$script:digest`t7`t2025/Без-имени.png`n",(New-Object Text.UTF8Encoding($false)))
        $bytes=[IO.File]::ReadAllBytes($script:zipPath)
        for($i=0;$i -lt $bytes.Length-46;$i++){if([BitConverter]::ToUInt32($bytes,$i) -eq 0x02014b50){$bytes[$i+41]=160;break}}
        [IO.File]::WriteAllBytes($script:zipPath,$bytes)
        Assert-FixtureRejected { Assert-UploadsPackage $script:zipPath $script:manifestPath }
    }
    It 'accepts delta and rejects its metadata mismatch' {
        $source=Join-Path $TestDrive 'delta-source'
        New-Item -ItemType Directory -Force (Join-Path $source '2025') | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $source '2025/Без-имени.png'),$script:payload)
        $entry=[pscustomobject]@{Path='2025/Без-имени.png';Size=7;Sha256=$script:digest}
        $deltaZip=Join-Path $TestDrive 'delta.zip'
        New-UploadsDeltaPackage -SourceDirectory $source -CurrentManifest @($entry) -BaselineManifest @([pscustomobject]@{Path='old';Size=0;Sha256=('0'*64)}) -DestinationZip $deltaZip | Out-Null
        Assert-FixtureRejected { Assert-UploadsPackage $deltaZip $script:manifestPath -Delta -ExpectedPayload @($entry) -ExpectedDeletes @('old') }
        Convert-UploadsDeltaDeleteListToLf $deltaZip
        (Assert-UploadsPackage $deltaZip $script:manifestPath -Delta -ExpectedPayload @($entry) -ExpectedDeletes @('old')).Files | Should Be 1
        $archive=[IO.Compression.ZipFile]::Open($deltaZip,[IO.Compression.ZipArchiveMode]::Update)
        try { $archive.GetEntry('manifest.tsv').Delete();$bad=$archive.CreateEntry('manifest.tsv');$s=$bad.Open();try{$s.WriteByte(120)}finally{$s.Dispose()} } finally {$archive.Dispose()}
        Assert-FixtureRejected { Assert-UploadsPackage $deltaZip $script:manifestPath -Delta -ExpectedPayload @($entry) -ExpectedDeletes @('old') }
    }
    It 'stops when Linux unzip is unavailable and saves the reason' {
        Mock Invoke-LocalWslBinaryProcess { [pscustomobject]@{ExitCode=2;Output='LOCAL_LINUX_UNZIP_UNAVAILABLE'} }
        $log=Join-Path $TestDrive 'linux.log'
        Assert-FixtureRejected { Invoke-LocalLinuxUploadsCheck -ZipPath $script:zipPath -ManifestPath $script:manifestPath -LogPath $log }
        [IO.File]::ReadAllText($log).Contains('LOCAL_LINUX_UNZIP_UNAVAILABLE') | Should Be $true
    }
    It 'rejects ambiguous ZIP Unicode decoding without UTF-8 flag' {
        Write-FixtureZip @('2025/Без-имени.png')
        $bytes=[IO.File]::ReadAllBytes($script:zipPath)
        for($i=0;$i -lt $bytes.Length-46;$i++){if([BitConverter]::ToUInt32($bytes,$i) -eq 0x02014b50){$bytes[$i+9]=$bytes[$i+9] -band 247;break}}
        [IO.File]::WriteAllBytes($script:zipPath,$bytes)
        Assert-FixtureRejected { Assert-UploadsPackage $script:zipPath $script:manifestPath }
    }
    It 'rejects invalid UTF-8, BOM, blank row and missing final newline' {
        Assert-FixtureRejected { Read-StrictPackageManifest ([byte[]]@(255)) }
        Assert-FixtureRejected { Read-StrictPackageManifest ([byte[]]@(239,187,191)) }
        Assert-FixtureRejected { Read-StrictPackageManifest ([Text.Encoding]::UTF8.GetBytes("$script:digest`t7`ta`n`n")) }
        Assert-FixtureRejected { Read-StrictPackageManifest ([Text.Encoding]::UTF8.GetBytes("$script:digest`t7`ta")) }
    }
    It 'keeps full failure marker in persistent diagnostic log' {
        $text="UPLOADS_INPUT kind=zip`nUPLOADS_MANIFEST_VERIFY_FAIL`trow=130`tpredicate=file`tpath=2025/Без-имени.png`texpected=regular`tactual=missing`nERROR: Uploads manifest verification failed"
        $path=Join-Path $TestDrive 'diagnostic.log'
        Save-RemoteDeploymentDiagnostic ([pscustomobject]@{Output=$text;ExitCode=1}) $path
        [IO.File]::ReadAllText($path) | Should Be $text
    }
    It 'places package validation before SQL SCP and preserves staging branch' {
        $source=[IO.File]::ReadAllText((Join-Path $repoRoot 'deploy.ps1'))
        $source.IndexOf('Assert-UploadsPackage -ZipPath') | Should BeLessThan $source.IndexOf("if (`$hasDatabase) { Invoke-CheckedCommand 'scp'")
        $source.IndexOf('Invoke-LocalLinuxUploadsCheck @linuxArguments') | Should BeLessThan $source.IndexOf("if (`$hasDatabase) { Invoke-CheckedCommand 'scp'")
        $source.Contains('StageBellaRunnerCandidate') | Should Be $true
        $source.Contains('Save-RemoteDeploymentDiagnostic -Result $result') | Should Be $true
    }
}

Describe 'Deterministic unzip filename bytes' {
    It 'forces C locale and clears inherited unzip/zipinfo options in local gate' {
        $source=[IO.File]::ReadAllText((Join-Path $repoRoot 'tools/UploadsPackageValidation.ps1'))
        $source.Contains('LC_ALL=C; LANG=C; export LC_ALL LANG') | Should Be $true
        $source.Contains('unset UNZIP UNZIPOPT ZIPINFO ZIPINFOOPT') | Should Be $true
    }
}