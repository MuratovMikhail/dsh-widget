# Проверка установщика: режимы, custom path, обновление, удаление и повторная установка.
# Требует Windows и собранный EXE. Не запускать на рабочей машине без понимания:
# тест ставит и удаляет программу в собственном каталоге и использует временный DSH_HOME.
[CmdletBinding()]
param(
    [string]$Exe,
    [string]$WorkRoot = (Join-Path $env:TEMP ('dsh-widget-installer-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))),
    [switch]$KeepInstalled
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$fail = 0
$oldDshHome = $env:DSH_HOME

function Write-Step([string]$text) { Write-Output ''; Write-Output ('=== ' + $text + ' ===') }
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Output ('  OK   ' + $name) }
    else {
        Write-Output ('  FAIL ' + $name + $(if ($detail) { ' — ' + $detail } else { '' }))
        $script:fail++
    }
}

if (-not $Exe) {
    $candidate = Get-ChildItem -Path (Join-Path $root 'dist') -Filter 'DSHWidget-Setup-*.exe' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidate) { $Exe = $candidate.FullName }
}
if (-not $Exe -or -not (Test-Path -LiteralPath $Exe)) { throw 'Не найден установщик: соберите через build-installer.ps1' }

$versionFile = Join-Path $root 'VERSION'
$expectedVersion = ''
if (Test-Path -LiteralPath $versionFile) { $expectedVersion = (Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim() }
if (-not $expectedVersion) {
    $ui = Get-Content -LiteralPath (Join-Path $root 'widget-ui.ps1') -Raw -Encoding UTF8
    $m = [regex]::Match($ui, "appVersion\s*=\s*'([^']+)'")
    if ($m.Success) { $expectedVersion = $m.Groups[1].Value }
}
if (-not $expectedVersion) { throw 'Не удалось определить ожидаемую версию (VERSION / widget-ui.ps1)' }
$expectedBridgeVersion = ''
$bridgeSourceManifest = Join-Path $root 'plugin-src\package.json'
if (Test-Path -LiteralPath $bridgeSourceManifest) {
    $expectedBridgeVersion = [string](Get-Content -LiteralPath $bridgeSourceManifest -Raw -Encoding UTF8 | ConvertFrom-Json).version
}

$appDir = Join-Path $WorkRoot 'app'
$dshHome = Join-Path $WorkRoot 'dsh-home'
$profileDir = Join-Path $dshHome 'profiles\desktop'
$manifest = Join-Path $profileDir 'package.json'
$pointerDir = Join-Path $env:LOCALAPPDATA 'DSH Widget'
$pointer = Join-Path $pointerDir 'install-dir.txt'
$startMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'DSH Widget'
$startMenu = Join-Path $startMenuDir 'DSH Widget.lnk'
$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'DSH Widget.lnk'
$desktop = Join-Path ([Environment]::GetFolderPath('Desktop')) 'DSH Widget.lnk'
$uninstKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{B7E1C0D4-5A62-4F0B-9A3E-2D7C6B1F0A55}_is1'
$unins = Join-Path $appDir 'unins000.exe'
$defaultAppDir = Join-Path $env:LOCALAPPDATA 'Programs\DSH Widget'

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null

# Защита от запуска на рабочей машине: тест использует общие имена ярлыков,
# ключ деинсталлятора и указатель. В изолированной среде их быть не должно.
$existing = @()
foreach ($p in @($uninstKey, $startMenuDir, $startup, $desktop, $pointerDir, (Join-Path $defaultAppDir 'widget-ui.ps1'))) {
    if (Test-Path -LiteralPath $p) { $existing += $p }
}
if ($existing.Count -gt 0) {
    throw ("Тест обнаружен существующую установку DSH Widget:`n  " + ($existing -join "`n  ") +
           "`nЗапускайте lifecycle-тест только в изолированной Windows/VM без установленного виджета.")
}

function Reset-Install {
    if (Test-Path -LiteralPath $unins) {
        $p = Start-Process -FilePath $unins -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait -PassThru
        Start-Sleep -Seconds 2
    }
    if (Test-Path -LiteralPath $appDir) { Remove-Item -LiteralPath $appDir -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($p in @($startMenuDir, $startMenu, $startup, $desktop, $pointer, (Join-Path $appDir 'pending-plugin.json'))) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $uninstKey) { Remove-Item -LiteralPath $uninstKey -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $pointerDir) { Remove-Item -LiteralPath $pointerDir -Recurse -Force -ErrorAction SilentlyContinue }
}

function New-Profile([string[]]$bundles = @('@deepseek-ai/dsh-base')) {
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    $obj = [ordered]@{ dsh = [ordered]@{ profile = [ordered]@{ bundles = @($bundles) } } }
    [IO.File]::WriteAllText($manifest, ($obj | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
}

function Get-Config {
    $p = Join-Path $appDir 'config.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Has-Bundle {
    if (-not (Test-Path -LiteralPath $manifest)) { return $false }
    try {
        $d = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
        return (@($d.dsh.profile.bundles) -contains '@local/dsh-widget-bridge')
    } catch { return $false }
}

function Run-Installer([string]$tasks, [string]$name) {
    $log = Join-Path $WorkRoot ('install-' + $name + '.log')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /TASKS="' + $tasks + '" /DIR="' + $appDir + '" /LOG="' + $log + '"'
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit(180000)) {
        try { $proc.Kill() } catch { }
        throw ('Установщик не завершился за 180 секунд: ' + $name)
    }
    return $proc.ExitCode
}

function Check-Common([string]$label, [string]$expectedMode, [bool]$pluginExpected, [bool]$startupExpected) {
    $cfg = Get-Config
    Check ($label + ': config есть') ($null -ne $cfg)
    Check ($label + ': launchMode=' + $expectedMode) ($null -ne $cfg -and [string]$cfg.launchMode -eq $expectedMode) ('actual=' + $(if ($cfg) { $cfg.launchMode } else { '<none>' }))
    Check ($label + ': autostart=' + $startupExpected) ($null -ne $cfg -and [bool]$cfg.autostart -eq $startupExpected)
    Check ($label + ': bundle=' + $pluginExpected) ((Has-Bundle) -eq $pluginExpected) ('actual=' + (Has-Bundle))
    Check ($label + ': pending marker отсутствует') (-not (Test-Path -LiteralPath (Join-Path $appDir 'pending-plugin.json')))
    Check ($label + ': start menu') (Test-Path -LiteralPath $startMenu)
    Check ($label + ': startup shortcut=' + $startupExpected) ((Test-Path -LiteralPath $startup) -eq $startupExpected)
    if (Test-Path -LiteralPath $startMenu) {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($startMenu)
        Check ($label + ': start menu target') ($lnk.TargetPath -like '*wscript.exe')
        Check ($label + ': start menu args custom path') ($lnk.Arguments -like ('*' + $appDir + '*'))
        Check ($label + ': start menu working dir') ([string]$lnk.WorkingDirectory -eq $appDir)
    }
    if (Test-Path -LiteralPath $uninstKey) {
        $props = Get-ItemProperty -LiteralPath $uninstKey
        Check ($label + ': DisplayVersion') ([string]$props.DisplayVersion -eq $expectedVersion) ('actual=' + $props.DisplayVersion)
        Check ($label + ': UninstallString') ([bool]$props.UninstallString)
    }
    $installedVersionFile = Join-Path $appDir 'VERSION'
    Check ($label + ': installed VERSION') ((Test-Path -LiteralPath $installedVersionFile) -and ((Get-Content -LiteralPath $installedVersionFile -Raw -Encoding UTF8).Trim() -eq $expectedVersion))
    Check ($label + ': status.ps1 установлен') (Test-Path -LiteralPath (Join-Path $appDir 'tools\status.ps1'))
    Check ($label + ': finish-plugin.ps1 установлен') (Test-Path -LiteralPath (Join-Path $appDir 'tools\finish-plugin.ps1'))
    Check ($label + ': dsh-common.ps1 установлен') (Test-Path -LiteralPath (Join-Path $appDir 'tools\dsh-common.ps1'))
    Check ($label + ': VERSION установлен') ((Test-Path -LiteralPath (Join-Path $appDir 'VERSION')) -or (Test-Path -LiteralPath (Join-Path $appDir 'version.txt')))
    Check ($label + ': pointer=' + $appDir) ((Test-Path -LiteralPath $pointer) -and ((Get-Content -LiteralPath $pointer -Raw -Encoding UTF8).Trim() -eq $appDir))
    if ($pluginExpected) {
        $bridgeManifest = Join-Path $profileDir 'node_modules\@local\dsh-widget-bridge\package.json'
        Check ($label + ': bridge package.json') (Test-Path -LiteralPath $bridgeManifest)
        if (Test-Path -LiteralPath $bridgeManifest) {
            $bridgeVersion = [string](Get-Content -LiteralPath $bridgeManifest -Raw -Encoding UTF8 | ConvertFrom-Json).version
            Check ($label + ': bridge version ' + $expectedBridgeVersion) ($bridgeVersion -eq $expectedBridgeVersion) ('actual=' + $bridgeVersion)
        }
    } else {
        Check ($label + ': bridge package отсутствует') (-not (Test-Path -LiteralPath (Join-Path $profileDir 'node_modules\@local\dsh-widget-bridge')))
    }
}

function Install-Mode([string]$mode, [string]$task, [bool]$withProfile, [bool]$pluginExpected, [bool]$startupExpected) {
    Write-Step ('режим ' + $mode)
    Reset-Install
    if ($withProfile) { New-Profile } else { Remove-Item -LiteralPath $dshHome -Recurse -Force -ErrorAction SilentlyContinue }
    $code = Run-Installer $task $mode
    Check ($mode + ': exit 0') ($code -eq 0) ('code=' + $code)
    Check-Common $mode $mode $pluginExpected $startupExpected
}

function Switch-Mode([string]$label, [string]$task, [string]$expectedMode, [bool]$pluginExpected, [bool]$startupExpected) {
    Write-Step ('переключение ' + $label)
    $code = Run-Installer $task ('switch-' + $label)
    Check ($label + ': exit 0') ($code -eq 0) ('code=' + $code)
    Check-Common $label $expectedMode $pluginExpected $startupExpected
    Check ($label + ': bridge package соответствует режиму') ((Test-Path -LiteralPath (Join-Path $profileDir 'node_modules\@local\dsh-widget-bridge')) -eq $pluginExpected)
    Check ($label + ': startup-ссылка соответствует режиму') ((Test-Path -LiteralPath $startup) -eq $startupExpected)
}

try {
    $env:DSH_HOME = $dshHome
    Write-Output ('установщик: ' + $Exe)
    Write-Output ('ожидаемая версия: ' + $expectedVersion)
    Write-Output ('app: ' + $appDir)
    Write-Output ('DSH_HOME: ' + $dshHome)

    # 1. Три режима.
    Install-Mode 'plugin' 'mode_plugin' $true $true $false
    Install-Mode 'startup' 'mode_startup' $false $false $true
    Install-Mode 'manual' 'mode_manual' $false $false $false

    # 1b. Последовательные переключения без удаления приложения.
    Write-Step 'переключения plugin -> startup -> manual -> plugin -> manual'
    Reset-Install
    New-Profile
    Check 'sequence: первичный plugin' ((Run-Installer 'mode_plugin' 'sequence-plugin') -eq 0)
    Switch-Mode 'plugin-to-startup' 'mode_startup' 'startup' $false $true
    Switch-Mode 'startup-to-manual' 'mode_manual' 'manual' $false $false
    Switch-Mode 'manual-to-plugin' 'mode_plugin' 'plugin' $true $false
    Switch-Mode 'plugin-to-manual' 'mode_manual' 'manual' $false $false

    # 1c. Отмена уже запущенного finisher при повторной установке.
    Write-Step 'отмена pending -> manual'
    Reset-Install
    Remove-Item -LiteralPath $dshHome -Recurse -Force -ErrorAction SilentlyContinue
    Check 'pending-manual: plugin install exit 0' ((Run-Installer 'mode_plugin' 'pending-manual-before') -eq 0)
    Check 'pending-manual: marker создан' (Test-Path -LiteralPath (Join-Path $appDir 'pending-plugin.json'))
    Switch-Mode 'pending-to-manual' 'mode_manual' 'manual' $false $false

    Write-Step 'отмена pending -> startup'
    Reset-Install
    Remove-Item -LiteralPath $dshHome -Recurse -Force -ErrorAction SilentlyContinue
    Check 'pending-startup: plugin install exit 0' ((Run-Installer 'mode_plugin' 'pending-startup-before') -eq 0)
    Check 'pending-startup: marker создан' (Test-Path -LiteralPath (Join-Path $appDir 'pending-plugin.json'))
    Switch-Mode 'pending-to-startup' 'mode_startup' 'startup' $false $true

    # 2. Обновление поверх установленной версии: custom path и конфиг должны сохраниться.
    Write-Step 'обновление поверх'
    Reset-Install
    New-Profile
    [void](Run-Installer 'mode_plugin' 'update-before')
    $before = Get-Config
    if ($before) {
        $before | Add-Member -NotePropertyName updateSentinel -NotePropertyValue 'keep' -Force
        [IO.File]::WriteAllText((Join-Path $appDir 'config.json'), ($before | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    }
    $code = Run-Installer 'mode_plugin' 'update-after'
    Check 'update: exit 0' ($code -eq 0) ('code=' + $code)
    $after = Get-Config
    Check 'update: режим сохранился' ($after -and [string]$after.launchMode -eq 'plugin')
    Check 'update: произвольное поле не потерялось' ($after -and [string]$after.updateSentinel -eq 'keep')

    # 3. Удаление и проверка остатков.
    Write-Step 'удаление'
    if (Test-Path -LiteralPath $unins) {
        $p = Start-Process -FilePath $unins -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait -PassThru
        Start-Sleep -Seconds 2
        Check 'uninstall: exit 0' ($p.ExitCode -eq 0) ('code=' + $p.ExitCode)
    } else { Check 'uninstall: unins000.exe существует' $false }
    Check 'uninstall: app удалён' (-not (Test-Path -LiteralPath $appDir))
    Check 'uninstall: config удалён' (-not (Test-Path -LiteralPath (Join-Path $appDir 'config.json')))
    Check 'uninstall: start menu удалён' (-not (Test-Path -LiteralPath $startMenu))
    Check 'uninstall: startup удалён' (-not (Test-Path -LiteralPath $startup))
    Check 'uninstall: registry удалён' (-not (Test-Path -LiteralPath $uninstKey))
    Check 'uninstall: pointer удалён' (-not (Test-Path -LiteralPath $pointer))
    Check 'uninstall: pending marker удалён' (-not (Test-Path -LiteralPath (Join-Path $appDir 'pending-plugin.json')))
    Check 'uninstall: bridge удалён из профиля' (-not (Has-Bundle))

    # 4. Повторная установка после удаления.
    Write-Step 'повторная установка после удаления'
    $code = Run-Installer 'mode_manual' 'reinstall'
    Check 'reinstall: exit 0' ($code -eq 0) ('code=' + $code)
    Check 'reinstall: config manual' ($null -ne (Get-Config) -and [string](Get-Config).launchMode -eq 'manual')

    # 5. Установка до первого запуска DSH: pending marker и finisher.
    Write-Step 'установка до первого запуска DSH'
    Reset-Install
    Remove-Item -LiteralPath $dshHome -Recurse -Force -ErrorAction SilentlyContinue
    $dshRunning = @(Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe' OR Name='dsh.exe'" -ErrorAction SilentlyContinue).Count -gt 0
    if ($dshRunning) {
        Write-Output '  SKIP: DSH сейчас запущен; finisher ждёт закрытия DSH'
    } else {
        $code = Run-Installer 'mode_plugin' 'before-dsh'
        Check 'before-dsh: exit 0' ($code -eq 0) ('code=' + $code)
        Check 'before-dsh: config manual' ($null -ne (Get-Config) -and [string](Get-Config).launchMode -eq 'manual')
        Check 'before-dsh: pending marker создан' (Test-Path -LiteralPath (Join-Path $appDir 'pending-plugin.json'))
        New-Profile
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline) {
            $cfg = Get-Config
            if ((Has-Bundle) -and $cfg -and [string]$cfg.launchMode -eq 'plugin') { break }
            Start-Sleep -Seconds 2
        }
        Check 'before-dsh: finisher поставил bridge' (Has-Bundle)
        Check 'before-dsh: finisher поставил plugin' ($null -ne (Get-Config) -and [string](Get-Config).launchMode -eq 'plugin')
    }

    if (-not $KeepInstalled) { Reset-Install }
}
finally {
    $env:DSH_HOME = $oldDshHome
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'DshWidgetFinishPlugin' -ErrorAction SilentlyContinue
    if (-not $KeepInstalled) {
        if (Test-Path -LiteralPath $appDir) { Remove-Item -LiteralPath $appDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Output ''
if ($fail -eq 0) { Write-Output 'ИТОГ: все проверки пройдены' } else { Write-Output ('ИТОГ: ошибок ' + $fail) }
exit $fail
