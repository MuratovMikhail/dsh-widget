[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$AppDir)

$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:LOCALAPPDATA 'DSH Widget'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$file = Join-Path $dir 'install-dir.txt'
[IO.File]::WriteAllText($file, $AppDir, (New-Object Text.UTF8Encoding($false)))
