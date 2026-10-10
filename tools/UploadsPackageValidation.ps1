function Read-StrictUploadsText([byte[]] $Bytes, [string] $Label) {
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $text = $utf8.GetString($Bytes)
    if ($text.StartsWith([string][char]0xfeff, [StringComparison]::Ordinal)) { throw "${Label}: UTF-8 BOM is not allowed" }
    if ($text.Contains([string][char]0) -or $text -match '\r(?!\n)') { throw "Invalid text encoding/line ending: $Label" }
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { throw "Missing final newline: $Label" }
    return $text.Replace("`r`n", "`n")
}

function Test-PackageRelativePath([string] $Path) {
    return (Test-UploadsManifestPath $Path) -and $Path -notmatch '(^/|//|/$|[\x00-\x1f\x7f])' -and $Path -notmatch '^[A-Za-z]:'
}

function Read-StrictPackageManifest([byte[]] $Bytes) {
    $text = Read-StrictUploadsText $Bytes 'uploads manifest'
    $result = New-Object 'System.Collections.Generic.List[object]'
    $previous = $null
    foreach ($line in $text.Substring(0, [Math]::Max(0,$text.Length-1)).Split([char]10)) {

        if ($line -eq '') { if ($text -eq '') { break }; throw 'Blank manifest row' }
        $parts = $line.Split([char]9)
        if ($parts.Count -ne 3 -or $parts[0] -notmatch '^[0-9a-fA-F]{64}$' -or $parts[1] -notmatch '^(0|[1-9][0-9]*)$' -or -not (Test-PackageRelativePath $parts[2])) { throw "Invalid manifest row: $line" }
        if ($null -ne $previous -and [string]::CompareOrdinal($previous, $parts[2]) -ge 0) { throw "Duplicate/unsorted manifest path: $($parts[2])" }
        $result.Add([pscustomobject]@{ Path=$parts[2]; Size=[long]$parts[1]; Sha256=$parts[0].ToLowerInvariant() })
        $previous = $parts[2]
    }
    return $result.ToArray()
}

