#requires -Version 5.1
<#
    DSH Widget — виджет состояния DeepSeek Harness для Windows 10/11.

    Показывает, чем занят агент прямо сейчас (думает / выполняет команду / ждёт ответа),
    сколько идёт ход и сколько шагов сделано, а когда работа закончена — присылает
    всплывающее уведомление.

    Данные берутся из локального движка widget-engine.js (порт по умолчанию 45871),
    который читает журналы сессий ~/.dsh/sessions и ничего не меняет в самом DSH.

    Запуск: см. start-widget.vbs / install.ps1
#>

[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$SelfTest,
    [switch]$ShowSettings,
    [switch]$ShowAbout,
    [switch]$SettingsSave,
    [ValidateSet('working', 'thinking', 'done', 'waiting', 'approval', 'error', 'idle', 'subagents', 'list', 'many', 'empty', 'offline')]
    [string]$Demo = '',
    [ValidateSet('', 'system', 'light', 'dark')]
    [string]$DemoTheme = '',
    [ValidateSet('', 'en', 'ru', 'zh-CN')]
    [string]$DemoLang = ''
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:configPath = Join-Path $scriptDir 'config.json'
$script:enginePath = Join-Path $scriptDir 'widget-engine.js'
$script:appVersion = '1.0.3'
$script:author = 'Муратов Михаил'
# Заполним, когда появится доступ к GitHub (и будет известен точный URL репозитория).
$script:repoUrl = 'https://github.com/MuratovMikhail/dsh-widget'

function Write-WidgetLog([string]$message) {
    try {
        $path = Join-Path $scriptDir 'widget.log'
        # Не даём логу расти без предела: после 256 КБ начинаем новый файл.
        if (Test-Path -LiteralPath $path) {
            if ((Get-Item -LiteralPath $path).Length -gt 262144) {
                Move-Item -LiteralPath $path -Destination ($path + '.1') -Force -ErrorAction SilentlyContinue
            }
        }
        $line = (Get-Date).ToString('HH:mm:ss') + ' ' + $message
        Add-Content -LiteralPath $path -Value $line -ErrorAction SilentlyContinue
    } catch { }
}

# ------------------------------------------------------------------ конфиг

$defaults = [ordered]@{
    port               = 45871
    sound              = $true
    soundMode          = 'builtin'
    theme              = 'system'
    opacity            = 100
    accentBar          = $true
    autostart          = $false
    launchMode         = ''
    exitWhenDshClosedMin = 10
    x                  = $null
    y                  = $null
    balance            = $true
    balanceSource      = 'account'
    balanceApiKey      = ''
    balanceIntervalSec = 300
    pinnedSessionId    = $null
    topMost            = $true
    doneVisibleSec     = 180
    maxSessions        = 3
    language           = 'auto'
}

$script:config = [ordered]@{}
foreach ($k in $defaults.Keys) { $script:config[$k] = $defaults[$k] }
if (Test-Path -LiteralPath $script:configPath) {
    try {
        $loaded = Get-Content -LiteralPath $script:configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in $defaults.Keys) {
            if ($null -ne $loaded.$k) { $script:config[$k] = $loaded.$k }
        }
    } catch { }
}
if ($Port -gt 0) { $script:config.port = $Port }
$script:port = [int]$script:config.port

function Save-Config {
    try {
        # $script:config содержит только ключи из $defaults, поэтому мусор из старых версий в файл не попадает.
        $json = $script:config | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($script:configPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# ------------------------------------------------------------------ язык
# Строки UI переведены по исходному русскому тексту. Так проще не разъехаться
# с уже существующим интерфейсом; en.json/zh-CN.json — словари «русский → перевод».

$script:localeDir = Join-Path $scriptDir 'locale'

function Resolve-UiLanguage([string]$value) {
    if ($value -in @('en', 'ru', 'zh-CN')) { return $value }
    $name = ''
    try { $name = [System.Globalization.CultureInfo]::CurrentUICulture.Name } catch { }
    if ($name -match '^ru') { return 'ru' }
    # Традиционный китайский намеренно не подхватываем: перевода zh-TW нет.
    if ($name -match '^zh-(CN|Hans|SG)') { return 'zh-CN' }
    return 'en'
}

function Read-LocaleMap([string]$code) {
    $map = @{}
    $path = Join-Path $script:localeDir ($code + '.json')
    if (-not (Test-Path -LiteralPath $path)) { return $map }
    try {
        $obj = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $map[[string]$p.Name] = [string]$p.Value }
    } catch { }
    return $map
}

$script:language = Resolve-UiLanguage $(if ($DemoLang) { $DemoLang } else { [string]$script:config.language })
$script:localeMap = Read-LocaleMap $script:language
$script:fallbackMap = if ($script:language -ne 'en') { Read-LocaleMap 'en' } else { @{} }

function T([string]$text) {
    if (-not $text) { return $text }
    $value = $text
    if ($script:localeMap.ContainsKey($text)) {
        $value = [string]$script:localeMap[$text]
    } elseif ($script:language -ne 'ru' -and $script:fallbackMap.ContainsKey($text)) {
        $value = [string]$script:fallbackMap[$text]
    }
    if ($args.Count -gt 0) {
        try { return [string]::Format($value, $args) } catch { return $value }
    }
    return $value
}

# ------------------------------------------------------------------ Win32 / WinForms

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not ('DshCardForm' -as [type])) {
    Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition @'
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class DshCardForm : Form
{
    public DshCardForm()
    {
        this.DoubleBuffered = true;
        this.SetStyle(
            ControlStyles.OptimizedDoubleBuffer |
            ControlStyles.AllPaintingInWmPaint |
            ControlStyles.UserPaint |
            ControlStyles.Opaque |
            ControlStyles.ResizeRedraw,
            true);
        this.FormBorderStyle = FormBorderStyle.None;
        this.ShowInTaskbar = false;
        this.TopMost = true;
        this.StartPosition = FormStartPosition.Manual;
        this.MinimizeBox = false;
        this.MaximizeBox = false;
        this.Text = "DeepSeek Harness";
        this.AutoScaleMode = AutoScaleMode.None;
    }

    // Стиль Opaque отключает стандартную заливку фона: иначе WinForms на мгновение
    // рисует окно белым, прежде чем отработает наш Paint.
    protected override void OnPaintBackground(PaintEventArgs e)
    {
        e.Graphics.Clear(this.BackColor);
    }
}

public static class DshNative
{
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("dwmapi.dll", PreserveSig = true)] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool attachFlag);
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    // Перетаскивание безрамочного окна за любую его точку.
    public static void BeginDrag(IntPtr h)
    {
        ReleaseCapture();
        SendMessage(h, 0xA1, new IntPtr(2), IntPtr.Zero); // WM_NCLBUTTONDOWN, HTCAPTION
    }

    // Windows не даёт чужому процессу забрать фокус: пробуем несколько известных обходов.
    public static bool ForceForeground(IntPtr h)
    {
        if (h == IntPtr.Zero) return false;
        try
        {
            if (IsIconic(h)) ShowWindowAsync(h, 9);
            SetWindowPos(h, new IntPtr(0), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040); // NOSIZE|NOMOVE|SHOWWINDOW
            if (SetForegroundWindow(h) && GetForegroundWindow() == h) return true;

            uint pid;
            uint targetThread = GetWindowThreadProcessId(h, out pid);
            uint me = GetCurrentThreadId();
            bool attached = AttachThreadInput(me, targetThread, true);
            try
            {
                BringWindowToTop(h);
                SetForegroundWindow(h);
            }
            finally
            {
                if (attached) AttachThreadInput(me, targetThread, false);
            }
            if (GetForegroundWindow() == h) return true;

            // имитация нажатия Alt снимает «замок» фокуса
            keybd_event(0x12, 0, 0, UIntPtr.Zero);
            keybd_event(0x12, 0, 2, UIntPtr.Zero);
            SetForegroundWindow(h);
            if (GetForegroundWindow() == h) return true;

            SwitchToThisWindow(h, true);
            return GetForegroundWindow() == h;
        }
        catch
        {
            return false;
        }
    }

    // Ищет видимое окно, чей заголовок заканчивается суффиксом и содержит фрагмент.
    public static IntPtr FindWindowByTitle(string suffix, string contains)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            int len = GetWindowTextLength(h);
            if (len <= 0) return true;
            System.Text.StringBuilder sb = new System.Text.StringBuilder(len + 2);
            GetWindowText(h, sb, sb.Capacity);
            string title = sb.ToString();
            if (suffix != null && !title.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) return true;
            if (contains != null && title.IndexOf(contains, StringComparison.OrdinalIgnoreCase) < 0) return true;
            found = h;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    // Список окон, в заголовке которых есть «DeepSeek Harness»: "hwnd|visible|title".
    // Нужен, чтобы UI сам решал, какое окно подходит, и мог залогировать кандидатов.
    public static string[] ListDshWindows()
    {
        System.Collections.Generic.List<string> list = new System.Collections.Generic.List<string>();
        EnumWindows(delegate (IntPtr h, IntPtr l)
        {
            int len = GetWindowTextLength(h);
            if (len <= 0) return true;
            System.Text.StringBuilder sb = new System.Text.StringBuilder(len + 2);
            GetWindowText(h, sb, sb.Capacity);
            string title = sb.ToString();
            if (title.IndexOf("DeepSeek Harness", StringComparison.OrdinalIgnoreCase) < 0) return true;
            list.Add(h.ToInt64().ToString() + "|" + (IsWindowVisible(h) ? "1" : "0") + "|" + title);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
    [DllImport("gdi32.dll")] public static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int width, int height);
    [DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr hwnd, IntPtr region, bool redraw);

    // Скругление углов средствами DWM есть только в Windows 11.
    // Возвращает true, если система сама скруглила окно.
    public static bool RoundCorners(IntPtr hwnd)
    {
        try
        {
            // DWMWCP_ROUND появился только в Windows 11 (build 22000). На Windows 10
            // атрибут может вернуть успех, но окно останется квадратным — тогда нужен
            // запасной путь через SetWindowRgn.
            if (Environment.OSVersion.Version.Build < 22000) return false;

            int pref = 2; // DWMWCP_ROUND
            int hr = DwmSetWindowAttribute(hwnd, 33, ref pref, sizeof(int));
            if (hr == 0) return true;

            int legacy = 2; // DWMWA_USE_IMMERSIVE_DARK_MODE на старых сборках
            DwmSetWindowAttribute(hwnd, 20, ref legacy, sizeof(int));
            return false;
        }
        catch
        {
            return false;
        }
    }

    // Запасной путь для Windows 10: обрезаем окно скруглённым регионом.
    public static void ApplyRoundRegion(IntPtr hwnd, int width, int height, int radius)
    {
        try
        {
            IntPtr rgn = CreateRoundRectRgn(0, 0, width + 1, height + 1, radius, radius);
            SetWindowRgn(hwnd, rgn, true);
        }
        catch { }
    }
}

// Тёмное оформление выпадающих списков: системный белый фон здесь не годится.
public class DshDarkColorTable : ProfessionalColorTable
{
    static readonly Color Bg = Color.FromArgb(255, 29, 30, 34);
    static readonly Color Hover = Color.FromArgb(255, 45, 48, 56);
    public override Color ToolStripDropDownBackground { get { return Bg; } }
    public override Color ImageMarginGradientBegin { get { return Bg; } }
    public override Color ImageMarginGradientMiddle { get { return Bg; } }
    public override Color ImageMarginGradientEnd { get { return Bg; } }
    public override Color MenuItemSelected { get { return Hover; } }
    public override Color MenuItemBorder { get { return Hover; } }
    public override Color MenuBorder { get { return Color.FromArgb(255, 58, 61, 70); } }
}

public class DshDarkMenuRenderer : ToolStripProfessionalRenderer
{
    public DshDarkMenuRenderer() : base(new DshDarkColorTable()) { }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        e.TextColor = Color.FromArgb(255, 230, 232, 238);
        base.OnRenderItemText(e);
    }
}
'@
}

# Не объявляем процесс DPI-aware: геометрия виджета фиксированная (328 px), и при
# масштабе 125–150 % системное масштабирование Windows надёжнее, чем обрезанный текст.
# На 100 % разницы нет; на остальных масштабах карточка чуть мягче, но не ломается.
# try { [DshNative]::SetProcessDPIAware() | Out-Null } catch { }
try { [DshNative]::SetCurrentProcessExplicitAppUserModelID('DSH.Widget') | Out-Null } catch { }

# ------------------------------------------------------------------ однократный запуск

$createdNew = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\DshWidgetUi', [ref]$createdNew)
if (-not $createdNew) {
    if (-not $SelfTest) { Write-WidgetLog 'уже запущен: второй экземпляр выходит'; return }
}

# ------------------------------------------------------------------ поиск Node и движка

# Аккуратный выход: гасим движок, убираем иконку и файл состояния.
function Exit-Widget {
    try { if ($script:engineProc -and -not $script:engineProc.HasExited) { $script:engineProc.Kill() } } catch { }
    try { $tray.Visible = $false; $tray.Dispose() } catch { }
    Remove-RuntimeState
    try { $form.Close() } catch { }
    [System.Windows.Forms.Application]::Exit()
}

function Restart-Widget {
    try {
        $helper = Join-Path $scriptDir 'tools\restart-widget.ps1'
        if (Test-Path -LiteralPath $helper) {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $helper + '"')) -WindowStyle Hidden | Out-Null
        } else {
            Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + (Join-Path $scriptDir 'start-widget.vbs') + '"') | Out-Null
        }
    } catch { }
    Exit-Widget
}
function Get-NodePath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe'),
        (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$script:nodePath = Get-NodePath
$script:engineProc = $null

function Test-Engine {
    $wc = $null
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Proxy = $null
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $raw = $wc.DownloadString("http://127.0.0.1:$($script:port)/health")
        return ($raw -match '"ok"\s*:\s*true')
    } catch { return $false } finally { if ($wc) { $wc.Dispose() } }
}

function Start-Engine {
    if (-not $script:nodePath) { return $false }
    if ($script:engineProc -and -not $script:engineProc.HasExited) { return $true }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:nodePath
        $psi.Arguments = '"' + $script:enginePath + '" --port ' + $script:port + ' --parent-pid ' + $PID
        $psi.WorkingDirectory = $scriptDir
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $script:engineProc = [System.Diagnostics.Process]::Start($psi)
        Start-Sleep -Milliseconds 400
        $ok = Test-Engine
        if (-not $ok -and $script:engineProc.HasExited) {
            Write-WidgetLog ('engine exit code ' + $script:engineProc.ExitCode + ' (node ' + $script:nodePath + ')')
        }
        return $ok
    } catch { return $false }
}

# Демо-снимкам движок не нужен: не плодим node.exe на каждый кадр превью.
if (-not ($SelfTest -and ($Demo -or $ShowSettings))) {
    if (-not (Test-Engine)) { Start-Engine | Out-Null }
}

# ------------------------------------------------------------------ шрифты и цвета

function Get-FirstFont([string[]]$names, [single]$size, $style) {
    $installed = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
    foreach ($n in $names) {
        if ($installed -contains $n) { return New-Object System.Drawing.Font($n, $size, $style) }
    }
    return New-Object System.Drawing.Font('Segoe UI', $size, $style)
}

