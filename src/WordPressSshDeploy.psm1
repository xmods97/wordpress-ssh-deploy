Set-StrictMode -Version 2.0

function ConvertTo-ShSingleQuotedString {
	[CmdletBinding()]
	param(
		[AllowEmptyString()]
		[Parameter(Mandatory = $true)]
		[string] $Value
	)

	$singleQuote = [string] [char] 39
	$escaped = $Value.Replace($singleQuote, $singleQuote + '"' + $singleQuote + '"' + $singleQuote)
	return $singleQuote + $escaped + $singleQuote
}

function Invoke-CheckedCommand {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $FilePath,
		[Parameter(Mandatory = $true)] [string[]] $Arguments,
		[Parameter(Mandatory = $true)] [string] $WorkingDirectory
	)

	Push-Location $WorkingDirectory
	try {
		& $FilePath @Arguments
		if ($LASTEXITCODE -ne 0) {
			throw "Command failed ($LASTEXITCODE): $FilePath"
		}
	} finally {
		Pop-Location
	}
}

function Invoke-CommandOutput {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $FilePath,
		[Parameter(Mandatory = $true)] [string[]] $Arguments,
		[Parameter(Mandatory = $true)] [string] $WorkingDirectory
	)

	Push-Location $WorkingDirectory
	try {
		$output = & $FilePath @Arguments 2>&1
		if ($LASTEXITCODE -ne 0) {
			throw "Command failed ($LASTEXITCODE): $FilePath"
		}
		return $output
	} finally {
		Pop-Location
	}
}

function ConvertTo-WindowsProcessArgument {
	[CmdletBinding()]
	param([AllowEmptyString()] [Parameter(Mandatory = $true)] [string] $Value)

	if ($Value.Length -eq 0) { return '""' }
	if ($Value -notmatch '[\s"]') { return $Value }
	$builder = New-Object Text.StringBuilder
	[void] $builder.Append('"')
	$slashes = 0
	foreach ($character in $Value.ToCharArray()) {
		if ($character -eq [char] 92) {
			$slashes++
			continue
		}
		if ($character -eq [char] 34) {
			for ($index = 0; $index -lt ($slashes * 2 + 1); $index++) { [void] $builder.Append([char] 92) }
			[void] $builder.Append([char] 34)
			$slashes = 0
			continue
		}
		for ($index = 0; $index -lt $slashes; $index++) { [void] $builder.Append([char] 92) }
		$slashes = 0
		[void] $builder.Append($character)
	}
	for ($index = 0; $index -lt ($slashes * 2); $index++) { [void] $builder.Append([char] 92) }
	[void] $builder.Append('"')
	return $builder.ToString()
}

function Invoke-NativeProcessWithFileInput {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $FilePath,
		[Parameter(Mandatory = $true)] [string[]] $Arguments,
		[Parameter(Mandatory = $true)] [string] $InputPath,
		[hashtable] $EnvironmentVariables = @{}
	)

	if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "Executable not found: $FilePath" }
	if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) { throw "Input file not found: $InputPath" }
	$startInfo = New-Object Diagnostics.ProcessStartInfo
	$startInfo.FileName = $FilePath
	$startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsProcessArgument ([string] $_) }) -join ' ')
	$startInfo.UseShellExecute = $false
	$startInfo.CreateNoWindow = $true
	$startInfo.RedirectStandardInput = $true
	$startInfo.RedirectStandardError = $true
	foreach ($key in $EnvironmentVariables.Keys) {
		$startInfo.EnvironmentVariables[[string] $key] = [string] $EnvironmentVariables[$key]
	}

	$process = New-Object Diagnostics.Process
	$process.StartInfo = $startInfo
	$inputStream = $null
	$inputPipe = $null
	$errorTask = $null
	$previousInputEncoding = [Console]::InputEncoding
	$inputEncodingChanged = $false
	try {
		# Windows PowerShell creates StandardInput's StreamWriter during
		# Process.Start(), so the no-preamble encoding must be in place before
		# starting the child process.
		[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
		$inputEncodingChanged = $true
		if (-not $process.Start()) { throw "Could not start process: $FilePath" }
		$errorTask = $process.StandardError.ReadToEndAsync()
		$inputStream = [IO.File]::OpenRead($InputPath)
		$inputPipe = $process.StandardInput.BaseStream
		[Console]::InputEncoding = $previousInputEncoding
		$inputEncodingChanged = $false
		$inputStream.CopyTo($inputPipe)
		$inputPipe.Flush()
		$inputPipe.Close()
		$inputPipe = $null
		$process.WaitForExit()
		$stderr = [string] $errorTask.Result
		if ($process.ExitCode -ne 0) {
			throw "Command failed ($($process.ExitCode)): $FilePath$(if ($stderr) { ": $($stderr.Trim())" })"
		}
		return [pscustomobject] @{ ExitCode = $process.ExitCode; Error = $stderr }
	} finally {
		if ($inputEncodingChanged) { [Console]::InputEncoding = $previousInputEncoding }
		if ($inputStream) { $inputStream.Dispose() }
		if ($inputPipe) { $inputPipe.Dispose() }
		if ($process) { $process.Dispose() }
	}
}

function Restore-FileSwaps {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [object[]] $Swaps)

	for ($index = $Swaps.Count - 1; $index -ge 0; $index--) {
		$swap = $Swaps[$index]
		if (Test-Path -LiteralPath $swap.Target) { Remove-Item -LiteralPath $swap.Target -Recurse -Force -ErrorAction SilentlyContinue }
		if ($swap.HadTarget -and (Test-Path -LiteralPath $swap.Old)) {
			Move-Item -LiteralPath $swap.Old -Destination $swap.Target -Force -ErrorAction SilentlyContinue
		}
	}
}

function Get-DirectoryContentSizeBytes {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
		throw "Directory not found: $Path"
	}
	$total = [long] 0
	Get-ChildItem -LiteralPath $Path -File -Recurse -Force | ForEach-Object { $total += $_.Length }
	return $total
}

function Assert-AvailableDiskSpace {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $Path,
		[Parameter(Mandatory = $true)] [long] $RequiredBytes,
		[string] $Label = 'Target disk'
	)

	$fullPath = [IO.Path]::GetFullPath($Path)
	$root = [IO.Path]::GetPathRoot($fullPath)
	try {
		$available = ([IO.DriveInfo] $root).AvailableFreeSpace
	} catch {
		throw "$Label free-space check failed."
	}
	if ($available -lt $RequiredBytes) {
		throw "$Label does not have enough free space. Required: $RequiredBytes bytes; available: $available bytes."
	}
}

function Assert-SqlDumpFile {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw 'SQL dump was not created.'
	}
	$file = Get-Item -LiteralPath $Path
	if ($file.Length -lt 64) {
		throw 'SQL dump is empty or unexpectedly small.'
	}
	$hasHeader = Select-String -LiteralPath $Path -Pattern '^-- (MySQL|MariaDB) dump' -Quiet
	$hasStructure = Select-String -LiteralPath $Path -Pattern '^(CREATE TABLE|INSERT INTO|-- Table structure for table)' -Quiet
	if (-not $hasHeader -or -not $hasStructure) {
		throw 'SQL dump does not contain the expected dump header and table structure.'
	}
}

function Assert-SqlDumpTablePrefix {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $Path,
		[Parameter(Mandatory = $true)] [string] $ExpectedPrefix
	)

	if ($ExpectedPrefix -notmatch '^[A-Za-z0-9_]+$') {
		throw 'Expected SQL table prefix contains unsupported characters.'
	}
	$reader = $null
	$found = $false
	try {
		$reader = [IO.File]::OpenText($Path)
		while (($line = $reader.ReadLine()) -ne $null) {
			if ($line -notmatch '^CREATE TABLE(?: IF NOT EXISTS)? `([^`]+)`') { continue }
			$found = $true
			$tableName = $Matches[1]
			if (-not $tableName.StartsWith($ExpectedPrefix, [StringComparison]::Ordinal)) {
				throw "SQL dump table prefix mismatch: expected '$ExpectedPrefix', found '$tableName'."
			}
		}
	} finally {
		if ($reader) { $reader.Dispose() }
	}
	if (-not $found) {
		throw 'SQL dump contains no CREATE TABLE statements for table-prefix validation.'
	}
}

function Get-SqlByteSafeEncoding {
	# ISO-8859-1 maps bytes 0x00-0xFF to the identical code points and back, so a
	# GetString/GetBytes round-trip is lossless for arbitrary binary content. UTF-8
	# decoding would silently replace invalid sequences with U+FFFD and corrupt the dump.
	return [Text.Encoding]::GetEncoding(28591)
}

function Convert-SqlIdentifierPrefix {
	# Rewrites `<SourcePrefix> to `<TargetPrefix> in place, in a single forward pass over
	# the whole dump. Scanning from the start rather than from the enclosing line keeps
	# string, line-comment, and block-comment state correct across line boundaries, so a
	# /* ... */ comment opened on an earlier line still suppresses the rewrite.
	# Both prefixes are the same ASCII length, so no offset ever shifts.
	# Returns the number of identifiers rewritten.
	param(
		[Parameter(Mandatory = $true)] [char[]] $Characters,
		[Parameter(Mandatory = $true)] [string] $SourcePrefix,
		[Parameter(Mandatory = $true)] [string] $TargetPrefix
	)

	$length = $Characters.Length
	$prefixLength = $SourcePrefix.Length
	$replacements = 0
	$index = 0
	$inString = $false
	$inBlockComment = $false
	while ($index -lt $length) {
		$character = $Characters[$index]
		if ($inString) {
			# A backslash escapes the next byte, including a quote or another backslash.
			if ($character -eq '\') { $index += 2; continue }
			if ($character -eq "'") { $inString = $false }
			$index++
			continue
		}
		if ($inBlockComment) {
			if ($character -eq '*' -and ($index + 1) -lt $length -and $Characters[$index + 1] -eq '/') {
				$inBlockComment = $false
				$index += 2
				continue
			}
			$index++
			continue
		}
		if ($character -eq "'") { $inString = $true; $index++; continue }
		if ($character -eq '#' -or ($character -eq '-' -and ($index + 1) -lt $length -and $Characters[$index + 1] -eq '-')) {
			# Line comment: skip to the newline, which the next iteration consumes.
			while ($index -lt $length -and $Characters[$index] -ne "`n") { $index++ }
			continue
		}
		if ($character -eq '/' -and ($index + 1) -lt $length -and $Characters[$index + 1] -eq '*') {
			# /*! ... */ is an executable MySQL conditional comment, not a comment.
			if (($index + 2) -lt $length -and $Characters[$index + 2] -eq '!') { $index += 3; continue }
			$inBlockComment = $true
			$index += 2
			continue
		}
		if ($character -eq '`' -and ($index + $prefixLength) -lt $length) {
			$matched = $true
			for ($position = 0; $position -lt $prefixLength; $position++) {
				if ($Characters[$index + 1 + $position] -cne $SourcePrefix[$position]) { $matched = $false; break }
			}
			if ($matched) {
				for ($position = 0; $position -lt $prefixLength; $position++) {
					$Characters[$index + 1 + $position] = $TargetPrefix[$position]
				}
				$replacements++
				$index += $prefixLength + 1
				continue
			}
		}
		$index++
	}

	return $replacements
}

function Normalize-SqlDumpTablePrefix {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $Path,
		[Parameter(Mandatory = $true)] [string] $ExpectedPrefix,
		[Parameter(Mandatory = $true)] [int] $ExpectedTableCount
	)

	if ($ExpectedPrefix -notmatch '^[A-Za-z0-9_]+$') {
		throw 'Expected SQL table prefix contains unsupported characters.'
	}
	if ($ExpectedTableCount -lt 1) {
		throw 'Expected SQL table count must be positive.'
	}

	$encoding = Get-SqlByteSafeEncoding
	$contents = $encoding.GetString([IO.File]::ReadAllBytes($Path))
	$sourcePrefix = $ExpectedPrefix.ToLowerInvariant()
	$createMatches = [regex]::Matches($contents, '(?m)^CREATE TABLE(?: IF NOT EXISTS)? `([^`]+)`')
	if ($createMatches.Count -ne $ExpectedTableCount) {
		throw "SQL dump table count mismatch: expected $ExpectedTableCount, found $($createMatches.Count)."
	}

	$tableNames = @($createMatches | ForEach-Object { $_.Groups[1].Value })
	$targetCount = @($tableNames | Where-Object { $_.StartsWith($ExpectedPrefix, [StringComparison]::Ordinal) }).Count
	$sourceCount = @($tableNames | Where-Object { $_.StartsWith($sourcePrefix, [StringComparison]::Ordinal) }).Count
	if ($targetCount -eq $ExpectedTableCount) {
		Assert-SqlDumpTablePrefix $Path $ExpectedPrefix
		return
	}
	if ([string]::Equals($sourcePrefix, $ExpectedPrefix, [StringComparison]::Ordinal) -or $sourceCount -ne $ExpectedTableCount) {
		throw "SQL dump contains unexpected table identifiers for expected prefix '$ExpectedPrefix'."
	}

	# Replace in place: the rewrite is a same-length ASCII case change applied only to
	# identifier positions, so every other byte of the dump is preserved exactly.
	[char[]] $characters = $contents.ToCharArray()
	$null = Convert-SqlIdentifierPrefix $characters $sourcePrefix $ExpectedPrefix

	[IO.File]::WriteAllBytes($Path, $encoding.GetBytes((New-Object string (, $characters))))
	Assert-SqlDumpTablePrefix $Path $ExpectedPrefix
}

