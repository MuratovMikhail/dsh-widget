# Собирает один контактный лист со всеми состояниями виджета: docs/preview-states.png.
# Запуск: powershell -ExecutionPolicy Bypass -File .\tools\make-states-sheet.ps1
[CmdletBinding()]
param(
    [string]$Root = '',
    [ValidateSet('ru', 'en', 'zh-CN')]
    [string]$Lang = 'ru',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$ui = Join-Path $Root 'widget-ui.ps1'
if (-not (Test-Path -LiteralPath $ui)) { throw "Не найден widget-ui.ps1: $ui" }
if (-not $OutDir) { $OutDir = Join-Path (Join-Path $Root 'docs') $Lang }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$labels = @{
    ru = @('Работает · выполняет команду', 'Работает · думает', 'Ждёт ответа', 'Ждёт подтверждения', 'Работают субагенты', 'Готово', 'Ошибка', 'Простой · нет активных задач', 'Нет связи с движком')
    en = @('Working · running a command', 'Working · thinking', 'Waiting for an answer', 'Waiting for approval', 'Subagents at work', 'Done', 'Error', 'Idle · no active tasks', 'Engine offline')
    'zh-CN' = @('工作 · 执行命令', '工作 · 思考', '等待回答', '等待确认', '子代理工作', '完成', '错误', '空闲 · 没有活动任务', '引擎未连接')
}
$titles = @{ ru = 'Все состояния виджета'; en = 'All widget states'; 'zh-CN' = '组件全部状态' }
$accentLabels = @{ ru = 'акцент Windows'; en = 'Windows accent'; 'zh-CN' = 'Windows 强调色' }
$footers = @{ ru = '328×92 · тёмная тема · все значения демонстрационные'; en = '328×92 · dark theme · demo data'; 'zh-CN' = '328×92 · 深色主题 · 演示数据' }

$cases = @(
    @{ Demo = 'working';  Label = $labels[$Lang][0] },
    @{ Demo = 'thinking'; Label = $labels[$Lang][1] },
    @{ Demo = 'waiting';  Label = $labels[$Lang][2] },
    @{ Demo = 'approval'; Label = $labels[$Lang][3] },
    @{ Demo = 'subagents'; Label = $labels[$Lang][4] },
    @{ Demo = 'done';     Label = $labels[$Lang][5] },
    @{ Demo = 'error';    Label = $labels[$Lang][6] },
    @{ Demo = 'empty';    Label = $labels[$Lang][7] },
    @{ Demo = 'offline';  Label = $labels[$Lang][8] }
)

$images = @{}
foreach ($c in $cases) {
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $ui -SelfTest -Demo $c.Demo -DemoTheme dark -DemoLang $Lang | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ("selftest не удался: {0} (код {1})" -f $c.Demo, $LASTEXITCODE) }
    $path = Join-Path $Root ('selftest-' + $c.Demo + '-dark.png')
    if (-not (Test-Path -LiteralPath $path)) { throw "Нет снимка: $path" }
    $images[$c.Demo] = [System.Drawing.Image]::FromFile($path)
}

function Get-AccentColor {
    try {
        $t = [Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType = WindowsRuntime]
        $u = [Activator]::CreateInstance($t)
        $c = $u.GetColorValue([Windows.UI.ViewManagement.UIColorType]::Accent)
        return [System.Drawing.Color]::FromArgb(255, [int]$c.R, [int]$c.G, [int]$c.B)
    } catch { }
    try {
        $v = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -Name AccentColor -ErrorAction Stop
        $n = [uint32]$v.AccentColor
        return [System.Drawing.Color]::FromArgb(255, [int]($n -band 0xFF), [int](($n -shr 8) -band 0xFF), [int](($n -shr 16) -band 0xFF))
    } catch { }
    return [System.Drawing.Color]::FromArgb(255, 76, 141, 255)
}

$margin = 32
$gapX = 28
$cardW = 328
$cardH = 92
$labelH = 24
$rowGap = 28
$cols = 3
$rows = 3
$W = $margin * 2 + $cols * $cardW + ($cols - 1) * $gapX
$H = 100 + $rows * ($cardH + $labelH + $rowGap) + 12

$bmp = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g.Clear([System.Drawing.Color]::FromArgb(255, 11, 13, 18))

$white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 232, 234, 237))
$muted = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 154, 163, 175))
$dim = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 110, 117, 128))
$line = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 39, 44, 54), 1)

$fontKicker = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
$fontTitle = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$fontLabel = New-Object System.Drawing.Font('Segoe UI', 9.5)
$fontSmall = New-Object System.Drawing.Font('Segoe UI', 8)

$g.DrawString('DSH WIDGET', $fontKicker, $muted, [single]$margin, [single]18)
$g.DrawString($titles[$Lang], $fontTitle, $white, [single]$margin, [single]34)
$g.DrawLine($line, $margin, 82, $W - $margin, 82)

$accent = Get-AccentColor
$accentText = $accentLabels[$Lang] + '  #' + $accent.R.ToString('X2') + $accent.G.ToString('X2') + $accent.B.ToString('X2')
$textSize = $g.MeasureString($accentText, $fontSmall)
$accentX = $W - $margin - [int]$textSize.Width
$accentBrush = New-Object System.Drawing.SolidBrush($accent)
$g.FillEllipse($accentBrush, [single]($accentX - 18), [single]46.5, [single]10, [single]10)
$g.DrawString($accentText, $fontSmall, $muted, [single]$accentX, [single]46)

for ($i = 0; $i -lt $cases.Count; $i++) {
    $col = $i % $cols
    $row = [int][math]::Floor($i / $cols)
    $x = $margin + $col * ($cardW + $gapX)
    $y = 100 + $row * ($cardH + $labelH + $rowGap)
    $img = $images[$cases[$i].Demo]
    $g.DrawImage($img, $x, $y, $cardW, $cardH)
    $g.DrawString($cases[$i].Label, $fontLabel, $muted, [single]($x + 2), [single]($y + $cardH + 4))
}

$g.DrawLine($line, $margin, $H - 30, $W - $margin, $H - 30)
$g.DrawString($footers[$Lang], $fontSmall, $dim, [single]$margin, [single]($H - 22))

$outDir = $OutDir
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$out = Join-Path $outDir 'preview-states.png'
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)

$g.Dispose(); $bmp.Dispose()
$white.Dispose(); $muted.Dispose(); $dim.Dispose(); $line.Dispose()
$accentBrush.Dispose()
$fontKicker.Dispose(); $fontTitle.Dispose(); $fontLabel.Dispose(); $fontSmall.Dispose()
foreach ($img in $images.Values) { $img.Dispose() }
Get-ChildItem -LiteralPath $Root -Filter 'selftest-*.png' -File | Remove-Item -Force
Write-Output $out
