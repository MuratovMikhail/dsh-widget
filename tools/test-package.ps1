[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Zip)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Zip)) { throw "Нет архива: $Zip" }

$temp = Join-Path $env:TEMP ('dsh-package-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fail = 0
try {
    Expand-Archive -LiteralPath $Zip -DestinationPath $temp -Force
    $root = Get-ChildItem -LiteralPath $temp -Directory | Select-Object -First 1
    if (-not $root) { throw 'Архив пуст' }
    $required = @(
        'widget-ui.ps1',
        'widget-engine.js',
        'VERSION',
        'tools\status.ps1',
        'tools\dsh-common.ps1',
        'tools\install-plugin.ps1',
        'tools\finish-plugin.ps1',
        'tools\cancel-pending-plugin.ps1',
        'tools\remove-plugin.ps1',
        'plugin\dsh-widget-bridge-1.0.1.tgz'
    )
    foreach ($rel in $required) {
        $path = Join-Path $root.FullName $rel
        if (Test-Path -LiteralPath $path) { Write-Output ('  OK   ' + $rel) }
        else { Write-Output ('  FAIL ' + $rel); $fail++ }
    }
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail -gt 0) { exit $fail }
Write-Output 'package: ok'