function Assert-GzipFile {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw 'Downloaded archive was not created.'
	}
	$file = Get-Item -LiteralPath $Path
	if ($file.Length -lt 32) {
		throw 'Downloaded archive is empty or unexpectedly small.'
	}
	$header = New-Object byte[] 3
	$stream = [IO.File]::OpenRead($Path)
	try {
		if ($stream.Read($header, 0, 3) -ne 3 -or $header[0] -ne 0x1F -or $header[1] -ne 0x8B -or $header[2] -ne 0x08) {
			throw 'Downloaded archive is not a deflate gzip stream.'
		}
	} finally {
		$stream.Dispose()
	}

	# GZipStream verifies the CRC and length recorded in the gzip trailer, but only once it
	# actually reaches that trailer: a truncated archive simply stops returning data and
	# reports success. Comparing the decompressed length against the recorded ISIZE closes
	# that gap. The runner writes single-member archives (gzip -c, tar -czf), so the last
	# four bytes are the ISIZE of the whole stream.
	$trailer = New-Object byte[] 4
	$tail = [IO.File]::OpenRead($Path)
	try {
		$tail.Seek(-4, [IO.SeekOrigin]::End) | Out-Null
		if ($tail.Read($trailer, 0, 4) -ne 4) {
			throw 'Downloaded archive failed its gzip integrity check.'
		}
	} finally {
		$tail.Dispose()
	}
	$recordedSize = [BitConverter]::ToUInt32($trailer, 0)

	# Decompress the whole stream: a truncated or corrupted archive fails here rather
	# than halfway through writing the extracted SQL or files.
	$expanded = [long] 0
	$source = $null
	$gzip = $null
	try {
		$source = [IO.File]::OpenRead($Path)
		$gzip = New-Object IO.Compression.GZipStream($source, [IO.Compression.CompressionMode]::Decompress)
		$buffer = New-Object byte[] 65536
		while ($true) {
			$read = $gzip.Read($buffer, 0, $buffer.Length)
			if ($read -le 0) { break }
			$expanded += $read
		}
	} catch {
		throw 'Downloaded archive failed its gzip integrity check.'
	} finally {
		if ($gzip) { $gzip.Dispose() }
		if ($source) { $source.Dispose() }
	}
	if ($expanded -le 0) {
		throw 'Downloaded archive expands to no content.'
	}
	if (($expanded -band 0xFFFFFFFF) -ne $recordedSize) {
		throw 'Downloaded archive failed its gzip integrity check: it is truncated or incomplete.'
	}

	return $expanded
}

function Expand-GzipFile {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $Path,
		[Parameter(Mandatory = $true)] [string] $Destination
	)

	$null = Assert-GzipFile $Path
	$source = $null
	$gzip = $null
	$target = $null
	try {
		$source = [IO.File]::OpenRead($Path)
		$gzip = New-Object IO.Compression.GZipStream($source, [IO.Compression.CompressionMode]::Decompress)
		$target = [IO.File]::Create($Destination)
		$gzip.CopyTo($target)
	} finally {
		if ($target) { $target.Dispose() }
		if ($gzip) { $gzip.Dispose() }
		if ($source) { $source.Dispose() }
	}
}

function Get-SqlDumpTableNames {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $Path)

	$names = New-Object 'System.Collections.Generic.List[string]'
	$reader = $null
	try {
		$reader = [IO.File]::OpenText($Path)
		while (($line = $reader.ReadLine()) -ne $null) {
			if ($line -match '^CREATE TABLE(?: IF NOT EXISTS)? `([^`]+)`') {
				$names.Add($Matches[1])
			}
		}
	} finally {
		if ($reader) { $reader.Dispose() }
	}

	return $names.ToArray()
}

function Assert-SqlDumpTableSet {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $Path,
		[Parameter(Mandatory = $true)] [string] $ExpectedPrefix,
		[int] $ExpectedTableCount = 0,
		[ValidateRange(1, 1048576)] [int] $MinimumTableCount = 1
	)

	if ($ExpectedPrefix -notmatch '^[A-Za-z0-9_]+$') {
		throw 'Expected SQL table prefix contains unsupported characters.'
	}
	if ($ExpectedTableCount -lt 0) {
		throw 'Expected SQL table count cannot be negative.'
	}
	if ($ExpectedTableCount -eq 0 -and $MinimumTableCount -lt 1) {
		throw 'Minimum SQL table count must be positive when no exact count is configured.'
	}

	Assert-SqlDumpFile $Path
	$names = @(Get-SqlDumpTableNames $Path)
	if ($names.Count -eq 0) {
		throw 'SQL dump contains no CREATE TABLE statements for table-set validation.'
	}
	if ($ExpectedTableCount -gt 0 -and $names.Count -ne $ExpectedTableCount) {
		throw "SQL dump table count mismatch: expected $ExpectedTableCount, found $($names.Count)."
	}
	if ($ExpectedTableCount -eq 0 -and $names.Count -lt $MinimumTableCount) {
		throw "SQL dump contains too few tables: minimum $MinimumTableCount, found $($names.Count)."
	}
	# Ordinal comparison rejects a foreign prefix and a case-mismatched one alike, so a
	# mixed dump can never reach the import step.
	$foreign = @($names | Where-Object { -not $_.StartsWith($ExpectedPrefix, [StringComparison]::Ordinal) })
	if ($foreign.Count -gt 0) {
		throw "SQL dump contains unexpected table identifiers for expected prefix '$ExpectedPrefix'."
	}

	return $names
}

function ConvertFrom-TarHeaderBlock {
	param([byte[]] $Block)

	# Returns $null for the zero block that terminates a tar stream.
	$empty = $true
	foreach ($byte in $Block) { if ($byte -ne 0) { $empty = $false; break } }
	if ($empty) { return $null }

	# GNU tar stores POSIX path fields as bytes; the remote WordPress files use UTF-8.
	# ASCII decoding turns Cyrillic names into literal '?' characters, which then become
	# invalid Windows paths during extraction.
	$ascii = [Text.Encoding]::ASCII
	$utf8 = New-Object Text.UTF8Encoding($false, $true)
	$name = $utf8.GetString($Block, 0, 100).TrimEnd([char] 0)
	$prefix = $utf8.GetString($Block, 345, 155).TrimEnd([char] 0)
	if ($prefix) { $name = "$prefix/$name" }
	$sizeField = $ascii.GetString($Block, 124, 12).Trim([char] 0, ' ')
	$size = [long] 0
	if ($sizeField) {
		if ($sizeField -notmatch '^[0-7]+$') { throw 'Archive listing has an unreadable entry size.' }
		$size = [Convert]::ToInt64($sizeField, 8)
	}
	$typeFlag = [char] $Block[156]
	if ($typeFlag -eq [char] 0) { $typeFlag = '0' }

	return [pscustomobject] @{ Name = $name; Size = $size; TypeFlag = [string] $typeFlag }
}

function Read-TarPayloadBytes {
	param(
		[Parameter(Mandatory = $true)] [IO.Stream] $Stream,
		[Parameter(Mandatory = $true)] [long] $Size
	)

	if ($Size -lt 0 -or $Size -gt 1MB) {
		throw 'Archive metadata record is unreasonably large.'
	}
	$bytes = New-Object byte[] ([int] $Size)
	$offset = 0
	while ($offset -lt $bytes.Length) {
		$read = $Stream.Read($bytes, $offset, $bytes.Length - $offset)
		if ($read -le 0) { throw 'Archive is truncated.' }
		$offset += $read
	}
	$padding = [long] ([Math]::Ceiling($Size / 512.0)) * 512 - $Size
	if ($padding -gt 0) {
		if (($Stream.Position + $padding) -gt $Stream.Length) { throw 'Archive is truncated.' }
		$Stream.Seek($padding, [IO.SeekOrigin]::Current) | Out-Null
	}
	return $bytes
}

function Get-TarEntryList {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $Path)

	$entries = New-Object 'System.Collections.Generic.List[object]'
	$stream = $null
	$pendingLongName = $null
	try {
		$stream = [IO.File]::OpenRead($Path)
		$header = New-Object byte[] 512
		while ($true) {
			$read = $stream.Read($header, 0, 512)
			if ($read -eq 0) { break }
			if ($read -ne 512) { throw 'Archive listing is truncated.' }
			$entry = ConvertFrom-TarHeaderBlock $header
			if ($null -eq $entry) { break }
			if ($entry.TypeFlag -eq 'L') {
				if ($pendingLongName) { throw 'Archive contains consecutive GNU long-name records.' }
				$payload = Read-TarPayloadBytes $stream $entry.Size
				$pendingLongName = [Text.Encoding]::UTF8.GetString($payload).TrimEnd([char] 0)
				if (-not $pendingLongName) { throw 'Archive contains an empty GNU long-name record.' }
				continue
			}
			if ($pendingLongName) {
				$entry.Name = $pendingLongName
				$pendingLongName = $null
			}
			$entries.Add($entry)

			$skip = [long] ([Math]::Ceiling($entry.Size / 512.0)) * 512
			if ($skip -gt 0) {
				if (($stream.Position + $skip) -gt $stream.Length) { throw 'Archive listing is truncated.' }
				$stream.Seek($skip, [IO.SeekOrigin]::Current) | Out-Null
			}
		}
		if ($pendingLongName) { throw 'Archive contains an unterminated GNU long-name record.' }
	} finally {
		if ($stream) { $stream.Dispose() }
	}

	return $entries.ToArray()
}