$uiFontNames = @('Segoe UI Variable Small Text', 'Segoe UI Variable Text', 'Segoe UI')
$statusFontNames = @('Segoe UI Variable Display', 'Segoe UI Semibold', 'Segoe UI')
if ($script:language -eq 'zh-CN') {
    $uiFontNames = @('Microsoft YaHei UI', 'Microsoft YaHei') + $uiFontNames
    $statusFontNames = @('Microsoft YaHei UI', 'Microsoft YaHei') + $statusFontNames
}
$script:fontLabel  = Get-FirstFont $uiFontNames 7.5 ([System.Drawing.FontStyle]::Regular)
$script:fontTitle  = Get-FirstFont $uiFontNames 9.5 ([System.Drawing.FontStyle]::Regular)
$script:fontStatus = Get-FirstFont $statusFontNames 14 ([System.Drawing.FontStyle]::Bold)
$script:fontDetail = Get-FirstFont $uiFontNames 8.5 ([System.Drawing.FontStyle]::Regular)
try {
    $script:fontGear = New-Object System.Drawing.Font('Segoe MDL2 Assets', 16, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
} catch {
    $script:fontGear = Get-FirstFont @('Segoe UI Symbol', 'Segoe UI') 12 ([System.Drawing.FontStyle]::Regular)
}
$script:gearFormat = New-Object System.Drawing.StringFormat
$script:gearFormat.Alignment = [System.Drawing.StringAlignment]::Center
$script:gearFormat.LineAlignment = [System.Drawing.StringAlignment]::Center

# ------------------------------------------------------------------ состояние запуска

# runtime.json нужен внешним скриптам (остановка, удаление), чтобы гасить именно наши процессы.
function Save-RuntimeState {
    try {
        $state = [ordered]@{ ui = $PID; engine = $null; started = (Get-Date).ToString('o') }
        if ($script:engineProc -and -not $script:engineProc.HasExited) { $state.engine = $script:engineProc.Id }
        $json = $state | ConvertTo-Json
        [System.IO.File]::WriteAllText((Join-Path $scriptDir 'runtime.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Remove-RuntimeState {
    try { Remove-Item -LiteralPath (Join-Path $scriptDir 'runtime.json') -Force -ErrorAction SilentlyContinue } catch { }
}

# ------------------------------------------------------------------ тема

$script:palettes = @{
    dark  = @{
        bg = @(21, 23, 28); hover = @(26, 29, 35); border = @(44, 48, 58)
        text = @(232, 234, 237); muted = @(148, 155, 166); dim = @(110, 117, 128)
        track = @(38, 42, 51); field = @(32, 36, 44); button = @(44, 48, 58)
        working = @(76, 141, 255); subagents = @(150, 128, 255); waiting = @(255, 176, 32)
        done = @(52, 199, 89); error = @(255, 107, 107); idle = @(110, 117, 128)
    }
    light = @{
        bg = @(246, 247, 249); hover = @(240, 242, 246); border = @(212, 216, 224)
        text = @(26, 29, 35); muted = @(88, 95, 108); dim = @(128, 135, 148)
        track = @(224, 227, 233); field = @(255, 255, 255); button = @(234, 236, 240)
        working = @(41, 98, 214); subagents = @(112, 84, 224); waiting = @(190, 128, 16)
        done = @(26, 150, 66); error = @(198, 40, 40); idle = @(128, 135, 148)
    }
}

function Get-SystemAccentColor {
    # Официальный источник — UISettings (WinRT): ровно то значение, что Windows считает акцентом.
    try {
        if (-not $script:uiSettings) {
            $script:uiSettingsType = [Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType = WindowsRuntime]
            $script:uiColorType = [Windows.UI.ViewManagement.UIColorType, Windows.UI.ViewManagement, ContentType = WindowsRuntime]
            $script:uiSettings = [Activator]::CreateInstance($script:uiSettingsType)
        }
        $c = $script:uiSettings.GetColorValue($script:uiColorType::Accent)
        return [System.Drawing.Color]::FromArgb(255, [int]$c.R, [int]$c.G, [int]$c.B)
    } catch { }
    # Запасные пути: DWM AccentColor (0xAABBGGRR), затем классический цвет выделения.
    try {
        $v = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\DWM' -Name AccentColor -ErrorAction Stop
        $n = [uint32]$v.AccentColor
        return [System.Drawing.Color]::FromArgb(255, [int]($n -band 0xFF), [int](($n -shr 8) -band 0xFF), [int](($n -shr 16) -band 0xFF))
    } catch { }
    try {
        $c = Get-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name Hilight -ErrorAction Stop
        $parts = ([string]$c.Hilight).Split(' ') | Where-Object { $_ -ne '' }
        if ($parts.Count -eq 3) {
            return [System.Drawing.Color]::FromArgb(255, [int]$parts[0], [int]$parts[1], [int]$parts[2])
        }
    } catch { }
    return $null
}

function Get-SystemTheme {
    try {
        $v = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        if ([int]$v.AppsUseLightTheme -eq 1) { return 'light' }
        return 'dark'
    } catch {
        return 'dark'
    }
}

# 'system' | 'light' | 'dark' из конфига -> фактическая тема
function Get-EffectiveTheme {
    $mode = [string]$script:config.theme
    if ($mode -eq 'light' -or $mode -eq 'dark') { return $mode }
    return (Get-SystemTheme)
}

# --- контраст акцента: акцент Windows бывает пастельным/серым, а название и спиннер
# должны читаться на фоне карточки в любой теме.

function Get-RelativeLuminance([System.Drawing.Color]$c) {
    $linear = {
        param([double]$v)
        $s = $v / 255.0
        if ($s -le 0.03928) { return ($s / 12.92) }
        return [math]::Pow((($s + 0.055) / 1.055), 2.4)
    }
    $r = & $linear $c.R
    $g = & $linear $c.G
    $b = & $linear $c.B
    return (0.2126 * $r + 0.7152 * $g + 0.0722 * $b)
}

function Get-ContrastRatio([System.Drawing.Color]$a, [System.Drawing.Color]$b) {
    $la = Get-RelativeLuminance $a
    $lb = Get-RelativeLuminance $b
    $hi = [math]::Max($la, $lb)
    $lo = [math]::Min($la, $lb)
    return (($hi + 0.05) / ($lo + 0.05))
}

function Mix-Color([System.Drawing.Color]$a, [System.Drawing.Color]$b, [double]$t) {
    return [System.Drawing.Color]::FromArgb(
        255,
        [int][math]::Round($a.R + ($b.R - $a.R) * $t),
        [int][math]::Round($a.G + ($b.G - $a.G) * $t),
        [int][math]::Round($a.B + ($b.B - $a.B) * $t))
}

# Подмешивает белый/чёрный, пока контраст с фоном не достигнет target.
function Get-ReadableAccent([System.Drawing.Color]$accent, [System.Drawing.Color]$bg, [double]$target) {
    if ((Get-ContrastRatio $accent $bg) -ge $target) { return $accent }
    $toward = if ((Get-RelativeLuminance $bg) -lt 0.5) {
        [System.Drawing.Color]::White
    } else {
        [System.Drawing.Color]::Black
    }
    for ($i = 1; $i -le 10; $i++) {
        $candidate = Mix-Color $accent $toward ($i / 10.0)
        if ((Get-ContrastRatio $candidate $bg) -ge $target) { return $candidate }
    }
    return $toward
}

function Set-ThemePalette([string]$theme) {
    $p = $script:palettes[$theme]
    if (-not $p) { $p = $script:palettes['dark']; $theme = 'dark' }

    $rgb = { param($a) [System.Drawing.Color]::FromArgb(255, $a[0], $a[1], $a[2]) }
    $script:theme = $theme
    $script:clrBg      = & $rgb $p.bg
    $script:clrBgHover = & $rgb $p.hover
    $script:clrBorder  = & $rgb $p.border
    $script:clrText    = & $rgb $p.text
    $script:clrMuted   = & $rgb $p.muted
    $script:clrDim     = & $rgb $p.dim
    $script:clrTrack   = & $rgb $p.track
    $script:clrField   = & $rgb $p.field
    $script:clrButton  = & $rgb $p.button
    $script:accentByState = @{
        working   = & $rgb $p.working
        subagents = & $rgb $p.subagents
        waiting   = & $rgb $p.waiting
        done      = & $rgb $p.done
        error     = & $rgb $p.error
        idle      = & $rgb $p.idle
        stale     = & $rgb $p.idle
        offline   = & $rgb $p.idle
    }

    # В режиме контрастных цветов Windows и при включённом акценте красим рабочие
    # состояния, спиннер и название сессии системным акцентом.
    $script:highContrast = [bool][System.Windows.Forms.SystemInformation]::HighContrast
    $useAccent = $script:highContrast -or [bool]$script:config.accentBar
    $script:accentColor = $null
    $script:accentSpinner = $script:accentByState['working']
    $script:clrTitle = $script:clrMuted
    if ($useAccent) {
        $accent = Get-SystemAccentColor
        if ($accent) {
            $script:accentColor = $accent
            # Спиннеру достаточно 3:1, названию (мелкий текст) — 4.5:1.
            $script:accentSpinner = Get-ReadableAccent $accent $script:clrBg 3.0
            $script:clrTitle = Get-ReadableAccent $accent $script:clrBg 4.5
            $script:accentByState['working'] = $script:accentSpinner
        }
    }
}

Set-ThemePalette (Get-EffectiveTheme)


# ------------------------------------------------------------------ состояние

$script:snap = $null
$script:engineOk = $false
$script:dshRunning = $true
$script:lastDshCheck = [DateTime]::MinValue
$script:lastThemeCheck = [DateTime]::MinValue
$script:lastSnapAt = Get-Date
$script:startedAtMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$script:lastCompletionAt = 0
$script:completionSeen = $false
$script:lastDshTitle = ''
$script:lastDshTitleAt = [DateTime]::MinValue
$script:lastBusyAt = Get-Date
$script:emptySince = $null
$script:dshGoneSince = $null
$script:anim = 0
$script:hoverRow = $null
$script:gearHover = $false
$script:collapseHover = $false
$script:dragging = $false
$script:dragMoved = $false
$script:dragStart = $null
$script:formStart = $null
$script:cardVisible = $true
$script:manualShow = $false
$script:rows = @()
$script:overflowCount = 0
$script:projectLabel = 'DSH'
$script:viewKey = ''

$script:soundPlayer = $null
$script:customSoundBroken = $false

$CARD_W = 328
$CARD_H = 92
$HEADER_H = 26
$BLOCK_H = 58
$FOOTER_H = 14

# ------------------------------------------------------------------ текст

function Get-StatusText($primary, $engineOk) {
    if (-not $engineOk) { return @{ status = (T 'Нет связи с движком'); detail = (T 'Перезапускаю…'); state = 'offline' } }
    if (-not $primary) {
        if ($script:dshRunning) { return @{ status = (T 'Нет активных задач'); detail = (T 'Запустите сессию в DSH'); state = 'idle' } }
        return @{ status = (T 'DeepSeek Harness не запущен'); detail = (T 'Откройте приложение'); state = 'idle' }
    }
    return (Get-SessionText $primary)
}

function Get-SessionTextRaw($s) {
    $act = $s.activity
    switch ([string]$s.status) {
        'working' {
            if ($act.kind -eq 'tool') {
                $verb = switch ($act.tool) {
                    'pwsh' { 'Выполняет команду' }
                    'bash' { 'Выполняет команду' }
                    'read' { 'Читает файл' }
                    'write' { 'Пишет файл' }
                    'edit' { 'Правит файл' }
                    'str_replace_editor' { 'Правит файл' }
                    'grep' { 'Ищет в файлах' }
                    'glob' { 'Ищет файлы' }
                    'web_search' { 'Ищет в интернете' }
                    'web_fetch' { 'Открывает страницу' }
                    'subagent' { 'Запустил субагента' }
                    'subagent_fork' { 'Запустил субагента' }
                    'present' { 'Готовит результат' }
                    'todo_write' { 'Обновляет план' }
                    'workflow' { 'Выполняет сценарий' }
                    'skill' { 'Загружает навык' }
                    default { 'Работает' }
                }
                return @{ status = (T $verb); detail = [string]$act.detail; state = 'working' }
            }
            if ($act.kind -eq 'question' -or $act.kind -eq 'approval') {
                # Страховка для старых снимков: статус ещё working, но агент уже ждёт.
                return (Get-WaitingText $act)
            }
            if ($act.kind -eq 'thinking') { return @{ status = (T 'Думает…'); detail = ''; state = 'working' } }
            return @{ status = (T 'Думает…'); detail = ''; state = 'working' }
        }
        'waiting' { return (Get-WaitingText $act) }
        'subagents' {
            $n = 0
            if ($s.subagents) { $n = [int]$s.subagents.active }
            $word = Get-SubagentWord $n
            $detail = "$n $word"
            if ($s.subagents -and $s.subagents.top -and $s.subagents.top.detail) {
                $detail = "$n $word · " + $s.subagents.top.detail
            }
            return @{ status = (T 'Работают субагенты'); detail = $detail; state = 'subagents' }
        }
        'done' {
            $preview = ''
            if ($s.done) { $preview = [string]$s.done.preview }
            if ($s.done -and $s.done.ok -eq $false) {
                if (-not $preview) { $preview = T 'Ход завершился с ошибкой' }
                return @{ status = (T 'Остановлено'); detail = $preview; state = 'error' }
            }
            return @{ status = (T 'Готово'); detail = $preview; state = 'done' }
        }
        'stale' {
            return @{ status = (T 'Пауза'); detail = (T 'Ход прерван — DSH был закрыт'); state = 'stale' }
        }
        default {
            return @{ status = (T 'Нет активных задач'); detail = ''; state = 'idle' }
        }
    }
}

# Ожидание ответа: вопрос агента или подтверждение инструмента.
function Get-WaitingText($act) {
    $detail = ''
    if ($act -and $act.detail) { $detail = [string]$act.detail }
    if ($act -and $act.kind -eq 'approval') {
        $tool = [string]$act.tool
        if ($tool -and $detail) { $detail = $tool + ' · ' + $detail }
        elseif ($tool) { $detail = $tool }
        return @{ status = (T 'Ждёт подтверждения'); detail = $detail; state = 'waiting' }
    }
    if ($detail) { $detail = (T '«') + $detail + (T '»') }
    return @{ status = (T 'Ждёт вашего ответа'); detail = $detail; state = 'waiting' }
}

function Get-SessionText($s) {
    return (Get-SessionTextRaw $s)
}

# Компактный прогресс плана: «2/5». Показывается, только пока план не выполнен.
function Get-PlanChip($s) {
    if ($s -and $s.todos -and ([int]$s.todos.total -gt 0) -and ([int]$s.todos.done -lt [int]$s.todos.total)) {
        return ([string]$s.todos.done + '/' + [string]$s.todos.total)
    }
    return ''
}

function Get-SessionMeta($s) {
    switch ([string]$s.status) {
        'working' {
            if ($null -eq $s.elapsedMs) { return '' }
            $elapsed = [double]$s.elapsedMs + ((Get-Date) - $script:lastSnapAt).TotalMilliseconds
            return (Format-Duration $elapsed)
        }
        'done' {
            if ($s.done -and $s.done.durationMs) { return (T 'за {0}' (Format-Duration ([double]$s.done.durationMs))) }
            return ''
        }
        default { return '' }
    }
}

# Один блок карточки: значок состояния, заголовок, время, статус, деталь и чип плана.
function Draw-Row($g, $row, [int]$top) {
    if ($script:hoverRow -eq [int]$row.index) {
        $hoverBrush = New-Object System.Drawing.SolidBrush($script:clrBgHover)
        $hoverPath = New-RoundedPath 4 ($top + 1) ($CARD_W - 8) 56 8
        $g.FillPath($hoverBrush, $hoverPath)
        $hoverPath.Dispose(); $hoverBrush.Dispose()
    }

    $stateKey = [string]$row.state
    $accent = $script:accentByState[$stateKey]
    if (-not $accent) { $accent = $script:clrDim }
    Draw-StateGlyph $g $stateKey 22 ($top + 30.5) $accent

    Draw-TextLine $g ([string]$row.title) $script:fontTitle $script:clrTitle 16 ($top + 2) ($CARD_W - 106) 16 $false
    if ($row.meta) { Draw-TextLine $g ([string]$row.meta) $script:fontLabel $script:clrMuted ($CARD_W - 76) ($top + 2) 60 16 $true }

    $statusW = $CARD_W - 50
    if ($row.plan) {
        Draw-TextLine $g ([string]$row.plan) $script:fontLabel $script:clrMuted ($CARD_W - 60) ($top + 17) 44 22 $true
        $statusW = $CARD_W - 98
    }
    Draw-TextLine $g ([string]$row.status) $script:fontStatus $script:clrText 34 ($top + 17) $statusW 22 $false
    if ($row.detail) {
        Draw-TextLine $g ([string]$row.detail) $script:fontDetail $script:clrMuted 34 ($top + 43) ($CARD_W - 50) 14 $false
    }
}

function Draw-StateGlyph($g, [string]$state, [single]$cx, [single]$cy, $color) {
    switch ($state) {
        'working' { Draw-Spinner $g $cx $cy $color }
        'subagents' { Draw-Spinner $g $cx $cy $color }
        'waiting' { Draw-HaloDot $g $cx $cy $color $true }
        'done' { Draw-HaloDot $g $cx $cy $color $false }
        'error' { Draw-HaloDot $g $cx $cy $color $false }
        default { Draw-FilledDot $g $cx $cy $color 3.5 }
    }
}

# Крутящийся кружок: дуга 300° в цвете акцента, оборот примерно раз в секунду.
function Draw-Spinner($g, [single]$cx, [single]$cy, $color) {
    $r = [single]5
    $pen = New-Object System.Drawing.Pen($color, 2.2)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $start = [single](($script:anim * 18) % 360)
    $g.DrawArc($pen, [single]($cx - $r), [single]($cy - $r), [single]($r * 2), [single]($r * 2), $start, 300)
    $pen.Dispose()
}

# Единый значок для ожидания/готово/ошибки: цветная точка с мягким ореолом.
# У ожидания ореол пульсирует, у готово и ошибки — статичный.
function Draw-HaloDot($g, [single]$cx, [single]$cy, $color, [bool]$pulse) {
    $alpha = 55
    if ($pulse) {
        $phase = 0.5 + 0.5 * [math]::Sin($script:anim / 8.0)
        $alpha = [int](30 + 45 * $phase)
    }
    $halo = [System.Drawing.Color]::FromArgb($alpha, $color.R, $color.G, $color.B)
    $haloBrush = New-Object System.Drawing.SolidBrush($halo)
    $g.FillEllipse($haloBrush, [single]($cx - 6.5), [single]($cy - 6.5), [single]13, [single]13)
    $haloBrush.Dispose()
    Draw-FilledDot $g $cx $cy $color 3.5
}

function Draw-FilledDot($g, [single]$cx, [single]$cy, $color, [single]$r) {
    $brush = New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($brush, [single]($cx - $r), [single]($cy - $r), [single]($r * 2), [single]($r * 2))
    $brush.Dispose()
}

function Get-VisibleSessions {
    $snap = $script:snap
    if (-not $snap) { return @() }
    $limit = 3
    if ($null -ne $script:config.maxSessions) { $limit = [int]$script:config.maxSessions }
    if ($limit -lt 1) { $limit = 1 }

    $list = @()
    if ($snap.primary -and ([string]$snap.primary.status -notin @('idle', 'stale'))) { $list += $snap.primary }
    foreach ($o in @(Get-OtherSessions)) {
        if ($list.Count -ge $limit) { break }
        $list += $o
    }
    return $list
}

function Get-OtherSessions {
    $snap = $script:snap
    if (-not $snap -or -not $snap.sessions) { return @() }
    $primaryId = ''
    if ($snap.primary) { $primaryId = [string]$snap.primary.id }

    $rank = @{ waiting = 0; working = 1; subagents = 2; done = 3; stale = 4; idle = 5 }
    # В список — только живые сессии: простой и брошенные ходы не занимают место.
    $list = @($snap.sessions | Where-Object {
            [string]$_.id -ne $primaryId -and [string]$_.status -notin @('idle', 'stale')
        })
    $list = @($list | Sort-Object `
        @{ Expression = { $v = $rank[[string]$_.status]; if ($null -eq $v) { 9 } else { $v } } }, `
        @{ Expression = { [double]$_.lastEventAt }; Descending = $true })
    return @($list | Select-Object -First 3)
}

# Строки карточки считаются один раз на снимок: Paint и мышь не ходят в движок.
function Update-ViewCache {
    $snap = $script:snap
    $rows = @()
    if ($snap) {
        $sessions = @(Get-VisibleSessions)
        for ($i = 0; $i -lt $sessions.Count; $i++) {
            $s = $sessions[$i]
            $texts = Get-SessionText $s
            $title = [string]$s.title
            if (-not $title) { $title = [string]$s.id }
            $state = [string]$texts.state
            $plan = ''
            if ($state -in @('working', 'waiting', 'subagents')) { $plan = Get-PlanChip $s }
            $rows += [pscustomobject]@{
                index   = $i
                session = $s
                title   = $title
                meta    = Get-SessionMeta $s
                status  = [string]$texts.status
                detail  = [string]$texts.detail
                state   = $state
                plan    = $plan
            }
        }
    }
    $script:rows = $rows

    $active = 0
    if ($snap -and $null -ne $snap.activeCount) { $active = [int]$snap.activeCount }
    $script:overflowCount = [math]::Max(0, $active - $rows.Count)

    $label = 'DSH'
    $cwd = ''
    if ($snap -and $snap.primary) { $cwd = [string]$snap.primary.cwd }
    if (-not $cwd -and $snap -and $snap.sessions -and $snap.sessions.Count -gt 0) { $cwd = [string]$snap.sessions[0].cwd }
    if ($cwd) {
        $leaf = Split-Path -Leaf ($cwd.TrimEnd('\'))
        if ($leaf) { $label = 'DSH · ' + $leaf }
    }
    $script:projectLabel = $label
    $script:viewKey = Get-ViewKey
}

function Get-ViewKey {
    $snap = $script:snap
    $parts = @($script:projectLabel, [string]$script:engineOk, [string]$script:dshRunning, [string]$script:theme, [string]$script:overflowCount)
    if ($snap -and $snap.balance) {
        $parts += ([string]$snap.balance.enabled + ':' + [string]$snap.balance.amount + ':' + [string]$snap.balance.ok)
    }
    foreach ($r in $script:rows) {
        $parts += ($r.title + '|' + $r.meta + '|' + $r.status + '|' + $r.detail + '|' + $r.state + '|' + $r.plan)
    }
    return ($parts -join "`n")
}

function Get-CardHeight([int]$count, [int]$overflow) {
    if ($count -lt 1) { $count = 1 }
    $height = $HEADER_H + ($count * $BLOCK_H) + 8
    if ($overflow -gt 0) { $height += $FOOTER_H + 4 }
    return $height
}

# Индекс блока сессии под курсором (или $null, если мимо).
function Get-SessionBlockIndex([int]$y, [int]$count) {
    if ($count -le 0 -or $y -lt $HEADER_H) { return $null }
    $idx = [int][math]::Floor(($y - $HEADER_H) / $BLOCK_H)
    if ($idx -ge 0 -and $idx -lt $count -and $y -lt ($HEADER_H + $count * $BLOCK_H - 2)) { return $idx }
    return $null
}

# Рабочая область того монитора, на котором стоит карточка.
function Get-CardWorkingArea {
    $pt = New-Object System.Drawing.Point(($form.Left + [int]($form.Width / 2)), ($form.Top + [int]($form.Height / 2)))
    return [System.Windows.Forms.Screen]::FromPoint($pt).WorkingArea
}

# Шестерёнка рисуется вектором: глиф ⚙ смещён внутри текстового бокса и не даёт
# точного центрирования, а здесь центр задан явно.
function Draw-Gear($g, [single]$cx, [single]$cy, [single]$r, $color) {
    # Штатная шестерёнка Windows (Segoe MDL2 Assets, E713): читается как шестерёнка,
    # а не как звезда из тонких лучей.
    $oldHint = $g.TextRenderingHint
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $brush = New-Object System.Drawing.SolidBrush($color)
    $rect = New-Object System.Drawing.RectangleF([single]($cx - 12), [single]($cy - 12), [single]24, [single]24)
    $g.DrawString([string][char]0xE713, $script:fontGear, $brush, $rect, $script:gearFormat)
    $brush.Dispose()
    $g.TextRenderingHint = $oldHint
}

function Draw-Collapse($g, [single]$cx, [single]$cy, $color) {
    # «Свернуть» — короткая горизонтальная черта.
    $pen = New-Object System.Drawing.Pen($color, 1.6)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawLine($pen, [single]($cx - 5), [single]$cy, [single]($cx + 5), [single]$cy)
    $pen.Dispose()
}

# Попадание в кнопку «свернуть» (слева от шестерёнки).
function Test-CollapseHit([int]$x, [int]$y) {
    return ($x -ge ($CARD_W - 70) -and $x -le ($CARD_W - 46) -and $y -ge 4 -and $y -le 28)
}

# Попадание в шестерёнку настроек (правый верхний угол карточки).
function Test-GearHit([int]$x, [int]$y) {
    return ($x -ge ($CARD_W - 38) -and $x -le ($CARD_W - 14) -and $y -ge 4 -and $y -le 28)
}

function Get-SubagentWord([int]$n) {
    if ($script:language -eq 'en') { if ($n -eq 1) { return 'subagent' } else { return 'subagents' } }
    if ($script:language -eq 'zh-CN') { return '个子代理' }
    $mod10 = $n % 10
    $mod100 = $n % 100
    if ($mod10 -eq 1 -and $mod100 -ne 11) { return 'субагент' }
    if ($mod10 -ge 2 -and $mod10 -le 4 -and ($mod100 -lt 12 -or $mod100 -gt 14)) { return 'субагента' }
    return 'субагентов'
}

function Get-SessionWord([int]$n) {
    if ($script:language -eq 'en') { if ($n -eq 1) { return 'session' } else { return 'sessions' } }
    if ($script:language -eq 'zh-CN') { return '会话' }
    $mod10 = $n % 10
    $mod100 = $n % 100
    if ($mod10 -eq 1 -and $mod100 -ne 11) { return 'сессия' }
    if ($mod10 -ge 2 -and $mod10 -le 4 -and ($mod100 -lt 12 -or $mod100 -gt 14)) { return 'сессии' }
    return 'сессий'
}

function Format-Duration([double]$ms) {    if ($ms -lt 0) { $ms = 0 }
    $total = [int]([math]::Floor($ms / 1000))
    $m = [int][math]::Floor($total / 60)
    $s = $total % 60
    if ($m -ge 60) { return ('{0}:{1:00}:{2:00}' -f [int][math]::Floor($m / 60), ($m % 60), $s) }
    return ('{0}:{1:00}' -f $m, $s)
}

function New-DemoSnapshot([string]$demoState) {
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $primary = [ordered]@{
        id            = 'session-demo'
        title         = (T 'Рефакторинг плагина сессий')
        cwd           = 'C:\Projects\billing-service'
        status        = 'working'
        turn          = 3
        step          = 12
        steps         = 12
        elapsedMs     = 271000
        idleMs        = 800
        activity      = @{ kind = 'tool'; tool = 'pwsh'; detail = (T 'Запускает тесты: pnpm test') }
        jobs          = @{ active = 2; registered = 10; settled = 8 }
        subagents     = @{ active = 0; total = 0; top = $null }
        done          = $null
        completionSerial = 0
        todos         = @{ done = 2; total = 5 }
        primary       = $true
    }
    $workingCount = 1
    $activeCount = 1
    switch ($demoState) {
        'thinking' {
            $primary.activity = @{ kind = 'thinking'; tool = $null; detail = '' }
        }
        'done' {
            $primary.status = 'done'
            $primary.elapsedMs = $null
            $primary.todos = @{ done = 5; total = 5 }
            $primary.activity = @{ kind = 'done'; tool = $null; detail = (T 'Сборка зелёная, можно коммитить.') }
            $primary.done = @{
                at = $nowMs; ok = $true; reason = 'completed'
                preview = (T 'Сборка зелёная, можно коммитить.')
                durationMs = 192000
            }
        }
        'error' {
            $primary.status = 'done'
            $primary.elapsedMs = $null
            $primary.todos = @{ done = 3; total = 5 }
            $primary.activity = @{ kind = 'done'; tool = $null; detail = (T 'Тесты упали на шаге сборки.') }
            $primary.done = @{
                at = $nowMs; ok = $false; reason = 'error'
                preview = (T 'Тесты упали на шаге сборки.')
                durationMs = 192000
            }
        }
        'waiting' {
            $primary.status = 'waiting'
            $primary.activity = @{ kind = 'question'; tool = 'ask_user_question'; detail = (T 'Куда коммитить изменения?') }
        }
        'approval' {
            $primary.status = 'waiting'
            $primary.activity = @{ kind = 'approval'; tool = 'pwsh'; detail = 'escalate sandbox to danger-full-access' }
        }
        'subagents' {
            $primary.status = 'subagents'
            $primary.elapsedMs = $null
            $primary.activity = @{ kind = 'subagents'; tool = $null; detail = '' }
            $primary.subagents = @{
                active = 2
                total  = 3
                top    = @{ title = (T 'Проверка формы'); kind = 'tool'; tool = 'pwsh'; detail = (T 'Прогоняет сценарии формы') }
            }
        }
        'idle' {
            $primary = $null
            $workingCount = 0
            $activeCount = 0
        }
        'empty' {
            $primary = $null
            $workingCount = 0
            $activeCount = 0
        }
    }

    $demoSessions = @()
    if ($demoState -eq 'list') {
        $workingCount = 2
        $activeCount = 3
        $demoSessions = @(
            [ordered]@{
                id = 'session-demo-2'; title = (T 'Проверка API заказов'); cwd = 'C:\Projects\orders-api'
                status = 'waiting'; step = 7; steps = 7; elapsedMs = $null; lastEventAt = $nowMs - 1200
                activity = @{ kind = 'question'; tool = 'ask_user_question'; detail = (T 'Какой контракт считать основным?') }
                jobs = @{ active = 0 }; subagents = @{ active = 0; total = 0; top = $null }
                done = $null; completionSerial = 0; todos = @{ done = 1; total = 4 }
            },
            [ordered]@{
                id = 'session-demo-3'; title = (T 'Сборка лендинга'); cwd = 'C:\Projects\landing'
                status = 'done'; step = 9; steps = 9; elapsedMs = $null; lastEventAt = $nowMs - 20000
                activity = @{ kind = 'done'; tool = $null; detail = (T 'Готово к публикации.') }
                jobs = @{ active = 0 }; subagents = @{ active = 0; total = 0; top = $null }
                done = @{ at = $nowMs - 20000; ok = $true; reason = 'completed'; preview = (T 'Готово к публикации.'); durationMs = 96000 }
                completionSerial = 1; todos = @{ done = 3; total = 3 }
            }
        )
    }
    if ($demoState -eq 'many') {
        $workingCount = 4
        $activeCount = 4
        $demoSessions = @(
            [ordered]@{
                id = 'session-demo-2'; title = (T 'Сборка лендинга'); cwd = 'C:\Projects\landing'
                status = 'working'; step = 4; steps = 4; elapsedMs = 96000; lastEventAt = $nowMs - 500
                activity = @{ kind = 'tool'; tool = 'read'; detail = 'index.html' }
                jobs = @{ active = 0 }; subagents = @{ active = 0; total = 0; top = $null }
                done = $null; completionSerial = 0; todos = @{ done = 1; total = 3 }
            },
            [ordered]@{
                id = 'session-demo-3'; title = (T 'Проверка API заказов'); cwd = 'C:\Projects\orders-api'
                status = 'working'; step = 7; steps = 7; elapsedMs = 54000; lastEventAt = $nowMs - 1500
                activity = @{ kind = 'tool'; tool = 'pwsh'; detail = (T 'Прогоняет контрактные тесты') }
                jobs = @{ active = 1 }; subagents = @{ active = 0; total = 0; top = $null }
                done = $null; completionSerial = 0; todos = @{ done = 0; total = 2 }
            },
            [ordered]@{
                id = 'session-demo-4'; title = (T 'Задача d'); cwd = 'C:\Projects\billing-service'
                status = 'working'; step = 3; steps = 3; elapsedMs = 23000; lastEventAt = $nowMs - 3000
                activity = @{ kind = 'thinking'; tool = $null; detail = '' }
                jobs = @{ active = 0 }; subagents = @{ active = 0; total = 0; top = $null }
                done = $null; completionSerial = 0; todos = $null
            }
        )
    }

    $snap = [ordered]@{
        ok = $true; version = '1.0.3'; now = $nowMs; dshHome = 'C:\dsh-home'
        sessionsTracked = 1 + $demoSessions.Count; workingCount = $workingCount; activeCount = $activeCount
        primary = $primary; pinnedId = $null; lastCompletion = $null; sessions = $demoSessions
        balance = @{ enabled = $true; ok = $true; source = 'platform'; currency = 'CNY'; symbol = '¥'; amount = 42.00; bonus = 0 }
    }
    return ($snap | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
}

function New-RoundedPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}


function Draw-TextLine($g, [string]$text, $font, $color, [int]$x, [int]$y, [int]$w, [int]$h, [bool]$right) {
    $flags = [System.Windows.Forms.TextFormatFlags]::NoPrefix -bor `
             [System.Windows.Forms.TextFormatFlags]::SingleLine -bor `
             [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor `
             [System.Windows.Forms.TextFormatFlags]::NoPadding -bor `
             [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    if ($right) { $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::Right }
    $rect = New-Object System.Drawing.Rectangle($x, $y, $w, $h)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $text, $font, $rect, $color, $flags)
}

# ------------------------------------------------------------------ карточка

$form = New-Object DshCardForm
$form.Width = $CARD_W
$form.Height = $CARD_H
$form.BackColor = $script:clrBg
$form.TopMost = [bool]$script:config.topMost
        $form.Opacity = [double]([math]::Max(50, [math]::Min(100, [int]$script:config.opacity))) / 100.0

function Get-DefaultPosition {
    $wa = Get-CardWorkingArea
    return @{ x = $wa.Right - $CARD_W - 18; y = $wa.Bottom - $CARD_H - 18 }
}

$startPos = Get-DefaultPosition
if ($null -ne $script:config.x -and $null -ne $script:config.y) {
    $startPos = @{ x = [int]$script:config.x; y = [int]$script:config.y }
}
$form.Left = [int]$startPos.x
$form.Top = [int]$startPos.y

# сохранённая позиция могла остаться от более высокой карточки — зажимаем в рабочую область
$waStart = Get-CardWorkingArea
$form.Left = [int][math]::Max($waStart.Left + 8, [math]::Min($form.Left, $waStart.Right - $form.Width - 8))
$form.Top = [int][math]::Max($waStart.Top + 8, [math]::Min($form.Top, $waStart.Bottom - $form.Height - 8))

$form.Add_HandleCreated({
    # Windows 11 скругляет окно через DWM; в Windows 10 включаем запасной путь через регион.
    try {
        $script:dwmCorners = [DshNative]::RoundCorners($form.Handle)
        if ($env:DSH_WIDGET_FORCE_REGION) { $script:dwmCorners = $false }
        if (-not $script:dwmCorners) { [DshNative]::ApplyRoundRegion($form.Handle, $form.Width, $form.Height, 12) }
        Write-WidgetLog ('corners: dwm=' + $script:dwmCorners)
    } catch { }
})

$form.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    $g.Clear($script:clrBg)

    # тонкая рамка: на светлом фоне карточка иначе сливается с рабочим столом
    $borderPen = New-Object System.Drawing.Pen($script:clrBorder, 1)
    $borderPath = New-RoundedPath 0.5 0.5 ($CARD_W - 1) ($form.Height - 1) 12
    $g.DrawPath($borderPen, $borderPath)
    $borderPath.Dispose()
    $borderPen.Dispose()

    # строки уже посчитаны в Update-Snapshot; в пустом/офлайн-состоянии показываем одну заглушку
    $rows = @($script:rows)
    if ($rows.Count -eq 0) {
        $texts = Get-StatusText $null $script:engineOk
        if ($script:manualShow -and $script:engineOk) {
            if (-not $script:dshRunning) { $texts = @{ status = (T 'DeepSeek Harness не запущен'); detail = (T 'Откройте приложение'); state = 'idle' } }
            else { $texts = @{ status = (T 'Нет активных задач'); detail = (T 'Запустите сессию в DeepSeek Harness'); state = 'idle' } }
        }
        $rows = @([pscustomobject]@{
                index = 0; session = $null; title = 'DeepSeek Harness'; meta = ''
                status = [string]$texts.status; detail = [string]$texts.detail
                state = [string]$texts.state; plan = ''
            })
    }

    # шапка: проект + баланс
    Draw-TextLine $g $script:projectLabel $script:fontLabel $script:clrMuted 16 5 ($CARD_W - 172) 16 $false

    $bal = $null
    if ($script:snap) { $bal = $script:snap.balance }
    $balText = ''
    $balColor = $script:clrMuted
    if ($bal -and $bal.enabled -and $null -ne $bal.amount) {
        $amount = [double]$bal.amount
        $prefix = if ($bal.ok) { '' } else { '~' }
        $balText = $prefix + [string]$bal.symbol + $amount.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
        if ($amount -le 5) { $balColor = $script:accentByState['waiting'] }
    }
    if ($balText) { Draw-TextLine $g $balText $script:fontLabel $balColor ($CARD_W - 148) 5 68 16 $true }

    # кнопка «свернуть» — слева от шестерёнки, в одну линию со строкой шапки
    $collapseBox = New-Object System.Drawing.Rectangle(($CARD_W - 70), 3, 24, 24)
    $collapseColor = if ($script:collapseHover) { $script:clrText } else { $script:clrDim }
    if ($script:collapseHover) {
        $hoverBrush2 = New-Object System.Drawing.SolidBrush($script:clrTrack)
        $hoverPath2 = New-RoundedPath $collapseBox.X $collapseBox.Y $collapseBox.Width $collapseBox.Height 7
        $g.FillPath($hoverBrush2, $hoverPath2)
        $hoverPath2.Dispose(); $hoverBrush2.Dispose()
    }
    Draw-Collapse $g ([single]($collapseBox.X + $collapseBox.Width / 2)) ([single]($collapseBox.Y + $collapseBox.Height / 2)) $collapseColor

    # шестерёнка настроек справа от баланса — в одну линию со строкой шапки
    $gearColor = if ($script:gearHover) { $script:clrText } else { $script:clrDim }
    $gearBox = New-Object System.Drawing.Rectangle(($CARD_W - 38), 3, 24, 24)
    if ($script:gearHover) {
        $hoverBrush = New-Object System.Drawing.SolidBrush($script:clrTrack)
        $hoverPath = New-RoundedPath $gearBox.X $gearBox.Y $gearBox.Width $gearBox.Height 7
        $g.FillPath($hoverBrush, $hoverPath)
        $hoverPath.Dispose(); $hoverBrush.Dispose()
    }
    Draw-Gear $g ([single]($gearBox.X + $gearBox.Width / 2)) ([single]($gearBox.Y + $gearBox.Height / 2)) 5.3 $gearColor

    # блоки сессий — все одинаковые, без полосы «прогресса»
    for ($i = 0; $i -lt $rows.Count; $i++) {
        Draw-Row $g $rows[$i] ($HEADER_H + $i * $BLOCK_H)
    }

    # подвал — только когда не все сессии поместились
    if ($script:overflowCount -gt 0 -and $rows.Count -eq $script:rows.Count) {
        $n = [int]$script:overflowCount
        $word = Get-SessionWord $n
        Draw-TextLine $g (T 'ещё {0} {1}' $n $word) $script:fontLabel $script:clrMuted 16 ($HEADER_H + $rows.Count * $BLOCK_H + 4) 220 14 $false
    }
})

$form.Add_MouseLeave({
    $script:hoverRow = $null
    $script:gearHover = $false
    $script:collapseHover = $false
    $form.Invalidate()
})

$form.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:dragging = $true
        $script:dragMoved = $false
        $script:dragStart = [System.Windows.Forms.Cursor]::Position
        $script:formStart = @{ x = $form.Left; y = $form.Top }
    }
})

$form.Add_MouseMove({
    param($sender, $e)
    if ($script:dragging) {
        $p = [System.Windows.Forms.Cursor]::Position
        $dx = $p.X - $script:dragStart.X
        $dy = $p.Y - $script:dragStart.Y
        if ([math]::Abs($dx) + [math]::Abs($dy) -gt 3) { $script:dragMoved = $true }
        if ($script:dragMoved) {
            $form.Left = $script:formStart.x + $dx
            $form.Top = $script:formStart.y + $dy
        }
        return
    }

    $overGear = Test-GearHit $e.X $e.Y
    if ($overGear -ne $script:gearHover) { $script:gearHover = $overGear; $form.Invalidate() }
    $overCollapse = Test-CollapseHit $e.X $e.Y
    if ($overCollapse -ne $script:collapseHover) { $script:collapseHover = $overCollapse; $form.Invalidate() }

    # подсвечиваем строку под курсором, а не всю карточку
    $idx = $null
    if (-not ($overGear -or $overCollapse)) { $idx = Get-SessionBlockIndex $e.Y $script:rows.Count }
    if ($idx -ne $script:hoverRow) { $script:hoverRow = $idx; $form.Invalidate() }

    if ($overGear -or $overCollapse -or $null -ne $idx) {
        $form.Cursor = [System.Windows.Forms.Cursors]::Hand
    } else {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

$form.Add_MouseUp({
    param($sender, $e)
    if (-not $script:dragging) { return }
    $script:dragging = $false

    if ($script:dragMoved) {
        # не даём уронить карточку на панель задач или за край экрана
        $wa = Get-CardWorkingArea
        $top = [math]::Max($wa.Top + 8, [math]::Min($form.Top, $wa.Bottom - $form.Height - 8))
        $left = [math]::Max($wa.Left + 8, [math]::Min($form.Left, $wa.Right - $form.Width - 8))
        $form.SetBounds([int]$left, [int]$top, $form.Width, $form.Height)

        $script:config.x = $form.Left
        $script:config.y = $form.Top
        Save-Config
        return
    }

    # клик по «свернуть» — прячем карточку в трей
    if (Test-CollapseHit $e.X $e.Y) {
        $script:cardVisible = $false
        $script:manualShow = $false
        $form.Hide()
        $miShow.Text = T 'Показать виджет'
        return
    }

    # клик по шестерёнке — настройки
    if (Test-GearHit $e.X $e.Y) {
        Show-SettingsWindow
        return
    }

    # Клик по блоку — открыть именно это окно DSH (по заголовку сессии).
    $idx = Get-SessionBlockIndex $e.Y $script:rows.Count
    if ($null -ne $idx) {
        $row = $script:rows[$idx]
        $title = [string]$row.title
        if (-not (Focus-DshWindowForSession $title)) { Open-DshWindow }
        # Ошибку нельзя закрыть автоматически по фокусу; клик по блоку — явное «увидел».
        if ($row.session -and ([string]$row.state -in @('done', 'error'))) {
            Send-Ack ([string]$row.session.id)
        }
    }
})

$form.Add_DoubleClick({ Open-DshWindow })

# ------------------------------------------------------------------ звук

function Play-SystemSound {
    try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
}

# Встроенный «тук-тук» из assets; если файла нет — системный сигнал.
function Play-BuiltinSound {
    $file = Join-Path $scriptDir 'assets\notify.wav'
    if ($script:customSoundBroken -or -not (Test-Path -LiteralPath $file)) { Play-SystemSound; return }
    try {
        if (-not $script:soundPlayer) { $script:soundPlayer = New-Object System.Media.SoundPlayer }
        $script:soundPlayer.SoundLocation = $file
        $script:soundPlayer.Play()
    } catch {
        $script:customSoundBroken = $true
        Play-SystemSound
    }
}

# Успех — «тук-тук»/системный сигнал; ошибка — системный Hand.
function Play-NotificationSound([bool]$isError = $false) {
    if (-not $script:config.sound) { return }
    $mode = [string]$script:config.soundMode
    if ($mode -eq 'off') { return }
    if ($isError) {
        try { [System.Media.SystemSounds]::Hand.Play() } catch { }
        return
    }
    if ($mode -eq 'system') { Play-SystemSound; return }
    Play-BuiltinSound
}

# Сфокусировать окно DSH, в котором открыта конкретная сессия (по заголовку окна).
function Focus-DshWindowForSession([string]$sessionTitle) {
    if (-not $sessionTitle) { return $false }
    try {
        $suffix = ' — DeepSeek Harness'
        $candidates = @([DshNative]::ListDshWindows())
        if ($candidates.Count -eq 0) {
            Write-WidgetLog 'focus: окон DSH не найдено'
            return $false
        }

        $picked = $null
        $parsed = @($candidates | ForEach-Object { , ($_ -split '\|', 3) })

        # 1) точное совпадение: заголовок оканчивается суффиксом и содержит название сессии
        foreach ($c in $parsed) {
            if ($c.Count -lt 3) { continue }
            if ($c[2].EndsWith($suffix) -and $c[2].IndexOf($sessionTitle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $picked = $c; break }
        }
        # 2) то же по первым 18 символам — на случай, если DSH обрезал заголовок
        if (-not $picked) {
            $short = if ($sessionTitle.Length -gt 18) { $sessionTitle.Substring(0, 18) } else { $sessionTitle }
            foreach ($c in $parsed) {
                if ($c.Count -lt 3) { continue }
                if ($c[2].EndsWith($suffix) -and $c[2].IndexOf($short, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $picked = $c; break }
            }
        }
        # 3) любое окно DSH — лучше открыть приложение, чем ничего
        if (-not $picked) {
            foreach ($c in $parsed) {
                if ($c.Count -lt 3) { continue }
                if ($c[2].EndsWith($suffix)) { $picked = $c; break }
            }
        }

        if (-not $picked) {
            $titles = ($parsed | Where-Object { $_.Count -ge 3 } | ForEach-Object { $_[2] }) -join ' | '
            Write-WidgetLog ('focus: подходящего окна нет; кандидаты: ' + $titles)
            return $false
        }

        $hwnd = [IntPtr]([int64]$picked[0])
        $ok = [DshNative]::ForceForeground($hwnd)
        Write-WidgetLog ('focus: «' + $sessionTitle + '» -> [' + $picked[2] + '] ok=' + $ok)
        return $ok
    } catch {
        Write-WidgetLog ('focus error: ' + $_.Exception.Message)
        return $false
    }
}
# ------------------------------------------------------------------ DSH

function Get-DshHome {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:DSH_HOME) { [void]$candidates.Add($env:DSH_HOME) }
    if ($env:USERPROFILE) { [void]$candidates.Add((Join-Path $env:USERPROFILE '.dsh')) }

    foreach ($name in @('DeepSeek Harness.exe', 'dsh.exe')) {
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

    foreach ($home in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath (Join-Path $home 'profiles\desktop')) { return $home }
    }
    return $null
}

function Get-DshExe {
    foreach ($name in @('DeepSeek Harness.exe', 'dsh.exe')) {
        try {
            $procs = Get-CimInstance Win32_Process -Filter ("Name='" + $name + "'") -ErrorAction SilentlyContinue
            foreach ($p in @($procs)) {
                if ($p -and $p.ExecutablePath -and (Test-Path -LiteralPath $p.ExecutablePath)) { return $p.ExecutablePath }
            }
        } catch { }
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'))
    [void]$candidates.Add((Join-Path ${env:ProgramFiles} 'DeepSeek Harness\DeepSeek Harness.exe'))

    foreach ($root in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        try {
            Get-ItemProperty $root -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*DeepSeek Harness*' } |
                ForEach-Object {
                    if ($_.InstallLocation) {
                        [void]$candidates.Add((Join-Path $_.InstallLocation 'DeepSeek Harness.exe'))
                    }
                    if ($_.DisplayIcon) {
                        $icon = ([string]$_.DisplayIcon).Split(',')[0].Trim('"')
                        if ($icon -like '*.exe') { [void]$candidates.Add($icon) }
                    }
                }
        } catch { }
    }

    foreach ($c in ($candidates | Select-Object -Unique)) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Open-DshWindow {
    $procs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
    if ($procs.Count -gt 0) {
        $h = $procs[0].MainWindowHandle
        try {
            [DshNative]::ShowWindowAsync($h, 9) | Out-Null
            [DshNative]::SetForegroundWindow($h) | Out-Null
        } catch { }
        return
    }
    $exe = Get-DshExe
    if ($exe) { Start-Process -FilePath $exe | Out-Null }
}


# Название сессии из активного окна DSH. DSH подписывает окно как «<сессия> — DeepSeek Harness»,
# поэтому опознаём по суффиксу: PID окна из песочницы может быть недоступен.
function Get-ForegroundDshTitle {
    try {
        $fg = [DshNative]::GetForegroundWindow()
        if ($fg -eq [IntPtr]::Zero) { return '' }
        $len = [DshNative]::GetWindowTextLength($fg)
        if ($len -le 0) { return '' }
        $sb = New-Object System.Text.StringBuilder ($len + 2)
        [void][DshNative]::GetWindowText($fg, $sb, $sb.Capacity)
        $title = $sb.ToString()

        $suffix = ' — DeepSeek Harness'
        if ($title.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $title.Substring(0, $title.Length - $suffix.Length).Trim()
        }
        return ''
    } catch { return '' }
}

function ConvertTo-TitleKey([string]$text) {
    if (-not $text) { return '' }
    return ($text.ToLowerInvariant() -replace '\s+', ' ').Trim()
}

# Совпадение заголовка окна с названием сессии (DSH может дописывать к заголовку своё).
function Test-TitleMatch([string]$windowTitle, [string]$sessionTitle) {
    $a = ConvertTo-TitleKey $windowTitle
    $b = ConvertTo-TitleKey $sessionTitle
    if (-not $a -or -not $b) { return $false }
    if ($a -eq $b) { return $true }
    $short = if ($a.Length -lt $b.Length) { $a } else { $b }
    if ($short.Length -lt 6) { return $false }
    return ($a.Contains($b) -or $b.Contains($a))
}

# Отметить завершённую сессию просмотренной.
function Send-Ack([string]$id) {
    try {
        Invoke-EngineJson '/ack' 'POST' ('{"id":"' + $id + '"}') | Out-Null
        Write-WidgetLog ('ack ' + $id)
    } catch { }
}

# ------------------------------------------------------------------ настройки

# Поле ключа нужно только для источника «Свой ключ»; остальное время не мозолит глаза.
function Update-SettingsKeyVisibility {
    $ui = $script:settingsKeyUi
    if (-not $ui) { return }
    $show = ([int]$ui.Source.Index -eq 1)
    if ($ui.Label) { $ui.Label.Visible = $show }
    if ($ui.Hint) { $ui.Hint.Visible = $show }
    if ($ui.Link) { $ui.Link.Visible = $show }
    if ($ui.Box -and $ui.Box.Parent) { $ui.Box.Parent.Visible = $show }
}

function Show-SettingsWindow {
    param([int]$AutoCloseMs = 0, [string]$ShotPath = '', [switch]$SaveOnClose)

    $bg = $script:clrBg
    $fg = $script:clrText
    $dim = $script:clrDim
    $fieldBg = $script:clrField
    $btnBg = $script:clrButton
    $line = $script:clrBorder
    $fieldLine = [System.Drawing.Color]::FromArgb(255, 58, 61, 70)

    $W = 680; $H = 660
    $left = 24; $right = 356
    $colW = 300

    $pluginInstalled = $false
    try {
        $dshHome = Get-DshHome
        if ($dshHome) {
            $manifest = Join-Path (Join-Path (Join-Path $dshHome 'profiles') 'desktop') 'package.json'
            if (Test-Path -LiteralPath $manifest) {
                $pkg = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
                $pluginInstalled = @($pkg.dsh.profile.bundles) -contains '@local/dsh-widget-bridge'
            }
        }
    } catch { }

    $dlg = New-Object DshCardForm
    $dlg.Width = $W; $dlg.Height = $H
    $dlg.BackColor = $bg
    $dlg.TopMost = $false
    $dlg.ShowInTaskbar = $true
    $dlg.Text = T 'Настройки виджета'
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    if ($script:appIcon) { $dlg.Icon = $script:appIcon }
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Add_HandleCreated({
        try {
            if (-not [DshNative]::RoundCorners($dlg.Handle)) { [DshNative]::ApplyRoundRegion($dlg.Handle, $dlg.Width, $dlg.Height, 14) }
        } catch { }
    })

    $sectionFont = New-Object System.Drawing.Font($script:fontLabel.FontFamily, 8, [System.Drawing.FontStyle]::Bold)
    $labelFont = New-Object System.Drawing.Font($script:fontDetail.FontFamily, 9, [System.Drawing.FontStyle]::Regular)
    $titleFont = New-Object System.Drawing.Font($script:fontTitle.FontFamily, 14, [System.Drawing.FontStyle]::Bold)

    $dlg.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($bg)
        $pen = New-Object System.Drawing.Pen($line, 1)
        $g.DrawLine($pen, 0, 54, $W, 54)
        $g.DrawLine($pen, 0, $H - 60, $W, $H - 60)
        $path = New-RoundedPath 0.5 0.5 ($W - 1.5) ($H - 1.5) 13
        $g.DrawPath($pen, $path)
        $path.Dispose(); $pen.Dispose()
    })

    $beginDrag = {
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            try { [DshNative]::BeginDrag($dlg.Handle) } catch { }
        }
    }
    $dlg.Add_MouseDown($beginDrag)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = T 'Настройки виджета'
    $title.Left = $left; $title.Top = 12; $title.Width = 420; $title.Height = 30
    $title.ForeColor = $fg; $title.BackColor = $bg
    $title.Font = $titleFont
    $title.Add_MouseDown($beginDrag)
    $dlg.Controls.Add($title)

    $btnClose = New-Object System.Windows.Forms.Label
    $btnClose.Text = '✕'
    $btnClose.Left = $W - 46; $btnClose.Top = 12; $btnClose.Width = 30; $btnClose.Height = 30
    $btnClose.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $btnClose.ForeColor = $dim; $btnClose.BackColor = $bg
    $btnClose.Font = New-Object System.Drawing.Font($script:fontLabel.FontFamily, 11)
    $btnClose.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnClose.Add_MouseEnter({ $btnClose.ForeColor = $fg; $btnClose.BackColor = $script:clrButton })
    $btnClose.Add_MouseLeave({ $btnClose.ForeColor = $dim; $btnClose.BackColor = $script:clrBg })
    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnClose)

    function New-Section($text, $x, $y) {
        $text = T $text
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Left = $x; $l.Top = $y; $l.Width = 300; $l.Height = 16
        $l.ForeColor = $dim; $l.BackColor = $bg
        $l.Font = $sectionFont
        $dlg.Controls.Add($l)
    }

    function New-Label($text, $x, $y, $w) {
        $text = T $text
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Left = $x; $l.Top = $y; $l.Width = $w; $l.Height = 18
        $l.ForeColor = $fg; $l.BackColor = $bg
        $l.Font = $labelFont
        $dlg.Controls.Add($l)
        return $l
    }

    function New-Hint($text, $x, $y, $w, $h) {
        $text = T $text
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Left = $x; $l.Top = $y; $l.Width = $w; $l.Height = $h
        $l.ForeColor = $script:clrMuted; $l.BackColor = $bg
        $l.Font = $script:fontDetail
        $dlg.Controls.Add($l)
        return $l
    }

    function New-LinkLabel($text, $x, $y, $w) {
        $text = T $text
        $l = New-Object System.Windows.Forms.LinkLabel
        $l.Text = $text
        $l.Left = $x; $l.Top = $y; $l.Width = $w; $l.Height = 16
        $l.BackColor = $bg
        $l.Font = $script:fontDetail
        $l.LinkColor = $script:accentByState['working']
        $l.ActiveLinkColor = $fg
        $l.VisitedLinkColor = $script:accentByState['working']
        $l.LinkBehavior = [System.Windows.Forms.LinkBehavior]::HoverUnderline
        $dlg.Controls.Add($l)
        return $l
    }

    function New-Check($text, $x, $y, $checked) {
        $text = T $text
        $c = New-Object System.Windows.Forms.CheckBox
        $c.Text = $text
        $c.Left = $x; $c.Top = $y
        $c.AutoSize = $true
        $c.Checked = [bool]$checked
        $c.ForeColor = $fg; $c.BackColor = $bg
        $c.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $c.Font = $labelFont
        $c.Cursor = [System.Windows.Forms.Cursors]::Hand
        $dlg.Controls.Add($c)
        return $c
    }

    function New-Radio($text, $x, $y, $checked) {
        $text = T $text
        $r = New-Object System.Windows.Forms.RadioButton
        $r.Text = $text
        $r.Left = $x; $r.Top = $y
        $r.AutoSize = $true
        $r.Checked = [bool]$checked
        $r.ForeColor = $fg; $r.BackColor = $bg
        $r.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $r.Font = $labelFont
        $r.Cursor = [System.Windows.Forms.Cursors]::Hand
        $dlg.Controls.Add($r)
        return $r
    }

    function New-Number($x, $y, $value, $min, $max, $width) {
        # Не NumericUpDown: его текст сидит на 2 px выше центра и тянет за собой
        # белые системные кнопки. TextBox центрируется сам, а стрелки рисуем справа.
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Text = [string]([math]::Max($min, [math]::Min($max, $value)))
        $tb.BackColor = $fieldBg; $tb.ForeColor = $fg
        $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $tb.Font = $labelFont
        $fieldH = $tb.PreferredHeight + 8

        $wrap = New-Object System.Windows.Forms.Panel
        $wrap.Left = $x; $wrap.Top = $y; $wrap.Width = $width; $wrap.Height = $fieldH
        $wrap.BackColor = $fieldBg
        $dlg.Controls.Add($wrap)
        $wrap.Add_Paint({
            $s = $args[0]
            $g = $args[1].Graphics
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 58, 61, 70), 1)
            $g.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
            $pen.Dispose()
        })

        $tb.Left = 6; $tb.Top = 4; $tb.Width = $width - 24; $tb.Height = $tb.PreferredHeight
        $wrap.Controls.Add($tb)

        $num = [pscustomobject]@{ TextBox = $tb; Min = [int]$min; Max = [int]$max }
        $num | Add-Member -MemberType ScriptProperty -Name Value -Value {
            $v = 0
            [void][int]::TryParse($this.TextBox.Text, [ref]$v)
            if ($v -lt $this.Min) { $v = $this.Min }
            if ($v -gt $this.Max) { $v = $this.Max }
            return $v
        } -SecondValue {
            param($v)
            $iv = [int]$v
            if ($iv -lt $this.Min) { $iv = $this.Min }
            if ($iv -gt $this.Max) { $iv = $this.Max }
            $this.TextBox.Text = [string]$iv
        }
        $tb.Tag = $num
        $tb.Add_KeyPress({
            $e = $args[1]
            if (-not [char]::IsDigit($e.KeyChar) -and -not [char]::IsControl($e.KeyChar)) { $e.Handled = $true }
        })
        $tb.Add_LostFocus({
            $s = $args[0]
            $n = $s.Tag
            if ($n) { $s.Text = [string]$n.Value }
        })

        $stepperW = 16
        $stepper = New-Object System.Windows.Forms.Panel
        $stepper.Left = $width - $stepperW - 1; $stepper.Top = 1
        $stepper.Width = $stepperW; $stepper.Height = $fieldH - 2
        $stepper.BackColor = $fieldBg
        $stepper.Cursor = [System.Windows.Forms.Cursors]::Hand
        $stepper.Tag = $num
        $stepper.Add_Paint({
            $s = $args[0]
            $g = $args[1].Graphics
            $h = $s.Height; $w = $s.Width
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $linePen = New-Object System.Drawing.Pen($script:clrBorder, 1)
            $g.DrawLine($linePen, 0, 2, 0, $h - 3)
            $linePen.Dispose()
            $chevPen = New-Object System.Drawing.Pen($script:clrDim, 1.5)
            $chevPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $chevPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $cx = [math]::Floor($w / 2)
            $g.DrawLine($chevPen, $cx - 3, [math]::Floor($h * 0.34), $cx, [math]::Floor($h * 0.22))
            $g.DrawLine($chevPen, $cx, [math]::Floor($h * 0.22), $cx + 3, [math]::Floor($h * 0.34))
            $g.DrawLine($chevPen, $cx - 3, [math]::Floor($h * 0.66), $cx, [math]::Floor($h * 0.78))
            $g.DrawLine($chevPen, $cx, [math]::Floor($h * 0.78), $cx + 3, [math]::Floor($h * 0.66))
            $chevPen.Dispose()
        })
        $stepper.Add_MouseDown({
            $s = $args[0]
            $num = $s.Tag
            $delta = if ($args[1].Y -lt ($s.Height / 2)) { 1 } else { -1 }
            $num.Value = [int]$num.Value + $delta
        })
        $wrap.Controls.Add($stepper)
        $stepper.BringToFront()
        return $num
    }

    function New-TextBox($x, $y, $w, $value) {
        $t = New-Object System.Windows.Forms.TextBox
        $t.Text = [string]$value
        $t.BackColor = $fieldBg; $t.ForeColor = $fg
        $t.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $t.Font = $labelFont
        $th = $t.PreferredHeight
        $wrap = New-Object System.Windows.Forms.Panel
        $wrap.Left = $x; $wrap.Top = $y; $wrap.Width = $w; $wrap.Height = $th + 8
        $wrap.BackColor = $fieldBg
        $dlg.Controls.Add($wrap)
        $wrap.Add_Paint({
            $s = $args[0]
            $g = $args[1].Graphics
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 58, 61, 70), 1)
            $g.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
            $pen.Dispose()
        })
        $t.Left = 6; $t.Top = 4; $t.Width = $w - 16; $t.Height = $th
        $wrap.Controls.Add($t)
        return $t
    }

    function New-Dropdown($x, $y, $w, $items, $selected) {
        $items = @($items | ForEach-Object { T ([string]$_) })
        $box = New-Object System.Windows.Forms.Button
        $box.Left = $x; $box.Top = $y; $box.Width = $w; $box.Height = 28
        $box.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $box.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $box.BackColor = $fieldBg; $box.ForeColor = $fg
        $box.FlatAppearance.BorderColor = $fieldLine
        $box.FlatAppearance.BorderSize = 1
        $box.FlatAppearance.MouseOverBackColor = $script:clrButton
        $box.Font = $labelFont
        $box.Cursor = [System.Windows.Forms.Cursors]::Hand
        $box.Text = '  ' + $items[[int]$selected]

        $chev = New-Object System.Drawing.Bitmap(12, 8)
        $cg = [System.Drawing.Graphics]::FromImage($chev)
        $cg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $cg.Clear([System.Drawing.Color]::Transparent)
        $cpen = New-Object System.Drawing.Pen($dim, 1.6)
        $cg.DrawLine($cpen, 1, 1, 6, 6)
        $cg.DrawLine($cpen, 6, 6, 11, 1)
        $cpen.Dispose(); $cg.Dispose()
        $box.Image = $chev
        $box.ImageAlign = [System.Drawing.ContentAlignment]::MiddleRight
        $box.TextImageRelation = [System.Windows.Forms.TextImageRelation]::Overlay
        $box.Padding = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $menu.Renderer = New-Object DshDarkMenuRenderer
        $menu.ShowImageMargin = $false
        $menu.ShowCheckMargin = $false
        $menu.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
        $menu.MinimumSize = New-Object System.Drawing.Size($w, 0)

        $state = [pscustomobject]@{ Index = [int]$selected; Items = $items; Button = $box; OnChange = $null }

        for ($i = 0; $i -lt $items.Count; $i++) {
            $mi = New-Object System.Windows.Forms.ToolStripMenuItem($items[$i])
            $mi.Tag = $i
            $mi.Font = $labelFont
            $mi.Padding = New-Object System.Windows.Forms.Padding(10, 3, 10, 3)
            $mi.Add_Click({
                $item = $args[0]
                $ctx = $item.Owner.Tag
                $idx = [int]$item.Tag
                $ctx.State.Index = $idx
                $ctx.Box.Text = '  ' + $ctx.Items[$idx]
                if ($ctx.State.OnChange) { & $ctx.State.OnChange $idx }
                if ($ctx.OnChange) { & $ctx.OnChange $idx }
            })
            [void]$menu.Items.Add($mi)
        }

        $ctx = @{ State = $state; Box = $box; Items = $items; OnChange = $null }
        $menu.Tag = $ctx
        $box.Tag = $menu
        $box.Add_Click({
            $b = $args[0]
            $m = $b.Tag
            if ($m) {
                $pt = $b.PointToScreen((New-Object System.Drawing.Point(0, $b.Height)))
                $m.Show($pt)
            }
        })
        $dlg.Controls.Add($box)
        return $state
    }

    function Set-Dropdown($dd, [int]$index) {
        $dd.Index = $index
        $dd.Button.Text = '  ' + $dd.Items[$index]
    }

    function New-Button($text, $x, $y, $w, $h, $back, $fore, $border) {
        $text = T $text
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text
        $b.Left = $x; $b.Top = $y; $b.Width = $w; $b.Height = $h
        $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $b.BackColor = $back; $b.ForeColor = $fore
        $b.FlatAppearance.BorderColor = $border
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.MouseOverBackColor = $script:clrButton
        $b.FlatAppearance.MouseDownBackColor = $line
        $b.Font = $labelFont
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        $dlg.Controls.Add($b)
        return $b
    }

    # ---------------- левая колонка
    New-Section 'ЗАПУСК' $left 72
    $modeCurrent = [string]$script:config.launchMode
    if ($modeCurrent -ne 'plugin' -and $modeCurrent -ne 'startup' -and $modeCurrent -ne 'manual') {
        $modeCurrent = if ($pluginInstalled) { 'plugin' } else { 'manual' }
    }
    # Без плагина режим «вместе с DSH» недоступен: не даём выбрать его и получить ошибку.
    if ($modeCurrent -eq 'plugin' -and -not $pluginInstalled) { $modeCurrent = 'manual' }

    $rbPlugin = New-Radio 'Вместе с DeepSeek Harness' $left 96 ($modeCurrent -eq 'plugin')
    if ($pluginInstalled) {
        $startupTop = 120; $manualTop = 144; $hintTop = 170
    } else {
        # Недоступный режим не показываем серым огрызком — объясняем в подсказке.
        $rbPlugin.Visible = $false
        $startupTop = 96; $manualTop = 120; $hintTop = 146
    }
    $rbStartup = New-Radio 'При входе в Windows' $left $startupTop ($modeCurrent -eq 'startup')
    $rbManual = New-Radio 'Только вручную, по ярлыку' $left $manualTop ($modeCurrent -eq 'manual')

    $lblModeHint = New-Hint '' $left $hintTop 300 64
    $baseHints = @{
        plugin  = T 'Виджет откроется вместе с DSH и закроется вместе с ним.'
        startup = T 'Виджет будет работать всегда, даже если DSH закрыт.'
        manual  = T 'Запуск только ярлыком из «Пуск». Автозапуска нет.'
    }
    $pluginNote = if (-not $pluginInstalled) {
        T 'Плагин не установлен: режим «вместе с DSH» недоступен. Переустановите виджет.'
    } else { '' }
    $script:settingsHints = @{
        plugin  = $baseHints.plugin
        startup = if ($pluginNote) { $pluginNote + "`n" + $baseHints.startup } else { $baseHints.startup }
        manual  = if ($pluginNote) { $pluginNote + "`n" + $baseHints.manual } else { $baseHints.manual }
    }
    $lblModeHint.Text = $script:settingsHints[$modeCurrent]
    $script:modeHintLabel = $lblModeHint
    $rbPlugin.Add_Click({ $script:modeHintLabel.Text = $script:settingsHints['plugin'] })
    $rbStartup.Add_Click({ $script:modeHintLabel.Text = $script:settingsHints['startup'] })
    $rbManual.Add_Click({ $script:modeHintLabel.Text = $script:settingsHints['manual'] })

    New-Section 'ОКНО' $left 240
    $cbTop = New-Check 'Поверх всех окон' $left 264 $script:config.topMost
    $btnReset = New-Button 'Вернуть виджет в угол' $left 294 210 28 $btnBg $fg $line
    $btnReset.Add_Click({
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $form.Left = $wa.Right - $form.Width - 18
        $form.Top = $wa.Bottom - $form.Height - 18
        $script:config.x = $form.Left
        $script:config.y = $form.Top
        Save-Config
    })

    New-Section 'ОФОРМЛЕНИЕ' $left 356
    [void](New-Label 'Тема' $left 380 100)
    $themeIndex = switch ([string]$script:config.theme) { 'light' { 1 } 'dark' { 2 } default { 0 } }
    $ddTheme = New-Dropdown $left 398 190 @('Как в системе', 'Светлая', 'Тёмная') $themeIndex
    $cbAccent = New-Check 'Цвет индикатора и названия как в Windows' $left 434 $script:config.accentBar

    [void](New-Label 'Прозрачность виджета' $left 462 160)
    $opacityValue = [int]$script:config.opacity
    if ($opacityValue -lt 50) { $opacityValue = 50 }
    if ($opacityValue -gt 100) { $opacityValue = 100 }
    $lblOpacity = New-Hint (([string]$opacityValue) + '%') 140 462 60 18
    $lblOpacity.ForeColor = $fg

    $slider = New-Object System.Windows.Forms.Panel
    $slider.Left = $left; $slider.Top = 482; $slider.Width = 210; $slider.Height = 20
    $slider.BackColor = $bg
    $slider.Tag = $opacityValue
    $slider.Add_Paint({
        $s = $args[0]
        $e = $args[1]
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pad = 7; $trackY = 10; $span = $s.Width - $pad * 2
        $v = [int]$s.Tag
        $pos = $pad + [int]($span * (($v - 50) / 50.0))
        $trackPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 58, 61, 70), 3)
        $g.DrawLine($trackPen, $pad, $trackY, ($pad + $span), $trackY)
        $trackPen.Dispose()
        $accentBrush = New-Object System.Drawing.SolidBrush($script:accentByState['working'])
        $g.FillRectangle($accentBrush, $pad, ($trackY - 1), [int]($pos - $pad), 2)
        $accentBrush.Dispose()
        $knob = New-Object System.Drawing.SolidBrush($script:clrText)
        $g.FillEllipse($knob, ($pos - 6), ($trackY - 6), 12, 12)
        $knob.Dispose()
    })
    $script:opacityLabel = $lblOpacity
    $script:opacitySlider = $slider
    $slider.Add_MouseDown({
        $s = $args[0]
        $s.Capture = $true
        $pad = 7; $span = $s.Width - $pad * 2
        $x = [System.Windows.Forms.Cursor]::Position.X - $s.PointToScreen([System.Drawing.Point]::Empty).X
        $v = 50 + [int]([math]::Round(([math]::Max(0, [math]::Min($span, ($x - $pad))) / $span) * 50))
        $s.Tag = $v
        $script:opacityLabel.Text = ([string]$v) + '%'
        $s.Invalidate()
    })
    $slider.Add_MouseMove({
        $s = $args[0]
        if (-not $s.Capture) { return }
        $pad = 7; $span = $s.Width - $pad * 2
        $x = [System.Windows.Forms.Cursor]::Position.X - $s.PointToScreen([System.Drawing.Point]::Empty).X
        $v = 50 + [int]([math]::Round(([math]::Max(0, [math]::Min($span, ($x - $pad))) / $span) * 50))
        $s.Tag = $v
        $script:opacityLabel.Text = ([string]$v) + '%'
        $s.Invalidate()
    })
    $slider.Add_MouseUp({ $args[0].Capture = $false })
    $dlg.Controls.Add($slider)

    New-Section 'Язык' $left 520
    $langValues = @('auto', 'en', 'ru', 'zh-CN')
    $langIndex = [array]::IndexOf($langValues, [string]$script:config.language)
    if ($langIndex -lt 0) { $langIndex = 0 }
    $ddLang = New-Dropdown $left 544 220 @('Авто', 'English', 'Русский', '简体中文') $langIndex
    [void](New-Hint 'Применится после перезапуска виджета.' $left 578 300 16)

    # ---------------- правая колонка
    New-Section 'УВЕДОМЛЕНИЯ' $right 72
    [void](New-Label 'Звук завершения' $right 96 200)
    $soundIndex = switch ([string]$script:config.soundMode) {
        'system' { 1 }
        'off' { 2 }
        default { if ([bool]$script:config.sound) { 0 } else { 2 } }
    }
    $ddSound = New-Dropdown $right 116 300 @('Встроенный «тук-тук»', 'Системный сигнал Windows', 'Без звука') $soundIndex
    [void](New-Hint 'При ошибке звучит системный сигнал Windows.' $right 152 300 16)

    [void](New-Label 'Сколько секунд показывать «Готово» и ошибку' $right 200 300)
    $numDone = New-Number $right 218 $script:config.doneVisibleSec 30 3600 80

    New-Section 'ВИДЖЕТ' $right 266
    [void](New-Label 'Сколько сессий показывать одновременно' $right 290 300)
    $numSessions = New-Number $right 308 $script:config.maxSessions 1 3 70

    New-Section 'БАЛАНС DEEPSEEK' $right 362
    $cbBalance = New-Check 'Показывать баланс DeepSeek' $right 386 $script:config.balance

    [void](New-Label 'Откуда брать баланс' $right 412 200)
    $sourceIndex = switch ([string]$script:config.balanceSource) { 'apikey' { 1 } 'off' { 2 } default { 0 } }
    $ddSource = New-Dropdown $right 430 300 @('Аккаунт DeepSeek (как в DSH)', 'Свой ключ DeepSeek', 'Выключен') $sourceIndex
    $ddSource.OnChange = { Update-SettingsKeyVisibility }

    $lblKey = New-Label 'Ключ DeepSeek' $right 464 200
    $tbKey = New-TextBox $right 482 220 $script:config.balanceApiKey
    $tbKey.UseSystemPasswordChar = $true
    $lblKeyHint = New-Hint 'Хранится локально в config.json' $right 512 190 16
    $lnkKey = New-LinkLabel 'Где взять ключ?' ($right + 196) 512 104
    $lnkKey.Add_LinkClicked({
        try { Start-Process 'https://platform.deepseek.com/api_keys' } catch { }
    })
    $script:settingsKeyUi = @{ Source = $ddSource; Label = $lblKey; Box = $tbKey; Hint = $lblKeyHint; Link = $lnkKey }
    Update-SettingsKeyVisibility

    # ---------------- подвал
    $accentSave = [System.Drawing.Color]::FromArgb(255, 58, 108, 210)
    $accentSaveBorder = [System.Drawing.Color]::FromArgb(255, 76, 141, 255)
    $btnSave = New-Button 'Сохранить' ($W - 164) ($H - 48) 140 32 $accentSave ([System.Drawing.Color]::White) $accentSaveBorder
    $btnSave.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(255, 70, 124, 228)
    $btnCancel = New-Button 'Отмена' ($W - 290) ($H - 48) 118 32 $btnBg $fg $line
    $btnDefaults = New-Button 'Вернуть по умолчанию' $left ($H - 48) 210 32 $btnBg $fg $line

    $dlg.AcceptButton = $btnSave
    $dlg.CancelButton = $btnCancel
    $btnCancel.Add_Click({ $dlg.Close() })

    $btnDefaults.Add_Click({
        $cbTop.Checked = $true
        if ($pluginInstalled) { $rbPlugin.Checked = $true } else { $rbManual.Checked = $true }
        Set-Dropdown $ddSound 0
        Set-Dropdown $ddTheme 0
        Set-Dropdown $ddSource 0
        Set-Dropdown $ddLang 0
        $tbKey.Text = ''
        Update-SettingsKeyVisibility
        $script:opacitySlider.Tag = 100
        $script:opacityLabel.Text = '100%'
        $script:opacitySlider.Invalidate()
        $numDone.Value = 180
        $numSessions.Value = 3
        $cbAccent.Checked = $true
        $cbBalance.Checked = $true
    })

    $btnSave.Add_Click({
        $oldLanguage = [string]$script:config.language
        $mode = 'manual'
        if ($rbPlugin.Checked) { $mode = 'plugin' }
        elseif ($rbStartup.Checked) { $mode = 'startup' }

        if ($mode -eq 'plugin' -and -not $pluginInstalled) {
            [void][System.Windows.Forms.MessageBox]::Show(
                (T 'Плагин bridge не установлен в профиль DSH. Виджет будет запускаться вручную — переустановите виджет, чтобы включить режим «вместе с DSH».'),
                (T 'Режим запуска'), 'OK', 'Information')
            $mode = 'manual'
        }

        $script:config.launchMode = $mode
        $script:config.autostart = ($mode -eq 'startup')
        Set-Autostart ($mode -eq 'startup')

        if ($mode -ne 'plugin' -and $pluginInstalled) {
            try {
                $remover = Join-Path $scriptDir 'tools\remove-plugin.ps1'
                if (Test-Path -LiteralPath $remover) {
                    $quoted = '"' + $remover + '"'
                    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quoted, '-Quiet') -WindowStyle Hidden | Out-Null
                }
            } catch { }
        }

        $script:config.topMost = [bool]$cbTop.Checked
        $script:config.theme = @('system', 'light', 'dark')[[int]$ddTheme.Index]
        $soundIdx = [int]$ddSound.Index
        $script:config.sound = ($soundIdx -ne 2)
        $script:config.soundMode = @('builtin', 'system', 'off')[$soundIdx]
        $script:customSoundBroken = $false
        $script:config.doneVisibleSec = [int]$numDone.Value
        $script:config.maxSessions = [int]$numSessions.Value
        $script:config.opacity = [int]$slider.Tag
        $script:config.accentBar = [bool]$cbAccent.Checked
        $script:config.balance = [bool]$cbBalance.Checked
        $script:config.balanceSource = @('account', 'apikey', 'off')[[int]$ddSource.Index]
        $script:config.balanceApiKey = ([string]$tbKey.Text).Trim()
        $script:config.language = $langValues[[int]$ddLang.Index]
        $script:config.exitWhenDshClosedMin = $(if ($mode -eq 'plugin') { 5 } else { 0 })

        Save-Config

        if ([string]$script:config.language -ne $oldLanguage) {
            $dlg.Close()
            Restart-Widget
            return
        }

        $form.TopMost = [bool]$script:config.topMost
        $form.Opacity = [double]([math]::Max(50, [math]::Min(100, [int]$script:config.opacity))) / 100.0
        Set-ThemePalette (Get-EffectiveTheme)
        $form.BackColor = $script:clrBg
        if ($script:cardVisible -and -not $form.Visible) { $form.Show() }

        try { Invoke-EngineJson '/balance/refresh' | Out-Null } catch { }

        Update-Snapshot
        $form.Invalidate()
        $dlg.Close()
    })

    if ($AutoCloseMs -gt 0) {
        $shotTimer = New-Object System.Windows.Forms.Timer
        $shotTimer.Interval = $AutoCloseMs
        $shotTimer.Add_Tick({
            $shotTimer.Stop()
            if ($ShotPath) {
                try {
                    $bmp = New-Object System.Drawing.Bitmap($dlg.Width, $dlg.Height)
                    $g = [System.Drawing.Graphics]::FromImage($bmp)
                    $g.CopyFromScreen($dlg.Left, $dlg.Top, 0, 0, (New-Object System.Drawing.Size($dlg.Width, $dlg.Height)))
                    $g.Dispose()
                    $bmp.Save($ShotPath, [System.Drawing.Imaging.ImageFormat]::Png)
                    $bmp.Dispose()
                } catch { }
            }
            if ($SaveOnClose) { $btnSave.PerformClick() } else { $dlg.Close() }
        })
        $shotTimer.Start()
    }

    [void]$dlg.ShowDialog($form)
}

