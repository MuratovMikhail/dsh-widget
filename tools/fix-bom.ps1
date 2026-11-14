# Пересохраняет .ps1 в UTF-8 с BOM: Windows PowerShell 5.1 без BOM читает файл как ANSI
# и ломает кириллицу в строках.
param([Parameter(Mandatory = $true)][string[]]$Path)

foreach ($p in $Path) {
    $full = (Resolve-Path -LiteralPath $p).Path
    $text = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding($true)))
    $bytes = [System.IO.File]::ReadAllBytes($full)
    Write-Output ("{0}: BOM {1:X2}{2:X2}{3:X2}" -f (Split-Path -Leaf $full), $bytes[0], $bytes[1], $bytes[2])
}
