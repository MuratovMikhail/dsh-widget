# Ставит микроплагин dsh-widget-bridge в профиль DSH.
# Установщик вызывает этот скрипт при включённой задаче «запускать вместе с DSH».
#
# `dsh plugin add` сам добавляет бандл в dsh.profile.bundles, отдельная правка манифеста не нужна.
#
# Коды выхода:
#   0 — установлено или уже стоит
#   3 — не найден DSH, профиль или пакет
#   1 — ошибка установки
[CmdletBinding()]
param(
    [string]$Profile = 'desktop',
    [string]$Tgz = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
function Say([string]$text) { if (-not $Quiet) { Write-Output $text } }

$bundle = '@local/dsh-widget-bridge'

$dshHome = $env:DSH_HOME
if (-not $dshHome) { $dshHome = Join-Path $env:USERPROFILE '.dsh' }
$profileDir = Join-Path (Join-Path $dshHome 'profiles') $Profile
$manifest = Join-Path $profileDir 'package.json'

$desk = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'
$cli = Join-Path $desk 'resources\runtime\cli\bin\dsh.cmd'

if (-not (Test-Path -LiteralPath $profileDir)) {
    Say ('профиль не найден: ' + $profileDir + ' — откройте DeepSeek Harness один раз')
    exit 3
}
if (-not (Test-Path -LiteralPath $cli)) { Say ('не найден CLI десктопа: ' + $cli); exit 3 }

if (-not $Tgz) { $Tgz = Join-Path (Split-Path -Parent $PSScriptRoot) 'plugin\dsh-widget-bridge-1.0.0.tgz' }
if (-not (Test-Path -LiteralPath $Tgz)) { Say ('не найден пакет плагина: ' + $Tgz); exit 3 }

# Уже включён — ничего не делаем.
$data = $null
try { $data = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if ($data -and $data.dsh -and $data.dsh.profile -and (@($data.dsh.profile.bundles) -contains $bundle)) {
    Say 'плагин уже установлен'
    exit 0
}

Say ('ставлю пакет: ' + $Tgz)
$out = & cmd.exe /c "`"$cli`" plugin --profile $Profile add `"$Tgz`"" 2>&1
$code = $LASTEXITCODE
if ($code -ne 0) {
    Say ('не удалось установить плагин, код ' + $code)
    $out | Select-Object -Last 6 | ForEach-Object { Say ('  ' + $_) }
    exit 1
}

# Проверяем, что CLI действительно включил бандл.
$ok = $false
try {
    $data = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $ok = @($data.dsh.profile.bundles) -contains $bundle
} catch { }
if (-not $ok) {
    Say 'CLI не добавил бандл в профиль'
    exit 1
}

Say 'готово: виджет будет запускаться вместе с DSH'
exit 0