# ------------------------------------------------------------------ о программе

function Show-AboutWindow {
    param([int]$AutoCloseMs = 0, [string]$ShotPath = '')
    $W = 420; $H = 260
    $dlg = New-Object DshCardForm
    $dlg.Width = $W; $dlg.Height = $H
    $dlg.BackColor = $script:clrBg
    $dlg.TopMost = $false
    $dlg.ShowInTaskbar = $true
    $dlg.Text = T 'О DSH Widget'
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dlg.KeyPreview = $true
    $dlg.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $sender.Close() }
    })
    if ($script:appIcon) { $dlg.Icon = $script:appIcon }
    $dlg.Add_HandleCreated({
        try {
            if (-not [DshNative]::RoundCorners($dlg.Handle)) { [DshNative]::ApplyRoundRegion($dlg.Handle, $dlg.Width, $dlg.Height, 14) }
        } catch { }
    })
    $dlg.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear($script:clrBg)
        $pen = New-Object System.Drawing.Pen($script:clrBorder, 1)
        $path = New-RoundedPath 0.5 0.5 ($W - 1.5) ($H - 1.5) 14
        $g.DrawPath($pen, $path)
        $g.DrawLine($pen, 0, 58, $W, 58)
        $path.Dispose(); $pen.Dispose()
    })

    $beginDrag = {
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            try { [DshNative]::BeginDrag($dlg.Handle) } catch { }
        }
    }
    $dlg.Add_MouseDown($beginDrag)

    $iconBmp = $null
    try {
        $iconBmp = Get-IconFrameBitmap (Join-Path $scriptDir 'assets\DSHWidget.ico') 64
        if (-not $iconBmp) { $iconBmp = Get-IconFrameBitmap (Join-Path $scriptDir 'assets\DSHWidget.ico') 48 }
    } catch { }
    if ($iconBmp) {
        $pb = New-Object System.Windows.Forms.PictureBox
        $pb.Left = 20; $pb.Top = 9; $pb.Width = 40; $pb.Height = 40
        $pb.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $pb.Image = $iconBmp
        $pb.BackColor = $script:clrBg
        $dlg.Controls.Add($pb)
    }

    function New-AboutLabel($text, $x, $y, $w, $h, $font, $color) {
        $text = T $text
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Left = $x; $l.Top = $y; $l.Width = $w; $l.Height = $h
        $l.BackColor = $script:clrBg; $l.ForeColor = $color; $l.Font = $font
        $dlg.Controls.Add($l)
        return $l
    }

    $titleFont = New-Object System.Drawing.Font($script:fontStatus.FontFamily, 16, [System.Drawing.FontStyle]::Bold)
    [void](New-AboutLabel 'DSH Widget' 76 9 300 28 $titleFont $script:clrText)
    [void](New-AboutLabel ((T 'Версия ') + $script:appVersion) 78 36 220 16 $script:fontLabel $script:clrMuted)

    $btnClose = New-Object System.Windows.Forms.Label
    $btnClose.Text = '✕'
    $btnClose.Left = $W - 40; $btnClose.Top = 8; $btnClose.Width = 28; $btnClose.Height = 28
    $btnClose.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $btnClose.ForeColor = $script:clrDim; $btnClose.BackColor = $script:clrBg
    $btnClose.Font = New-Object System.Drawing.Font($script:fontLabel.FontFamily, 11)
    $btnClose.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnClose.Add_MouseEnter({ $btnClose.ForeColor = $script:clrText; $btnClose.BackColor = $script:clrButton })
    $btnClose.Add_MouseLeave({ $btnClose.ForeColor = $script:clrDim; $btnClose.BackColor = $script:clrBg })
    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnClose)

    $bodyFont = New-Object System.Drawing.Font($script:fontDetail.FontFamily, 9.5)
    [void](New-AboutLabel 'Виджет состояния DeepSeek Harness для Windows.' 24 72 372 18 $bodyFont $script:clrText)
    [void](New-AboutLabel 'Показывает, чем занят агент, чего он ждёт от вас и что уже готово.' 24 94 372 18 $script:fontDetail $script:clrMuted)
    [void](New-AboutLabel 'Неофициальный проект. DSH не изменяется: виджет только читает локальные журналы сессий.' 24 116 372 32 $script:fontDetail $script:clrMuted)

    [void](New-AboutLabel ((T 'Автор: ') + (T $script:author)) 24 154 372 16 $script:fontLabel $script:clrMuted)
    [void](New-AboutLabel 'GitHub' 24 176 64 16 $script:fontLabel $script:clrMuted)
    $gitTop = 176
    if ($script:repoUrl) {
        $lnkGit = New-Object System.Windows.Forms.LinkLabel
        $lnkGit.Text = $script:repoUrl
        $lnkGit.Left = 86; $lnkGit.Top = $gitTop; $lnkGit.Width = 310; $lnkGit.Height = 16
        $lnkGit.BackColor = $script:clrBg
        $lnkGit.Font = $script:fontDetail
        $lnkGit.LinkColor = $script:accentByState['working']
        $lnkGit.ActiveLinkColor = $script:clrText
        $lnkGit.VisitedLinkColor = $script:accentByState['working']
        $lnkGit.LinkBehavior = [System.Windows.Forms.LinkBehavior]::HoverUnderline
        $lnkGit.Add_LinkClicked({ try { Start-Process $script:repoUrl } catch { } })
        $dlg.Controls.Add($lnkGit)
    } else {
        [void](New-AboutLabel 'Ссылка появится после публикации репозитория.' 86 $gitTop 310 16 $script:fontDetail $script:clrDim)
    }

    [void](New-AboutLabel 'Лицензия MIT' 24 198 200 16 $script:fontLabel $script:clrMuted)
    $lnkFolder = New-Object System.Windows.Forms.LinkLabel
    $lnkFolder.Text = T 'Открыть папку виджета'
    $lnkFolder.Left = 24; $lnkFolder.Top = 220; $lnkFolder.Width = 220; $lnkFolder.Height = 16
    $lnkFolder.BackColor = $script:clrBg
    $lnkFolder.Font = $script:fontDetail
    $lnkFolder.LinkColor = $script:accentByState['working']
    $lnkFolder.ActiveLinkColor = $script:clrText
    $lnkFolder.VisitedLinkColor = $script:accentByState['working']
    $lnkFolder.LinkBehavior = [System.Windows.Forms.LinkBehavior]::HoverUnderline
    $lnkFolder.Add_LinkClicked({ try { Start-Process -FilePath $scriptDir } catch { } })
    $dlg.Controls.Add($lnkFolder)

    # Отдельная кнопка «Закрыть» не нужна: крестик в шапке и Esc.

    if ($AutoCloseMs -gt 0) {
        $shotTimer = New-Object System.Windows.Forms.Timer
        $shotTimer.Interval = $AutoCloseMs
        $shotTimer.Add_Tick({
            $shotTimer.Stop()
            if ($ShotPath) {
                try {
                    $bmp = New-Object System.Drawing.Bitmap($dlg.Width, $dlg.Height)
                    $g = [System.Drawing.Graphics]::FromImage($bmp)
                    $g.CopyFromScreen($dlg.Left, $dlg.Top, 0, 0, (New-Object System.Drawing.Size($dlg.Width, $dlg.Height)))
                    $g.Dispose()
                    $bmp.Save($ShotPath, [System.Drawing.Imaging.ImageFormat]::Png)
                    $bmp.Dispose()
                } catch { }
            }
            $dlg.Close()
        })
        $dlg.Add_Shown({ $shotTimer.Start() })
    }

    [void]$dlg.ShowDialog($form)
}

