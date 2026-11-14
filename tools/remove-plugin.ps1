# Убирает микроплагин dsh-widget-bridge из профиля DSH.
# Коды выхода: 0 — удалено или не было, 3 — нет профиля, 1 — ошибка.
[CmdletBinding()]
param(
    [string]$Profile = 'desktop',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
function Say([string]$text) { if (-not $Quiet) { Write-Output $text } }

$bundle = '@local/dsh-widget-bridge'
$dshHome = $env:DSH_HOME
if (-not $dshHome) { $dshHome = Join-Path $env:USERPROFILE '.dsh' }
$profileDir = Join-Path (Join-Path $dshHome 'profiles') $Profile
$manifest = Join-Path $profileDir 'package.json'
$cli = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd'

if (-not (Test-Path -LiteralPath $manifest)) { Say 'профиль не найден'; exit 0 }

$data = $null
try { $data = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
$installed = $false
if ($data -and $data.dsh -and $data.dsh.profile) {
    $installed = @($data.dsh.profile.bundles) -contains $bundle
}
if (-not $installed) { Say 'плагин не установлен'; exit 0 }

if (-not (Test-Path -LiteralPath $cli)) { Say ('не найден CLI десктопа: ' + $cli); exit 3 }

$out = & cmd.exe /c "`"$cli`" plugin --profile $Profile remove $bundle" 2>&1
$code = $LASTEXITCODE
if ($code -ne 0) {
    Say ('не удалось удалить плагин, код ' + $code)
    $out | Select-Object -Last 6 | ForEach-Object { Say ('  ' + $_) }
    exit 1
}

Say 'плагин удалён'
exit 0