function Expand-TarArchive {
	# Extraction is deliberately separate from listing: the caller validates the listing
	# with Assert-PullArchiveEntries first, and every entry is re-checked here so a path
	# can never resolve outside the destination even if validation was skipped.
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $Path,
		[Parameter(Mandatory = $true)] [string] $Destination
	)

	$root = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
	if (-not (Test-Path -LiteralPath $root -PathType Container)) {
		throw "Extraction destination does not exist: $Destination"
	}
	$extracted = 0
	$stream = $null
	$pendingLongName = $null
	try {
		$stream = [IO.File]::OpenRead($Path)
		$header = New-Object byte[] 512
		while ($true) {
			$read = $stream.Read($header, 0, 512)
			if ($read -eq 0) { break }
			if ($read -ne 512) { throw 'Archive is truncated.' }
			$entry = ConvertFrom-TarHeaderBlock $header
			if ($null -eq $entry) { break }
			if ($entry.TypeFlag -eq 'L') {
				if ($pendingLongName) { throw 'Archive contains consecutive GNU long-name records.' }
				$payload = Read-TarPayloadBytes $stream $entry.Size
				$pendingLongName = [Text.Encoding]::UTF8.GetString($payload).TrimEnd([char] 0)
				if (-not $pendingLongName) { throw 'Archive contains an empty GNU long-name record.' }
				continue
			}
			if ($pendingLongName) {
				$entry.Name = $pendingLongName
				$pendingLongName = $null
			}
			if ($entry.TypeFlag -notin @('0', '5')) {
				throw "Archive contains an unsupported entry type: $($entry.Name)"
			}

			$relative = ([string] $entry.Name).Replace('/', '\').TrimEnd('\')
			$full = [IO.Path]::GetFullPath((Join-Path $root $relative))
			if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
				throw "Archive entry resolves outside the extraction directory: $($entry.Name)"
			}

			if ($entry.TypeFlag -eq '5') {
				New-Item -ItemType Directory -Force -Path $full | Out-Null
			} else {
				$parent = Split-Path -Parent $full
				if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
					New-Item -ItemType Directory -Force -Path $parent | Out-Null
				}
				$target = [IO.File]::Create($full)
				try {
					$remaining = [long] $entry.Size
					$buffer = New-Object byte[] 65536
					while ($remaining -gt 0) {
						$want = [int] [Math]::Min([long] $buffer.Length, $remaining)
						$got = $stream.Read($buffer, 0, $want)
						if ($got -le 0) { throw 'Archive is truncated.' }
						$target.Write($buffer, 0, $got)
						$remaining -= $got
					}
				} finally {
					$target.Dispose()
				}
				$extracted++
			}

			$padding = [long] ([Math]::Ceiling($entry.Size / 512.0)) * 512 - $entry.Size
			if ($padding -gt 0) { $stream.Seek($padding, [IO.SeekOrigin]::Current) | Out-Null }
		}
		if ($pendingLongName) { throw 'Archive contains an unterminated GNU long-name record.' }
	} finally {
		if ($stream) { $stream.Dispose() }
	}

	return $extracted
}

function Assert-PullArchiveEntries {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Entries,
		[Parameter(Mandatory = $true)] [string[]] $AllowedPaths,
		[string[]] $ExcludedPaths = @()
	)

	if ($Entries.Count -eq 0) {
		throw 'Downloaded archive contains no entries.'
	}
	foreach ($entry in $Entries) {
		# Only plain files and directories may be extracted. Symlinks, hard links, and
		# device nodes can redirect a write outside the destination directory.
		if ($entry.TypeFlag -notin @('0', '5')) {
			throw "Downloaded archive contains an unsupported entry type: $($entry.Name)"
		}
		$name = ([string] $entry.Name).TrimEnd('/')
		if (-not (Test-PullPathAllowed $name -ExcludedPaths $ExcludedPaths)) {
			throw "Downloaded archive contains a path that is not allowed to be pulled: $($entry.Name)"
		}
		$underAllowed = $false
		foreach ($allowed in $AllowedPaths) {
			$normalized = ([string] $allowed).Replace('\', '/').TrimEnd('/')
			if ($name -ieq $normalized -or $name.StartsWith($normalized + '/', [StringComparison]::OrdinalIgnoreCase)) {
				$underAllowed = $true
				break
			}
		}
		if (-not $underAllowed) {
			throw "Downloaded archive contains a path outside AllowedPullPaths: $($entry.Name)"
		}
	}

	return $Entries.Count
}

function Assert-ZipArchiveFile {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw 'ZIP archive was not created.'
	}
	Add-Type -AssemblyName System.IO.Compression.FileSystem
	$archive = $null
	try {
		$archive = [IO.Compression.ZipFile]::OpenRead($Path)
		if ($archive.Entries.Count -eq 0) {
			throw 'ZIP archive contains no entries.'
		}
		$buffer = New-Object byte[] 8192
		foreach ($entry in $archive.Entries) {
			if ($entry.FullName.EndsWith('/')) { continue }
			$stream = $entry.Open()
			try { while ($stream.Read($buffer, 0, $buffer.Length) -gt 0) {} }
			finally { $stream.Dispose() }
		}
	} catch {
		throw "ZIP archive integrity check failed: $($_.Exception.Message)"
	} finally {
		if ($archive) { $archive.Dispose() }
	}
}

function New-RemoteDeployCommand {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration,
		[Parameter(Mandatory = $true)] [ValidateSet('preflight', 'full', 'code', 'db')] [string] $DeployMode,
		[string] $SqlFile = '',
		[string] $UploadsFile = '',
		[string[]] $SyncPaths = @(),
		[string[]] $FullSyncPaths = @(),
		[string] $ProtectedArchiveFile = '',
		[switch] $ReplaceProtected
	)
	if ($SyncPaths.Count -eq 0) {
		$SyncPaths = @($Configuration.SyncPaths)
	}
	if ($FullSyncPaths.Count -eq 0) {
		$FullSyncPaths = if ($Configuration.Contains('FullSyncPaths')) { @($Configuration.FullSyncPaths) } else { @($Configuration.SyncPaths) }
	}
	$protectedPaths = if ($ReplaceProtected -and $Configuration.Contains('ProtectedSyncPaths')) { ($Configuration.ProtectedSyncPaths -join ',') } else { '' }
	$replaceProtectedValue = if ($ReplaceProtected) { '1' } else { '0' }

	$assignments = @(
		@('LOCAL_URL', $Configuration.LocalUrl),
		@('REMOTE_URL', $Configuration.RemoteUrl),
		@('ENVIRONMENT', $Configuration.Environment),
		@('EXPECTED_REMOTE_DOMAIN', $Configuration.ExpectedRemoteDomain),
		@('WP_DIR', $Configuration.RemoteWpPath),
		@('REPO_DIR', $Configuration.RemoteRepoPath),
		@('BACKUP_DIR', $Configuration.RemoteBackups),
		@('KEEP_BACKUPS', $Configuration.KeepBackups),
		@('MIN_REMOTE_FREE_SPACE_MB', $Configuration.MinimumRemoteFreeSpaceMB),
		@('GIT_SSH_KEY', $Configuration.RemoteGitSshKey),
		@('PHP_BIN', $Configuration.RemotePhpPath),
		@('WP_CLI_BIN', $Configuration.RemoteWpCliPath),
		@('EXPECTED_WP_DIR', $Configuration.ExpectedRemoteWpPath),
		@('EXPECTED_DB_NAME', $Configuration.ExpectedRemoteDbName),
		@('EXPECTED_DB_TABLE_PREFIX', $Configuration.ExpectedDbTablePrefix),
		@('SYNC_PATHS', ($SyncPaths -join ',')),
		@('FULL_SYNC_PATHS', ($FullSyncPaths -join ',')),
		@('PROTECTED_PATHS', $protectedPaths),
		@('PROTECTED_ARCHIVE', $ProtectedArchiveFile),
		@('REPLACE_PROTECTED', $replaceProtectedValue),
		@('DEPLOY_MODE', $DeployMode),
		@('SQL_FILE', $SqlFile),
		@('UPLOADS_ZIP', $UploadsFile)
	)

	$parts = @()
	foreach ($assignment in $assignments) {
		$parts += "$($assignment[0])=$(ConvertTo-ShSingleQuotedString ([string] $assignment[1]))"
	}
	$parts += "sh $(ConvertTo-ShSingleQuotedString $Configuration.RemoteRunnerPath)"
	return $parts -join ' '
}

function New-RemotePullCommand {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration,
		[Parameter(Mandatory = $true)] [ValidateSet('pull-db', 'pull-files')] [string] $PullMode,
		[Parameter(Mandatory = $true)] [string] $ArtifactPath,
		[string[]] $PullPaths = @()
	)

	if (-not (Test-RemotePath $ArtifactPath)) {
		throw 'Pull artifact path must be a non-root absolute POSIX path without dot segments.'
	}
	foreach ($path in $PullPaths) {
		if (-not (Test-PullPathAllowed $path)) {
			throw "Pull path is not allowed: $path"
		}
	}
	if ($PullMode -eq 'pull-files' -and $PullPaths.Count -eq 0) {
		throw 'pull-files requires at least one allowed path.'
	}

	$assignments = @(
		@('LOCAL_URL', $Configuration.LocalUrl),
		@('REMOTE_URL', $Configuration.RemoteUrl),
		@('ENVIRONMENT', $Configuration.Environment),
		@('EXPECTED_REMOTE_DOMAIN', $Configuration.ExpectedRemoteDomain),
		@('WP_DIR', $Configuration.RemoteWpPath),
		@('REPO_DIR', $Configuration.RemoteRepoPath),
		@('BACKUP_DIR', $Configuration.RemoteBackups),
		@('KEEP_BACKUPS', $Configuration.KeepBackups),
		@('MIN_REMOTE_FREE_SPACE_MB', $Configuration.MinimumRemoteFreeSpaceMB),
		@('GIT_SSH_KEY', $Configuration.RemoteGitSshKey),
		@('PHP_BIN', $Configuration.RemotePhpPath),
		@('WP_CLI_BIN', $Configuration.RemoteWpCliPath),
		@('EXPECTED_WP_DIR', $Configuration.ExpectedRemoteWpPath),
		@('EXPECTED_DB_NAME', $Configuration.ExpectedRemoteDbName),
		@('EXPECTED_DB_TABLE_PREFIX', $Configuration.ExpectedDbTablePrefix),
		@('SYNC_PATHS', ($Configuration.SyncPaths -join ',')),
		@('ALLOW_PRODUCTION_PULL', $(if ($Configuration.Contains('AllowProductionPull') -and $Configuration.AllowProductionPull) { '1' } else { '0' })),
		@('DEPLOY_MODE', $PullMode),
		@('SQL_FILE', ''),
		@('UPLOADS_ZIP', ''),
		@('PULL_ARTIFACT', $ArtifactPath),
		@('PULL_PATHS', ($PullPaths -join ','))
	)

	$parts = @()
	foreach ($assignment in $assignments) {
		$parts += "$($assignment[0])=$(ConvertTo-ShSingleQuotedString ([string] $assignment[1]))"
	}
	$parts += "sh $(ConvertTo-ShSingleQuotedString $Configuration.RemoteRunnerPath)"
	return $parts -join ' '
}

function Add-ValidationError {
	param(
		[System.Collections.Generic.List[string]] $Errors,
		[string] $Message
	)

	$Errors.Add($Message)
}

function Test-HttpUrl {
	param([string] $Value)

	$uri = $null
	if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref] $uri)) {
		return $false
	}

	return $uri.Scheme -in @('http', 'https') -and -not [string]::IsNullOrWhiteSpace($uri.Host)
}

function Test-RemotePath {
	param([string] $Value)

	if ([string]::IsNullOrWhiteSpace($Value) -or -not $Value.StartsWith('/')) {
		return $false
	}
	if ($Value -eq '/' -or $Value -match '[\r\n]' -or $Value -match '(^|/)\.\.?(/|$)') {
		return $false
	}

	return $true
}

function Test-WrapperSafeValue {
	param([string] $Value)

	if ([string]::IsNullOrEmpty($Value)) { return $true }
	return $Value -match '^[A-Za-z0-9_.,:/@%+=?&#~-]+$'
}

