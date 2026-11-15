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
$pluginDir = Join-Path $app 'plugin'
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

# install-plugin.ps1 ставит пакет через cmd.exe "<dsh.cmd>" plugin ... add "<app>\plugin\*.tgz".
# Такая команда (и её потомки) завершает установку уже после того, как убит родительский
# PowerShell, поэтому узнаём её по пути к пакету этой установки.
function Test-PluginInstallCommandLine([string]$commandLine) {
    if (-not $commandLine) { return $false }
    $text = $commandLine.Replace('/', '\')
    return ($text.IndexOf($pluginDir.Replace('/', '\'), [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Stop-FinisherProcesses {
    $me = $PID
    for ($i = 0; $i -lt 3; $i++) {
        $snapshot = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $roots = @($snapshot | Where-Object {
            $_.ProcessId -ne $me -and ((Test-OwnedScriptProcess $_.CommandLine) -or (Test-PluginInstallCommandLine $_.CommandLine))
        })
        if ($roots.Count -eq 0) { return }

        $children = @{}
        foreach ($p in $snapshot) {
            $parentId = [int]$p.ParentProcessId
            if (-not $children.ContainsKey($parentId)) { $children[$parentId] = New-Object System.Collections.Generic.List[int] }
            $children[$parentId].Add([int]$p.ProcessId)
        }

        # Гасим дерево целиком: PowerShell -> cmd.exe -> node.exe.
        $targets = New-Object System.Collections.Generic.HashSet[int]
        $queue = New-Object System.Collections.Generic.Queue[int]
        foreach ($root in $roots) {
            if ($targets.Add([int]$root.ProcessId)) { $queue.Enqueue([int]$root.ProcessId) }
        }
        while ($queue.Count -gt 0) {
            $parentId = $queue.Dequeue()
            if (-not $children.ContainsKey($parentId)) { continue }
            foreach ($childId in $children[$parentId]) {
                if ($childId -ne $me -and $targets.Add($childId)) { $queue.Enqueue($childId) }
            }
        }

        foreach ($id in @($targets)) {
            try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Milliseconds 300
    }
}

function Get-BridgeState {
    # 'present' | 'absent' | 'unknown'.
    # 'unknown' — профиль существует, но прочитать его не удалось: отмена обязана
    # упасть, иначе неудачное удаление выглядит как «всё чисто».
    $dshHome = Get-DshHome
    if (-not $dshHome) { return 'absent' }
    $manifest = Join-Path (Join-Path (Join-Path $dshHome 'profiles') 'desktop') 'package.json'
    if (-not (Test-Path -LiteralPath $manifest)) { return 'absent' }
    $data = $null
    try { $data = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return 'unknown' }
    if (-not $data -or -not $data.dsh -or -not $data.dsh.profile) { return 'unknown' }
    if (@($data.dsh.profile.bundles) -contains '@local/dsh-widget-bridge') { return 'present' }
    return 'absent'
}

try {
    Write-CancelLog 'cancel requested'
    # Сначала снимаем маркер: watcher увидит отмену на следующей итерации.
    Remove-PendingState
    Stop-FinisherProcesses
    Start-Sleep -Milliseconds $WaitMs
    Stop-FinisherProcesses
    Remove-PendingState

    $removeCode = 0
    if (Test-Path -LiteralPath $removeScript) {
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $removeScript -Quiet 2>&1 | Out-Null
        $removeCode = $LASTEXITCODE
        $ErrorActionPreference = $oldEap
        if ($removeCode -ne 0) { Write-CancelLog ('remove-plugin code=' + $removeCode) }
    }

    # Откат, если установка успела записать bundle между kill и remove.
    for ($i = 0; $i -lt 3 -and ((Get-BridgeState) -ne 'absent'); $i++) {
        Stop-FinisherProcesses
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $removeScript) {
            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $removeScript -Quiet 2>&1 | Out-Null
            $removeCode = $LASTEXITCODE
            $ErrorActionPreference = $oldEap
            if ($removeCode -ne 0) { Write-CancelLog ('remove-plugin code=' + $removeCode) }
        }
    }
    Remove-PendingState

    $state = Get-BridgeState
    if ($state -eq 'unknown') {
        Write-CancelLog ('profile state unknown; failing closed (remove code=' + $removeCode + ')')
        exit 1
    }
    if ($state -eq 'present') {
        Write-CancelLog ('bridge still present after cancellation (remove code=' + $removeCode + ')')
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
