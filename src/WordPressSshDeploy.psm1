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

function Test-UploadsManifestPath {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $Path)

	if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path)) { return $false }
	if ($Path.Contains('\') -or $Path.Contains("`t") -or $Path.Contains("`r") -or $Path.Contains("`n")) { return $false }
	if ($Path -match '(^|/)\.\.?(/|$)' -or $Path -match '(^|/)\.git(/|$)') { return $false }
	return $true
}

function Get-UploadsManifest {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
		throw "Uploads directory not found: $Path"
	}
	$root = (Get-Item -LiteralPath $Path -Force).FullName.TrimEnd('\')
	$items = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction Stop)
	foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)) {
		if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
			throw "Uploads tree contains a symbolic link or reparse point: $($item.FullName)"
		}
	}
	$result = foreach ($item in $items) {
		$relative = $item.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/')
		if (-not (Test-UploadsManifestPath $relative)) { throw "Unsafe uploads manifest path: $relative" }
		$hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
		[pscustomobject]@{ Path = $relative; Size = [long]$item.Length; Sha256 = $hash }
	}
	return @($result | Sort-Object -Property Path)
}

function Get-DeploymentSourceManifest {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $RootPath,
		[Parameter(Mandatory = $true)] [string[]] $RelativePaths
	)

	$root = (Get-Item -LiteralPath $RootPath -Force).FullName.TrimEnd('\')
	$entries = @{}
	foreach ($relativeRoot in $RelativePaths) {
		$normalizedRoot = ([string]$relativeRoot).Replace('\', '/')
		if (-not (Test-UploadsManifestPath $normalizedRoot)) { throw "Unsafe deployment source path: $normalizedRoot" }
		$source = Join-Path $root ($normalizedRoot -replace '/', '\')
		if (-not (Test-Path -LiteralPath $source)) { throw "Deployment source path not found: $normalizedRoot" }
		$item = Get-Item -LiteralPath $source -Force
		if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Deployment source path is a symbolic link: $normalizedRoot" }
		if ($item.PSIsContainer) {
			foreach ($entry in @(Get-UploadsManifest $source)) {
				$path = "$normalizedRoot/$($entry.Path)"
				if ($entries.ContainsKey($path)) { throw "Duplicate deployment source path: $path" }
				$entries[$path] = [pscustomobject]@{ Path = $path; Size = [long]$entry.Size; Sha256 = $entry.Sha256 }
			}
		} else {
			$hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
			$entries[$normalizedRoot] = [pscustomobject]@{ Path = $normalizedRoot; Size = [long]$item.Length; Sha256 = $hash }
		}
	}
	return @($entries.Values | Sort-Object Path)
}

function Write-UploadsManifest {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [object[]] $Manifest,
		[Parameter(Mandatory = $true)] [string] $Path
	)

	$lines = New-Object System.Collections.Generic.List[string]
	$previous = $null
	foreach ($entry in @($Manifest | Sort-Object -Property Path)) {
		if ($entry.Path -isnot [string] -or -not (Test-UploadsManifestPath $entry.Path)) { throw "Unsafe uploads manifest path: $($entry.Path)" }
		if ($null -ne $previous -and [string]::CompareOrdinal($previous, $entry.Path) -ge 0) { throw "Duplicate or unsorted uploads manifest path: $($entry.Path)" }
		if ([long]$entry.Size -lt 0 -or $entry.Sha256 -notmatch '^[0-9a-fA-F]{64}$') { throw "Invalid uploads manifest entry: $($entry.Path)" }
		$lines.Add(('{0}{3}{1}{3}{2}' -f $entry.Sha256.ToLowerInvariant(), [long]$entry.Size, $entry.Path, [char]9))
		$previous = $entry.Path
	}
	$parent = Split-Path -Parent $Path
	if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
	[IO.File]::WriteAllLines($Path, $lines, (New-Object Text.UTF8Encoding($false)))
}

function Read-UploadsManifest {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string] $Path)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Uploads manifest not found: $Path" }
	$previous = $null
	$result = foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
		if ([string]::IsNullOrWhiteSpace($line)) { continue }
		$parts = [regex]::Split([string]$line, "`t", 3)
		if ($parts.Count -ne 3 -or $parts[0] -notmatch '^[0-9a-fA-F]{64}$' -or $parts[1] -notmatch '^[0-9]+$' -or -not (Test-UploadsManifestPath $parts[2])) {
			throw "Invalid uploads manifest line: $line"
		}
		if ($null -ne $previous -and [string]::CompareOrdinal($previous, $parts[2]) -ge 0) { throw "Uploads manifest is not strictly sorted" }
		$previous = $parts[2]
		[pscustomobject]@{ Path = $parts[2]; Size = [long]$parts[1]; Sha256 = $parts[0].ToLowerInvariant() }
	}
	return @($result)
}