function Test-SyncPath {
	[CmdletBinding()]
	param([string] $Value, [switch] $AllowProtected)

	if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq '.') {
		return $false
	}
	if ([IO.Path]::IsPathRooted($Value) -or $Value -match '[\\:\r\n]') {
		return $false
	}
	if ($Value -match '(^|/)\.\.?(/|$)' -or $Value.EndsWith('/')) {
		return $false
	}
	if ($Value -match '(?i)^(\.git|\.deploy)(/|$)' -or (-not $AllowProtected -and $Value -match '(?i)^wp-config\.php$')) {
		return $false
	}

	return $true
}

function Get-PullModeNames {
	return @('pull-db', 'pull-files', 'pull-full')
}

function Get-PullDenyList {
	# Paths that must never travel from the remote site into the local checkout, as
	# case-insensitive patterns over a WordPress-relative path. ExcludedPullPaths may
	# extend this list; nothing in the configuration can shorten it.
	return @(
		'^wp-config',
		'(^|/)\.env($|/)',
		'(^|/)\.git($|/)',
		'(^|/)\.ssh($|/)',
		'(^|/)\.deploy($|/)',
		'(^|/)\.htpasswd$',
		'(^|/)server-deploy\.sh$',
		'(^|/)server\.config\.sh$',
		'(^|/)deploy\.config\.ps1$',
		'(^|/)node_modules($|/)',
		'^wp-content/(cache|upgrade|backup|backups|w3tc-config)($|/)',
		'(^|/)id_(rsa|dsa|ecdsa|ed25519)(\.pub)?$',
		'\.(pem|key|p12|pfx)$'
	)
}

function Test-PullPathAllowed {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Path,
		[string[]] $ExcludedPaths = @()
	)

	# Test-SyncPath already rejects rooted paths, dot segments, backslashes, and control
	# characters, so anything it accepts cannot escape the WordPress directory.
	if (-not (Test-SyncPath $Path)) {
		return $false
	}
	$candidate = $Path.Replace('\', '/')
	foreach ($pattern in (Get-PullDenyList)) {
		if ($candidate -match "(?i)$pattern") { return $false }
	}
	foreach ($excluded in $ExcludedPaths) {
		if ([string]::IsNullOrWhiteSpace($excluded)) { continue }
		$normalized = $excluded.Replace('\', '/').TrimEnd('/')
		if ($candidate -ieq $normalized -or $candidate.StartsWith($normalized + '/', [StringComparison]::OrdinalIgnoreCase)) {
			return $false
		}
	}

	return $true
}

function Get-ProfileSiteId {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration)

	if ($Configuration.Contains('SiteId') -and -not [string]::IsNullOrWhiteSpace([string] $Configuration.SiteId)) {
		return ([string] $Configuration.SiteId).Trim().ToLowerInvariant()
	}
	return 'default-site'
}

function Get-ProfileScriptLoadResult {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $ProfilePath)

	$result = [pscustomobject] @{ Configuration = $null; Error = '' }
	$tokens = $null
	$parseErrors = $null
	$ast = [System.Management.Automation.Language.Parser]::ParseFile($ProfilePath, [ref] $tokens, [ref] $parseErrors)
	if ($parseErrors.Count -gt 0) {
		$result.Error = 'profile has PowerShell parse errors and was not loaded'
		return $result
	}
	if ($null -eq $ast.EndBlock) {
		$result.Error = 'profile has no executable end block and was not loaded'
		return $result
	}
	$statements = @($ast.EndBlock.Statements)
	if ($statements.Count -ne 1 -or $statements[0] -isnot [System.Management.Automation.Language.AssignmentStatementAst]) {
		$result.Error = 'profile must contain exactly one data-only $DeployConfig assignment'
		return $result
	}
	$commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
	if ($commands.Count -gt 0) {
		$result.Error = 'profile must be data-only and contain no command invocations'
		return $result
	}
	$methodCalls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))
	if ($methodCalls.Count -gt 0) {
		$result.Error = 'profile must be data-only and contain no method invocations'
		return $result
	}
	$assignment = $statements[0]
	if ($assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
		$assignment.Left.VariablePath.UserPath -ine 'DeployConfig') {
		$result.Error = 'profile must assign a $DeployConfig dictionary'
		return $result
	}
	if ($assignment.Right -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
		$assignment.Right.Expression -isnot [System.Management.Automation.Language.HashtableAst]) {
		$result.Error = 'profile must assign $DeployConfig directly from a hashtable literal'
		return $result
	}
	$unsupportedExpressions = @($assignment.Right.Expression.FindAll({
		param($node)
		if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
			return $node.VariablePath.UserPath -notin @('true', 'false', 'null')
		}
		return $node -isnot [System.Management.Automation.Language.HashtableAst] -and
			$node -isnot [System.Management.Automation.Language.ArrayExpressionAst] -and
			$node -isnot [System.Management.Automation.Language.ArrayLiteralAst] -and
			$node -isnot [System.Management.Automation.Language.StatementBlockAst] -and
			$node -isnot [System.Management.Automation.Language.PipelineAst] -and
			$node -isnot [System.Management.Automation.Language.CommandExpressionAst] -and
			$node -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -and
			$node -isnot [System.Management.Automation.Language.ConstantExpressionAst]
	}, $true))
	if ($unsupportedExpressions.Count -gt 0) {
		$result.Error = 'profile must contain only literal data values (variables, expressions, casts, and subexpressions are not allowed)'
		return $result
	}
	try {
		$loaded = $assignment.Right.Expression.SafeGetValue()
	} catch {
		$result.Error = "profile value could not be safely evaluated ($($_.Exception.GetType().Name))"
		return $result
	}
	if ($loaded -isnot [System.Collections.IDictionary]) {
		$result.Error = 'profile must assign a $DeployConfig dictionary'
		return $result
	}
	$result.Configuration = $loaded
	return $result
}

function Get-ProfileIsolationErrors {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration,
		[string] $ProfilePath = '',
		[string] $ProfilesDirectory = '',
		[string[]] $AdditionalProfilesDirectories = @(),
		[string] $CanonicalProfilesDirectory = ''
	)

	$errors = New-Object 'System.Collections.Generic.List[string]'
	$profiles = New-Object 'System.Collections.Generic.List[object]'
	$profiles.Add([pscustomobject] @{ Path = $ProfilePath; Configuration = $Configuration })
	$profileDirectories = New-Object 'System.Collections.Generic.List[string]'
	$profileDirectoryCandidates = New-Object 'System.Collections.Generic.List[object]'
	$profileDirectoryCandidates.Add($ProfilesDirectory)
	foreach ($directory in @($AdditionalProfilesDirectories)) { $profileDirectoryCandidates.Add($directory) }
	if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) {
		$profileDirectoryCandidates.Add((Split-Path -Parent ([IO.Path]::GetFullPath($ProfilePath))))
	}
	$toolRootDirectory = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
	if (-not [string]::IsNullOrWhiteSpace($CanonicalProfilesDirectory)) {
		$profileDirectoryCandidates.Add($toolRootDirectory)
		$profileDirectoryCandidates.Add($CanonicalProfilesDirectory)
	}
	foreach ($directory in $profileDirectoryCandidates) {
		if ([string]::IsNullOrWhiteSpace([string] $directory)) { continue }
		$fullDirectory = [IO.Path]::GetFullPath([string] $directory)
		if (-not ($profileDirectories | Where-Object { $_.Equals($fullDirectory, [StringComparison]::OrdinalIgnoreCase) })) {
			$profileDirectories.Add($fullDirectory)
		}
	}
	$seenProfilePaths = @{}
	foreach ($directory in $profileDirectories) {
		if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
		foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.example\.ps1$' })) {
			$filePath = [IO.Path]::GetFullPath($file.FullName)
			if ($directory.Equals($toolRootDirectory, [StringComparison]::OrdinalIgnoreCase) -and $file.Name -notmatch '^deploy\.config(?:\..+)?\.ps1$') { continue }
			if ($seenProfilePaths.ContainsKey($filePath)) { continue }
			$seenProfilePaths[$filePath] = $true
			if (-not [string]::IsNullOrWhiteSpace($ProfilePath) -and
				$filePath.Equals([IO.Path]::GetFullPath($ProfilePath), [StringComparison]::OrdinalIgnoreCase)) { continue }
			try {
				$profileResult = Get-ProfileScriptLoadResult -ProfilePath $filePath
				if (-not [string]::IsNullOrWhiteSpace([string] $profileResult.Error)) {
					$errors.Add("Could not load profile '$filePath': $($profileResult.Error)")
					continue
				}
				$loaded = $profileResult.Configuration
				if ($loaded -is [System.Collections.IDictionary]) {
					$profiles.Add([pscustomobject] @{ Path = $filePath; Configuration = $loaded })
				}
			} catch {
				$errors.Add("Could not load profile '$filePath': $($_.Exception.Message)")
			}
		}
	}

	$identityFields = @(
		@{ Name = 'SiteId'; Kind = 'value' },
		@{ Name = 'CodeRepositoryPath'; Kind = 'local-path' },
		@{ Name = 'WorkRoot'; Kind = 'local-path' },
		@{ Name = 'LocalWpPath'; Kind = 'local-path' },
		@{ Name = 'LocalBackupDirectory'; Kind = 'local-path' },
		@{ Name = 'LocalDbName'; Kind = 'value' },
		@{ Name = 'RemoteWpPath'; Kind = 'remote-path' },
		@{ Name = 'ExpectedRemoteDbName'; Kind = 'value' },
		@{ Name = 'RemoteRepoPath'; Kind = 'remote-path' },
		@{ Name = 'RemoteTmpPath'; Kind = 'remote-path' },
		@{ Name = 'RemoteBackups'; Kind = 'remote-path' },
		@{ Name = 'RemoteRunnerPath'; Kind = 'remote-path' }
	)
	$seen = @{}
	foreach ($profileRecord in $profiles) {
		$config = $profileRecord.Configuration
		$profileName = if ([string]::IsNullOrWhiteSpace([string] $profileRecord.Path)) { '<selected profile>' } else { [IO.Path]::GetFileName($profileRecord.Path) }
		foreach ($field in $identityFields) {
			if (-not $config.Contains($field.Name) -or [string]::IsNullOrWhiteSpace([string] $config[$field.Name])) { continue }
			$value = [string] $config[$field.Name]
			if ($field.Kind -eq 'local-path') { $value = [IO.Path]::GetFullPath($value).TrimEnd([char]'\', [char]'/') }
			elseif ($field.Kind -eq 'remote-path') { $value = $value.TrimEnd([char]'/') }
			$key = "$($field.Name)|$($value.ToLowerInvariant())"
			if ($seen.ContainsKey($key) -and $seen[$key].Path -ne $profileRecord.Path) {
				$other = $seen[$key]
				$errors.Add("Profile isolation collision: $($field.Name) '$value' is shared by '$($other.Name)' and '$profileName'.")
			} else {
				$seen[$key] = [pscustomobject] @{ Name = $profileName; Path = $profileRecord.Path }
			}
		}
	}
	return $errors.ToArray()
}

function Assert-ProfileIsolation {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration,
		[string] $ProfilePath = '',
		[string] $ProfilesDirectory = '',
		[string[]] $AdditionalProfilesDirectories = @(),
		[string] $CanonicalProfilesDirectory = ''
	)
	$errors = @(Get-ProfileIsolationErrors -Configuration $Configuration -ProfilePath $ProfilePath -ProfilesDirectory $ProfilesDirectory -AdditionalProfilesDirectories $AdditionalProfilesDirectories -CanonicalProfilesDirectory $CanonicalProfilesDirectory)
	if ($errors.Count -gt 0) { throw ($errors -join "`n") }
}

