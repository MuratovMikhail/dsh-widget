# Останавливает запущенный виджет и его движок.
# Нужен установщику перед установкой «поверх» и деинсталлятору перед удалением файлов.
#
# PID берём из runtime.json, который виджет пишет рядом с собой при старте:
# так мы не трогаем чужие powershell/node. WMI — только как резервный путь.
[CmdletBinding()]
param([int]$WaitSeconds = 5)

$ErrorActionPreference = 'SilentlyContinue'
$appDir = Split-Path -Parent $PSScriptRoot
$statePath = Join-Path $appDir 'runtime.json'

function Stop-IfOurs([int]$id, [string[]]$expectNames) {
    if ($id -le 0) { return $false }
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if ($expectNames -notcontains $p.ProcessName) { return $false }
    try { Stop-Process -Id $id -Force -ErrorAction Stop; Write-Output ("остановлен " + $p.ProcessName + " pid=" + $id); return $true } catch { return $false }
}

$stoppedAny = $false
if (Test-Path -LiteralPath $statePath) {
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.engine) { $stoppedAny = (Stop-IfOurs ([int]$state.engine) @('node')) -or $stoppedAny }
        if ($state.ui) { $stoppedAny = (Stop-IfOurs ([int]$state.ui) @('powershell', 'pwsh', 'wscript')) -or $stoppedAny }
    } catch { }
}

# Резервный путь: ищем процессы по командной строке, если файла состояния нет.
if (-not $stoppedAny) {
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
            Where-Object { $_.CommandLine -and ($_.CommandLine -match 'widget-ui\.ps1' -or $_.CommandLine -match 'widget-engine\.js') }
        foreach ($p in $procs) {
            try { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop; $stoppedAny = $true; Write-Output ("остановлен " + $p.Name + " pid=" + $p.ProcessId) } catch { }
        }
    } catch { }
}

$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ($stoppedAny -and (Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $statePath) {
        $alive = $false
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($id in @([int]$state.engine, [int]$state.ui)) {
                if ($id -gt 0 -and (Get-Process -Id $id -ErrorAction SilentlyContinue)) { $alive = $true }
            }
        } catch { }
        if (-not $alive) { break }
    } else { break }
    Start-Sleep -Milliseconds 200
}

Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
if ($stoppedAny) { Write-Output 'готово' } else { Write-Output 'виджет не запущен' }
exit 0