function Compare-UploadsManifests {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [object[]] $Baseline,
		[Parameter(Mandatory = $true)] [object[]] $Current
	)

	$old = @{}; foreach ($entry in @($Baseline)) { $old[$entry.Path] = $entry }
	$new = @{}; foreach ($entry in @($Current)) { $new[$entry.Path] = $entry }
	$added = @(); $changed = @(); $deleted = @()
	foreach ($path in @($new.Keys | Sort-Object)) {
		if (-not $old.ContainsKey($path)) { $added += $new[$path]; continue }
		if ($old[$path].Size -ne $new[$path].Size -or $old[$path].Sha256 -ne $new[$path].Sha256) { $changed += $new[$path] }
	}
	foreach ($path in @($old.Keys | Sort-Object)) { if (-not $new.ContainsKey($path)) { $deleted += $path } }
	[pscustomobject]@{ Added = @($added); Changed = @($changed); Deleted = @($deleted); UnchangedCount = $new.Count - $added.Count - $changed.Count }
}

function New-UploadsDeltaPackage {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [string] $SourceDirectory,
		[Parameter(Mandatory = $true)] [object[]] $CurrentManifest,
		[Parameter(Mandatory = $true)] [object[]] $BaselineManifest,
		[Parameter(Mandatory = $true)] [string] $DestinationZip
	)

	$comparison = Compare-UploadsManifests $BaselineManifest $CurrentManifest
	$stage = Join-Path ([IO.Path]::GetTempPath()) ('uploads-delta-' + [guid]::NewGuid().ToString('N'))
	try {
		$payload = Join-Path $stage 'payload'
		New-Item -ItemType Directory -Force -Path $payload | Out-Null
		foreach ($entry in @($comparison.Added + $comparison.Changed)) {
			$source = Join-Path $SourceDirectory ($entry.Path -replace '/', '\')
			if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Uploads source file not found: $($entry.Path)" }
			$item = Get-Item -LiteralPath $source -Force
			if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Uploads source file is a symbolic link: $($entry.Path)" }
			$destination = Join-Path $payload ($entry.Path -replace '/', '\')
			New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
			Copy-Item -LiteralPath $source -Destination $destination -Force
		}
		Write-UploadsManifest $CurrentManifest (Join-Path $stage 'manifest.tsv')
		[IO.File]::WriteAllLines((Join-Path $stage 'delete.list'), @($comparison.Deleted), (New-Object Text.UTF8Encoding($false)))
		if (Test-Path -LiteralPath $DestinationZip) { Remove-Item -LiteralPath $DestinationZip -Force }
		$destinationParent = Split-Path -Parent $DestinationZip
		if ($destinationParent) { New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null }
		Add-Type -AssemblyName System.IO.Compression.FileSystem
		[IO.Compression.ZipFile]::CreateFromDirectory($stage, $DestinationZip, [IO.Compression.CompressionLevel]::Optimal, $false)
		return [pscustomobject]@{ Package = $DestinationZip; Added = @($comparison.Added); Changed = @($comparison.Changed); Deleted = @($comparison.Deleted); TotalBytes = [long](Get-Item -LiteralPath $DestinationZip).Length }
	} finally {
		if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
	}
}

function Resolve-UploadsTransferPlan {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [ValidateSet('auto', 'full')] [string] $TransferMode,
		[Parameter(Mandatory = $true)] [string] $BaselinePath,
		[Parameter(Mandatory = $true)] [object[]] $CurrentManifest,
		[switch] $ConfirmDeletes,
		[switch] $ConfirmFullSnapshot
	)

	if ($TransferMode -eq 'full') {
		if (-not $ConfirmFullSnapshot) {
			throw 'Uploads full snapshot stopped: explicit -ConfirmUploadsFullSnapshot is required because production-only files may be replaced.'
		}
		return [pscustomobject]@{ UseDelta = $false; TransferKind = 'full'; Baseline = @(); Comparison = $null }
	}

	if (-not (Test-Path -LiteralPath $BaselinePath -PathType Leaf)) {
		throw 'Uploads delta preflight stopped: baseline manifest is missing. Review the remote state and choose an explicit full snapshot only after approval.'
	}
	try {
		$baseline = @(Read-UploadsManifest $BaselinePath)
		$comparison = Compare-UploadsManifests $baseline $CurrentManifest
		if ($comparison.Deleted.Count -gt 0 -and -not $ConfirmDeletes) {
			$deletedPaths = @($comparison.Deleted) -join ', '
			throw ("Uploads deploy stopped: {0} local file(s) would be removed from production: {1}. Rerun with -ConfirmUploadsDeletes after reviewing the exact delete list." -f $comparison.Deleted.Count, $deletedPaths)
		}
		return [pscustomobject]@{ UseDelta = $true; TransferKind = 'delta'; Baseline = $baseline; Comparison = $comparison }
	} catch {
		if ($_.Exception.Message -like 'Uploads deploy stopped:*') { throw }
		throw "Uploads delta preflight stopped: $($_.Exception.Message). Review the baseline and choose an explicit full snapshot only after approval."
	}
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

function Normalize-DeployComponentSelection {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string[]] $Components)

	$knownComponents = @('code', 'db', 'uploads', 'plugins', 'mu-plugins')
	$seen = @{}
	foreach ($component in $Components) {
		$normalized = ([string] $component).Trim().ToLowerInvariant()
		if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized -notin $knownComponents) {
			throw "Unknown deploy component: $component"
		}
		if ($seen.ContainsKey($normalized)) {
			throw "Duplicate deploy component: $normalized"
		}
		$seen[$normalized] = $true
	}
	return @($knownComponents | Where-Object { $seen.ContainsKey($_) })
}

