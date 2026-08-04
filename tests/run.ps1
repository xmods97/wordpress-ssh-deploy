$ErrorActionPreference = 'Stop'

$pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
	throw 'Pester is required to run the test suite.'
}

Import-Module $pester.Path -Force
if ($pester.Version.Major -ge 5) {
	$result = Invoke-Pester -Path $PSScriptRoot -PassThru
} else {
	$result = Invoke-Pester -Script $PSScriptRoot -PassThru
}

if ($result.FailedCount -gt 0) {
	exit 1
}
