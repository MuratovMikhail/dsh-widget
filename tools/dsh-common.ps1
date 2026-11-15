# Общее обнаружение DeepSeek Harness для install/remove/finish.
# Подключается через dot-source: . (Join-Path $PSScriptRoot 'dsh-common.ps1')

$script:DshDesktopName = 'DeepSeek Harness.exe'

function Get-DshHome {
    param([string]$Profile = 'desktop')

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:DSH_HOME) { [void]$candidates.Add($env:DSH_HOME) }
    if ($env:USERPROFILE) { [void]$candidates.Add((Join-Path $env:USERPROFILE '.dsh')) }

    # Портативная/нестандартная установка: смотрим, откуда запущен DSH.
    foreach ($name in @($script:DshDesktopName, 'dsh.exe')) {
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

function Get-DshCli {
    param([string]$DshHome)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:DSH_CLI) { [void]$candidates.Add($env:DSH_CLI) }
    if ($env:LOCALAPPDATA) {
        [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd'))
    }
    if ($DshHome) {
        [void]$candidates.Add((Join-Path $DshHome 'dsh-runtimes\dsh-primary-runtime\cli\bin\dsh.cmd'))
    }

    foreach ($name in @($script:DshDesktopName, 'dsh.exe')) {
        try {
            $procs = Get-CimInstance Win32_Process -Filter ("Name='" + $name + "'") -ErrorAction SilentlyContinue
            foreach ($p in @($procs)) {
                if (-not $p -or -not $p.ExecutablePath) { continue }
                $exeDir = Split-Path -Parent $p.ExecutablePath
                [void]$candidates.Add((Join-Path $exeDir 'resources\runtime\cli\bin\dsh.cmd'))
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
