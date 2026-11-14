# Перезапуск виджета после смены языка: даём старому процессу выйти, гасим движок, запускаем заново.
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
$stop = Join-Path $PSScriptRoot 'stop-widget.ps1'
$vbs = Join-Path $root 'start-widget.vbs'

Start-Sleep -Milliseconds 800
if (Test-Path -LiteralPath $stop) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stop }
Start-Sleep -Milliseconds 800
if (Test-Path -LiteralPath $vbs) { Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') }