function Test-DeployComponentsRequireProductionFullOptIn {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)] [string[]] $Components)

	$selection = @(Normalize-DeployComponentSelection -Components $Components)
	return ($selection -contains 'db') -and (
		$selection -contains 'uploads' -or
		$selection -contains 'plugins' -or
		$selection -contains 'mu-plugins'
	)
}

function New-RemoteDeployCommand {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Configuration,
		[Parameter(Mandatory = $true)] [ValidateSet('preflight', 'full', 'code', 'db', 'code-db', 'uploads', 'plugins', 'mu-plugins', 'components')] [string] $DeployMode,
		[string] $SqlFile = '',
		[string] $UploadsFile = '',
		[string] $UploadsDeltaFile = '',
		[string] $UploadsManifestFile = '',
		[string[]] $Components = @()
	)

	$componentSelection = @()
	if ($DeployMode -eq 'components') {
		if ($Components.Count -eq 0) { throw 'Components mode requires at least one selected component.' }
		$componentSelection = @(Normalize-DeployComponentSelection -Components $Components)
	} elseif ($Components.Count -gt 0) {
		throw 'Explicit components can only be used with components mode.'
	}

	$allowProductionFull = $Configuration.Contains('AllowProductionFull') -and $Configuration.AllowProductionFull -is [bool] -and $Configuration.AllowProductionFull
	$requiresProductionFullOptIn = $DeployMode -eq 'full' -or ($DeployMode -eq 'components' -and (Test-DeployComponentsRequireProductionFullOptIn -Components $componentSelection))
	$productionFullOptIn = if ($Configuration.Environment -eq 'production' -and $requiresProductionFullOptIn -and $allowProductionFull) { '1' } else { '0' }
	$pluginPaths = if ($Configuration.Contains('PluginSyncPaths')) { @($Configuration.PluginSyncPaths) } else { @() }
	$muPluginPaths = if ($Configuration.Contains('MuPluginSyncPaths')) { @($Configuration.MuPluginSyncPaths) } else { @() }
	$effectiveModes = if ($Configuration.Contains('AllowedDeployModes')) {
		@($Configuration.AllowedDeployModes)
	} elseif ($Configuration.Environment -eq 'production') {
		if ($allowProductionFull) { @('preflight', 'code', 'full') } else { @('preflight', 'code') }
	} else {
		@('preflight', 'code', 'db', 'full')
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
		@('SYNC_PATHS', ($Configuration.SyncPaths -join ',')),
		@('PLUGIN_SYNC_PATHS', ($pluginPaths -join ',')),
		@('MU_PLUGIN_SYNC_PATHS', ($muPluginPaths -join ',')),
		@('ALLOWED_DEPLOY_MODES', ($effectiveModes -join ',')),
		@('DEPLOY_MODE', $DeployMode),
		@('PRODUCTION_FULL_OPT_IN', $productionFullOptIn),
		@('SQL_FILE', $SqlFile),
		@('UPLOADS_ZIP', $UploadsFile),
		@('UPLOADS_DELTA_ZIP', $UploadsDeltaFile),
		@('UPLOADS_MANIFEST_FILE', $UploadsManifestFile)
	)
	if ($DeployMode -eq 'components') {
		$assignments += ,@('DEPLOY_COMPONENTS', ($componentSelection -join ','))
	}

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