# ------------------------------------------------------------------ трей

function Get-IconFrameBitmap([string]$path, [int]$size) {
    # В .ico кадры сжаты PNG — Icon.ToBitmap() их не понимает, поэтому достаём кадр сами.
    try {
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
    } catch { }
    return $null
}

# Фирменная иконка трея: одна статичная, без точек состояния.
$script:trayIcon = $null
try {
    $trayIconPath = Join-Path $scriptDir 'assets\DSHWidget-Tray.ico'
    if (Test-Path -LiteralPath $trayIconPath) {
        $script:trayIcon = New-Object System.Drawing.Icon($trayIconPath)
        Write-WidgetLog 'tray icon: static branded'
    }
} catch {
    $script:trayIcon = $null
}
if (-not $script:trayIcon) {
    $script:trayIcon = [System.Drawing.SystemIcons]::Application
    Write-WidgetLog 'tray icon: fallback'
}
$script:trayStatus = ''
$script:appIcon = $null
try {
    $appIconPath = Join-Path $scriptDir 'assets\DSHWidget.ico'
    if (Test-Path -LiteralPath $appIconPath) { $script:appIcon = New-Object System.Drawing.Icon($appIconPath) }
} catch { $script:appIcon = $null }

# При выходе гасим движок и убираем иконку, иначе остаётся осиротевший node.exe.
$form.Add_FormClosing({
    try { $tray.Visible = $false; $tray.Dispose() } catch { }
    Remove-RuntimeState
    try {
        if ($script:engineProc -and -not $script:engineProc.HasExited) { $script:engineProc.Kill() }
    } catch { }
})
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $script:trayIcon
$tray.Text = T 'Виджет DSH'
# Регистрируем иконку не сразу, а после старта цикла сообщений (см. Add_Shown):
# так оболочка надёжнее принимает Shell_NotifyIcon.
$tray.Visible = $false

