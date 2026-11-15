# Запоминает выбранный в установщике режим запуска и задаёт согласованный авто-выход.
# Правило: режим обновляем всегда, а авто-выход — только когда режим меняется
# или в конфиге этого ключа ещё нет (чтобы не затирать ручную настройку при обновлении).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('plugin', 'startup', 'manual')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
$app = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $app 'config.json'

$current = $null
if (Test-Path -LiteralPath $configPath) {
    try { $current = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $current = $null }
}

# plugin — плагин гасит карточку сам, авто-выход только как страховка;
# startup/manual — карточка не должна исчезать сама.
$exitMin = if ($Mode -eq 'plugin') { 5 } else { 0 }

$modeChanged = $true
$hasExit = $false
$hasAutostart = $false
$wantAutostart = ($Mode -eq 'startup')
$currentAutostart = $false
if ($current) {
    $modeChanged = ([string]$current.launchMode -ne $Mode)
    $hasExit = ($null -ne $current.exitWhenDshClosedMin)
    $hasAutostart = ($null -ne $current.autostart)
    $currentAutostart = [bool]$current.autostart
    if (-not $modeChanged -and $hasExit -and $hasAutostart -and ($currentAutostart -eq $wantAutostart)) { exit 0 }
}

$config = [ordered]@{ }
if ($current) {
    foreach ($p in $current.PSObject.Properties) { $config[$p.Name] = $p.Value }
}
$config['launchMode'] = $Mode
if ($modeChanged -or -not $hasExit) { $config['exitWhenDshClosedMin'] = $exitMin }
$config['autostart'] = $wantAutostart

$json = $config | ConvertTo-Json
[System.IO.File]::WriteAllText($configPath, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
