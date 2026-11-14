<#
    Установка ярлыков для виджета DeepSeek Harness.

    install.ps1                 — ярлыки в меню «Пуск» и на рабочем столе
    install.ps1 -Autostart      — плюс автозапуск при входе в систему
    install.ps1 -Remove         — удалить ярлыки и автозапуск
#>
[CmdletBinding()]
param(
    [switch]$Autostart,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs = Join-Path $scriptDir 'start-widget.vbs'
$ico = Join-Path $scriptDir 'assets\DSHWidget.ico'

if (-not (Test-Path -LiteralPath $vbs)) { throw "Не найден start-widget.vbs в $scriptDir" }

$startMenu = [Environment]::GetFolderPath('Programs')
$desktop = [Environment]::GetFolderPath('Desktop')
$startup = [Environment]::GetFolderPath('Startup')

$startMenuLink = Join-Path $startMenu 'DeepSeek Harness Widget.lnk'
$desktopLink = Join-Path $desktop 'DeepSeek Harness Widget.lnk'
$startupLink = Join-Path $startup 'DeepSeek Harness Widget.lnk'



function New-Shortcut {
    param([string]$LinkPath)
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($LinkPath)
    $sc.TargetPath = 'wscript.exe'
    $sc.Arguments = '"' + $vbs + '"'
    $sc.WorkingDirectory = $scriptDir
    $sc.WindowStyle = 7
    $sc.Description = 'DSH Widget'
    if (Test-Path -LiteralPath $ico) { $sc.IconLocation = $ico + ',0' }
    $sc.Save()
}

if ($Remove) {
    foreach ($link in @($startMenuLink, $desktopLink, $startupLink)) {
        if (Test-Path -LiteralPath $link) {
            Remove-Item -LiteralPath $link -Force
            Write-Output ('удалён: ' + $link)
        }
    }
    Write-Output 'Готово. Сам виджет закройте через меню иконки в трее → «Выход».'
    return
}

# Иконки — фирменные, из assets. Если их нет, установка невозможна: лучше сказать прямо.
if (-not (Test-Path -LiteralPath $ico)) { throw "Не найден $ico" }
New-Shortcut -LinkPath $startMenuLink
New-Shortcut -LinkPath $desktopLink
Write-Output ('ярлык в «Пуск»: ' + $startMenuLink)
Write-Output ('ярлык на рабочем столе: ' + $desktopLink)

if ($Autostart) {
    New-Shortcut -LinkPath $startupLink
    Write-Output ('автозапуск: ' + $startupLink)
}

Write-Output 'Готово. Запустите виджет двойным кликом по ярлыку.'
