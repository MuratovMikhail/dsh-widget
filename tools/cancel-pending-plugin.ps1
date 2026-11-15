# Отменяет отложенную установку bridge и гарантирует, что плагина нет.
# Вызывается установщиком перед сменой режима на startup/manual (и перед plugin).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [int]$WaitMs = 1500
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'dsh-common.ps1')

$app = (Resolve-Path -LiteralPath $AppDir).Path
$pending = Join-Path $app 'pending-plugin.json'
$runOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$runOnceName = 'DshWidgetFinishPlugin'
$finishScript = Join-Path $app 'tools\finish-plugin.ps1'
$installScript = Join-Path $app 'tools\install-plugin.ps1'
$setModeScript = Join-Path $app 'tools\set-mode.ps1'
$removeScript = Join-Path $app 'tools\remove-plugin.ps1'
$log = Join-Path $app 'cancel-plugin.log'

# Останавливать можно только скрипты этой установки: сравнение по полному пути,
# одноимённые скрипты из других каталогов и копий программы остаются жить.
$ownedScripts = @($finishScript, $installScript, $setModeScript)

function Write-CancelLog([string]$text) {
    try { Add-Content -LiteralPath $log -Value ((Get-Date).ToString('s') + ' ' + $text) -Encoding UTF8 } catch { }
}

function Remove-PendingState {
    Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
    try { Remove-ItemProperty -Path $runOnceKey -Name $runOnceName -ErrorAction SilentlyContinue } catch { }
}

function Test-OwnedScriptProcess([string]$commandLine) {
    if (-not $commandLine) { return $false }
    $text = $commandLine.Replace('/', '\')
    foreach ($scriptPath in $ownedScripts) {
        if (-not $scriptPath) { continue }
        if ($text.IndexOf($scriptPath.Replace('/', '\'), [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Stop-FinisherProcesses {
    $me = $PID
    for ($i = 0; $i -lt 3; $i++) {
        $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessId -ne $me -and (Test-OwnedScriptProcess $_.CommandLine)
        })
        if ($procs.Count -eq 0) { return }
        foreach ($p in $procs) {
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Milliseconds 300
    }
}

function Test-BridgePresent {
    # Общее обнаружение DSH: переменная окружения, профиль пользователя,
    # портативная/нестандартная установка и запись деинсталлятора.
    $dshHome = Get-DshHome
    if (-not $dshHome) { return $false }
    $manifest = Join-Path (Join-Path (Join-Path $dshHome 'profiles') 'desktop') 'package.json'
    if (-not (Test-Path -LiteralPath $manifest)) { return $false }
    try {
        $data = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
        return (@($data.dsh.profile.bundles) -contains '@local/dsh-widget-bridge')
    } catch { return $false }
}

try {
    Write-CancelLog 'cancel requested'
    # Сначала снимаем маркер: watcher увидит отмену на следующей итерации.
    Remove-PendingState
    Stop-FinisherProcesses
    Start-Sleep -Milliseconds $WaitMs
    Stop-FinisherProcesses
    Remove-PendingState

    if (Test-Path -LiteralPath $removeScript) {
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $removeScript -Quiet 2>&1 | Out-Null
        $code = $LASTEXITCODE
        $ErrorActionPreference = $oldEap
        if ($code -ne 0) { Write-CancelLog ('remove-plugin code=' + $code) }
    }

    # Откат, если установка успела записать bundle между kill и remove.
    for ($i = 0; $i -lt 3 -and (Test-BridgePresent); $i++) {
        Stop-FinisherProcesses
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $removeScript) {
            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $removeScript -Quiet 2>&1 | Out-Null
            $ErrorActionPreference = $oldEap
        }
    }
    Remove-PendingState

    if (Test-BridgePresent) {
        Write-CancelLog 'bridge still present after cancellation'
        exit 1
    }

    Write-CancelLog 'cancelled; bridge absent'
    exit 0
}
catch {
    Write-CancelLog ('fatal: ' + $_.Exception.Message)
    Remove-PendingState
    exit 1
}