function Test-SyncPath {
	param([string] $Value)

	if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq '.') {
		return $false
	}
	if ([IO.Path]::IsPathRooted($Value) -or $Value -match '[\\:\r\n]') {
		return $false
	}
	if ($Value -match '(^|/)\.\.?(/|$)' -or $Value.EndsWith('/')) {
		return $false
	}
	if ($Value -match '(?i)^(\.git|\.deploy)(/|$)' -or $Value -match '(?i)^wp-config\.php$') {
		return $false
	}

	return $true
}

function Test-CodeSyncPath {
	param([string] $Value)

	return (Test-SyncPath $Value) -and
		$Value -match '(?i)^wp-content/themes/.+' -and
		$Value -notmatch '(?i)^wp-content/themes/divi(/|$)'
}

function Test-PluginSyncPath {
	param([string] $Value)

	return (Test-SyncPath $Value) -and $Value -match '(?i)^wp-content/plugins/.+'
}

function Test-MuPluginSyncPath {
	param([string] $Value)

	return (Test-SyncPath $Value) -and $Value -match '(?i)^wp-content/mu-plugins/.+'
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
		'ExpectedRemoteDbName'
	)
	$optionalKeys = @('LocalDbPassword', 'SshKeyPath')
	$optionalBooleanKeys = @('AllowProductionFull')
	$optionalArrayKeys = @('PluginSyncPaths', 'MuPluginSyncPaths', 'AllowedDeployModes')
	$otherRequiredKeys = @('SshPort', 'KeepBackups', 'MinimumLocalFreeSpaceMB', 'MinimumRemoteFreeSpaceMB', 'SyncPaths')
	$allowedKeys = $requiredStringKeys + $optionalKeys + $optionalBooleanKeys + $optionalArrayKeys + $otherRequiredKeys

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
	foreach ($key in $optionalKeys) {
		if ($Configuration.Contains($key) -and $null -ne $Configuration[$key] -and $Configuration[$key] -isnot [string]) {
			Add-ValidationError $errors "Optional configuration value must be a string: $key"
		}
	}
	if ($Configuration.Contains('AllowProductionFull') -and $Configuration.AllowProductionFull -isnot [bool]) {
		Add-ValidationError $errors 'AllowProductionFull must be a Boolean when configured.'
	}
	foreach ($key in $optionalArrayKeys) {
		if ($Configuration.Contains($key) -and $Configuration[$key] -isnot [Array]) {
			Add-ValidationError $errors "$key must be an array when configured."
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

	foreach ($key in @('RemoteWpPath', 'RemoteRepoPath', 'RemoteRunnerPath', 'RemoteTmpPath', 'RemoteBackups', 'RemoteGitSshKey', 'RemotePhpPath', 'RemoteWpCliPath', 'ExpectedRemoteWpPath')) {
		if (-not (Test-RemotePath $Configuration[$key])) {
			Add-ValidationError $errors "$key must be a non-root absolute POSIX path without dot segments."
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

	foreach ($key in @('LocalWpPath', 'LocalUploadsPath', 'MysqldumpPath', 'GitPath')) {
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
			if ($path -isnot [string] -or -not (Test-CodeSyncPath $path)) {
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
	$pluginPathCount = 0
	foreach ($key in @('PluginSyncPaths')) {
		if (-not $Configuration.Contains($key)) { continue }
		if ($Configuration[$key] -isnot [Array]) {
			Add-ValidationError $errors "$key must be an array of wp-content/plugins paths."
			continue
		}
		$seen = @{}
		foreach ($path in @($Configuration[$key])) {
			$pluginPathCount++
			if ($path -isnot [string] -or -not (Test-PluginSyncPath $path)) {
				Add-ValidationError $errors "Unsafe $key value: $path"
				continue
			}
			$normalized = $path.ToLowerInvariant()
			if ($seen.ContainsKey($normalized)) { Add-ValidationError $errors "Duplicate $key value: $path" }
			$seen[$normalized] = $true
		}
	}
	$muPluginPathCount = 0
	if ($Configuration.Contains('MuPluginSyncPaths')) {
		if ($Configuration.MuPluginSyncPaths -isnot [Array]) {
			Add-ValidationError $errors 'MuPluginSyncPaths must be an array of wp-content/mu-plugins paths.'
		} else {
			$seen = @{}
			foreach ($path in @($Configuration.MuPluginSyncPaths)) {
				$muPluginPathCount++
				if ($path -isnot [string] -or -not (Test-MuPluginSyncPath $path)) {
					Add-ValidationError $errors "Unsafe MuPluginSyncPaths value: $path"
					continue
				}
				$normalized = $path.ToLowerInvariant()
				if ($seen.ContainsKey($normalized)) { Add-ValidationError $errors "Duplicate MuPluginSyncPaths value: $path" }
				$seen[$normalized] = $true
			}
		}
	}
	if ($Configuration.Contains('AllowedDeployModes')) {
		$knownModes = @('code', 'db', 'code-db', 'uploads', 'plugins', 'mu-plugins', 'full', 'preflight', 'components')
		$seen = @{}
		foreach ($mode in @($Configuration.AllowedDeployModes)) {
			if ($mode -isnot [string] -or $mode -notin $knownModes) { Add-ValidationError $errors "Unknown AllowedDeployModes value: $mode"; continue }
			if ($seen.ContainsKey($mode)) { Add-ValidationError $errors "Duplicate AllowedDeployModes value: $mode" }
			$seen[$mode] = $true
		}
		if (-not $seen.ContainsKey('preflight')) { Add-ValidationError $errors 'AllowedDeployModes must include preflight.' }
		if ($seen.ContainsKey('plugins') -and $pluginPathCount -eq 0) { Add-ValidationError $errors 'PluginSyncPaths must contain at least one path when plugins mode is enabled.' }
		if ($seen.ContainsKey('mu-plugins') -and $muPluginPathCount -eq 0) { Add-ValidationError $errors 'MuPluginSyncPaths must contain at least one path when mu-plugins mode is enabled.' }
	}

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
		[ValidateSet('full', 'code', 'db', 'code-db', 'uploads', 'plugins', 'mu-plugins', 'components')]
		[string] $Mode,

		[object] $AllowProductionFull = $false,
		[object[]] $AllowedDeployModes = @()
	)

	if ($AllowProductionFull -isnot [bool]) {
		throw 'AllowProductionFull must be a Boolean.'
	}

	if ($Environment -eq 'production') {
		if ($Mode -eq 'full' -and -not $AllowProductionFull) {
			throw "Mode '$Mode' is forbidden for production until AllowProductionFull is explicitly enabled."
		}
	}
	if ($AllowedDeployModes.Count -gt 0) {
		if ($Mode -notin $AllowedDeployModes) { throw "Mode '$Mode' is not enabled by this profile." }
		return
	}
	if ($Environment -eq 'production' -and $Mode -eq 'db') {
		throw "Mode '$Mode' is forbidden for production. Use code mode or an explicitly enabled full mode."
	}
}

Export-ModuleMember -Function Get-DeployConfigurationErrors, Assert-DeployConfiguration, Assert-DeployModeAllowed, ConvertTo-ShSingleQuotedString, New-RemoteDeployCommand, Test-DeployComponentsRequireProductionFullOptIn, Invoke-CheckedCommand, Invoke-CommandOutput, Get-DirectoryContentSizeBytes, Get-UploadsManifest, Get-DeploymentSourceManifest, Write-UploadsManifest, Read-UploadsManifest, Compare-UploadsManifests, New-UploadsDeltaPackage, Resolve-UploadsTransferPlan, Assert-AvailableDiskSpace, Assert-SqlDumpFile, Assert-ZipArchiveFile
