# Полный цикл проверки установщика: тихая установка -> проверки -> тихое удаление -> проверки.
# Запускать на чистой машине или после ручного удаления старой версии.
[CmdletBinding()]
param(
    [string]$Exe,
    [switch]$KeepInstalled
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$fail = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Output ("  OK   " + $name) }
    else { Write-Output ("  FAIL " + $name + $(if ($detail) { ' — ' + $detail } else { '' })); $script:fail++ }
}

if (-not $Exe) {
    $candidate = Get-ChildItem -Path (Join-Path $root 'dist') -Filter 'DSHWidget-Setup-*.exe' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidate) { $Exe = $candidate.FullName }
}
if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) { throw 'Не найден установщик: соберите его через build-installer.ps1' }
Write-Output ('установщик: ' + $Exe)

$appDir = Join-Path $env:LOCALAPPDATA 'Programs\DSH Widget'
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'DSH Widget\DSH Widget.lnk'
$desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'DSH Widget.lnk'
$uninstKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{B7E1C0D4-5A62-4F0B-9A3E-2D7C6B1F0A55}_is1'

Write-Output ''
Write-Output 'УСТАНОВКА'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $Exe
$psi.Arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /TASKS="desktopicon"'
$psi.UseShellExecute = $false
$proc = [System.Diagnostics.Process]::Start($psi)
$finished = $proc.WaitForExit(180000)
Check ("установщик завершился с кодом " + $(if ($finished) { $proc.ExitCode } else { "таймаут" })) ($finished -and $proc.ExitCode -eq 0)
Start-Sleep -Seconds 3

Check 'каталог установки' (Test-Path -LiteralPath $appDir)
Check 'widget-ui.ps1' (Test-Path -LiteralPath (Join-Path $appDir 'widget-ui.ps1'))
Check 'widget-engine.js' (Test-Path -LiteralPath (Join-Path $appDir 'widget-engine.js'))
Check 'start-widget.vbs' (Test-Path -LiteralPath (Join-Path $appDir 'start-widget.vbs'))
Check 'assets\DSHWidget.ico' (Test-Path -LiteralPath (Join-Path $appDir 'assets\DSHWidget.ico'))
Check 'assets\DSHWidget-Tray.ico' (Test-Path -LiteralPath (Join-Path $appDir 'assets\DSHWidget-Tray.ico'))
Check 'tools\stop-widget.ps1' (Test-Path -LiteralPath (Join-Path $appDir 'tools\stop-widget.ps1'))
Check 'ярлык в «Пуск»' (Test-Path -LiteralPath $startMenu)
Check 'ярлык на рабочем столе' (Test-Path -LiteralPath $desktop)
Check 'запись в «Приложениях»' (Test-Path -LiteralPath $uninstKey)
Check 'деинсталлятор' (Test-Path -LiteralPath (Join-Path $appDir 'unins000.exe'))

if (Test-Path -LiteralPath $uninstKey) {
    $props = Get-ItemProperty -LiteralPath $uninstKey
    Check ('DisplayName = ' + $props.DisplayName) ($props.DisplayName -eq 'DSH Widget')
    Check ('DisplayVersion = ' + $props.DisplayVersion) ($props.DisplayVersion -eq '1.0.0')
    Check 'UninstallString заполнен' ([bool]$props.UninstallString)
    Check 'DisplayIcon указывает на иконочный файл' ([bool]($props.DisplayIcon -like '*DSHWidget*'))
}
if (Test-Path -LiteralPath $desktop) {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($desktop)
    Check 'ярлык ведёт на wscript.exe' ($lnk.TargetPath -like '*wscript.exe')
    Check 'в аргументах start-widget.vbs' ($lnk.Arguments -like '*start-widget.vbs*')
    Check 'рабочий каталог задан' ([bool]$lnk.WorkingDirectory)
}

if ($KeepInstalled) {
    Write-Output ''
    Write-Output 'оставлено установленным (-KeepInstalled)'
    exit 0
}

Write-Output ''
Write-Output 'УДАЛЕНИЕ'
$unins = Join-Path $appDir 'unins000.exe'
if (Test-Path -LiteralPath $unins) {
    $upsi = New-Object System.Diagnostics.ProcessStartInfo
    $upsi.FileName = $unins
    $upsi.Arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    $upsi.UseShellExecute = $false
    $uproc = [System.Diagnostics.Process]::Start($upsi)
    [void]$uproc.WaitForExit(180000)
}
Start-Sleep -Seconds 3

# В тихом режиме вопрос про настройки подавляется; остатки config.json допустимы, если выбран «оставить».
Check 'ярлык в «Пуск» удалён' (-not (Test-Path -LiteralPath $startMenu))
Check 'ярлык на рабочем столе удалён' (-not (Test-Path -LiteralPath $desktop))
Check 'запись в «Приложениях» удалена' (-not (Test-Path -LiteralPath $uninstKey))
Check 'файлы удалены' (-not (Test-Path -LiteralPath (Join-Path $appDir 'widget-ui.ps1')))
Check 'деинсталлятор удалён' (-not (Test-Path -LiteralPath $unins))

Write-Output ''
if ($fail -eq 0) { Write-Output 'ИТОГ: все проверки пройдены' } else { Write-Output ("ИТОГ: ошибок " + $fail) }
exit $fail