function Get-PullPathSelection {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration,
		[Parameter(Mandatory = $true)] [string] $Mode
	)

    if ($Mode -eq 'pull-full' -and $Configuration.Contains('FullPullPaths')) {
        return [pscustomobject] @{ Values = @($Configuration.FullPullPaths); Source = 'FullPullPaths' }
    }
    if ($Mode -eq 'pull-full' -and ($Configuration.Contains('PullContentPaths') -or $Configuration.Contains('PullMediaPaths'))) {
        $content = if ($Configuration.Contains('PullContentPaths')) { @($Configuration.PullContentPaths) } else { @() }
        $media = if ($Configuration.Contains('PullMediaPaths')) { @($Configuration.PullMediaPaths) } else { @() }
        return [pscustomobject] @{ Values = @($content + $media); Source = 'PullContentPaths+PullMediaPaths' }
    }
	return [pscustomobject] @{ Values = @($Configuration.AllowedPullPaths); Source = 'AllowedPullPaths' }
}

function Get-FileSha256Hex {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found for hashing: $Path" }
	return ([string] (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash).Replace('-', '').ToLowerInvariant()
}

function Get-DirectorySha256Hex {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Directory not found for hashing: $Path" }
	$root = [IO.Path]::GetFullPath($Path).TrimEnd([char]'\', [char]'/')
	$entries = @(Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object FullName)
	$builder = New-Object Text.StringBuilder
	foreach ($entry in $entries) {
		if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse-point file is not allowed in a pull workspace: $($entry.FullName)" }
		$relative = $entry.FullName.Substring($root.Length).TrimStart([char]'\', [char]'/').Replace([char]'\', [char]'/')
		if ($entry.PSIsContainer) {
			[void] $builder.Append('D:').Append($relative).Append("`n")
		} else {
			[void] $builder.Append('F:').Append($relative).Append("`n").Append((Get-FileSha256Hex $entry.FullName)).Append("`n")
		}
	}
	$sha = [Security.Cryptography.SHA256]::Create()
	try {
		return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($builder.ToString())))).Replace('-', '').ToLowerInvariant()
	} finally {
		$sha.Dispose()
	}
}

function Get-LocalBackupRetentionPlan {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $BackupDirectory,
		[Parameter(Mandatory = $true)] [ValidateRange(1, 1000)] [int] $Keep,
		[ValidateRange(0, 36500)] [int] $KeepDays = 0,
		[ValidateRange(0, 10485760)] [long] $MaxBytes = 0,
		[datetime] $Now = (Get-Date)
	)

	if (-not (Test-Path -LiteralPath $BackupDirectory -PathType Container)) {
		return [pscustomobject] @{ Groups = @(); Remove = @(); Kept = @() }
	}
	$groups = @(Get-ChildItem -LiteralPath $BackupDirectory -Force -ErrorAction SilentlyContinue |
		Where-Object { $_.Name -match '^(local-db|files)-([0-9]{8}-[0-9]{6})' } |
		Group-Object { ([regex]::Match($_.Name, '^(?:local-db|files)-([0-9]{8}-[0-9]{6})')).Groups[1].Value } |
		Sort-Object Name -Descending |
		ForEach-Object {
			$stamp = [DateTime]::MinValue
			[DateTime]::TryParseExact($_.Name, 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref] $stamp) | Out-Null
			$bytes = [long] 0
			foreach ($item in @($_.Group)) {
				if ($item.PSIsContainer) {
					foreach ($file in @(Get-ChildItem -LiteralPath $item.FullName -File -Recurse -ErrorAction SilentlyContinue)) { $bytes += [long] $file.Length }
				} else { $bytes += [long] $item.Length }
			}
			[pscustomobject] @{ Stamp = $_.Name; Items = @($_.Group); Date = $stamp; Bytes = $bytes }
		})

	$remove = New-Object 'System.Collections.Generic.List[object]'
	for ($index = 0; $index -lt $groups.Count; $index++) {
		if ($index -eq 0) { continue } # A recoverable local copy always retains its newest complete backup group.
		$group = $groups[$index]
		$expired = $KeepDays -gt 0 -and $group.Date -ne [DateTime]::MinValue -and $group.Date -lt $Now.AddDays(-$KeepDays)
		if ($index -ge $Keep -or $expired) { $remove.Add($group) }
	}
	$removeStamps = @($remove | ForEach-Object { $_.Stamp })
	$survivors = @($groups | Where-Object { $removeStamps -notcontains $_.Stamp })
	$totalBytes = [long] 0
	foreach ($group in $survivors) { $totalBytes += [long] $group.Bytes }
	for ($index = $survivors.Count - 1; $index -ge 1 -and $MaxBytes -gt 0 -and $totalBytes -gt $MaxBytes; $index--) {
		$group = $survivors[$index]
		$remove.Add($group)
		$totalBytes -= [long] $group.Bytes
	}
	$removeStamps = @($remove | ForEach-Object { $_.Stamp })
	return [pscustomobject] @{ Groups = @($groups); Remove = $remove.ToArray(); Kept = @($groups | Where-Object { $removeStamps -notcontains $_.Stamp }) }
}

function New-PullManifest {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration,
		[Parameter(Mandatory = $true)] [object] $Plan,
		[Parameter(Mandatory = $true)] [string] $ManifestPath
	)

	$artifactHashes = [ordered] @{}
	if ($Plan.IncludeDatabase -and (Test-Path -LiteralPath $Plan.LocalDbArchive -PathType Leaf)) {
		$artifactHashes.database = Get-FileSha256Hex $Plan.LocalDbArchive
		$artifactHashes.databaseSql = Get-FileSha256Hex $Plan.LocalDbSql
	}
	if ($Plan.IncludeFiles -and (Test-Path -LiteralPath $Plan.LocalFilesArchive -PathType Leaf)) {
		$artifactHashes.files = Get-FileSha256Hex $Plan.LocalFilesArchive
		$artifactHashes.filesTree = Get-DirectorySha256Hex $Plan.FilesStagingDirectory
	}
	$manifest = [ordered] @{
		ManifestVersion       = 1
		SiteId                = Get-ProfileSiteId $Configuration
		Environment           = [string] $Configuration.Environment
		RemoteUrl             = [string] $Configuration.RemoteUrl
		Mode                  = [string] $Plan.Mode
		Stamp                 = [string] $Plan.Stamp
		ExpectedDbTablePrefix = [string] $Plan.ExpectedTablePrefix
		ExpectedDbTableCount  = [int] $Plan.ExpectedTableCount
		MinimumDbTableCount   = [int] $Plan.MinimumTableCount
		WordPressCoreVersion  = if ($Configuration.Contains('ExpectedWordPressCoreVersion')) { [string] $Configuration.ExpectedWordPressCoreVersion } else { '' }
		PathClasses           = [ordered] @{
			core    = if ($Configuration.Contains('CorePolicy')) { [string] $Configuration.CorePolicy } else { 'preserve-local-core' }
			content = if ($Configuration.Contains('PullContentPaths')) { @($Configuration.PullContentPaths) } else { @() }
			media   = if ($Configuration.Contains('PullMediaPaths')) { @($Configuration.PullMediaPaths) } else { @() }
			never   = @(Get-PullDenyList)
		}
		PullPaths             = @($Plan.PullPaths)
		Artifacts             = $artifactHashes
		CreatedUtc            = [DateTime]::UtcNow.ToString('o')
	}
	New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ManifestPath) | Out-Null
	$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
	return $manifest
}

function Assert-PullManifest {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration,
		[Parameter(Mandatory = $true)] [string] $ManifestPath,
		[Parameter(Mandatory = $true)] [object] $Plan
	)

	if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Pull manifest was not found: $ManifestPath" }
	try { $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json } catch { throw "Pull manifest is invalid: $ManifestPath" }
	if ([int] $manifest.ManifestVersion -ne 1) { throw 'Unsupported pull manifest version.' }
	if ([string] $manifest.SiteId -ne (Get-ProfileSiteId $Configuration)) { throw 'Pull manifest SiteId does not match the selected profile.' }
	if ([string] $manifest.Environment -ne [string] $Configuration.Environment) { throw 'Pull manifest environment does not match the selected profile.' }
	if ([string] $manifest.RemoteUrl -ne [string] $Configuration.RemoteUrl) { throw 'Pull manifest remote URL does not match the selected profile.' }
	if ([string] $manifest.ExpectedDbTablePrefix -ne [string] $Configuration.ExpectedDbTablePrefix) { throw 'Pull manifest database prefix does not match the selected profile.' }
	if ([int] $manifest.ExpectedDbTableCount -ne [int] $Plan.ExpectedTableCount) { throw 'Pull manifest database table count does not match the selected profile.' }
	if ([int] $manifest.MinimumDbTableCount -ne [int] $Plan.MinimumTableCount) { throw 'Pull manifest database sanity threshold does not match the selected profile.' }
	if ([string] $manifest.Mode -ne [string] $Plan.Mode -and [string] $Plan.Mode -ne 'apply-pull') { throw 'Pull manifest mode does not match the selected operation.' }
	$manifestPaths = @($manifest.PullPaths | ForEach-Object { [string] $_ })
	if (($manifestPaths -join "`n") -ne (@($Plan.PullPaths) -join "`n")) { throw 'Pull manifest path list does not match the selected profile.' }
	$databaseSql = if ($Plan.PSObject.Properties['DatabaseSql']) { [string] $Plan.DatabaseSql } else { [string] $Plan.LocalDbSql }
	$filesRoot = if ($Plan.PSObject.Properties['FilesRoot']) { [string] $Plan.FilesRoot } else { [string] $Plan.FilesStagingDirectory }
	if ($manifest.Artifacts.database) {
		$databaseArchive = Join-Path $Plan.Workspace 'database.sql.gz'
		if (-not (Test-Path -LiteralPath $databaseArchive -PathType Leaf)) { throw 'Pull database artifact referenced by the manifest is missing.' }
		if ((Get-FileSha256Hex $databaseArchive) -ne [string] $manifest.Artifacts.database) { throw 'Pull database artifact hash does not match the pull manifest.' }
		if (-not $manifest.Artifacts.databaseSql) { throw 'Pull database SQL hash is missing from the pull manifest.' }
		if (-not (Test-Path -LiteralPath $databaseSql -PathType Leaf)) { throw 'Extracted pull database SQL referenced by the manifest is missing.' }
		if ((Get-FileSha256Hex $databaseSql) -ne [string] $manifest.Artifacts.databaseSql) { throw 'Extracted pull database SQL hash does not match the pull manifest.' }
	}
	if ($manifest.Artifacts.files) {
		$filesArchive = Join-Path $Plan.Workspace 'files.tar.gz'
		if (-not (Test-Path -LiteralPath $filesArchive -PathType Leaf)) { throw 'Pull files artifact referenced by the manifest is missing.' }
		if ((Get-FileSha256Hex $filesArchive) -ne [string] $manifest.Artifacts.files) { throw 'Pull files artifact hash does not match the pull manifest.' }
		if (-not $manifest.Artifacts.filesTree) { throw 'Pull files tree hash is missing from the pull manifest.' }
		if (-not (Test-Path -LiteralPath $filesRoot -PathType Container)) { throw 'Extracted pull files referenced by the manifest are missing.' }
		if ((Get-DirectorySha256Hex $filesRoot) -ne [string] $manifest.Artifacts.filesTree) { throw 'Extracted pull files hash does not match the pull manifest.' }
	}
	return $manifest
}

