# Пересобирает docs/preview-tray.png: иконки трея во всех состояниях + крупный ярлык.
# Запуск: powershell -ExecutionPolicy Bypass -File .\tools\make-tray-preview.ps1
[CmdletBinding()]
param([string]$Root = '')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

function Get-IconFrame([string]$path, [int]$size) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $count = [BitConverter]::ToUInt16($bytes, 4)
    for ($i = 0; $i -lt $count; $i++) {
        $o = 6 + $i * 16
        $w = [int]$bytes[$o]
        if ($w -eq 0) { $w = 256 }
        if ($w -ne $size) { continue }
        $len = [int][BitConverter]::ToUInt32($bytes, $o + 8)
        $off = [int][BitConverter]::ToUInt32($bytes, $o + 12)
        $ms = New-Object System.IO.MemoryStream($bytes, $off, $len)
        try {
            $img = [System.Drawing.Image]::FromStream($ms)
            $bmp = New-Object System.Drawing.Bitmap($img.Width, $img.Height)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.DrawImage($img, 0, 0, $img.Width, $img.Height)
            $g.Dispose(); $img.Dispose()
            return $bmp
        } finally { $ms.Dispose() }
    }
    return $null
}

$trayBase = Get-IconFrame (Join-Path $Root 'assets\DSHWidget-Tray.ico') 32
if (-not $trayBase) { $trayBase = Get-IconFrame (Join-Path $Root 'assets\DSHWidget-Tray.ico') 48 }
if (-not $trayBase) { throw 'не удалось прочитать кадр иконки трея' }
$appIcon = Get-IconFrame (Join-Path $Root 'assets\DSHWidget.ico') 256

$states = @(
    @{ Key = 'working';   Label = 'работает';   Color = @(76, 141, 255) },
    @{ Key = 'waiting';   Label = 'ждёт ответа'; Color = @(255, 176, 32) },
    @{ Key = 'subagents'; Label = 'субагенты';  Color = @(150, 128, 255) },
    @{ Key = 'done';      Label = 'готово';     Color = @(52, 199, 89) },
    @{ Key = 'error';     Label = 'ошибка';     Color = @(255, 107, 107) },
    @{ Key = 'idle';      Label = 'простой';    Color = @(110, 117, 128) }
)

$W = 640; $H = 220
$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
$g.Clear([System.Drawing.Color]::FromArgb(255, 21, 23, 28))

$labelFont = New-Object System.Drawing.Font('Segoe UI', 8)
$labelBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 148, 155, 166))
$bigFont = New-Object System.Drawing.Font('Segoe UI', 9)
$smallFont = New-Object System.Drawing.Font('Segoe UI', 7)

$tile = 64
for ($i = 0; $i -lt $states.Count; $i++) {
    $s = $states[$i]
    $x = 8 + $i * 78
    $y = 26
    $base = New-Object System.Drawing.Bitmap($tile, $tile)
    $bg = [System.Drawing.Graphics]::FromImage($base)
    $bg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $bg.DrawImage($trayBase, 0, 0, $tile, $tile)
    $color = [System.Drawing.Color]::FromArgb(255, $s.Color[0], $s.Color[1], $s.Color[2])
    $dot = 18
    $bx = $tile - $dot - 1
    $by = $tile - $dot - 1
    $ring = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 21, 23, 28))
    $bg.FillEllipse($ring, ($bx - 3), ($by - 3), ($dot + 6), ($dot + 6))
    $ring.Dispose()
    $dotBrush = New-Object System.Drawing.SolidBrush($color)
    $bg.FillEllipse($dotBrush, $bx, $by, $dot, $dot)
    $dotBrush.Dispose()
    $bg.Dispose()
    $g.DrawImage($base, $x, $y, $tile, $tile)
    $base.Dispose()
    $g.DrawString($s.Label, $labelFont, $labelBrush, [single]($x - 2), [single]($y + $tile + 8))
}

if ($appIcon) {
    $g.DrawImage($appIcon, 482, 22, 110, 110)
    $g.DrawString('ярлык / установщик', $bigFont, $labelBrush, [single]482, [single]140)
    $g.DrawString('DEEPSEEK HARNESS', $smallFont, $labelBrush, [single]482, [single]160)
}

$outDir = Join-Path $Root 'docs'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$path = Join-Path $outDir 'preview-tray.png'
$bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose(); $g.Dispose()
Write-Output $path