# Левый клик по иконке в трее — показать/скрыть карточку.
$tray.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $script:cardVisible = -not $script:cardVisible
    $script:manualShow = $script:cardVisible
    if ($script:cardVisible) { $script:emptySince = $null; $form.Show(); $form.BringToFront() } else { $form.Hide() }
    $miShow.Text = if ($script:cardVisible) { T 'Скрыть виджет' } else { T 'Показать виджет' }
})
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.ShowImageMargin = $false
$menu.Renderer = New-Object DshDarkMenuRenderer
$menu.Font = $script:fontLabel

$miShow = New-Object System.Windows.Forms.ToolStripMenuItem((T 'Показать виджет'))
$miShow.CheckOnClick = $false
$miShow.Add_Click({
    $script:cardVisible = -not $script:cardVisible
    $script:manualShow = $script:cardVisible
    if ($script:cardVisible) { $script:emptySince = $null; $form.Show(); $form.BringToFront() } else { $form.Hide() }
})

$miOpen = New-Object System.Windows.Forms.ToolStripMenuItem((T 'Открыть DeepSeek Harness'))
$miOpen.Add_Click({ Open-DshWindow })

$miSettings = New-Object System.Windows.Forms.ToolStripMenuItem((T 'Настройки…'))
$miSettings.Add_Click({ Show-SettingsWindow })