function Get-PackageZipHeaders([string] $ZipPath) {
    $stream = [IO.File]::OpenRead($ZipPath)
    $reader = New-Object IO.BinaryReader($stream)
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    try {
        $tailSize = [int][Math]::Min($stream.Length, 65557)
        $stream.Position = $stream.Length - $tailSize
        $tail = $reader.ReadBytes($tailSize)
        $end = -1
        for ($i=$tail.Length-22; $i -ge 0; $i--) {
            if ([BitConverter]::ToUInt32($tail,$i) -eq 0x06054b50 -and $i+22+[BitConverter]::ToUInt16($tail,$i+20) -eq $tail.Length) { $end=$i; break }
        }
        if ($end -lt 0) { throw 'Missing ZIP end record' }
        $count = [BitConverter]::ToUInt16($tail,$end+10)
        $offset = [BitConverter]::ToUInt32($tail,$end+16)
        if ([BitConverter]::ToUInt32($tail,$end+4) -ne 0 -or [BitConverter]::ToUInt16($tail,$end+8) -ne $count -or $count -eq 65535 -or $offset -eq [uint32]::MaxValue) { throw 'Split/ZIP64 archives are not supported by the local uploads gate' }
        $stream.Position=$offset
        for ($index=0; $index -lt $count; $index++) {
            $header=$reader.ReadBytes(46)
            if ($header.Length -ne 46 -or [BitConverter]::ToUInt32($header,0) -ne 0x02014b50) { throw 'Invalid ZIP central header' }
            $flags=[BitConverter]::ToUInt16($header,8)
            $method=[BitConverter]::ToUInt16($header,10)
            if (($flags -band 1) -ne 0 -or $method -notin @(0,8)) { throw 'Encrypted/unsupported ZIP entry' }
            $nameBytes=$reader.ReadBytes([BitConverter]::ToUInt16($header,28))
            $extra=$reader.ReadBytes([BitConverter]::ToUInt16($header,30))
            $null=$reader.ReadBytes([BitConverter]::ToUInt16($header,32))
            if (($flags -band 2048) -eq 0 -and @($nameBytes | Where-Object { $_ -gt 127 }).Count -gt 0) { throw 'Non-ASCII ZIP name requires explicit UTF-8 flag for unzip compatibility' }
            $name=$utf8.GetString($nameBytes)
            for ($j=0; $j -lt $extra.Length;) {
                if ($j+4 -gt $extra.Length) { throw 'Invalid ZIP extra field' }
                $id=[BitConverter]::ToUInt16($extra,$j); $length=[BitConverter]::ToUInt16($extra,$j+2)
                if ($j+4+$length -gt $extra.Length) { throw 'Truncated ZIP extra field' }
                if ($id -in @(1,0x7075)) { throw "ZIP64/alternate Unicode-name extra field is unsupported: $name" }
                $j+=4+$length
            }
            $mode=([BitConverter]::ToUInt32($header,38) -shr 16) -band 0xf000
            if ($mode -notin @(0,0x4000,0x8000)) { throw "Symlink/special ZIP entry: $name" }
            $centralPosition=$stream.Position
            $stream.Position=[BitConverter]::ToUInt32($header,42)
            $local=$reader.ReadBytes(30)
            if ($local.Length -ne 30 -or [BitConverter]::ToUInt32($local,0) -ne 0x04034b50 -or [BitConverter]::ToUInt16($local,6) -ne $flags -or [BitConverter]::ToUInt16($local,8) -ne $method) { throw "ZIP local/central header mismatch: $name" }
            $localName=$reader.ReadBytes([BitConverter]::ToUInt16($local,26))
            if ([Convert]::ToBase64String($localName) -cne [Convert]::ToBase64String($nameBytes)) { throw "ZIP local/central filename mismatch: $name" }
            $stream.Position=$centralPosition
            [pscustomobject]@{ Name=$name; Size=[long][BitConverter]::ToUInt32($header,24); Directory=$name.EndsWith('/') }
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Get-PackageEntryBytes($Entry) {
    $inputStream=$Entry.Open(); $outputStream=New-Object IO.MemoryStream
    try { $inputStream.CopyTo($outputStream); return ,$outputStream.ToArray() }
    finally { $inputStream.Dispose(); $outputStream.Dispose() }
}

function Convert-UploadsDeltaDeleteListToLf([string]$ZipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::Open($ZipPath,[IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry=$zip.GetEntry('delete.list')
        if ($null -eq $entry) { throw 'Missing delta delete.list' }
        $bytes=Get-PackageEntryBytes $entry
        $text=Read-StrictUploadsText $bytes 'delete.list'
        if ([Text.Encoding]::UTF8.GetString($bytes).Contains("`r")) {
            $entry.Delete(); $entry=$zip.CreateEntry('delete.list')
            $stream=$entry.Open(); $normalized=[Text.Encoding]::UTF8.GetBytes($text)
            try { $stream.Write($normalized,0,$normalized.Length) } finally { $stream.Dispose() }
        }
    } finally { $zip.Dispose() }
}

function Assert-UploadsPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ZipPath, [Parameter(Mandatory=$true)][string]$ManifestPath,
        [switch]$Delta, [AllowEmptyCollection()][object[]]$ExpectedPayload=@(), [AllowEmptyCollection()][string[]]$ExpectedDeletes=@())
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $manifestBytes=[IO.File]::ReadAllBytes($ManifestPath)
    $manifest=@(Read-StrictPackageManifest $manifestBytes)
    if ($manifest.Count -eq 0) { throw 'Empty uploads manifest is not supported' }
    $expected=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $current=New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($item in $manifest) { $current.Add($item.Path,$item) }
    foreach ($entry in $(if ($Delta) { $ExpectedPayload } else { $manifest })) {
        if ($expected.ContainsKey($entry.Path)) { throw "Duplicate expected payload: $($entry.Path)" }
        if ($Delta -and (-not $current.ContainsKey($entry.Path) -or $current[$entry.Path].Size -ne $entry.Size -or $current[$entry.Path].Sha256 -cne $entry.Sha256.ToLowerInvariant())) { throw "Delta payload contradicts current manifest: $($entry.Path)" }
        $expected.Add($entry.Path,$entry)
    }
    foreach ($delete in $ExpectedDeletes) { if (-not (Test-PackageRelativePath $delete) -or $current.ContainsKey($delete)) { throw "Invalid delta deletion: $delete" } }
    $headers=@(Get-PackageZipHeaders $ZipPath)
    $names=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($header in $headers) {
        $path=$header.Name.TrimEnd('/')
        if (-not (Test-PackageRelativePath $path) -or -not $names.Add($path)) { throw "Unsafe/duplicate ZIP path: $($header.Name)" }
        if ($Delta -and $header.Directory -and $header.Name -cne 'payload/' -and -not $header.Name.StartsWith('payload/',[StringComparison]::Ordinal)) { throw "Unexpected delta directory: $($header.Name)" }
    }
    $files=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($header in $headers) { if (-not $header.Directory) { $null=$files.Add($header.Name) } }
    foreach ($name in $names) {
        $parent=$name
        while ($parent.Contains('/')) { $parent=$parent.Substring(0,$parent.LastIndexOf('/')); if ($files.Contains($parent)) { throw "ZIP file/directory collision: $name" } }
    }
    $zip=[IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($zip.Entries.Count -ne $headers.Count) { throw 'ZIP entry count mismatch' }
        $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $metadataSeen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        for ($i=0; $i -lt $zip.Entries.Count; $i++) {
            $entry=$zip.Entries[$i]; $header=$headers[$i]
            if ($entry.FullName -cne $header.Name -or $entry.Length -ne $header.Size) { throw 'ZIP decoded/raw metadata mismatch' }
            if ($header.Directory) { if ($entry.Length -ne 0) { throw 'Nonempty ZIP directory' }; continue }
            $path=$entry.FullName
            if ($Delta -and $path -in @('manifest.tsv','delete.list')) {
                $null=$metadataSeen.Add($path); $bytes=Get-PackageEntryBytes $entry
                if ($path -eq 'manifest.tsv') {
                    if ([Convert]::ToBase64String($bytes) -cne [Convert]::ToBase64String($manifestBytes)) { throw 'Delta embedded/sidecar manifest mismatch' }
                } else {
                    if ([Text.Encoding]::UTF8.GetString($bytes).Contains("`r")) { throw 'Delta delete.list requires LF: runner does not strip CR from deletion paths' }
                    $deleteText=Read-StrictUploadsText $bytes 'delete.list'
                    $deletes=@($deleteText.Split([char]10) | Where-Object { $_ -ne '' })
                    $deleteSet=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
                    foreach ($delete in $deletes) { if (-not (Test-PackageRelativePath $delete) -or -not $deleteSet.Add($delete)) { throw 'Unsafe/duplicate delta delete path' } }
                    if ($deletes.Count -ne $ExpectedDeletes.Count) { throw 'Delta delete count mismatch' }
                    foreach ($delete in $ExpectedDeletes) { if (-not $deleteSet.Contains($delete)) { throw 'Delta delete set mismatch' } }
                }
                continue
            }
            if ($Delta) { if (-not $path.StartsWith('payload/',[StringComparison]::Ordinal)) { throw "Unexpected delta entry: $path" }; $path=$path.Substring(8) }
            if (-not $expected.ContainsKey($path) -or -not $seen.Add($path)) { throw "Extra/duplicate payload: $path" }
            $wanted=$expected[$path]
            if ($entry.Length -ne $wanted.Size) { throw "Payload size mismatch: $path" }
            $stream=$entry.Open(); $sha=[Security.Cryptography.SHA256]::Create()
            try { $digest=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
            finally { $stream.Dispose(); $sha.Dispose() }
            if ($digest -cne $wanted.Sha256.ToLowerInvariant()) { throw "Payload SHA256 mismatch: $path" }
        }
        if ($seen.Count -ne $expected.Count) { throw 'Missing ZIP payload entries' }
        if ($Delta -and $metadataSeen.Count -ne 2) { throw 'Missing delta metadata' }
    } finally { $zip.Dispose() }
    [pscustomobject]@{ Kind=$(if($Delta){'delta'}else{'full'}); Files=$seen.Count; ZipBytes=(Get-Item -LiteralPath $ZipPath).Length; ZipSha256=(Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash; ManifestSha256=(Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash; LinuxUnzipVerified=$false }
}

function ConvertTo-LocalWslPath([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^([A-Za-z]):[\\/]') { throw 'Local Linux uploads validation requires a drive-letter Windows path accessible to WSL' }
    return '/mnt/'+$Matches[1].ToLowerInvariant()+'/'+$full.Substring(3).Replace('\','/')
}

function Invoke-LocalLinuxUploadsCheck {
    [CmdletBinding()]
    param([string]$ZipPath,[string]$ManifestPath,[string]$LogPath,[string]$UnzipPath='/usr/bin/unzip',
        [switch]$Delta,[AllowEmptyCollection()][object[]]$ExpectedPayload=@())
    $verifyFile=[IO.Path]::GetTempFileName()
    try {
        if ($Delta) {
            $sorted=New-Object 'System.Collections.Generic.List[object]'
            foreach ($entry in $ExpectedPayload) { $sorted.Add($entry) }
            $sorted.Sort([System.Comparison[object]]{ param($left,$right) [string]::CompareOrdinal([string]$left.Path,[string]$right.Path) })
            $lines=@($sorted | ForEach-Object { '{0}{3}{1}{3}{2}' -f $_.Sha256,$_.Size,$_.Path,[char]9 })
            [IO.File]::WriteAllLines($verifyFile,[string[]]$lines,(New-Object Text.UTF8Encoding($false)))
        } else { [IO.File]::Copy($ManifestPath,$verifyFile,$true) }
        $code=@'
set -eu
zip=$1; manifest=$2; sidecar=$3; kind=$4; unzip=$5
# Preserve raw UTF-8 filename bytes in DOS-origin ZIPs across unzip builds.
LC_ALL=C; LANG=C; export LC_ALL LANG
unset UNZIP UNZIPOPT ZIPINFO ZIPINFOOPT
if [ "$unzip" = /usr/bin/unzip ] && ! [ -x "$unzip" ]; then unzip="$HOME/.cache/bella-deploy-tools/unzip/usr/bin/unzip"; fi
[ -x "$unzip" ] || { echo 'LOCAL_LINUX_UNZIP_UNAVAILABLE: supply -LocalLinuxUnzipPath with an executable Linux unzip' >&2; exit 2; }
command -v sha256sum >/dev/null; command -v stat >/dev/null
"$unzip" -v | head -4
printf 'LOCAL_LINUX_SHELL='; readlink /bin/sh || true
locale
d=$(mktemp -d /tmp/uploads-local-gate.XXXXXX)
trap 'rm -rf -- "$d"' EXIT HUP INT TERM
cat > "$d/package.zip"
zip="$d/package.zip"
cp "$manifest" "$d/selected.tsv"; manifest="$d/selected.tsv"
cp "$sidecar" "$d/sidecar.tsv"; sidecar="$d/sidecar.tsv"
"$unzip" -tq "$zip"
mkdir "$d/tree"
"$unzip" -q "$zip" -d "$d/tree"
root="$d/tree"
if [ "$kind" = delta ]; then cmp "$sidecar" "$root/manifest.tsv"; root="$root/payload"; mkdir -p "$root"; fi
[ -z "$(find "$root" -type l -print -quit)" ] || { echo 'LOCAL_LINUX_FAIL predicate=symlink'; exit 1; }
row=0; previous=''; cr=$(printf '\r')
while IFS="$(printf '\t')" read -r sha size relative extra; do
    row=$((row+1)); relative=${relative%"$cr"}
    predicate=''; actual=''; expected=''
    if [ -n "$previous" ] && ! [ "$relative" \> "$previous" ]; then predicate=order; expected="after:$previous"; actual=$relative
    elif ! [ -f "$root/$relative" ]; then predicate=file; expected=regular; actual=missing
    else
        actual=$(stat -c '%s' "$root/$relative"); expected=$size
        if [ "$actual" != "$size" ]; then predicate=size
        else actual=$(sha256sum "$root/$relative" | awk '{print tolower($1)}'); expected=$(printf '%s' "$sha" | tr '[:upper:]' '[:lower:]'); [ "$actual" = "$expected" ] || predicate=sha256; fi
    fi
    if [ -n "$predicate" ]; then printf 'LOCAL_LINUX_FAIL\trow=%s\tpredicate=%s\tpath=%s\texpected=%s\tactual=%s\n' "$row" "$predicate" "$relative" "$expected" "$actual"; exit 1; fi
    previous=$relative
done < "$manifest"
actual=$(find "$root" -type f | wc -l | tr -d ' ')
[ "$actual" = "$row" ] || { printf 'LOCAL_LINUX_FAIL predicate=count expected=%s actual=%s\n' "$row" "$actual"; exit 1; }
printf 'LOCAL_LINUX_UNZIP_VALIDATION=PASS files=%s\n' "$row"
'@
        $arguments=@('--exec','sh','-c',$code,'uploads-local-check', (ConvertTo-LocalWslPath $ZipPath), (ConvertTo-LocalWslPath $verifyFile), (ConvertTo-LocalWslPath $ManifestPath), $(if($Delta){'delta'}else{'full'}),$UnzipPath)
        $result=Invoke-LocalWslBinaryProcess -Arguments $arguments -ZipPath $ZipPath
        $output=@($result.Output); $exitCode=$result.ExitCode
        [IO.File]::WriteAllText($LogPath,($output -join "`n"),(New-Object Text.UTF8Encoding($false)))
        $output | ForEach-Object { Write-Host ([string]$_) }
        if ($exitCode -ne 0) { throw "Local Linux unzip validation failed ($exitCode); no payload may be sent. Full log: $LogPath" }
    } finally { if (Test-Path -LiteralPath $verifyFile) { Remove-Item -LiteralPath $verifyFile -Force } }
}

function Save-RemoteDeploymentDiagnostic {
    param([Parameter(Mandatory=$true)]$Result, [Parameter(Mandatory=$true)][string]$LogPath)
    [IO.File]::WriteAllText($LogPath, [string]$Result.Output, (New-Object Text.UTF8Encoding($false)))
    Write-Host $Result.Output
    Write-Host "Remote deployment output saved: $LogPath"
}

function Invoke-LocalWslBinaryProcess([string[]]$Arguments,[string]$ZipPath) {
    $output=@(); $exitCode=-1
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName='wsl.exe'; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardInput=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $psi.StandardOutputEncoding=New-Object Text.UTF8Encoding($false); $psi.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    # Windows argv quoting, not shell interpolation; ZIP is streamed as binary stdin.
    if ($psi.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $Arguments) { $psi.ArgumentList.Add([string]$argument) }
    } else {
        $psi.Arguments=(@($Arguments | ForEach-Object {
            $value=[string]$_
            if ($value -ne '' -and $value -notmatch '[\s"]') { $value }
            else { '"'+[regex]::Replace([regex]::Replace($value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"' }
        }) -join ' ')
    }
    $process=New-Object Diagnostics.Process; $process.StartInfo=$psi
    try {
        if (-not $process.Start()) { throw 'Could not start local WSL' }
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $stream=[IO.File]::OpenRead($ZipPath)
        try { $stream.CopyTo($process.StandardInput.BaseStream,1048576) }
        catch { $output+=($_ | Out-String) }
        finally { $stream.Dispose(); $process.StandardInput.Close() }
        $process.WaitForExit(); $exitCode=$process.ExitCode
        $output+= $stdout.Result; $output+= $stderr.Result
    } catch { $output+=($_ | Out-String) }
    finally { $process.Dispose() }
    return [pscustomobject]@{ ExitCode=$exitCode; Output=($output -join "`n") }
}
