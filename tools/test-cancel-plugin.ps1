# Тесты отмены отложенной установки bridge.
# 1) Плагин ищется через общее обнаружение DSH (Get-DshHome): DSH_HOME, профиль
#    пользователя и нестандартная установка, известная только деинсталлятору.
#    Нечитаемый профиль — это ошибка отмены, а не «плагина нет».
# 2) Останавливаются только процессы скриптов из этой папки установки, вместе с деревом
#    (cmd.exe и потомки), но одноимённые скрипты из других каталогов и копий программы
#    остаются жить.
# Тест самодостаточен: реальный профиль DSH и установленный виджет не трогает.
[CmdletBinding()]
param(
    [string]$WorkRoot = (Join-Path $env:TEMP ('dsh-cancel-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))),
    [switch]$KeepWork
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$fail = 0
$oldDshHome = $env:DSH_HOME
$oldUserProfile = $env:USERPROFILE
$spawned = New-Object System.Collections.Generic.List[object]

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Output ('  OK   ' + $name) }
    else {
        Write-Output ('  FAIL ' + $name + $(if ($detail) { ' — ' + $detail } else { '' }))
        $script:fail++
    }
}

function Write-Utf8Bom([string]$path, [string]$text) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($true)))
}

function New-FakeApp([string]$dir) {
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'tools') | Out-Null
    Copy-Item -LiteralPath (Join-Path $scriptDir 'cancel-pending-plugin.ps1') -Destination (Join-Path $dir 'tools\cancel-pending-plugin.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $scriptDir 'dsh-common.ps1') -Destination (Join-Path $dir 'tools\dsh-common.ps1') -Force
    foreach ($name in @('finish-plugin.ps1', 'install-plugin.ps1', 'set-mode.ps1')) {
        Write-Utf8Bom (Join-Path $dir ('tools\' + $name)) "Start-Sleep -Seconds 120`r`n"
    }
}

function New-FakeDshHome([string]$path, [bool]$withBridge) {
    $profileDir = Join-Path $path 'profiles\desktop'
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    $bundles = @('@deepseek-ai/dsh-base')
    if ($withBridge) { $bundles += '@local/dsh-widget-bridge' }
    $obj = [ordered]@{ dsh = [ordered]@{ profile = [ordered]@{ bundles = @($bundles) } } }
    Write-Utf8Bom (Join-Path $profileDir 'package.json') ($obj | ConvertTo-Json -Depth 10)
}

function New-FakeUninstallEntry([string]$keyName, [string]$installLocation) {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $keyName
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    New-Item -Path $path -Force | Out-Null
    New-ItemProperty -Path $path -Name 'DisplayName' -Value 'DeepSeek Harness (тест)' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $path -Name 'InstallLocation' -Value $installLocation -PropertyType String -Force | Out-Null
    return $path
}

function New-LateInstallApp([string]$dir) {
    # Копия установки, чей finisher запускает cmd.exe, а тот ставит плагин с задержкой:
    # так воспроизводится гонка «cmd.exe пережил отмену».
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'tools') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'plugin') | Out-Null
    Copy-Item -LiteralPath (Join-Path $scriptDir 'cancel-pending-plugin.ps1') -Destination (Join-Path $dir 'tools\cancel-pending-plugin.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $scriptDir 'dsh-common.ps1') -Destination (Join-Path $dir 'tools\dsh-common.ps1') -Force
    New-SleepCmd (Join-Path $dir 'late-install.cmd') 'late-install.marker'
    $stub = @(
        '$child = Join-Path (Split-Path -Parent $PSScriptRoot) ''late-install.cmd''',
        "Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c `"' + `$child + '`"') -WindowStyle Hidden",
        'Start-Sleep -Seconds 120'
    ) -join "`r`n"
    Write-Utf8Bom (Join-Path $dir 'tools\finish-plugin.ps1') ($stub + "`r`n")
    foreach ($name in @('install-plugin.ps1', 'set-mode.ps1')) {
        Write-Utf8Bom (Join-Path $dir ('tools\' + $name)) "Start-Sleep -Seconds 120`r`n"
    }
}

function New-SleepCmd([string]$path, [string]$markerName) {
    # Без BOM: cmd.exe спотыкается о BOM в начале .cmd.
    $body = @(
        '@echo off',
        'ping -n 4 127.0.0.1 >nul',
        ('echo late > "%~dp0' + $markerName + '"')
    ) -join "`r`n"
    [IO.File]::WriteAllText($path, $body + "`r`n", (New-Object Text.UTF8Encoding($false)))
}

function Start-SleepScript([string]$scriptPath) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '"'
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $spawned.Add($p)
    return $p
}

function Test-Alive($p) {
    if (-not $p) { return $false }
    return ($null -ne (Get-Process -Id $p.Id -ErrorAction SilentlyContinue))
}

function Wait-Alive($p, [int]$TimeoutMs = 15000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        if (Test-Alive $p) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Wait-CommandLine([string]$needle, [int]$TimeoutMs = 15000) {
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $hit = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and ($_.CommandLine.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        })
        if ($hit.Count -gt 0) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

function Invoke-Cancel([string]$appDir, [int]$WaitMs = 100) {
    $script = Join-Path $appDir 'tools\cancel-pending-plugin.ps1'
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -AppDir $appDir -WaitMs $WaitMs 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $oldEap
    return $code
}

$app = Join-Path $WorkRoot 'app dir'
$copyApp = Join-Path $WorkRoot 'app dir copy'
$prefixApp = Join-Path $WorkRoot 'app dir2'
$portableHome = Join-Path $WorkRoot 'portable-dsh'
$emptyProfile = Join-Path $WorkRoot 'no-profile'
$dshProfile = Join-Path $WorkRoot 'profile-with-dsh'

try {
    New-Item -ItemType Directory -Force -Path $WorkRoot, $emptyProfile | Out-Null
    New-FakeApp $app
    New-FakeApp $copyApp
    New-FakeApp $prefixApp

    Write-Output ('рабочий каталог: ' + $WorkRoot)

    # 1. Нестандартный DSH_HOME: bridge записан туда, а не в %USERPROFILE%\.dsh.
    Write-Output ''
    Write-Output '=== 1. нестандартный DSH_HOME, bridge установлен ==='
    New-FakeDshHome $portableHome $true
    $env:DSH_HOME = $portableHome
    $env:USERPROFILE = $emptyProfile
    $code = Invoke-Cancel $app
    Check 'bridge в нестандартном DSH_HOME обнаружен' ($code -eq 1) ('code=' + $code)

    # 2. Тот же нестандартный путь, bridge нет: отмена проходит.
    Write-Output ''
    Write-Output '=== 2. нестандартный DSH_HOME, bridge отсутствует ==='
    New-FakeDshHome $portableHome $false
    $code = Invoke-Cancel $app
    Check 'отмена при нестандартном DSH_HOME успешна' ($code -eq 0) ('code=' + $code)

    # 3. Стандартный профиль пользователя тоже находится.
    Write-Output ''
    Write-Output '=== 3. стандартный профиль пользователя ==='
    New-FakeDshHome (Join-Path $dshProfile '.dsh') $true
    $env:DSH_HOME = ''
    $env:USERPROFILE = $dshProfile
    $code = Invoke-Cancel $app
    Check 'bridge в профиле пользователя обнаружен' ($code -eq 1) ('code=' + $code)

    # 4. Нестандартная (портативная) установка DSH: профиль виден только через
    #    запись деинсталлятора, DSH_HOME и %USERPROFILE%\.dsh молчат.
    Write-Output ''
    Write-Output '=== 4. нестандартная установка: запись деинсталлятора ==='
    $portableInstall = Join-Path $WorkRoot 'portable-install'
    New-FakeDshHome (Join-Path $portableInstall '.dsh') $true
    $uninstallKey = New-FakeUninstallEntry ('DSHWidgetTest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) $portableInstall
    try {
        $env:DSH_HOME = ''
        $env:USERPROFILE = $emptyProfile
        $code = Invoke-Cancel $app
        Check 'bridge найден по записи деинсталлятора' ($code -eq 1) ('code=' + $code)
    } finally {
        Remove-Item -LiteralPath $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 5. Посторонние процессы: свои останавливаем, чужие одноимённые — нет.
    Write-Output ''
    Write-Output '=== 5. посторонние процессы ==='
    New-FakeDshHome $portableHome $false
    $env:DSH_HOME = $portableHome
    $env:USERPROFILE = $emptyProfile

    $ownFinish = Start-SleepScript (Join-Path $app 'tools\finish-plugin.ps1')
    $ownSetMode = Start-SleepScript (Join-Path $app 'tools\set-mode.ps1')
    $foreignCopy = Start-SleepScript (Join-Path $copyApp 'tools\finish-plugin.ps1')
    $foreignPrefix = Start-SleepScript (Join-Path $prefixApp 'tools\install-plugin.ps1')

    $started = @(
        (Wait-Alive $ownFinish), (Wait-Alive $ownSetMode), (Wait-Alive $foreignCopy), (Wait-Alive $foreignPrefix)
    )
    Check 'тестовые процессы запустились' ($started -notcontains $false)

    $code = Invoke-Cancel $app
    Check 'отмена с посторонними процессами успешна' ($code -eq 0) ('code=' + $code)

    Start-Sleep -Milliseconds 800
    Check 'свой finish-plugin остановлен' (-not (Test-Alive $ownFinish))
    Check 'свой set-mode остановлен' (-not (Test-Alive $ownSetMode))
    Check 'одноимённый скрипт копии программы не тронут' (Test-Alive $foreignCopy)
    Check 'одноимённый скрипт с похожим путём не тронут' (Test-Alive $foreignPrefix)

    # 6. Нечитаемый профиль: состояние неизвестно, отмена обязана упасть.
    Write-Output ''
    Write-Output '=== 6. нечитаемый package.json ==='
    New-FakeDshHome $portableHome $false
    [IO.File]::WriteAllText((Join-Path $portableHome 'profiles\desktop\package.json'), '{broken', (New-Object Text.UTF8Encoding($false)))
    $env:DSH_HOME = $portableHome
    $env:USERPROFILE = $emptyProfile
    $code = Invoke-Cancel $app
    Check 'нечитаемый профиль: отмена падает (fail-closed)' ($code -eq 1) ('code=' + $code)

    # 7. Поздняя установка: cmd.exe из finisher не должен пережить отмену.
    Write-Output ''
    Write-Output '=== 7. поздняя установка через cmd.exe ==='
    $lateApp = Join-Path $WorkRoot 'app late'
    New-LateInstallApp $lateApp
    New-FakeDshHome $portableHome $false
    $env:DSH_HOME = $portableHome
    $env:USERPROFILE = $emptyProfile
    $lateMarker = Join-Path $lateApp 'late-install.marker'
    Remove-Item -LiteralPath $lateMarker -Force -ErrorAction SilentlyContinue
    $lateChain = Start-SleepScript (Join-Path $lateApp 'tools\finish-plugin.ps1')
    Check 'цепочка finisher -> cmd.exe запустилась' ((Wait-Alive $lateChain) -and (Wait-CommandLine 'late-install.cmd'))
    $code = Invoke-Cancel $lateApp
    Check 'отмена при живой цепочке cmd.exe успешна' ($code -eq 0) ('code=' + $code)
    Start-Sleep -Seconds 6
    Check 'cmd.exe-потомок остановлен вместе с деревом' (-not (Test-Path -LiteralPath $lateMarker))

    # 8. Осиротевшая команда установки: родитель убит, но путь к plugin\ остался
    #    в командной строке — такую команду отмена узнаёт и гасит.
    Write-Output ''
    Write-Output '=== 8. осиротевшая команда установки ==='
    $orphanCmd = Join-Path $WorkRoot 'orphan.cmd'
    New-SleepCmd $orphanCmd 'orphan.marker'
    $orphan = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ""' + $orphanCmd + '" "' + (Join-Path $lateApp 'plugin\dsh-widget-bridge-1.0.1.tgz') + '""') -WindowStyle Hidden -PassThru
    $spawned.Add($orphan)
    Check 'осиротевшая команда запустилась' ((Wait-Alive $orphan) -and (Wait-CommandLine 'orphan.cmd'))
    $code = Invoke-Cancel $lateApp
    Check 'отмена с осиротевшей командой успешна' ($code -eq 0) ('code=' + $code)
    Start-Sleep -Seconds 6
    Check 'осиротевшая команда установки остановлена' (-not (Test-Path -LiteralPath (Join-Path $WorkRoot 'orphan.marker')))

    # 9. Обычное поведение не изменилось: маркер отложенной установки снимается.
    Write-Output ''
    Write-Output '=== 9. маркер pending-plugin.json снимается ==='
    $marker = Join-Path $app 'pending-plugin.json'
    [IO.File]::WriteAllText($marker, '{}', (New-Object Text.UTF8Encoding($false)))
    $code = Invoke-Cancel $app
    Check 'отмена успешна' ($code -eq 0) ('code=' + $code)
    Check 'pending-plugin.json удалён' (-not (Test-Path -LiteralPath $marker))
}
finally {
    foreach ($p in $spawned) {
        try { if (Test-Alive $p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } } catch { }
    }
    $env:DSH_HOME = $oldDshHome
    $env:USERPROFILE = $oldUserProfile
    if (-not $KeepWork) {
        try { Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'ИТОГ: все проверки пройдены' } else { Write-Output ('ИТОГ: ошибок ' + $fail) }
exit $fail
