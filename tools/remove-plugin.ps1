# Убирает микроплагин dsh-widget-bridge из профиля DSH.
# Коды выхода: 0 — удалено или не было, 1 — ошибка.
[CmdletBinding()]
param(
    [string]$Profile = 'desktop',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
function Say([string]$text) { if (-not $Quiet) { Write-Output $text } }

. (Join-Path $PSScriptRoot 'dsh-common.ps1')

$bundle = '@local/dsh-widget-bridge'
$dshHome = Get-DshHome -Profile $Profile
if (-not $dshHome) {
    Say 'профиль DSH не найден'
    exit 0
}

$profileDir = Join-Path (Join-Path $dshHome 'profiles') $Profile
$manifest = Join-Path $profileDir 'package.json'
if (-not (Test-Path -LiteralPath $manifest)) {
    Say 'профиль не найден'
    exit 0
}

$data = $null
try { $data = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if (-not $data -or -not $data.dsh -or -not $data.dsh.profile) {
    Say 'не удалось прочитать package.json профиля'
    exit 1
}

$installed = @($data.dsh.profile.bundles) -contains $bundle
if (-not $installed) {
    Say 'плагин не установлен'
    exit 0
}

function Remove-PluginDirect([string]$profileDir) {
    $manifest = Join-Path $profileDir 'package.json'
    $data = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json

    $bundles = @($data.dsh.profile.bundles | Where-Object { $_ -ne $bundle })
    $data.dsh.profile | Add-Member -NotePropertyName bundles -NotePropertyValue $bundles -Force

    if ($data.PSObject.Properties['dependencies']) {
        $prop = $data.dependencies.PSObject.Properties[$bundle]
        if ($prop) { $data.dependencies.PSObject.Properties.Remove($bundle) }
    }

    $json = $data | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($manifest, $json, (New-Object Text.UTF8Encoding($false)))

    $dest = Join-Path $profileDir 'node_modules\@local\dsh-widget-bridge'
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
}

$cli = Get-DshCli -DshHome $dshHome
if ($cli) {
    Say ('удаляю через DSH CLI: ' + $cli)
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & cmd.exe /c "`"$cli`" plugin --profile $Profile remove `"$bundle`"" 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $oldEap

    $stillInstalled = $true
    try {
        $after = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
        $stillInstalled = @($after.dsh.profile.bundles) -contains $bundle
    } catch { }

    if ($code -eq 0 -and -not $stillInstalled) {
        Say 'плагин удалён'
        exit 0
    }
    Say ('CLI не удалил плагин, код ' + $code + '; удаляю напрямую')
    $out | Select-Object -Last 4 | ForEach-Object { Say ('  ' + $_) }
}

try {
    Remove-PluginDirect $profileDir
} catch {
    Say ('не удалось удалить плагин: ' + $_.Exception.Message)
    exit 1
}

Say 'плагин удалён'
exit 0
