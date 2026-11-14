<#
    Аудит архива перед отправкой людям.

    Распаковывает zip во временный каталог и ищет в нём личные данные:
    имя пользователя, домашние пути, токены, e-mail, идентификаторы сессий,
    номера баланса, метаданные картинок.

    Использование:
        powershell -ExecutionPolicy Bypass -File .\tools\audit-release.ps1
        powershell -ExecutionPolicy Bypass -File .\tools\audit-release.ps1 -Path C:\путь\к\архиву.zip
#>
[CmdletBinding()]
param(
    [string]$Path = ''
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $Path) {
    $candidate = Get-ChildItem $scriptDir -Filter 'dsh-widget-*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $candidate) { throw 'Архив не найден — сначала соберите его через release.ps1' }
    $Path = $candidate.FullName
}
$Path = (Resolve-Path -LiteralPath $Path).Path

Add-Type -AssemblyName System.IO.Compression.FileSystem

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-audit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$findings = New-Object System.Collections.Generic.List[string]
$checked = 0

# Что считаем личным. Шаблоны намеренно широкие.
$patterns = @(
    @{ name = 'имя пользователя'; re = [regex]::Escape($env:USERNAME) },
    @{ name = 'домашний путь'; re = 'C:\\Users\\[^\\"'']+' },
    @{ name = 'имя машины'; re = [regex]::Escape($env:COMPUTERNAME) },
    @{ name = 'API-ключ'; re = 'sk-[A-Za-z0-9]{16,}' },
    @{ name = 'e-mail'; re = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' },
    @{ name = 'id сессии'; re = 'session-[0-9a-f]{8}-' },
    @{ name = 'id субагента'; re = '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b' },
    @{ name = 'токен/секрет'; re = '(?i)(token|secret|password)\s*[:=]\s*["'']?[A-Za-z0-9_\-\.]{20,}' }
)

try {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Path, $tmp)

    $files = Get-ChildItem $tmp -Recurse -File
    Write-Output ('архив: ' + $Path)
    Write-Output ('файлов: ' + $files.Count + ', размер: ' + [math]::Round((Get-Item $Path).Length / 1KB, 1) + ' КБ')
    Write-Output ''

    foreach ($f in $files) {
        $rel = $f.FullName.Substring($tmp.Length).TrimStart('\')
        if ($f.Extension -in '.png', '.jpg', '.ico') {
            # В картинках смотрим печатаемые строки: метаданные, пути, подписи.
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
            foreach ($p in $patterns) {
                if ($p.re -eq '' ) { continue }
                if ($ascii -match $p.re) { $findings.Add($rel + ': ' + $p.name + ' в метаданных картинки') }
            }
            continue
        }

        $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
        $checked++
        # Публичная ссылка на GitHub-репозиторий — не личные данные.
        $scan = [regex]::Replace($text, 'https://github\.com/[A-Za-z0-9_.-]+/dsh-widget', '<public-repo>')
        foreach ($p in $patterns) {
            if ($scan -match $p.re) { $findings.Add($rel + ': ' + $p.name) }
        }
    }

    Write-Output ('проверено текстовых файлов: ' + $checked)
    if ($findings.Count -eq 0) {
        Write-Output 'РЕЗУЛЬТАТ: личных данных не найдено'
    } else {
        Write-Output 'РЕЗУЛЬТАТ: найдено потенциально личное —'
        $findings | Sort-Object -Unique | ForEach-Object { Write-Output ('  - ' + $_) }
        exit 1
    }
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
