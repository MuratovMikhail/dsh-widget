<#
    Сборка архива для передачи друзьям.

    В пакет попадает только код, README и синтетические скриншоты.
    config.json (позиция карточки, ключи), widget.ico, логи и тестовые каталоги
    не включаются — у получателя виджет создаст свой config.json при первом запуске.

    Использование:
        powershell -ExecutionPolicy Bypass -File .\release.ps1
        powershell -ExecutionPolicy Bypass -File .\release.ps1 -Version 1.0
#>
[CmdletBinding()]
param(
    [string]$Version = '1.0',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutDir) { $OutDir = $scriptDir }

# Белый список: всё, что реально нужно для работы виджета.
$files = @(
    'install.ps1',
    'start-widget.vbs',
    'widget-engine.js',
    'widget-ui.ps1',
    'assets\DSHWidget.ico',
    'assets\DSHWidget-Tray.ico',
    'assets\notify.wav',
    'locale\en.json',
    'locale\ru.json',
    'locale\zh-CN.json',
    'tools\restart-widget.ps1',
    'plugin\dsh-widget-bridge-1.0.0.tgz',
    'tools\install-plugin.ps1',
    'tools\remove-plugin.ps1',
    'README.md',
    'README.ru.md',
    'README.zh-CN.md',
    'LICENSE',
    'CHANGELOG.md',
    'CHANGELOG.ru.md',
    'tools\status.ps1'
)

$staging = Join-Path $OutDir ('.release-tmp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$root = Join-Path $staging 'dsh-widget'

try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    foreach ($rel in $files) {
        $src = Join-Path $scriptDir $rel
        if (-not (Test-Path -LiteralPath $src)) { throw "не найден файл для пакета: $rel" }
        $dst = Join-Path $root $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
    foreach ($lang in @('en', 'ru', 'zh-CN')) {
        $srcDocs = Join-Path $scriptDir ('docs\' + $lang)
        if (-not (Test-Path -LiteralPath $srcDocs)) { throw "не найден каталог превью: docs\$lang" }
        $dstDocs = Join-Path $root ('docs\' + $lang)
        New-Item -ItemType Directory -Force -Path $dstDocs | Out-Null
        Get-ChildItem -LiteralPath $srcDocs -File | Copy-Item -Destination $dstDocs -Force
    }

    # Страховка: личные данные не должны уехать в архив.
    # Публичная ссылка на GitHub-репозиторий — не личные данные, её не считаем.
    $leaks = @()
    foreach ($f in Get-ChildItem $root -Recurse -File -Include *.ps1, *.js, *.md, *.vbs) {
        $text = Get-Content -LiteralPath $f.FullName -Raw
        $scan = [regex]::Replace($text, 'https://github\.com/[A-Za-z0-9_.-]+/dsh-widget', '<public-repo>')
        foreach ($needle in @($env:USERNAME, $env:USERPROFILE)) {
            if ($needle -and $scan -like ('*' + $needle + '*')) {
                $leaks += ("{0}: встречается «{1}»" -f $f.Name, $needle)
            }
        }
    }
    if ($leaks.Count -gt 0) {
        throw ("в пакет попали личные данные:`n" + ($leaks -join "`n"))
    }

    $zip = Join-Path $OutDir ("dsh-widget-$Version.zip")
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path $root -DestinationPath $zip -CompressionLevel Optimal

    $size = [math]::Round((Get-Item -LiteralPath $zip).Length / 1KB, 1)
    Write-Output ("готово: " + $zip + " (" + $size + " КБ)")
    Write-Output ("файлов в пакете: " + (Get-ChildItem $root -Recurse -File).Count)
}
finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}