$miAbout = New-Object System.Windows.Forms.ToolStripMenuItem((T 'О программе'))
$miAbout.Add_Click({ Show-AboutWindow })

$miBalance = New-Object System.Windows.Forms.ToolStripMenuItem((T 'Обновить баланс'))
$miBalance.Add_Click({
    try { Invoke-EngineJson '/balance/refresh' | Out-Null } catch { }
    Update-Snapshot
})

$miExit = New-Object System.Windows.Forms.ToolStripMenuItem((T 'Выход'))
$miExit.Add_Click({ Exit-Widget })

[void]$menu.Items.Add($miShow)
[void]$menu.Items.Add($miOpen)
[void]$menu.Items.Add($miSettings)
[void]$menu.Items.Add($miAbout)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($miBalance)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($miExit)

$menu.Add_Opening({
    $miShow.Text = if ($script:cardVisible) { T 'Скрыть виджет' } else { T 'Показать виджет' }
    $miBalance.Enabled = [bool]$script:config.balance
})

$tray.ContextMenuStrip = $menu
$tray.Add_MouseDoubleClick({ Open-DshWindow })

# То же меню по правому клику на самой карточке — на случай, если иконка в трее
# спрятана Windows в «скрытые».
$form.ContextMenuStrip = $menu

function Set-Autostart([bool]$enable) {
    $startup = [Environment]::GetFolderPath('Startup')
    $lnk = Join-Path $startup 'DSH Widget.lnk'
    $legacy = Join-Path $startup 'DeepSeek Harness Widget.lnk'
    if ($enable) {
        $vbs = Join-Path $scriptDir 'start-widget.vbs'
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($lnk)
        $sc.TargetPath = 'wscript.exe'
        $sc.Arguments = '"' + $vbs + '"'
        $sc.WorkingDirectory = $scriptDir
        $sc.WindowStyle = 7
        $sc.Description = T 'Виджет состояния DeepSeek Harness'
        $sc.Save()
    } else {
        foreach ($f in @($lnk, $legacy)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    }
}

# ------------------------------------------------------------------ опрос движка

$script:missedPolls = 0

# Все запросы к движку — через один helper: WebClient всегда освобождается.
function Invoke-EngineJson([string]$path, [string]$method = 'GET', [string]$body = $null) {
    $wc = New-Object System.Net.WebClient
    $wc.Proxy = $null
    $wc.Encoding = [System.Text.Encoding]::UTF8
    try {
        if ($method -eq 'POST') {
            $wc.Headers['Content-Type'] = 'application/json'
            return ($wc.UploadString("http://127.0.0.1:$($script:port)$path", 'POST', $body) | ConvertFrom-Json)
        }
        return ($wc.DownloadString("http://127.0.0.1:$($script:port)$path") | ConvertFrom-Json)
    } finally {
        $wc.Dispose()
    }
}

function Update-Snapshot {
    $paletteChanged = $false
    # Тема «как в системе»: раз в 4 секунды проверяем оформление Windows и переключаем палитру.
    if (((Get-Date) - $script:lastThemeCheck).TotalSeconds -gt 4) {
        $script:lastThemeCheck = Get-Date
        $want = Get-EffectiveTheme
        $hc = [bool][System.Windows.Forms.SystemInformation]::HighContrast
        # Акцент Windows меняется отдельно от темы — сравниваем и его, иначе спиннер не перекрасится.
        $accentNow = $null
        if ($hc -or [bool]$script:config.accentBar) { $accentNow = Get-SystemAccentColor }
        $accentChanged = [bool]($accentNow -and $script:accentColor -and ($accentNow.ToArgb() -ne $script:accentColor.ToArgb()))
        if ($accentChanged) { Write-WidgetLog ('accent: #' + $accentNow.R.ToString('X2') + $accentNow.G.ToString('X2') + $accentNow.B.ToString('X2')) }
        if ($want -ne $script:theme -or $hc -ne $script:highContrast -or $accentChanged) {
            Set-ThemePalette $want
            $form.BackColor = $script:clrBg
            $paletteChanged = $true
        }
    }

    # Get-Process недёшев — проверяем не чаще раза в 3 секунды.
    if (((Get-Date) - $script:lastDshCheck).TotalSeconds -gt 3) {
        $script:lastDshCheck = Get-Date
        $script:dshRunning = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue).Count -gt 0
    }

    # Авто-выход: если DSH закрыт дольше N минут, виджет завершается, чтобы не висеть в процессах.
    if ($script:dshRunning) {
        $script:dshGoneSince = $null
    } else {
        if (-not $script:dshGoneSince) { $script:dshGoneSince = Get-Date }
        $exitMin = 0
        if ($null -ne $script:config.exitWhenDshClosedMin) { $exitMin = [int]$script:config.exitWhenDshClosedMin }
        if ($exitMin -gt 0 -and ((Get-Date) - $script:dshGoneSince).TotalMinutes -ge $exitMin) {
            Write-WidgetLog ('exit: DSH закрыт дольше ' + $exitMin + ' мин')
            Exit-Widget
            return
        }
    }

    try {
        $script:snap = Invoke-EngineJson '/status'
        $script:engineOk = $true
        $script:lastSnapAt = Get-Date
        $script:missedPolls = 0
    } catch {
        $script:engineOk = $false
        $script:missedPolls++
        if ($script:missedPolls -eq 3) {
            $script:snap = $null
            Start-Engine | Out-Null
        } elseif ($script:missedPolls % 30 -eq 0) {
            Start-Engine | Out-Null
        }
        $oldKey = $script:viewKey
        Update-ViewCache
        $wantHeight = Get-CardHeight $script:rows.Count $script:overflowCount
        if ($form.Height -ne $wantHeight) { $form.Height = $wantHeight }
        if ($script:viewKey -ne $oldKey) { $form.Invalidate() }
        return
    }

    # просмотренные задачи убираем: если в фокусе окно DSH с этой сессией — она считается прочитанной.
    # Недавний фокус тоже учитываем: ход мог завершиться через секунду после того, как вы открыли окно.
    $fgTitle = Get-ForegroundDshTitle
    if ($fgTitle) {
        $script:lastDshTitle = $fgTitle
        $script:lastDshTitleAt = Get-Date
    }
    if ($script:snap.sessions) {
        $recentTitle = ''
        if ($script:lastDshTitle -and ((Get-Date) - $script:lastDshTitleAt).TotalSeconds -lt 15) {
            $recentTitle = $script:lastDshTitle
        }
        foreach ($s in @($script:snap.sessions)) {
            if ([string]$s.status -ne 'done') { continue }
            # Ошибку не считаем просмотренной только потому, что окно DSH было в фокусе:
            # пользователь должен увидеть её на карточке (и снять кликом по блоку).
            if ($s.done -and $s.done.ok -eq $false) { continue }
            $title = [string]$s.title
            if (Test-TitleMatch $fgTitle $title) { Send-Ack ([string]$s.id); continue }
            if ($recentTitle -and (Test-TitleMatch $recentTitle $title)) { Send-Ack ([string]$s.id) }
        }
    }

    # Завершение работы: всплывающего окна нет — только звук, статус виден на карточке.
    # emittedAt — когда движок признал работу завершённой (после субагентов),
    # at — когда закончился сам ход; сравниваем по первому.
    $c = $script:snap.lastCompletion
    if ($c) {
        $emitted = [double]$c.at
        if ($null -ne $c.emittedAt) { $emitted = [double]$c.emittedAt }
        if (-not $script:completionSeen) {
            $script:completionSeen = $true
            $script:lastCompletionAt = $emitted
            # Если виджет стартовал во время хода, первое завершение — не история.
            $ageMs = [double]$script:snap.now - $emitted
            if ($emitted -ge $script:startedAtMs -and $ageMs -lt 90000 -and $script:config.sound) {
                Play-NotificationSound ([bool]($null -ne $c.ok -and $c.ok -eq $false))
            }
        } elseif ($emitted -gt $script:lastCompletionAt) {
            $script:lastCompletionAt = $emitted
            $ageMs = [double]$script:snap.now - $emitted
            # звучим только для свежих завершений — старые (история) не озвучиваем
            if ($ageMs -lt 90000 -and $script:config.sound) {
                Play-NotificationSound ([bool]($null -ne $c.ok -and $c.ok -eq $false))
            }
        }
    }

    $oldKey = $script:viewKey
    Update-ViewCache

    # Пустой карточки не бывает: показываем только когда есть что показывать.
    # Работа появилась — показываем; всё завершилось и просмотрено — прячем (пауза 5 c, чтобы не мигало).
    if ($script:rows.Count -gt 0) {
        $script:emptySince = $null
        if ($script:cardVisible -and -not $form.Visible) { $form.Show(); $form.Invalidate() }
    } elseif ($script:engineOk) {
        if (-not $script:emptySince) { $script:emptySince = Get-Date }
        elseif ($form.Visible -and $script:cardVisible -and ((Get-Date) - $script:emptySince).TotalSeconds -ge 5) { $form.Hide() }
    }

    # Статичная иконка трея; состояние показываем только в подсказке.
    $inset = Get-StatusText $script:snap.primary $script:engineOk
    if ($script:trayStatus -ne $inset.status) {
        $script:trayStatus = $inset.status
        $tray.Text = (T 'Виджет DSH — ') + $inset.status
    }

    # высота карточки зависит от числа показанных сессий; растём вверх и не залезаем
    # на панель задач — позиция зажимается по рабочей области.
    $wantHeight = Get-CardHeight $script:rows.Count $script:overflowCount
    $heightChanged = ($form.Height -ne $wantHeight)
    if ($heightChanged) {
        $wa = Get-CardWorkingArea
        $newTop = $form.Top - ($wantHeight - $form.Height)
        $newTop = [math]::Max($wa.Top + 8, [math]::Min($newTop, $wa.Bottom - $wantHeight - 8))
        $form.SetBounds($form.Left, [int]$newTop, $form.Width, $wantHeight)
        if ($script:dwmCorners -eq $false) { [DshNative]::ApplyRoundRegion($form.Handle, $form.Width, $form.Height, 12) }
    }

    if ($script:viewKey -ne $oldKey -or $paletteChanged -or $heightChanged) { $form.Invalidate() }
}

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 450
$pollTimer.Add_Tick({
    try { Update-Snapshot } catch { Write-WidgetLog ('poll error: ' + $_.Exception.Message) }
})

