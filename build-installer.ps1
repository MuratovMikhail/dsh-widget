# Собирает DSHWidget-Setup-<версия>.exe через Inno Setup.
# Компилятор нужен только на машине сборки: winget install -e --id JRSoftware.InnoSetup
[CmdletBinding()]
param([string]$Version = '')

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$issPath = Join-Path $scriptDir 'installer.iss'
$distDir = Join-Path $scriptDir 'dist'

if (-not (Test-Path -LiteralPath $issPath)) { throw "Нет installer.iss рядом: $issPath" }

$required = @(
    'widget-ui.ps1',
    'widget-engine.js',
    'start-widget.vbs',
    'assets\DSHWidget.ico',
    'assets\DSHWidget-Tray.ico',
    'tools\stop-widget.ps1'
)
foreach ($rel in $required) {
    $full = Join-Path $scriptDir $rel
    if (-not (Test-Path -LiteralPath $full)) { throw "Не найден обязательный файл: $rel" }
}

function Find-Iscc {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe'
    )
    if ($env:ISCC) { $candidates = @($env:ISCC) + $candidates }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

$iscc = Find-Iscc
if (-not $iscc) {
    Write-Output 'Компилятор Inno Setup не найден.'
    Write-Output ''
    Write-Output 'Установите его (нужно только для сборки, не для работы виджета):'
    Write-Output '    winget install -e --id JRSoftware.InnoSetup'
    Write-Output 'или скачайте с https://jrsoftware.org/isdl.php'
    Write-Output ''
    Write-Output 'После установки запустите этот скрипт ещё раз.'
    exit 1
}

New-Item -ItemType Directory -Force -Path $distDir | Out-Null

$isccArgs = @('/Qp')
if ($Version) { $isccArgs += "/DAppVersion=$Version" }
$isccArgs += $issPath

Write-Output ('компилятор: ' + $iscc)
& $iscc @isccArgs
if ($LASTEXITCODE -ne 0) { throw "ISCC завершился с кодом $LASTEXITCODE" }

$exe = Get-ChildItem -Path $distDir -Filter 'DSHWidget-Setup-*.exe' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $exe) { throw 'Установщик не появился в dist\' }

$hash = (Get-FileHash -LiteralPath $exe.FullName -Algorithm SHA256).Hash
Write-Output ''
Write-Output ('готово: ' + $exe.FullName)
Write-Output ('размер: ' + [math]::Round($exe.Length / 1MB, 2) + ' МБ')
Write-Output ('SHA256: ' + $hash)
