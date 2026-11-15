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
$pluginVersion = '1.0.1'
. (Join-Path $PSScriptRoot 'dsh-common.ps1')

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

if (-not $Tgz) { $Tgz = Join-Path (Split-Path -Parent $PSScriptRoot) 'plugin\dsh-widget-bridge-1.0.1.tgz' }
if (-not (Test-Path -LiteralPath $Tgz)) {
    Say ('не найден пакет плагина: ' + $Tgz)
    exit 3
}

# Уже включён и нужной версии — ничего не делаем.
try {
    $data = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($data -and $data.dsh -and $data.dsh.profile -and (@($data.dsh.profile.bundles) -contains $bundle)) {
        $installedVersion = $null
        $pkgManifest = Join-Path $profileDir 'node_modules\@local\dsh-widget-bridge\package.json'
        if (Test-Path -LiteralPath $pkgManifest) {
            try { $installedVersion = [string](Get-Content -LiteralPath $pkgManifest -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { }
        }
        if ($installedVersion -eq $pluginVersion) {
            Say 'плагин уже установлен'
            exit 0
        }
        Say ('обновляю плагин: ' + $installedVersion + ' -> ' + $pluginVersion)
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
            $pkgManifest = Join-Path $profileDir 'node_modules\@local\dsh-widget-bridge\package.json'
            $installedVersion = $null
            if (Test-Path -LiteralPath $pkgManifest) {
                try { $installedVersion = [string](Get-Content -LiteralPath $pkgManifest -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { }
            }
            $ok = (@($data.dsh.profile.bundles) -contains $bundle) -and ($installedVersion -eq $pluginVersion)
        } catch { }
        if ($ok) {
            Say 'готово: виджет будет запускаться вместе с DSH'
            exit 0
        }
        Say 'CLI не обновил плагин до нужной версии, ставлю напрямую'
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