$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 50
$animTimer.Add_Tick({
    $script:anim++
    $active = $false
    foreach ($r in $script:rows) {
        if ([string]$r.state -in @('working', 'waiting', 'subagents')) { $active = $true; break }
    }
    if ($active) { $form.Invalidate() }
})

# ------------------------------------------------------------------ старт

$form.Add_Shown({
    # иконка в трее — после того, как окно и цикл сообщений уже живут
    try {
        $tray.Visible = $true
        Write-WidgetLog ('tray visible=' + $tray.Visible + ' handle=' + $tray.Icon.Handle)
        Save-RuntimeState
    } catch {
        Write-WidgetLog ('tray error: ' + $_.Exception.Message)
    }
    if (-not $SelfTest) {
        Update-Snapshot
        $pollTimer.Start()
    }
    $animTimer.Start()
})

if ($SelfTest) {
    $form.Show()
    if ($DemoTheme) {
        $script:config.theme = $DemoTheme
        $theme = if ($DemoTheme -eq 'system') { Get-EffectiveTheme } else { $DemoTheme }
        Set-ThemePalette $theme
        $script:lastThemeCheck = Get-Date
        $form.BackColor = $script:clrBg
    }
    if ($ShowAbout) {
        $script:snap = New-DemoSnapshot 'working'
        Show-AboutWindow -AutoCloseMs 900 -ShotPath (Join-Path $scriptDir 'selftest-about.png')
        $form.Close()
        $tray.Visible = $false
        Write-Output ('about: ' + (Join-Path $scriptDir 'selftest-about.png'))
        return
    }
    if ($ShowSettings) {
        $script:snap = New-DemoSnapshot 'working'
        # Превью для документации снимаем с демо-значениями: личные пути не должны попасть в архив.
        $script:config.balanceApiKey = ''
        Show-SettingsWindow -AutoCloseMs 900 -ShotPath (Join-Path $scriptDir 'selftest-settings.png') -SaveOnClose:$SettingsSave
        $form.Close()
        $tray.Visible = $false
        Write-Output ('settings: ' + (Join-Path $scriptDir 'selftest-settings.png'))
        return
    }
    if ($Demo -eq 'offline') {
        $script:engineOk = $false
        $script:snap = $null
        $script:manualShow = $true
        $script:lastSnapAt = Get-Date
        Update-ViewCache
        $form.Height = Get-CardHeight $script:rows.Count $script:overflowCount
    } elseif ($Demo) {
        $script:engineOk = $true
        $script:snap = New-DemoSnapshot $Demo
        if ($Demo -eq 'empty' -or $Demo -eq 'idle') { $script:manualShow = $true }
        $script:lastSnapAt = Get-Date
        Update-ViewCache
        $form.Height = Get-CardHeight $script:rows.Count $script:overflowCount
    } else {
        Update-Snapshot
    }
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 700
    $form.Invalidate()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 250

    $shotName = if ($Demo) { $Demo } else { 'live' }
    if ($DemoTheme) { $shotName += '-' + $DemoTheme }
    $shot = Join-Path $scriptDir ('selftest-' + $shotName + '.png')
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save($shot, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()


    # общий снимок экрана — чтобы увидеть карточку в контексте рабочего стола
    $wa = Get-CardWorkingArea
    $sx = [int]($wa.Right - 420); $sy = [int]($wa.Bottom - 300)
    $screenShot = Join-Path $scriptDir ('selftest-screen-' + $shotName + '.png')
    $sb = New-Object System.Drawing.Bitmap(420, 300)
    $sg = [System.Drawing.Graphics]::FromImage($sb)
    try { $sg.CopyFromScreen($sx, $sy, 0, 0, (New-Object System.Drawing.Size(420, 300))) } catch { }
    $sg.Dispose()
    $sb.Save($screenShot, [System.Drawing.Imaging.ImageFormat]::Png)
    $sb.Dispose()

    Write-Output ('card ' + $form.Width + 'x' + $form.Height + ' at ' + $form.Left + ',' + $form.Top)
    $primaryForStatus = $null
    if ($script:snap) { $primaryForStatus = $script:snap.primary }
    Write-Output ('status: ' + (Get-StatusText $primaryForStatus $script:engineOk | ConvertTo-Json -Compress))
    Write-Output ('shot: ' + $shot)
    Write-Output ('screen: ' + $screenShot)
    $form.Close()
    $tray.Visible = $false
    return
}

[System.Windows.Forms.Application]::Run($form)
