# Доустанавливает bridge-плагин, когда DSH впервые создал профиль.
# Запускается установщиком, если DSH ещё ни разу не открывали.
[CmdletBinding()]
param(
    [int]$TimeoutSec = 1800,
    [int]$IntervalSec = 5
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$app = Split-Path -Parent $here
$installer = Join-Path $here 'install-plugin.ps1'
$setMode = Join-Path $here 'set-mode.ps1'
$log = Join-Path $app 'finish-plugin.log'
$pending = Join-Path $app 'pending-plugin.json'
$runOnceKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$runOnceName = 'DshWidgetFinishPlugin'
$mutex = $null

function Write-FinishLog([string]$text) {
    try { Add-Content -LiteralPath $log -Value ((Get-Date).ToString('s') + ' ' + $text) -Encoding UTF8 } catch { }
}

function Remove-RunOnce {
    try {
        if (Get-ItemProperty -Path $runOnceKey -Name $runOnceName -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $runOnceKey -Name $runOnceName -ErrorAction SilentlyContinue
        }
    } catch { }
}

try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\DshWidgetFinishPlugin')
    if (-not $mutex.WaitOne(0)) { exit 0 }

    # Пережить перезагрузку между установкой и первым запуском DSH.
    try {
        $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $MyInvocation.MyCommand.Path + '" -TimeoutSec ' + $TimeoutSec
        Set-ItemProperty -Path $runOnceKey -Name $runOnceName -Value $cmd -ErrorAction Stop
    } catch { }

    Write-FinishLog ('start timeout=' + $TimeoutSec)
    if (-not (Test-Path -LiteralPath $pending)) {
        Write-FinishLog 'pending marker missing; leaving mode unchanged'
        Remove-RunOnce
        exit 0
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath $pending)) {
            Write-FinishLog 'pending marker cleared by user; leaving mode unchanged'
            Remove-RunOnce
            exit 0
        }

        $running = $false
        try {
            $running = @(Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe' OR Name='dsh.exe'" -ErrorAction SilentlyContinue).Count -gt 0
        } catch { }

        if ($running) {
            Start-Sleep -Seconds $IntervalSec
            continue
        }

        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $installer -Quiet 2>&1
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            if (-not (Test-Path -LiteralPath $pending)) {
                Write-FinishLog 'mode changed during install; leaving mode unchanged'
                Remove-RunOnce
                exit 0
            }
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $setMode -Mode plugin | Out-Null
            Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
            Write-FinishLog 'plugin installed; mode=plugin'
            Remove-RunOnce
            exit 0
        }
        if ($code -ne 3) {
            Write-FinishLog ('install failed code=' + $code + ' out=' + (($out | Select-Object -Last 3) -join ' | '))
            Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
            Remove-RunOnce
            exit 1
        }

        Start-Sleep -Seconds $IntervalSec
    }

    Write-FinishLog 'timeout; profile not found'
    Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
    Remove-RunOnce
    exit 2
}
catch {
    Write-FinishLog ('fatal: ' + $_.Exception.Message)
    Remove-RunOnce
    exit 1
}
finally {
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
}