function Add-PullConfigurationErrors {
	param(
		[System.Collections.Generic.List[string]] $Errors,
		[System.Collections.IDictionary] $Configuration
	)

	foreach ($key in @('PullEnabled', 'AllowProductionPull', 'RequirePullConfirmation', 'AllowDestructiveLocalReplace')) {
		if ($Configuration.Contains($key) -and $Configuration[$key] -isnot [bool]) {
			Add-ValidationError $Errors "$key must be a boolean."
		}
	}

	# Pull keys may be pre-filled while pull stays switched off, so an existing push-only
	# configuration keeps validating. Only an enabled pull is held to the full schema.
	$pullEnabled = $Configuration.Contains('PullEnabled') -and $Configuration['PullEnabled'] -is [bool] -and $Configuration['PullEnabled']
	if (-not $pullEnabled) {
		return
	}

	$allowProductionPull = $Configuration.Contains('AllowProductionPull') -and $Configuration['AllowProductionPull'] -is [bool] -and $Configuration['AllowProductionPull']
	if ($Configuration.Environment -eq 'production' -and -not $allowProductionPull) {
		Add-ValidationError $Errors 'Production pull requires AllowProductionPull = $true in the private configuration.'
	}
	if ($Configuration.Environment -ne 'production' -and $allowProductionPull) {
		Add-ValidationError $Errors 'AllowProductionPull may be true only for a production read-only pull profile.'
	}

	foreach ($key in @('LocalBackupDirectory', 'LocalPhpPath', 'LocalWpCliPath', 'MysqlPath')) {
		if (-not $Configuration.Contains($key)) {
			Add-ValidationError $Errors "Missing configuration value while PullEnabled is true: $key"
			continue
		}
		if ($Configuration[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Configuration[$key])) {
			Add-ValidationError $Errors "Configuration value must be a non-empty string: $key"
		}
	}

	foreach ($key in @('LocalBackupDirectory', 'LocalPhpPath', 'LocalWpCliPath', 'MysqlPath')) {
		if ($Configuration[$key] -is [string] -and -not [IO.Path]::IsPathRooted($Configuration[$key])) {
			Add-ValidationError $Errors "$key must be an absolute local path."
		}
	}
	if ($Configuration['LocalBackupDirectory'] -is [string] -and $Configuration['LocalWpPath'] -is [string]) {
		$wpRoot = $Configuration.LocalWpPath.TrimEnd('\', '/')
		if ($Configuration.LocalBackupDirectory.TrimEnd('\', '/').StartsWith($wpRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
			Add-ValidationError $Errors 'LocalBackupDirectory must be outside LocalWpPath.'
		}
	}

	foreach ($key in @('AllowedPullPaths', 'FullPullPaths', 'PullContentPaths', 'PullMediaPaths', 'ExcludedPullPaths')) {
		if (-not $Configuration.Contains($key)) {
			if ($key -eq 'AllowedPullPaths') {
				Add-ValidationError $Errors 'Missing configuration value while PullEnabled is true: AllowedPullPaths'
			}
			continue
		}
		if ($Configuration[$key] -isnot [Array]) {
			Add-ValidationError $Errors "$key must be an array of WordPress-relative paths."
			continue
		}
		$values = @($Configuration[$key])
		if ($key -in @('AllowedPullPaths', 'FullPullPaths') -and $values.Count -eq 0) {
			Add-ValidationError $Errors "$key must contain at least one path."
		}
		$seen = @{}
		foreach ($value in $values) {
			if ($value -isnot [string] -or -not (Test-SyncPath $value) -or -not (Test-WrapperSafeValue ([string] $value))) {
				Add-ValidationError $Errors "Unsafe $key value: $value"
				continue
			}
			$seenKey = $value.ToLowerInvariant()
			if ($seen.ContainsKey($seenKey)) {
				Add-ValidationError $Errors "Duplicate $key value: $value"
			}
			$seen[$seenKey] = $true
			if ($key -in @('AllowedPullPaths', 'FullPullPaths') -and -not (Test-PullPathAllowed $value)) {
				Add-ValidationError $Errors "$key value is permanently excluded and cannot be pulled: $value"
			}
		}
	}

	$requireConfirmation = -not $Configuration.Contains('RequirePullConfirmation') -or $Configuration['RequirePullConfirmation'] -isnot [bool] -or $Configuration['RequirePullConfirmation']
	$allowDestructive = $Configuration.Contains('AllowDestructiveLocalReplace') -and $Configuration['AllowDestructiveLocalReplace'] -is [bool] -and $Configuration['AllowDestructiveLocalReplace']
	if ($allowDestructive -and -not $requireConfirmation) {
		Add-ValidationError $Errors 'AllowDestructiveLocalReplace requires RequirePullConfirmation to stay true.'
	}
	if (-not $Configuration.Contains('ExpectedPullDbTableCount')) {
		Add-ValidationError $Errors 'Missing configuration value while PullEnabled is true: ExpectedPullDbTableCount'
	} elseif ($Configuration.ExpectedPullDbTableCount -isnot [int] -or $Configuration.ExpectedPullDbTableCount -lt 1) {
		Add-ValidationError $Errors 'ExpectedPullDbTableCount must be an integer greater than or equal to 1.'
	}
	$corePolicy = if ($Configuration.Contains('CorePolicy')) { [string] $Configuration.CorePolicy } else { 'preserve-local-core' }
	if ($corePolicy -ne 'preserve-local-core') {
		Add-ValidationError $Errors 'CorePolicy must be preserve-local-core. Pull never downloads or replaces WordPress core.'
	}
}

function Assert-PullAllowed {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration,
		[Parameter(Mandatory = $true)] [string] $Mode,
		[switch] $Confirmed,
		[switch] $Mirror,
		[switch] $DryRun,
		[switch] $AllowProductionPull
	)

	if ($Mode -notin (Get-PullModeNames)) {
		throw "Assert-PullAllowed expects a pull mode, not '$Mode'."
	}
	Assert-DeployModeAllowed -Environment $Configuration.Environment -Mode $Mode -AllowProductionPull:$AllowProductionPull
	if (-not ($Configuration.Contains('PullEnabled') -and $Configuration['PullEnabled'] -is [bool] -and $Configuration['PullEnabled'])) {
		throw 'Pull is disabled. Set PullEnabled = $true in deploy.config.ps1 before using a pull mode.'
	}
	if ($Mirror -and -not ($Configuration.Contains('AllowDestructiveLocalReplace') -and $Configuration['AllowDestructiveLocalReplace'] -is [bool] -and $Configuration['AllowDestructiveLocalReplace'])) {
		throw 'Mirror pull requires AllowDestructiveLocalReplace to be true.'
	}
	if ($DryRun) {
		return
	}
	$requireConfirmation = -not $Configuration.Contains('RequirePullConfirmation') -or $Configuration['RequirePullConfirmation'] -isnot [bool] -or $Configuration['RequirePullConfirmation']
	$replacesLocalData = $Mirror -or $Mode -in @('pull-db', 'pull-full')
	if ($replacesLocalData -and $requireConfirmation -and -not $Confirmed) {
		throw "Mode '$Mode' writes to local data and requires -Confirm. Run it with -DryRun first."
	}
	if ($Mirror) {
		# Mirror deletes local files the remote no longer has. It is part of the contract
		# but deliberately not executable until it has live-tested coverage.
		throw 'Mirror pull is not implemented and must not be run. Use the additive pull-files mode.'
	}
}

function New-PullPlan {
	# Resolves every path and target a pull run will use, and refuses the run if any of
	# them is unsafe. It touches no disk and opens no connection, so the whole decision
	# surface of a pull is testable without a server and without local writes.
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration,
		[Parameter(Mandatory = $true)] [string] $Mode,
		[Parameter(Mandatory = $true)] [string] $Stamp,
		[Parameter(Mandatory = $true)] [string] $WorkspaceRoot,
		[switch] $DryRun,
		[switch] $Confirmed,
		[switch] $Mirror,
		[switch] $AllowProductionPull
	)

	Assert-PullAllowed -Configuration $Configuration -Mode $Mode -Confirmed:$Confirmed -Mirror:$Mirror -DryRun:$DryRun -AllowProductionPull:$AllowProductionPull
	if ($Stamp -notmatch '^[0-9A-Za-z-]+$') {
		throw 'Pull run stamp contains unsupported characters.'
	}

	# Everything a pull writes locally lives here, never inside the working WordPress copy.
	$siteId = Get-ProfileSiteId $Configuration
	$workspace = Join-Path (Join-Path $WorkspaceRoot '.pull') (Join-Path $siteId $Stamp)
	$wpRoot = $Configuration.LocalWpPath.TrimEnd('\', '/')
	if ([IO.Path]::GetFullPath($workspace).StartsWith($wpRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
		throw 'Pull workspace must be outside LocalWpPath.'
	}

	$excluded = @()
	if ($Configuration.Contains('ExcludedPullPaths') -and $Configuration['ExcludedPullPaths'] -is [Array]) {
		$excluded = @($Configuration.ExcludedPullPaths)
	}
	$pathSelection = Get-PullPathSelection $Configuration $Mode
	$pullPathSource = @($pathSelection.Values)
	$pullPaths = @()
	if ($pullPathSource.Count -gt 0) {
		$pullPaths = @($pullPathSource | Where-Object { Test-PullPathAllowed $_ -ExcludedPaths $excluded })
	}

	$includeDatabase = $Mode -in @('pull-db', 'pull-full')
	$includeFiles = $Mode -in @('pull-files', 'pull-full')
	if ($includeFiles -and $pullPaths.Count -eq 0) {
		throw 'No pull path survived the exclusion rules. Review the pull path list and ExcludedPullPaths.'
	}

	$remoteTmp = $Configuration.RemoteTmpPath.TrimEnd('/')
	return [pscustomobject] @{
		Mode                  = $Mode
		SiteId                = $siteId
		Stamp                 = $Stamp
		IsDryRun              = [bool] $DryRun
		IncludeDatabase       = $includeDatabase
		IncludeFiles          = $includeFiles
		Workspace             = $workspace
		ManifestPath          = Join-Path $workspace 'manifest.json'
		WorkingDatabase       = [string] $Configuration.LocalDbName
		LocalBackupDirectory  = [string] $Configuration.LocalBackupDirectory
		RemoteDbArtifact      = if ($includeDatabase) { "$remoteTmp/pull-db-$Stamp.sql.gz" } else { '' }
		LocalDbArchive        = if ($includeDatabase) { Join-Path $workspace 'database.sql.gz' } else { '' }
		LocalDbSql            = if ($includeDatabase) { Join-Path $workspace 'database.sql' } else { '' }
		RemoteFilesArtifact   = if ($includeFiles) { "$remoteTmp/pull-files-$Stamp.tar.gz" } else { '' }
		LocalFilesArchive     = if ($includeFiles) { Join-Path $workspace 'files.tar.gz' } else { '' }
		FilesStagingDirectory = if ($includeFiles) { Join-Path $workspace 'files' } else { '' }
		PullPaths             = $pullPaths
		PullPathSource        = $pathSelection.Source
		ExcludedPaths         = $excluded
		ExpectedTablePrefix   = [string] $Configuration.ExpectedDbTablePrefix
		ExpectedTableCount    = [int] $Configuration.ExpectedPullDbTableCount
		MinimumTableCount     = [int] $Configuration.ExpectedPullDbTableCount
	}
}

function Get-PullSummaryLines {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [object] $Plan)

	$lines = @(
		"Mode                : $($Plan.Mode)",
		"Dry run             : $($Plan.IsDryRun)",
		"Site ID             : $($Plan.SiteId)",
		"Workspace           : $($Plan.Workspace)",
		"Manifest            : $($Plan.ManifestPath)",
		"Working database    : $($Plan.WorkingDatabase) (never written by download)"
	)
	if ($Plan.IncludeDatabase) {
		$lines += "Apply target database: $($Plan.WorkingDatabase) (replaced only by a separate confirmed apply after backup)"
		$lines += "Remote artifact     : $($Plan.RemoteDbArtifact)"
		$lines += "Verified SQL        : $($Plan.LocalDbSql)"
		$lines += "Expected tables     : $($Plan.ExpectedTableCount) with prefix '$($Plan.ExpectedTablePrefix)'"
	}
	if ($Plan.IncludeFiles) {
		$lines += "Remote artifact     : $($Plan.RemoteFilesArtifact)"
		$lines += "Files staged in     : $($Plan.FilesStagingDirectory) (additive, working files untouched)"
		$lines += "Pull paths          : $($Plan.PullPaths -join ', ') ($($Plan.PullPathSource))"
		if ($Plan.ExcludedPaths.Count -gt 0) {
			$lines += "Excluded paths      : $($Plan.ExcludedPaths -join ', ')"
		}
	}

	return $lines
}

function New-ApplyPullPlan {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration,
		[Parameter(Mandatory = $true)] [string] $Workspace,
		[Parameter(Mandatory = $true)] [string] $WorkspaceRoot,
		[switch] $DryRun,
		[switch] $Confirmed
	)

	if (-not ($Configuration.Contains('PullEnabled') -and $Configuration.PullEnabled -eq $true)) {
		throw 'Pull is disabled. Set PullEnabled = $true before applying a pulled workspace.'
	}
	if (-not $DryRun -and -not $Confirmed) {
		throw 'Applying a pulled workspace writes the local site and requires -Confirm.'
	}
	if ([string]::IsNullOrWhiteSpace($Workspace)) {
		throw 'PullWorkspace is required for apply-pull.'
	}
	$workspaceFull = [IO.Path]::GetFullPath($Workspace).TrimEnd('\', '/')
	$rootFull = [IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd('\', '/')
	$wpRoot = $Configuration.LocalWpPath.TrimEnd('\', '/')
	if ($workspaceFull.StartsWith($wpRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
		throw 'PullWorkspace must be outside LocalWpPath.'
	}
	$pullRoot = Join-Path (Join-Path $rootFull '.pull') (Get-ProfileSiteId $Configuration)
	if (-not $workspaceFull.StartsWith($pullRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
		throw 'PullWorkspace must be an existing .pull workspace created by pull-full.'
	}
	$pathSelection = Get-PullPathSelection $Configuration 'pull-full'
	$applyPullPathSource = @($pathSelection.Values)
	$applyPullPaths = @($applyPullPathSource | Where-Object { Test-PullPathAllowed $_ -ExcludedPaths @($Configuration.ExcludedPullPaths) })

	return [pscustomobject] @{
		Mode             = 'apply-pull'
		SiteId           = Get-ProfileSiteId $Configuration
		IsDryRun         = [bool] $DryRun
		Workspace        = $workspaceFull
		ManifestPath     = Join-Path $workspaceFull 'manifest.json'
		DatabaseSql      = Join-Path $workspaceFull 'database.sql'
		FilesRoot        = Join-Path $workspaceFull 'files'
		WorkingDatabase  = [string] $Configuration.LocalDbName
		LocalBackupDirectory = [string] $Configuration.LocalBackupDirectory
		LocalWpPath      = [string] $Configuration.LocalWpPath
		RemoteUrl        = [string] $Configuration.RemoteUrl
		LocalUrl         = [string] $Configuration.LocalUrl
		PullPaths        = $applyPullPaths
		ExpectedTablePrefix = [string] $Configuration.ExpectedDbTablePrefix
		ExpectedTableCount  = [int] $Configuration.ExpectedPullDbTableCount
		MinimumTableCount   = [int] $Configuration.ExpectedPullDbTableCount
	}
}

function Assert-ApplyPullWorkspace {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $FilesRoot,
		[Parameter(Mandatory = $true)] [string[]] $PullPaths,
		[string[]] $ExcludedPaths = @()
	)

	if (-not (Test-Path -LiteralPath $FilesRoot -PathType Container)) {
		throw "Pulled files root was not found: $FilesRoot"
	}
	$root = [IO.Path]::GetFullPath($FilesRoot).TrimEnd('\', '/')
	$rootItem = Get-Item -LiteralPath $FilesRoot -Force
	if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
		throw 'Pulled files root must not be a reparse point.'
	}
	foreach ($relative in $PullPaths) {
		if (-not (Test-PullPathAllowed $relative -ExcludedPaths $ExcludedPaths)) {
			throw "Pulled path is not allowed: $relative"
		}
		$candidate = [IO.Path]::GetFullPath((Join-Path $root $relative))
		if (-not $candidate.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
			throw "Pulled path escaped the files root: $relative"
		}
		if (-not (Test-Path -LiteralPath $candidate)) {
			throw "Pulled path is missing from the verified workspace: $relative"
		}
		$items = @(Get-Item -LiteralPath $candidate -Force) + @(Get-ChildItem -LiteralPath $candidate -Force -Recurse -ErrorAction Stop)
		foreach ($item in $items) {
			if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
				throw "Pulled workspace contains a reparse point: $($item.FullName)"
			}
		}
	}
}

function Get-ApplyPullSummaryLines {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [object] $Plan)

	return @(
		'Mode                : apply-pull',
		"Dry run             : $($Plan.IsDryRun)",
		"Site ID             : $($Plan.SiteId)",
		"Workspace           : $($Plan.Workspace)",
		"Manifest            : $($Plan.ManifestPath)",
		"Database SQL        : $($Plan.DatabaseSql)",
		"Target database     : $($Plan.WorkingDatabase) (will be replaced after backup in the one working local WordPress copy)",
		"Local URL mapping   : $($Plan.RemoteUrl) -> $($Plan.LocalUrl)",
		"Working files       : $($Plan.PullPaths -join ', ') (replaced only after local backup and explicit -Confirm)"
	)
}

function Get-DeployConfigurationErrors {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[object] $Configuration
	)

	$errors = New-Object 'System.Collections.Generic.List[string]'
	if ($Configuration -isnot [System.Collections.IDictionary]) {
		Add-ValidationError $errors 'DeployConfig must be a hashtable or another IDictionary.'
		return $errors.ToArray()
	}

	$requiredStringKeys = @(
		'SiteId',
		'CodeRepositoryPath',
		'WorkRoot',
		'Environment',
		'LocalWpPath',
		'LocalUrl',
		'LocalUploadsPath',
		'LocalDbName',
		'LocalDbUser',
		'LocalDbHost',
		'MysqldumpPath',
		'GitPath',
		'SshUser',
		'SshHost',
		'RemoteUrl',
		'RemoteWpPath',
		'RemoteRepoPath',
		'RemoteRunnerPath',
		'RemoteTmpPath',
		'RemoteBackups',
		'RemoteGitSshKey',
		'RemotePhpPath',
		'RemoteWpCliPath',
		'ExpectedRemoteDomain',
		'ExpectedRemoteWpPath',
		'ExpectedRemoteDbName',
		'ExpectedDbTablePrefix'
	)
	$optionalKeys = @('LocalDbPassword', 'SshKeyPath', 'DisplayName', 'GitRemoteName', 'GitBranch', 'ExpectedWordPressCoreVersion', 'CorePolicy')
	$optionalBooleanKeys = @('UseLegacyScp')
	$otherRequiredKeys = @('SshPort', 'KeepBackups', 'ExpectedDbTableCount', 'MinimumLocalFreeSpaceMB', 'MinimumRemoteFreeSpaceMB', 'SyncPaths')
	$optionalPathKeys = @('FullSyncPaths', 'ProtectedSyncPaths')
	# Pull keys are optional so that a push-only configuration stays valid unchanged.
	# Add-PullConfigurationErrors enforces the full schema once PullEnabled is true.
	$pullKeys = @(
		'PullEnabled',
		'AllowProductionPull',
		'LocalBackupDirectory',
		'AllowedPullPaths',
		'FullPullPaths',
		'ExcludedPullPaths',
		'RequirePullConfirmation',
		'AllowDestructiveLocalReplace',
		'ExpectedPullDbTableCount',
		'KeepLocalBackups',
		'KeepBackupDays',
		'MaxBackupSizeMB',
		'PullContentPaths',
		'PullMediaPaths',
		'LocalPhpPath',
		'LocalWpCliPath',
		'MysqlPath'
	)
	$allowedKeys = $requiredStringKeys + $optionalKeys + $optionalBooleanKeys + $otherRequiredKeys + $optionalPathKeys + $pullKeys

	foreach ($key in $Configuration.Keys) {
		if ([string] $key -notin $allowedKeys) {
			Add-ValidationError $errors "Unknown configuration key: $key"
		}
	}

	foreach ($key in $requiredStringKeys) {
		if (-not $Configuration.Contains($key)) {
			Add-ValidationError $errors "Missing configuration value: $key"
			continue
		}
		if ($Configuration[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Configuration[$key])) {
			Add-ValidationError $errors "Configuration value must be a non-empty string: $key"
		}
	}

	foreach ($key in $otherRequiredKeys) {
		if (-not $Configuration.Contains($key)) {
			Add-ValidationError $errors "Missing configuration value: $key"
		}
	}
	foreach ($key in $optionalPathKeys) {
		if ($Configuration.Contains($key) -and $Configuration[$key] -isnot [Array]) {
			Add-ValidationError $errors "$key must be an array of repository-relative paths."
		}
	}
	foreach ($key in $optionalKeys) {
		if ($Configuration.Contains($key) -and $null -ne $Configuration[$key] -and $Configuration[$key] -isnot [string]) {
			Add-ValidationError $errors "Optional configuration value must be a string: $key"
		}
	}
	foreach ($key in $optionalBooleanKeys) {
		if ($Configuration.Contains($key) -and $Configuration[$key] -isnot [bool]) {
			Add-ValidationError $errors "$key must be a boolean."
		}
	}

	if ($errors.Count -gt 0) {
		return $errors.ToArray()
	}

	if ($Configuration.Environment -notin @('development', 'staging', 'production')) {
		Add-ValidationError $errors 'Environment must be development, staging, or production.'
	}

	foreach ($key in @('LocalUrl', 'RemoteUrl')) {
		if (-not (Test-HttpUrl $Configuration[$key])) {
			Add-ValidationError $errors "$key must be an absolute HTTP or HTTPS URL."
		}
	}

	if (Test-HttpUrl $Configuration.RemoteUrl) {
		$remoteUri = [Uri] $Configuration.RemoteUrl
		if ($remoteUri.Host -ine $Configuration.ExpectedRemoteDomain) {
			Add-ValidationError $errors 'RemoteUrl host does not match ExpectedRemoteDomain.'
		}
	}

	if ($Configuration.ExpectedRemoteDomain -notmatch '^[A-Za-z0-9.-]+$') {
		Add-ValidationError $errors 'ExpectedRemoteDomain must contain only a DNS host name.'
	}
	if ($Configuration.SshHost -notmatch '^[A-Za-z0-9.-]+$') {
		Add-ValidationError $errors 'SshHost must contain only a DNS host name or IPv4 address.'
	}
	if ($Configuration.SshUser -notmatch '^[A-Za-z0-9._-]+$') {
		Add-ValidationError $errors 'SshUser contains unsupported characters.'
	}
	if ($Configuration.LocalDbName -notmatch '^[A-Za-z0-9_]+$') {
		Add-ValidationError $errors 'LocalDbName contains unsupported characters.'
	}
	if ($Configuration.ExpectedRemoteDbName -notmatch '^[A-Za-z0-9_]+$') {
		Add-ValidationError $errors 'ExpectedRemoteDbName contains unsupported characters.'
	}
	if ($Configuration.ExpectedDbTablePrefix -notmatch '^[A-Za-z0-9_]+$') {
		Add-ValidationError $errors 'ExpectedDbTablePrefix contains unsupported characters.'
	}
	if ($Configuration.SiteId -notmatch '^[a-z0-9][a-z0-9-]{0,62}$') {
		Add-ValidationError $errors 'SiteId must be a unique lowercase kebab-case identifier.'
	}
	foreach ($key in @('CodeRepositoryPath', 'WorkRoot')) {
		if (-not [IO.Path]::IsPathRooted($Configuration[$key])) {
			Add-ValidationError $errors "$key must be an absolute local path."
		}
	}
	if ([IO.Path]::IsPathRooted($Configuration.CodeRepositoryPath) -and [IO.Path]::IsPathRooted($Configuration.WorkRoot)) {
		$codeRoot = ([IO.Path]::GetFullPath($Configuration.CodeRepositoryPath)).TrimEnd('\', '/') + '\'
		$workRoot = ([IO.Path]::GetFullPath($Configuration.WorkRoot)).TrimEnd('\', '/') + '\'
		if ($workRoot.StartsWith($codeRoot, [StringComparison]::OrdinalIgnoreCase) -or $codeRoot.StartsWith($workRoot, [StringComparison]::OrdinalIgnoreCase)) {
			Add-ValidationError $errors 'WorkRoot and CodeRepositoryPath must be separate roots.'
		}
	}

	foreach ($key in @('RemoteWpPath', 'RemoteRepoPath', 'RemoteRunnerPath', 'RemoteTmpPath', 'RemoteBackups', 'RemoteGitSshKey', 'RemotePhpPath', 'RemoteWpCliPath', 'ExpectedRemoteWpPath')) {
		if (-not (Test-RemotePath $Configuration[$key])) {
			Add-ValidationError $errors "$key must be a non-root absolute POSIX path without dot segments."
		}
		if ([string] $Configuration[$key] -match '/$') {
			Add-ValidationError $errors "$key must not end with '/'."
		}
		if (-not (Test-WrapperSafeValue ([string] $Configuration[$key]))) {
			Add-ValidationError $errors "$key contains characters unsupported by the forced-command wrapper."
		}
	}
	foreach ($key in @('LocalUrl', 'RemoteUrl', 'ExpectedRemoteDomain', 'ExpectedRemoteDbName', 'ExpectedDbTablePrefix')) {
		if (-not (Test-WrapperSafeValue ([string] $Configuration[$key]))) {
			Add-ValidationError $errors "$key contains characters unsupported by the forced-command wrapper."
		}
	}
	foreach ($key in @('RemoteRunnerPath', 'RemoteGitSshKey', 'RemotePhpPath', 'RemoteWpCliPath')) {
		if ($Configuration[$key] -notmatch '^/[A-Za-z0-9._/-]+$') {
			Add-ValidationError $errors "$key contains characters that are unsafe in a remote command."
		}
	}
	if ($Configuration.RemoteWpPath -ne $Configuration.ExpectedRemoteWpPath) {
		Add-ValidationError $errors 'RemoteWpPath does not match ExpectedRemoteWpPath.'
	}

	foreach ($key in @('LocalWpPath', 'LocalUploadsPath', 'MysqldumpPath', 'GitPath', 'CodeRepositoryPath', 'WorkRoot')) {
		if (-not [IO.Path]::IsPathRooted($Configuration[$key])) {
			Add-ValidationError $errors "$key must be an absolute local path."
		}
	}
	if ($Configuration.SshKeyPath -and -not [IO.Path]::IsPathRooted($Configuration.SshKeyPath)) {
		Add-ValidationError $errors 'SshKeyPath must be an absolute local path when configured.'
	}

	$remotePaths = @(
		$Configuration.RemoteWpPath.TrimEnd('/'),
		$Configuration.RemoteRepoPath.TrimEnd('/'),
		$Configuration.RemoteTmpPath.TrimEnd('/'),
		$Configuration.RemoteBackups.TrimEnd('/')
	)
	if (@($remotePaths | Select-Object -Unique).Count -ne $remotePaths.Count) {
		Add-ValidationError $errors 'RemoteWpPath, RemoteRepoPath, RemoteTmpPath, and RemoteBackups must be different paths.'
	}
	$wpPrefix = $Configuration.RemoteWpPath.TrimEnd('/') + '/'
	foreach ($key in @('RemoteRepoPath', 'RemoteTmpPath', 'RemoteBackups')) {
		if ($Configuration[$key].StartsWith($wpPrefix, [StringComparison]::Ordinal)) {
			Add-ValidationError $errors "$key must not be inside RemoteWpPath."
		}
	}
	$repoPrefix = $Configuration.RemoteRepoPath.TrimEnd('/') + '/'
	if ($Configuration.RemoteRunnerPath.StartsWith($wpPrefix, [StringComparison]::Ordinal) -or
		$Configuration.RemoteRunnerPath.StartsWith($repoPrefix, [StringComparison]::Ordinal)) {
		Add-ValidationError $errors 'RemoteRunnerPath must be outside RemoteWpPath and RemoteRepoPath.'
	}

	if ($Configuration.SshPort -isnot [int] -or $Configuration.SshPort -lt 1 -or $Configuration.SshPort -gt 65535) {
		Add-ValidationError $errors 'SshPort must be an integer from 1 to 65535.'
	}
	if ($Configuration.KeepBackups -isnot [int] -or $Configuration.KeepBackups -lt 1 -or $Configuration.KeepBackups -gt 1000) {
		Add-ValidationError $errors 'KeepBackups must be an integer from 1 to 1000.'
	}
	foreach ($key in @('KeepLocalBackups', 'KeepBackupDays', 'MaxBackupSizeMB')) {
		if ($Configuration.Contains($key) -and ($Configuration[$key] -isnot [int] -or $Configuration[$key] -lt 1 -or $Configuration[$key] -gt 1048576)) {
			Add-ValidationError $errors "$key must be an integer from 1 to 1048576."
		}
	}
	if ($Configuration.ExpectedDbTableCount -isnot [int] -or $Configuration.ExpectedDbTableCount -lt 1) {
		Add-ValidationError $errors 'ExpectedDbTableCount must be an integer greater than or equal to 1.'
	}
	foreach ($key in @('MinimumLocalFreeSpaceMB', 'MinimumRemoteFreeSpaceMB')) {
		if ($Configuration[$key] -isnot [int] -or $Configuration[$key] -lt 1 -or $Configuration[$key] -gt 1048576) {
			Add-ValidationError $errors "$key must be an integer from 1 to 1048576."
		}
	}

	if ($Configuration.SyncPaths -isnot [Array]) {
		Add-ValidationError $errors 'SyncPaths must be a non-empty array of repository-relative paths.'
	} else {
		$syncPaths = @($Configuration.SyncPaths)
		if ($syncPaths.Count -eq 0) {
			Add-ValidationError $errors 'SyncPaths must contain at least one path.'
		}
		$seen = @{}
		foreach ($path in $syncPaths) {
			if ($path -isnot [string] -or -not (Test-SyncPath $path) -or -not (Test-WrapperSafeValue ([string] $path))) {
				Add-ValidationError $errors "Unsafe SyncPaths value: $path"
				continue
			}
			$key = $path.ToLowerInvariant()
			if ($seen.ContainsKey($key)) {
				Add-ValidationError $errors "Duplicate SyncPaths value: $path"
			}
			$seen[$key] = $true
		}
	}
	foreach ($key in $optionalPathKeys) {
		if (-not $Configuration.Contains($key) -or $Configuration[$key] -isnot [Array]) { continue }
		$seen = @{}
		foreach ($path in @($Configuration[$key])) {
			$allowProtected = $key -eq 'ProtectedSyncPaths'
			if ($path -isnot [string] -or ($allowProtected -and $path.EndsWith('/')) -or ($allowProtected -and $path.EndsWith('\')) -or -not (Test-SyncPath $path -AllowProtected:$allowProtected) -or -not (Test-WrapperSafeValue ([string] $path))) {
				Add-ValidationError $errors "Unsafe $key value: $path"
				continue
			}
			$normalized = $path.ToLowerInvariant()
			if ($seen.ContainsKey($normalized)) { Add-ValidationError $errors "Duplicate $key value: $path" }
			$seen[$normalized] = $true
		}
	}
	if ($Configuration.Contains('ProtectedSyncPaths') -and $Configuration.ProtectedSyncPaths -is [Array]) {
		$protected = @($Configuration.ProtectedSyncPaths | ForEach-Object { ([string] $_).ToLowerInvariant().TrimEnd('/', '\') })
		foreach ($syncKey in @('SyncPaths', 'FullSyncPaths')) {
			if (-not $Configuration.Contains($syncKey) -or $Configuration[$syncKey] -isnot [Array]) { continue }
			foreach ($path in @($Configuration[$syncKey])) {
				$normalizedPath = ([string] $path).ToLowerInvariant().TrimEnd('/', '\')
				foreach ($protectedPath in $protected) {
					if ($normalizedPath -eq $protectedPath -or
						$normalizedPath.StartsWith($protectedPath + '/') -or
						$protectedPath.StartsWith($normalizedPath + '/')) {
						Add-ValidationError $errors "$syncKey overlaps ProtectedSyncPaths: $path"
					}
				}
			}
		}
	}

	Add-PullConfigurationErrors $errors $Configuration

	return $errors.ToArray()
}

function Assert-DeployConfiguration {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[object] $Configuration
	)

	$errors = @(Get-DeployConfigurationErrors -Configuration $Configuration)
	if ($errors.Count -gt 0) {
		$message = "Invalid deploy.config.ps1:`n - " + ($errors -join "`n - ")
		throw $message
	}
}

function Assert-DeployModeAllowed {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[ValidateSet('development', 'staging', 'production')]
		[string] $Environment,

		[Parameter(Mandatory = $true)]
		[ValidateSet('full', 'code', 'db', 'pull-db', 'pull-files', 'pull-full', 'apply-pull')]
		[string] $Mode,

		[switch] $AllowProductionPull
	)

	if ($Environment -eq 'production' -and $Mode -in (Get-PullModeNames) -and -not $AllowProductionPull) {
		throw "Mode '$Mode' requires the explicit -AllowProductionPull switch for production read-only pull."
	}
	if ($Environment -eq 'production' -and $Mode -eq 'apply-pull' -and -not $AllowProductionPull) {
		throw "Mode '$Mode' requires the explicit -AllowProductionPull switch for a local production pull apply."
	}
	if ($Environment -eq 'production' -and $Mode -ne 'code' -and $Mode -notin (Get-PullModeNames) -and $Mode -ne 'apply-pull') {
		throw "Mode '$Mode' is forbidden for production. Use code mode."
	}
}

Export-ModuleMember -Function Get-DeployConfigurationErrors, Assert-DeployConfiguration, Assert-DeployModeAllowed, ConvertTo-ShSingleQuotedString, New-RemoteDeployCommand, Invoke-CheckedCommand, Invoke-CommandOutput, ConvertTo-WindowsProcessArgument, Invoke-NativeProcessWithFileInput, Restore-FileSwaps, Get-DirectoryContentSizeBytes, Assert-AvailableDiskSpace, Assert-SqlDumpFile, Assert-SqlDumpTablePrefix, Normalize-SqlDumpTablePrefix, Assert-ZipArchiveFile, Get-PullModeNames, Get-PullDenyList, Test-PullPathAllowed, Assert-PullAllowed, Assert-GzipFile, Expand-GzipFile, Get-SqlDumpTableNames, Assert-SqlDumpTableSet, Get-TarEntryList, Assert-PullArchiveEntries, New-RemotePullCommand, New-PullPlan, Get-PullSummaryLines, New-ApplyPullPlan, Assert-ApplyPullWorkspace, Get-ApplyPullSummaryLines, Expand-TarArchive, Get-ProfileSiteId, Get-ProfileIsolationErrors, Assert-ProfileIsolation, Get-PullPathSelection, Get-FileSha256Hex, Get-DirectorySha256Hex, Get-LocalBackupRetentionPlan, New-PullManifest, Assert-PullManifest
