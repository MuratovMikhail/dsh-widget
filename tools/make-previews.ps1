# Переснимает превью карточки для docs/<lang>/ по демо-состояниям.
# Запуск: powershell -ExecutionPolicy Bypass -File .\tools\make-previews.ps1 -Lang ru
[CmdletBinding()]
param(
    [string]$Root = '',
    [ValidateSet('ru', 'en', 'zh-CN')]
    [string]$Lang = 'ru',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$ui = Join-Path $Root 'widget-ui.ps1'
if (-not (Test-Path -LiteralPath $ui)) { throw "Не найден widget-ui.ps1: $ui" }
if (-not $OutDir) { $OutDir = Join-Path (Join-Path $Root 'docs') $Lang }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$cases = @(
    @{ Demo = 'working'; File = 'preview-working.png' },
    @{ Demo = 'done'; File = 'preview-done.png' },
    @{ Demo = 'error'; File = 'preview-error.png' },
    @{ Demo = 'waiting'; File = 'preview-waiting.png' },
    @{ Demo = 'approval'; File = 'preview-approval.png' },
    @{ Demo = 'subagents'; File = 'preview-subagents.png' },
    @{ Demo = 'list'; File = 'preview-list.png' },
    @{ Demo = 'many'; File = 'preview-many.png' },
    @{ Demo = 'list'; Theme = 'light'; File = 'preview-light.png' }
)

foreach ($c in $cases) {
    $args = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $ui, '-SelfTest', '-Demo', $c.Demo, '-DemoLang', $Lang)
    if ($c.Theme) { $args += @('-DemoTheme', $c.Theme) }
    & powershell.exe @args | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ("selftest завершился с кодом {0}: {1}" -f $LASTEXITCODE, $c.Demo) }
    $suffix = if ($c.Theme) { '-' + $c.Theme } else { '' }
    $src = Join-Path $Root ('selftest-' + $c.Demo + $suffix + '.png')
    if (-not (Test-Path -LiteralPath $src)) { throw "Нет снимка: $src" }
    Copy-Item -LiteralPath $src -Destination (Join-Path $OutDir $c.File) -Force
    Write-Output (Join-Path $OutDir $c.File)
}

# Окно настроек снимается отдельным режимом SelfTest.
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $ui -SelfTest -ShowSettings -DemoLang $Lang | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'не удалось снять окно настроек' }
Copy-Item -LiteralPath (Join-Path $Root 'selftest-settings.png') -Destination (Join-Path $OutDir 'preview-settings.png') -Force
Write-Output (Join-Path $OutDir 'preview-settings.png')


# Временные снимки в корне не нужны.
Get-ChildItem -LiteralPath $Root -Filter 'selftest-*.png' -File | Remove-Item -Force
Write-Output 'готово'
