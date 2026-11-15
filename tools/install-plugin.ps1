# Ставит микроплагин dsh-widget-bridge в профиль DSH.
# Установщик вызывает этот скрипт при включённой задаче «запускать вместе с DSH».
#
# Коды выхода:
#   0 — установлено или уже стоит
#   3 — не найден DSH, профиль или пакет
#   1 — ошибка установки
[CmdletBinding()]
param(
    [string]$Profile = 'desktop',
    [string]$Tgz = '',
    [switch]$Quiet,
    [switch]$Direct
)

$ErrorActionPreference = 'Stop'
function Say([string]$text) { if (-not $Quiet) { Write-Output $text } }

$bundle = '@local/dsh-widget-bridge'
$desktopName = 'DeepSeek Harness.exe'

function Get-DshHome {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:DSH_HOME) { [void]$candidates.Add($env:DSH_HOME) }
    if ($env:USERPROFILE) { [void]$candidates.Add((Join-Path $env:USERPROFILE '.dsh')) }

    # Портативная/нестандартная установка: смотрим, откуда запущен DSH.
    foreach ($name in @($desktopName, 'dsh.exe')) {
        try {
            $procs = Get-CimInstance Win32_Process -Filter ("Name='" + $name + "'") -ErrorAction SilentlyContinue
            foreach ($p in @($procs)) {
                if (-not $p -or -not $p.ExecutablePath) { continue }
                $exeDir = Split-Path -Parent $p.ExecutablePath
                [void]$candidates.Add((Join-Path $exeDir '.dsh'))
                [void]$candidates.Add((Join-Path (Split-Path -Parent $exeDir) '.dsh'))
            }
        } catch { }
    }

    foreach ($root in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        try {
            Get-ItemProperty $root -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*DeepSeek Harness*' -and $_.InstallLocation } |
                ForEach-Object { [void]$candidates.Add((Join-Path $_.InstallLocation '.dsh')) }
        } catch { }
    }

    foreach ($c in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath (Join-Path $c ('profiles\' + $Profile))) { return $c }
    }
    return $null
}

function Get-DshCli([string]$dshHome) {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:DSH_CLI) { [void]$candidates.Add($env:DSH_CLI) }
    if ($env:LOCALAPPDATA) {
        [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd'))
    }
    if ($dshHome) {
        [void]$candidates.Add((Join-Path $dshHome 'dsh-runtimes\dsh-primary-runtime\cli\bin\dsh.cmd'))
    }

    foreach ($name in @($desktopName, 'dsh.exe')) {
        try {
            $procs = Get-CimInstance Win32_Process -Filter ("Name='" + $name + "'") -ErrorAction SilentlyContinue
            foreach ($p in @($procs)) {
                if (-not $p -or -not $p.ExecutablePath) { continue }
                $exeDir = Split-Path -Parent $p.ExecutablePath
                [void]$candidates.Add((Join-Path $exeDir 'resources\runtime\cli\bin\dsh.cmd'))
            }
        } catch { }
    }

    # Установка за пределами %LOCALAPPDATA% обычно видна в Uninstall.
    foreach ($root in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        try {
            Get-ItemProperty $root -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*DeepSeek Harness*' -and $_.InstallLocation } |
                ForEach-Object {
                    [void]$candidates.Add((Join-Path $_.InstallLocation 'resources\runtime\cli\bin\dsh.cmd'))
                }
        } catch { }
    }

    $cmd = Get-Command dsh.cmd -ErrorAction SilentlyContinue
    if ($cmd) { [void]$candidates.Add($cmd.Source) }

    foreach ($c in ($candidates | Select-Object -Unique)) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Install-PluginDirect([string]$profileDir, [string]$packagePath) {
    $dest = Join-Path $profileDir 'node_modules\@local\dsh-widget-bridge'
    $manifest = Join-Path $profileDir 'package.json'

    $data = $null
    if (Test-Path -LiteralPath $manifest) {
        try { $data = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        if (-not $data) { throw 'не удалось прочитать package.json профиля' }
    } else {
        $data = [pscustomobject]@{}
    }

    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tar) { throw 'не найден tar.exe для распаковки плагина' }

    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    & $tar.Source -xzf $packagePath -C $dest --strip-components=1
    if ($LASTEXITCODE -ne 0) { throw ('tar завершился с кодом ' + $LASTEXITCODE) }

    if (-not $data.PSObject.Properties['dsh']) {
        $data | Add-Member -NotePropertyName dsh -NotePropertyValue ([pscustomobject]@{})
    }
    if (-not $data.dsh.PSObject.Properties['profile']) {
        $data.dsh | Add-Member -NotePropertyName profile -NotePropertyValue ([pscustomobject]@{})
    }
    $bundles = @($data.dsh.profile.bundles)
    if ($bundles -notcontains $bundle) {
        $bundles += $bundle
        $data.dsh.profile | Add-Member -NotePropertyName bundles -NotePropertyValue $bundles -Force
    }

    $json = $data | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($manifest, $json, (New-Object Text.UTF8Encoding($false)))
}

$dshHome = Get-DshHome
if (-not $dshHome) {
    Say 'профиль DSH не найден: откройте DeepSeek Harness один раз'
    exit 3
}

$profileDir = Join-Path (Join-Path $dshHome 'profiles') $Profile
$manifest = Join-Path $profileDir 'package.json'
if (-not (Test-Path -LiteralPath $profileDir)) {
    Say ('профиль не найден: ' + $profileDir)
    exit 3
}

if (-not $Tgz) { $Tgz = Join-Path (Split-Path -Parent $PSScriptRoot) 'plugin\dsh-widget-bridge-1.0.0.tgz' }
if (-not (Test-Path -LiteralPath $Tgz)) {
    Say ('не найден пакет плагина: ' + $Tgz)
    exit 3
}

# Уже включён — ничего не делаем.
try {
    $data = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($data -and $data.dsh -and $data.dsh.profile -and (@($data.dsh.profile.bundles) -contains $bundle)) {
        Say 'плагин уже установлен'
        exit 0
    }
} catch { }

$cli = if ($Direct) { $null } else { Get-DshCli $dshHome }
if ($cli) {
    Say ('ставлю пакет через DSH CLI: ' + $cli)
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & cmd.exe /c "`"$cli`" plugin --profile $Profile add `"$Tgz`"" 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $oldEap
    if ($code -eq 0) {
        $ok = $false
        try {
            $data = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
            $ok = @($data.dsh.profile.bundles) -contains $bundle
        } catch { }
        if ($ok) {
            Say 'готово: виджет будет запускаться вместе с DSH'
            exit 0
        }
        Say 'CLI не добавил бандл в профиль, ставлю напрямую'
    } else {
        Say ('CLI не сработал, код ' + $code + '; ставлю напрямую')
        $out | Select-Object -Last 4 | ForEach-Object { Say ('  ' + $_) }
    }
}

try {
    Install-PluginDirect $profileDir $Tgz
} catch {
    Say ('не удалось установить плагин: ' + $_.Exception.Message)
    exit 1
}

Say 'готово: виджет будет запускаться вместе с DSH'
exit 0
