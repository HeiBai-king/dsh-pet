# ============================================================================
# pet-ball.ps1 —— DSH 桌宠 · 桌面鲸鱼球（P1）
# ----------------------------------------------------------------------------
# 与旧版（桌宠v1\pet-desktop.ps1）的区别，全部来自实测：
#   1. 穿透：旧版没做，透明区照样吃鼠标。
#      实测 WM_NCHITTEST/HTTRANSPARENT **跨进程无效**（只有同线程窗口链才往下找），
#      所以改用 SetWindowRgn —— 把窗口区域裁成鲸鱼的形状，区域之外窗口在命中测试里
#      根本"不存在"，穿透由系统完成，零轮询。
#   2. DPI：旧版用 SetProcessDPIAware（system-DPI aware）+ 写死的 /1.5。
#      实测本机是 150% 缩放、物理 2160×1440 —— 那个 1.5 是蒙对的，换到 125%/100% 就错。
#      本版用 PER_MONITOR_AWARE_V2，坐标统一走物理像素。
#   3. 位置/尺寸：旧版完全不存。本版落盘 $DSH_HOME\pet\window.json，带版本 + 非法值自愈。
#
# ⚠️ 本文件含中文，**必须带 UTF-8 BOM**，否则 PowerShell 5.1 按 GBK 解码 → 乱码 → 语法报错。
#    用 edit 工具改过之后要重新补 BOM。
# ============================================================================
param(
  [string]$Here = $PSScriptRoot,
  [string]$DataDir = $null,          # 默认 $DSH_HOME\pet
  [string]$Image = $null,            # 默认 $Here\whale-ball.png
  [switch]$UseRegion,                # 可选：SetWindowRgn 把窗口裁成鲸鱼形状。**默认关**
                                     #   实测（tools/test-passthrough-ab.sh）：普通 AllowsTransparency
                                     #   窗口本来就自带逐像素跨进程穿透（alpha=0 的像素放行鼠标），
                                     #   裁区域是净损失 —— 抗锯齿边缘被 1 位区域切出硬边，
                                     #   而且微软明说复杂 region 的典型症状是闪烁。
                                     #   只有"鲸鱼边缘那圈半透明像素咬手"受不了时才开。
  [switch]$NoPidFile,                # 调试：跳过单实例检查
  [switch]$Log                       # 调试：把拖动/区域等事件写进 $DataDir\pet-ball.log
)
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 路径
if (-not $DataDir) {
  $home_ = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
  $DataDir = Join-Path $home_ 'pet'
}
# 角色图：用**切图版** whale.png（没有画死的气泡）—— 气泡现在由代码画，见下面的 $bubble。
# whale-ball.png 那张图上自带一个空气泡，文字是叠上去的，一长就跑到圈外。
if (-not $Image) { $Image = Join-Path $Here 'whale.png' }
# ⚠️ pid 文件必须放在 **$DataDir**（= $DSH_HOME\pet），不能放在脚本旁边。
#    宿主那半边（lib/index.js）就是去 $DataDir 读它来判断"球在不在跑"的；
#    两边不一致的后果是：球明明活着，宿主报 "spawned but never came up"，
#    然后每点一次开关就再起一个进程（第二个会被单实例检查挡掉、静静退出）。
$PidFile  = Join-Path $DataDir 'pet-ball.pid'
$CfgFile  = Join-Path $DataDir 'window.json'
$StateFile = Join-Path $DataDir 'pet-state.json'
$StopFile = Join-Path $DataDir 'stop.flag'
# 「问一下」按钮写的请求文件，宿主监听它
$AskReqFile = Join-Path $DataDir 'ask.request'
# 「问一下」弹框里写的文字说明（可以为空）。宿主读一次就删。
$AskTextFile = Join-Path $DataDir 'ask.text'
# 会话选择：宿主 dump 的会话树（球读）、球选中的目标（宿主读）、"要最新列表"的信号
$SessionsFile = Join-Path $DataDir 'sessions.json'
$AskTargetFile = Join-Path $DataDir 'ask.target'
$SessionsWantFile = Join-Path $DataDir 'sessions.want'
$script:pickResult = $null
# 会话那半边（agent）的**回答**落在这里。
# 为什么绕这一圈：agent 被沙箱限死只能写自己的 workspace（$DSH_HOME\bot\workspace），
# 写不进 $DataDir —— 它没法直接把字写进 pet-state.json。
# 所以约定：把回答原文写进这个文件；球每秒读一次，**比 pet-state.json 新就用它**
# （谁后写谁显示，规则引擎照样能把球上的字盖回去）。
# 点了「问一下」/「发消息」之后，会话要几秒到几十秒才把回答写进 $AnswerFile。
# 这段等待期气泡固定显示「正在思考…」—— 否则数据端每 1~2 秒重写的状态文字会一直盖在上面，
# 看着跟这次提问毫无关系。等超过 $script:ASK_WAIT_MIN 分钟就放弃，回到正常显示。
$script:askingSince = [datetime]::MinValue
$script:ASK_WAIT_MIN = 3
# 最近一次**发请求**的时间。回答文件只有比它新才认作"这一轮的回答"。
# 所以回答能一直挂着，直到你下次提问（Send-Ask 会刷新它并删掉旧答案）。
#
# ⚠️ 初值是**现在**，不是 MinValue。
#    写成 MinValue 的话，球一启动磁盘上那条上次的回答就算"比它新" → 开机就把上一轮的话
#    又显示出来。用户原话：「打开自动显示上一次的话，我需要每次重启，气泡清零不显示，
#    使用再一直显示」。设成现在 = 启动时一切旧内容都不算数，只有启动后新写的才显示。
$script:lastAskAt = Get-Date
# 球启动后**有没有被用过**。false = 气泡一律不显示（重启即清零）。
# 一旦发过请求（Send-Ask）就置 true，之后回答/状态照常显示。
$script:bubbleArmed = $false
# 气泡里最多显示多少字（暂时没启用截断，留着备用）。
$script:ANSWER_MAX_CHARS = 90
# 回传文件（会话把回答写在这里，球读它上气泡）。
# ⚠️ **路径由宿主决定，不能写死**：
#    agent 被沙箱限死在它自己的 cwd，只能往那儿写；不同用户/不同会话的 cwd 完全不一样。
#    宿主每次投递时把"这一轮该写到哪"写进 $AnswerPathFile，球读它。
#    目标会话换了路径就变 → 所以必须**反复读**，不能启动时读一次就完。
$AnswerPathFile = Join-Path $DataDir 'answer-path'
$AnswerFile = Join-Path $env:USERPROFILE '.dsh\bot\workspace\pet-answer.txt'
$script:answerPathSeen = ''

function Update-AnswerFile {
  try {
    if (-not (Test-Path -LiteralPath $AnswerPathFile)) { return }
    $p0 = ([System.IO.File]::ReadAllText($AnswerPathFile, [System.Text.Encoding]::UTF8)).Trim()
    if ($p0 -and $p0 -ne $script:answerPathSeen) {
      $script:answerPathSeen = $p0
      $script:AnswerFile = $p0
      Log ("answer file -> " + $p0)
    }
  } catch {}
}
# ⚠️ 这里**不能**调用 Update-AnswerFile —— 它里面会 Log，而 Log 定义在下面很靠后，
#    过早调用会"找不到命令 Log"（被 try/catch 吞掉，路径虽然生效但没日志）。
#    真正的首次调用挪到 Log 定义之后。
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# ---------------------------------------------------------------- 单实例
if (-not $NoPidFile -and (Test-Path -LiteralPath $PidFile)) {
  $old = (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
  $n = 0
  if ($old -and [int]::TryParse("$old".Trim(), [ref]$n)) {
    $proc = Get-Process -Id $n -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -like 'powershell*') {
      Write-Output "pet-ball already running (pid=$n)"; exit 0
    }
  }
}
if (-not $NoPidFile) {
  [System.IO.File]::WriteAllText($PidFile, "$PID", (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- Win32
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public class PetNative {
  // ---- DPI ----
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("shcore.dll")] static extern int SetProcessDpiAwareness(int v);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);

  /// PER_MONITOR_AWARE_V2，失败退回 shcore 的 PER_MONITOR，再退回 system aware
  public static string InitDpi() {
    try { if (SetProcessDpiAwarenessContext((IntPtr)(-4))) return "per-monitor-v2"; } catch {}
    try { if (SetProcessDpiAwareness(2) == 0) return "per-monitor"; } catch {}
    try { if (SetProcessDPIAware()) return "system"; } catch {}
    return "none";
  }

  // ---- 窗口区域 ----
  [StructLayout(LayoutKind.Sequential)] struct RGNDATAHEADER {
    public uint dwSize; public uint iType; public uint nCount; public uint nRgnSize;
    public int bL, bT, bR, bB;
  }
  [DllImport("gdi32.dll")] static extern IntPtr ExtCreateRegion(IntPtr xform, uint nCount, byte[] data);
  [DllImport("user32.dll")] static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);
  [DllImport("gdi32.dll")] static extern IntPtr CreateRectRgn(int l, int t, int r, int b);
  [DllImport("gdi32.dll")] static extern int CombineRgn(IntPtr dst, IntPtr a, IntPtr b, int mode);
  [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);

  public static int LastBBoxL, LastBBoxT, LastBBoxR, LastBBoxB, LastSpanCount;

  /// 逐行取 alpha>thresh 的连续区间，拼成一个区域。y 步长可 >1 以减少矩形数。
  public static IntPtr BuildAlphaRegion(string png, int w, int h, int thresh, int yStep) {
    var rects = new List<int[]>();
    using (var src = new Bitmap(png))
    using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
      using (var g = Graphics.FromImage(bmp)) {
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.DrawImage(src, 0, 0, w, h);
      }
      var r = new Rectangle(0, 0, w, h);
      var bd = bmp.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      int stride = bd.Stride;
      var buf = new byte[stride * h];
      Marshal.Copy(bd.Scan0, buf, 0, buf.Length);
      bmp.UnlockBits(bd);

      int minX = w, minY = h, maxX = -1, maxY = -1;
      for (int y = 0; y < h; y += yStep) {
        int row = y * stride;
        int x = 0;
        while (x < w) {
          if (buf[row + x * 4 + 3] > thresh) {
            int x0 = x;
            while (x < w && buf[row + x * 4 + 3] > thresh) x++;
            int x1 = x;                       // [x0, x1)
            rects.Add(new int[] { x0, y, x1, Math.Min(h, y + yStep) });
            if (x0 < minX) minX = x0;
            if (x1 > maxX) maxX = x1;
            if (y < minY) minY = y;
            if (y + yStep > maxY) maxY = y + yStep;
          } else x++;
        }
      }
      LastBBoxL = minX; LastBBoxT = minY; LastBBoxR = maxX; LastBBoxB = maxY;
      LastSpanCount = rects.Count;
    }
    if (rects.Count == 0) return IntPtr.Zero;
    int n = rects.Count;
    int total = 32 + 16 * n;
    var data = new byte[total];
    // RGNDATAHEADER
    BitConverter.GetBytes((uint)32).CopyTo(data, 0);
    BitConverter.GetBytes((uint)1).CopyTo(data, 4);
    BitConverter.GetBytes((uint)n).CopyTo(data, 8);
    BitConverter.GetBytes((uint)(16 * n)).CopyTo(data, 12);
    BitConverter.GetBytes(LastBBoxL).CopyTo(data, 16);
    BitConverter.GetBytes(LastBBoxT).CopyTo(data, 20);
    BitConverter.GetBytes(LastBBoxR).CopyTo(data, 24);
    BitConverter.GetBytes(LastBBoxB).CopyTo(data, 28);
    for (int i = 0; i < n; i++) {
      int o = 32 + 16 * i;
      BitConverter.GetBytes(rects[i][0]).CopyTo(data, o);
      BitConverter.GetBytes(rects[i][1]).CopyTo(data, o + 4);
      BitConverter.GetBytes(rects[i][2]).CopyTo(data, o + 8);
      BitConverter.GetBytes(rects[i][3]).CopyTo(data, o + 12);
    }
    return ExtCreateRegion(IntPtr.Zero, (uint)total, data);
  }

  /// 把若干矩形并进已有区域（给控制条留出可点区）
  public static IntPtr UnionRects(IntPtr baseRgn, int[][] rects) {
    IntPtr acc = baseRgn;
    foreach (var rc in rects) {
      IntPtr one = CreateRectRgn(rc[0], rc[1], rc[2], rc[3]);
      if (acc == IntPtr.Zero) { acc = one; continue; }
      CombineRgn(acc, acc, one, 2);   // RGN_OR
      DeleteObject(one);
    }
    return acc;
  }

  public static bool ApplyRegion(IntPtr hWnd, IntPtr hRgn) {
    if (hRgn == IntPtr.Zero) return false;
    return SetWindowRgn(hWnd, hRgn, true) != 0;   // 成功后系统接管该 region，不要再 DeleteObject
  }

  // ---- 屏幕 ----
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, ref RECT r, uint c);
  // SPI_GETWORKAREA 只给主屏；多屏要用 MonitorFromPoint/GetMonitorInfo
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT p, uint flags);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO {
    public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
  }
  /// 取包含该点的显示器工作区（物理像素）
  public static RECT WorkAreaAt(int x, int y) {
    var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
    var p = new POINT(); p.X = x; p.Y = y;
    IntPtr mon = MonitorFromPoint(p, 2);  // MONITOR_DEFAULTTONEAREST
    if (mon != IntPtr.Zero && GetMonitorInfo(mon, ref mi)) return mi.rcWork;
    var wa = new RECT();
    SystemParametersInfo(0x0030, 0, ref wa, 0);
    return wa;
  }
  public static bool MoveWindow(IntPtr h, int x, int y) {
    return SetWindowPos(h, IntPtr.Zero, x, y, 0, 0, 0x0001 | 0x0004); // NOSIZE|NOZORDER
  }
  public static bool ResizeAndMove(IntPtr h, int x, int y, int w, int hh) {
    return SetWindowPos(h, IntPtr.Zero, x, y, w, hh, 0x0004);         // NOZORDER
  }

  // ---- 拖动：不依赖 WPF 的鼠标捕获 ----
  // 实测：窗口用了 SetWindowRgn 之后，光标一旦移出"鲸鱼区域"，窗口就不再收到 WM_MOUSEMOVE，
  // 依赖 MouseMove 的拖动会卡死在第一步（日志实证：Start-Drag 之后再无 Move）。
  // 所以改成按下后 16ms 轮询位置 + GetAsyncKeyState 判左键是否松开。
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  [DllImport("user32.dll")] public static extern IntPtr SetCapture(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ReleaseCapture();
  public static bool LeftButtonDown() {
    return (GetAsyncKeyState(0x01) & 0x8000) != 0;
  }
}
'@ -ReferencedAssemblies 'System.Drawing'

$dpiMode = [PetNative]::InitDpi()
Write-Output "dpi-awareness=$dpiMode"

# ---------------------------------------------------------------- 配置读写
function Read-Cfg {
  try {
    $o = Get-Content -LiteralPath $CfgFile -Raw | ConvertFrom-Json
    if ($o -and $o.v -eq 1 -and $null -ne $o.w -and $null -ne $o.h) { return $o }
  } catch {}
  return $null
}
function Write-Cfg($x, $y, $w, $h) {
  try {
    $o = [ordered]@{ v = 1; x = [int]$x; y = [int]$y; w = [int]$w; h = [int]$h; updatedAt = (Get-Date).ToString('o') }
    [System.IO.File]::WriteAllText($CfgFile, ($o | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

# ---------------------------------------------------------------- 窗口
$cfg = Read-Cfg
# 尺寸：配置里有就用；否则按主屏工作区的比例给一个默认
$primary = [PetNative]::WorkAreaAt(0, 0)
$defW = [int]([Math]::Min($primary.R - $primary.L, 620))
$defH = [int]([Math]::Min($primary.B - $primary.T, 620))
$physW = if ($cfg) { [int]$cfg.w } else { $defW }
$physH = if ($cfg) { [int]$cfg.h } else { $defH }

$win = New-Object System.Windows.Window
$win.WindowStyle = [System.Windows.WindowStyle]::None
$win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.Topmost = $true
$win.ShowInTaskbar = $false
$win.ResizeMode = [System.Windows.ResizeMode]::NoResize
$win.Title = 'DSH-PET-BALL'

$grid = New-Object System.Windows.Controls.Grid

# ---------------------------------------------------------------- 配色 / 字体
# 对齐余额挂件那套 —— 用户明确说它的页面"好看、整齐、全面"，是现成的参照物。
# 实测它的前端主色分布：藏青 #203170 用得最多，配浅蓝 #DBE4F5 / #F3F5FB 底、弱化 #9FB0D9。
$C_INK   = [System.Windows.Media.Color]::FromRgb(32, 49, 112)     # #203170 主色
$C_INK2  = [System.Windows.Media.Color]::FromRgb(47, 68, 136)     # #2F4488
$C_PAPER = [System.Windows.Media.Color]::FromRgb(251, 252, 254)   # #FBFCFE 气泡底
$C_SOFT  = [System.Windows.Media.Color]::FromRgb(219, 228, 245)   # #DBE4F5
function Br([System.Windows.Media.Color]$c) { New-Object System.Windows.Media.SolidColorBrush($c) }
function BrA([int]$r, [int]$g, [int]$b, [double]$a) {
  New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb([int]($a * 255), $r, $g, $b))
}
$FONT = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI, Microsoft YaHei, Segoe UI')

# ---------------------------------------------------------------- 角色
# 用 whale.png（切图版）而**不是** whale-ball.png：
# 后者图上自带一个**画死的空气泡**，文字是叠上去的 —— 一长就跑到圈外，而且字体风格和画的气泡不搭。
# 现在气泡改由代码画，尺寸自己跟着文字走，两者风格统一。
$img = New-Object System.Windows.Controls.Image
try {
  $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
  $bmp.BeginInit(); $bmp.UriSource = New-Object System.Uri($Image)
  $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
  $bmp.EndInit()
  $img.Source = $bmp
} catch { Write-Output "image load failed: $Image" }
$img.Stretch = [System.Windows.Media.Stretch]::Uniform
$grid.Children.Add($img) | Out-Null

# ---------------------------------------------------------------- 气泡（代码画）
$bubble = New-Object System.Windows.Controls.Border
$bubble.CornerRadius = New-Object System.Windows.CornerRadius(14)
$bubble.Background = Br $C_PAPER
$bubble.BorderBrush = Br $C_INK
$bubble.BorderThickness = New-Object System.Windows.Thickness(2.5)
$bubble.Padding = New-Object System.Windows.Thickness(14, 10, 14, 10)
$bubble.HorizontalAlignment = 'Left'    # 收紧到文字宽度，不被容器拉满
$bubble.VerticalAlignment = 'Top'

$bubbleBox = New-Object System.Windows.Controls.Grid
$bubbleBox.HorizontalAlignment = 'Left'
$bubbleBox.VerticalAlignment = 'Top'
$grid.Children.Add($bubbleBox) | Out-Null
$bubbleBox.Children.Add($bubble) | Out-Null

# 小尾巴：朝右下指着角色。放在同一个 auto-size 的 Grid 里、贴底负外边距探出去，
# 这样气泡无论多高，尾巴都跟着底部走。
$tail = New-Object System.Windows.Shapes.Polygon
$tail.Points = New-Object System.Windows.Media.PointCollection
$tail.Points.Add((New-Object System.Windows.Point(0, 0)))
$tail.Points.Add((New-Object System.Windows.Point(17, 0)))
$tail.Points.Add((New-Object System.Windows.Point(5, 13)))
$tail.Fill = Br $C_PAPER
$tail.Stroke = Br $C_INK
$tail.StrokeThickness = 2.5
$tail.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
$tail.HorizontalAlignment = 'Left'
$tail.VerticalAlignment = 'Bottom'
$tail.Margin = New-Object System.Windows.Thickness(30, 0, 0, -12)
$bubbleBox.Children.Add($tail) | Out-Null

$tb = New-Object System.Windows.Controls.TextBlock
$tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
$tb.FontFamily = $FONT
$tb.Foreground = Br $C_INK
$tb.LineHeight = 21
$tb.Text = 'loading...'

# Viewbox(DownOnly)：文字太长时**整体等比缩小**，保证永远待在气泡里（不再溢出去压桌面）
$vb = New-Object System.Windows.Controls.Viewbox
$vb.Stretch = [System.Windows.Media.Stretch]::Uniform
$vb.StretchDirection = [System.Windows.Controls.StretchDirection]::DownOnly
$vb.Child = $tb
$bubble.Child = $vb

# ---------------------------------------------------------------- 菜单（仿余额挂件）
# 用户要求：球上不要摊一排方块按钮，改成余额挂件那种**圆角卡片式设置面板**，
# 而且以后要能往里塞新功能（切换会话 / 换模型 / 调思考深度）。
#
# 规格直接抄余额挂件的 CSS：
#   按钮  .dshwv-menu-btn  26×26、圆角 6、底 rgba(32,49,112,.85)、悬停才 opacity 1
#   面板  .dshwv-menu      底 rgba(255,255,255,.92)、1px rgba(32,49,112,.35) 边框、
#                          圆角 10、内边距 10/12、阴影 0 6px 18px rgba(0,0,0,.18)
#   行    .dshwv-menu-row  flex、gap 8、margin 5 0、色 #203170、字号 12
#   分隔  .dshwv-menu-sep  1px rgba(32,49,112,.25)、margin 6 0

# 菜单按钮：三条杠，手画（不依赖符号字体里有没有那个字符）
$menuBtn = New-Object System.Windows.Controls.Button
$menuBtn.Width = 26; $menuBtn.Height = 26
$menuBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$menuBtn.ToolTip = '设置'
$menuBtn.Background = (BrA 32 49 112 0.85)
$menuBtn.BorderThickness = New-Object System.Windows.Thickness(0)
$menuBtn.Template = [System.Windows.Markup.XamlReader]::Parse(@'
<ControlTemplate TargetType="Button" xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
  <Border Background="{TemplateBinding Background}" CornerRadius="6">
    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
  </Border>
</ControlTemplate>
'@)
$hamb = New-Object System.Windows.Controls.StackPanel
$hamb.HorizontalAlignment = 'Center'; $hamb.VerticalAlignment = 'Center'
for ($hi = 0; $hi -lt 3; $hi++) {
  $barRect = New-Object System.Windows.Shapes.Rectangle
  $barRect.Width = 12; $barRect.Height = 1.6
  $barRect.Fill = [System.Windows.Media.Brushes]::White
  $barRect.Margin = New-Object System.Windows.Thickness(0, $(if ($hi -eq 0) { 0 } else { 3 }), 0, 0)
  $hamb.Children.Add($barRect) | Out-Null
}
$menuBtn.Content = $hamb
$menuBtn.Visibility = 'Collapsed'      # 默认隐身；鼠标进球才出现
$menuBtn.HorizontalAlignment = 'Right'
$menuBtn.VerticalAlignment = 'Top'
$grid.Children.Add($menuBtn) | Out-Null

# 面板本体
$menu = New-Object System.Windows.Controls.Border
$menu.Background = (BrA 255 255 255 0.94)
$menu.BorderBrush = (BrA 32 49 112 0.35)
$menu.BorderThickness = New-Object System.Windows.Thickness(1)
$menu.CornerRadius = New-Object System.Windows.CornerRadius(10)
$menu.Padding = New-Object System.Windows.Thickness(12, 8, 12, 8)
$menu.HorizontalAlignment = 'Right'
$menu.VerticalAlignment = 'Bottom'   # 由 Layout-Children 每次重算，这里只是初值
$menu.Visibility = 'Collapsed'
$grid.Children.Add($menu) | Out-Null

$menuStack = New-Object System.Windows.Controls.StackPanel
$menu.Child = $menuStack

function New-MenuRow {
  param([string]$Label, $Control)
  $row = New-Object System.Windows.Controls.StackPanel
  $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $row.Margin = New-Object System.Windows.Thickness(0, 2, 0, 2)
  $lab = New-Object System.Windows.Controls.TextBlock
  $lab.Text = $Label
  $lab.FontSize = 12
  $lab.FontFamily = $FONT
  $lab.Foreground = Br $C_INK
  $lab.Width = 44
  $lab.VerticalAlignment = 'Center'
  $row.Children.Add($lab) | Out-Null
  if ($Control) { $row.Children.Add($Control) | Out-Null }
  return $row
}
function New-MenuSep {
  $sep = New-Object System.Windows.Shapes.Rectangle
  $sep.Height = 1
  $sep.Fill = (BrA 32 49 112 0.25)
  $sep.Margin = New-Object System.Windows.Thickness(0, 5, 0, 5)
  return $sep
}
function New-MenuButton {
  param([string]$Text)
  $b = New-Object System.Windows.Controls.Button
  $b.Content = $Text
  $b.FontSize = 12
  $b.FontFamily = $FONT
  $b.Height = 20
  $b.Margin = New-Object System.Windows.Thickness(0, 2, 0, 2)
  $b.HorizontalAlignment = 'Stretch'
  $b.Cursor = [System.Windows.Input.Cursors]::Hand
  $b.Foreground = Br $C_INK
  $b.Background = Br $C_PAPER
  $b.BorderBrush = (BrA 32 49 112 0.45)
  $b.BorderThickness = New-Object System.Windows.Thickness(1)
  return $b
}

# —— 大小：滑块 + 百分比 ——
$sizeSlider = New-Object System.Windows.Controls.Slider
$sizeSlider.Minimum = 40; $sizeSlider.Maximum = 200; $sizeSlider.Value = 100
$sizeSlider.Width = 92
$sizeSlider.VerticalAlignment = 'Center'
$sizeSlider.IsSnapToTickEnabled = $true
$sizeSlider.TickFrequency = 5
$sizeVal = New-Object System.Windows.Controls.TextBlock
$sizeVal.Text = '100%'
$sizeVal.FontSize = 11
$sizeVal.FontFamily = $FONT
$sizeVal.Foreground = Br $C_INK2
$sizeVal.VerticalAlignment = 'Center'
$sizeVal.Margin = New-Object System.Windows.Thickness(6, 0, 0, 0)
$sizeCtl = New-Object System.Windows.Controls.StackPanel
$sizeCtl.Orientation = [System.Windows.Controls.Orientation]::Horizontal
$sizeCtl.Children.Add($sizeSlider) | Out-Null
$sizeCtl.Children.Add($sizeVal) | Out-Null

# —— 自动翻转：贴屏幕左半边时角色面朝右 ——
$flipChk = New-Object System.Windows.Controls.CheckBox
$flipChk.IsChecked = $true
$flipChk.VerticalAlignment = 'Center'
$flipChk.Content = '自动'
$flipChk.FontSize = 12
$flipChk.FontFamily = $FONT
$flipChk.Foreground = Br $C_INK

# ---------------------------------------------------------------- 输入框（「截屏问一下」和「发消息」共用）
# 整个界面用 XAML 描述，再 XamlReader.Parse 出来。
# 为什么不一段段 New-Object：圆角按钮和圆角输入框都得改 ControlTemplate，
# 用代码拼要造 XamlReader.Parse 的字符串一样长，还不直观。
#
# ⚠️ 两个坑，都踩过：
#   ① **PowerShell 变量不分大小写** —— 局部变量名绝不能跟参数同名（`$hint` 和 `$Hint` 是同一个），
#      参数上的 `[string]` 类型约束会把赋给它的 TextBlock 强转成字符串，下一行就"没有 .Text 属性"。
#      所以下面所有控件都用 `$xxxCtl` 结尾，跟参数隔开。
#   ② 结果走 `$script:dlgResult`，**不用 return** —— PowerShell 会把函数里所有没被吃掉的输出
#      都当返回值，漏一个 [void] 就变成返回数组了。
#
# 取值：用户输入的文字（可能空串）；**取消 = $null**。
function Show-AskDialog {
  param([string]$Title = '问一下', [string]$Tip = '')
  $script:dlgResult = $null
  $titleText = $Title
  $tipText = $Tip
  try {
    # 配色沿用球的主题：藏青 #203170 / 次藏青 #2F4488 / 纸白 #FBFCFE / 软蓝 #DBE4F5
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        SizeToContent="WidthAndHeight" WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize" Topmost="True" ShowInTaskbar="False"
        FontFamily="Microsoft YaHei UI">
  <Window.Resources>
    <Style x:Key="Pill" TargetType="Button">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="20,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="15" Background="#DBE4F5"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#C6D4F0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PillPrimary" TargetType="Button">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="22,7"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="15" Background="#203170"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2F4488"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Round" TargetType="TextBox">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="bd" CornerRadius="9" Background="White"
                    BorderBrush="#DBE4F5" BorderThickness="1.4" Padding="9,7">
              <ScrollViewer x:Name="PART_ContentHost" VerticalScrollBarVisibility="Auto"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="bd" Property="BorderBrush" Value="#203170"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border Background="#FBFCFE" BorderBrush="#203170" BorderThickness="2"
          CornerRadius="16" Padding="18,15,18,15" Width="430">
    <Border.Effect>
      <DropShadowEffect BlurRadius="20" ShadowDepth="5" Opacity="0.28" Color="#203170"/>
    </Border.Effect>
    <StackPanel>
      <TextBlock x:Name="title" FontSize="15" FontWeight="SemiBold" Foreground="#203170"/>
      <TextBlock x:Name="tip" FontSize="12" Foreground="#2F4488"
                 Margin="0,6,0,10" TextWrapping="Wrap"/>
      <TextBox x:Name="box" Style="{StaticResource Round}" FontSize="13.5"
               Foreground="#203170" AcceptsReturn="True" TextWrapping="Wrap"
               Height="76" VerticalContentAlignment="Top"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
        <Button x:Name="no" Style="{StaticResource Pill}" Foreground="#2F4488"
                Content="取消" Margin="0,0,9,0"/>
        <Button x:Name="ok" Style="{StaticResource PillPrimary}" Content="发送"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
    $dlg = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $titleCtl = $dlg.FindName('title')
    $tipCtl = $dlg.FindName('tip')
    $boxCtl = $dlg.FindName('box')
    $okCtl = $dlg.FindName('ok')
    $noCtl = $dlg.FindName('no')

    $titleCtl.Text = $titleText
    if ($tipText -eq '') { $tipCtl.Visibility = 'Collapsed' } else { $tipCtl.Text = $tipText }

    # 拖动整张卡片也能挪窗口（无边框窗口没地方抓）
    $dlg.Add_MouseLeftButtonDown({ try { $dlg.DragMove() } catch {} })

    $okCtl.Add_Click({ $dlg.DialogResult = $true })
    $noCtl.Add_Click({ $dlg.DialogResult = $false })
    # 开框就把焦点交给输入框，不然打字没落点
    $boxCtl.Add_Loaded({ try { [void]$boxCtl.Focus() } catch {} })
    $dlg.Add_Loaded({ try { [void]$boxCtl.Focus() } catch {} })

    # Enter 发送 / Shift+Enter 换行。
    # ⚠️ 必须用 **PreviewKeyDown**，不能用 KeyDown：
    #    TextBox 的**类处理器先于实例处理器**跑，而 AcceptsReturn=True 时它会把 Enter
    #    消化掉去插换行（事件被标成 handled），普通 KeyDown 处理器默认收不到已 handled 的事件
    #    —— 现象就是"按 Enter 没反应"。Preview 处在隧道阶段，比类处理器更早，一定拿得到。
    $enterKey = {
      param($s, $e)
      if ($e.Key -eq 'Return' -and -not ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift)) {
        $e.Handled = $true
        $dlg.DialogResult = $true
      }
    }
    $boxCtl.Add_PreviewKeyDown($enterKey)
    # 兜底：焦点万一没在输入框上（比如落到按钮），窗口层再拦一次
    $dlg.Add_PreviewKeyDown($enterKey)
    $dlg.Add_KeyDown({
      param($s, $e)
      if ($e.Key -eq 'Escape') { $dlg.DialogResult = $false }
    })

    if ($dlg.ShowDialog() -eq $true) { $script:dlgResult = ([string]$boxCtl.Text).Trim() } else { $script:dlgResult = $null }
  } catch {
    Log ("ask dialog failed: " + $_.Exception.Message)
    $script:dlgResult = ''   # 出错就当空输入，至少还能发出去
  }
}

# ---------------------------------------------------------------- 发请求（「截屏问一下」和「发消息」共用）
# 两个入口只有两点不同：① ask.request 里写的模式 ② 球上那句提示文案。
# 回传链路（$AnswerFile）完全一样 —— 「发消息」的回答也要能回到球上。
function Send-Ask {
  param($Note, [bool]$NoShot)
  if ($null -eq $Note) {          # 取消 = 什么都不发
    $menu.Visibility = 'Collapsed'
    Update-Region
    return
  }
  Update-AnswerFile   # 路径可能因为换了目标会话而变，发之前重读一次
  if ($NoShot -and ([string]$Note).Trim() -eq '') {   # 纯文字模式下空消息没意义
    $tb.Text = '没写内容，没发'
    $menu.Visibility = 'Collapsed'
    Update-Region
    return
  }
  try {
    # 只写用户写的那段。**回传提示不在这里加** ——
    #   球不知道目标会话的 cwd（宿主才知道），路径写错的提示比没有更糟。
    #   宿主投递时会自己追加一句"回答写到 <真实路径>"。
    [System.IO.File]::WriteAllText($AskTextFile, [string]$Note, (New-Object System.Text.UTF8Encoding($false)))
    # 旧回答先清掉，否则新一轮还没回，球上还挂着上一轮的答案
    Remove-Item -LiteralPath $AnswerFile -Force -ErrorAction SilentlyContinue
    # 记下这一轮是从什么时候开始的 —— 定时器靠它区分"本轮回答"和"上一轮的老答案"
    $script:lastAskAt = Get-Date
    $script:bubbleArmed = $true   # 用过一次之后气泡就一直显示了
    # ⚠️ 这里的**内容就是模式**，宿主读它决定要不要截图（以前只当时间戳用）：
    #    'shot'   = 截屏问一下（老版本球写纯时间戳，宿主按“非 noshot 即 shot”处理，兼容）
    #    'noshot' = 发消息：只要这段文字，不截图
    # 从这一刻起进入"等回答"状态，气泡显示「正在思考…」
    $script:askingSince = Get-Date
    $mode = 'shot'
    if ($NoShot) { $mode = 'noshot' }
    [System.IO.File]::WriteAllText($AskReqFile, $mode, (New-Object System.Text.UTF8Encoding($false)))
    Log ("ask.request written -> $AskReqFile (mode=$mode)")
    if ($NoShot) { $tb.Text = '消息已发出，等回复…' } else { $tb.Text = '已请求截屏，稍后…' }
  } catch {
    Log ("ask.request write failed: " + $_.Exception.Message)
    $tb.Text = "请求失败`n$($_.Exception.Message)"
  }
  $menu.Visibility = 'Collapsed'
  Update-Region
}

# ---------------------------------------------------------------- 会话选择框
# 球是独立进程，读不到 DSH 内部的会话服务 —— 列表是宿主每分钟 dump 到
# $DataDir\sessions.json 的（见 lib/index.js 的 dumpSessions）。
#
# 交互按用户要求：
#   · 先列**工作区**，默认全部收起
#   · 点一下工作区 → 展开它下面的子会话
#   · 点子会话 → **立刻选中并关闭**（"选择完自动退出"）
#   · 取消 = 什么都不改
#   · 居中、**不能拖**（用户明确要求"不可移动"，所以这里**故意不接 DragMove**）
#   · 外观跟球/菜单同一套（藏青 + 纸白 + 圆角 + 胶囊按钮）
#
# 结果走 $script:pickResult：选中的会话 id；取消或出错 = $null。
function Show-SessionPicker {
  param([string]$Current = '')
  $script:pickResult = $null

  # —— 读宿主 dump 的会话树 ——
  $items = @()
  try {
    $raw = [System.IO.File]::ReadAllText($SessionsFile, [System.Text.Encoding]::UTF8)
    $j = $raw | ConvertFrom-Json
    if ($j -and $j.items) { $items = @($j.items) }
  } catch {
    Log ("session picker: 读 $SessionsFile 失败 —— " + $_.Exception.Message)
  }
  if ($items.Count -eq 0) {
    # ⚠️ 必须把气泡**弹出来**再说。
    #    之前只改了 $tb.Text，可气泡这时候多半是收起状态（kind=no-browser 时收的），
    #    于是用户看到的就是"点进去就没了，啥也不显示"。
    $tb.Text = "还没有会话列表`n等一会儿再点（宿主每 20 秒刷新一次）"
    if ($bubbleBox.Visibility -ne 'Visible') { $bubbleBox.Visibility = 'Visible' }
    # 借"回答钉住"那个机制把气泡留一会儿，否则下一轮状态刷新又把它收回去
    if ($script:answerPinnedUntil -lt [datetime]::Now) {
      $script:answerPinnedUntil = [datetime]::Now.AddMinutes($script:ANSWER_PIN_MIN)
    }
    Fit-BubbleText
    $menu.Visibility = 'Collapsed'
    Update-Region
    Log 'session picker: 没有数据，已弹气泡提示'
    return
  }

  # —— 按工作区分组（第一层） ——
  # ⚠️ 用宿主 dump 出来的 `ws` 字段（= DSH 侧边栏那个工作区名），**不要**自己从 cwd 取最后一段。
  #    否则 `qq-bridge\state\agents` 会显示成 "agents"，而侧边栏叫它 "QQ 聊天" —— 用户怼过这个。
  $groups = [ordered]@{}
  foreach ($it in $items) {
    $name = [string]$it.ws
    if (-not $name) {
      # 兜底（老宿主没给 ws 时）：cwd 最后一段
      $cwd = [string]$it.cwd
      if ($cwd) { try { $name = Split-Path -Leaf ($cwd.TrimEnd('\', '/')) } catch { $name = $cwd } }
    }
    if (-not $name) { $name = '未分组' }
    if (-not $groups.Contains($name)) { $groups[$name] = @() }
    $groups[$name] += $it
  }

  try {
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        SizeToContent="WidthAndHeight" WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize" Topmost="True" ShowInTaskbar="False"
        FontFamily="Microsoft YaHei UI">
  <Window.Resources>
    <Style x:Key="Pill" TargetType="Button">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="20,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="15" Background="#DBE4F5"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#C6D4F0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Background="#FBFCFE" BorderBrush="#203170" BorderThickness="2"
          CornerRadius="16" Padding="18,15,18,15" Width="430">
    <Border.Effect>
      <DropShadowEffect BlurRadius="20" ShadowDepth="5" Opacity="0.28" Color="#203170"/>
    </Border.Effect>
    <StackPanel>
      <TextBlock x:Name="title" Text="选择会话" FontSize="15" FontWeight="SemiBold" Foreground="#203170"/>
      <TextBlock x:Name="tip" FontSize="12" Foreground="#2F4488" Margin="0,6,0,10" TextWrapping="Wrap"
                 Text="选哪一段，悬浮球的消息就发给它。点工作区展开，点子会话直接选中。"/>
      <Border CornerRadius="10" Background="White" BorderBrush="#DBE4F5" BorderThickness="1.4">
        <ScrollViewer Height="300" VerticalScrollBarVisibility="Auto" Padding="6,6,6,6">
          <StackPanel x:Name="list"/>
        </ScrollViewer>
      </Border>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
        <Button x:Name="no" Style="{StaticResource Pill}" Foreground="#2F4488" Content="取消"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
    $dlg = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $listCtl = $dlg.FindName('list')
    $noCtl = $dlg.FindName('no')

    # ⚠️ 故意**不接** $dlg.Add_MouseLeftButtonDown({ $dlg.DragMove() })
    #    —— 用户明确要"不可移动"的框。输入框那个是可拖的，这个不是。

    $noCtl.Add_Click({ $dlg.DialogResult = $false })

    # 当前目标的短 id，用来打勾
    $curId = [string]$Current

    foreach ($gname in $groups.Keys) {
      $sessList = $groups[$gname]

      # —— 工作区那一行：就是个可点的标题，点一下展开/收起 ——
      $gBtn = New-Object System.Windows.Controls.Button
      $gBtn.Content = ([string]$gname) + "   (" + $sessList.Count + ")"
      $gBtn.FontSize = 13
      $gBtn.HorizontalContentAlignment = 'Left'
      $gBtn.Cursor = [System.Windows.Input.Cursors]::Hand
      $gBtn.Foreground = Br $C_INK
      $gBtn.Background = [System.Windows.Media.Brushes]::Transparent
      $gBtn.BorderThickness = New-Object System.Windows.Thickness(0)
      $gBtn.Padding = New-Object System.Windows.Thickness(8, 5, 6, 5)
      $gBtn.Margin = New-Object System.Windows.Thickness(0, 1, 0, 1)
      [void]$listCtl.Children.Add($gBtn)

      # —— 子会话容器：默认收起 ——
      $sub = New-Object System.Windows.Controls.StackPanel
      $sub.Visibility = 'Collapsed'
      $sub.Margin = New-Object System.Windows.Thickness(16, 0, 0, 2)
      [void]$listCtl.Children.Add($sub)
      $gBtn.Tag = $sub   # 按钮记住自己那块面板（见下面 Add_Click 的注释）

      $gBtn.Add_Click({
        param($s, $e)
        # ⚠️ **不能用变量 $sub** —— PowerShell 的 foreach 里 $sub 是**同一个变量**，
        #    所有按钮的回调都指向最后一次赋值的那个面板。结果就是：点哪个工作区，
        #    展开的都是**最后一个**工作区的会话（2026-10-31 用户实测："我无论点哪个都是这样显示"）。
        #    面板挂在按钮自己的 Tag 上，各用各的。
        $panel = $s.Tag
        if ($panel -and ($panel.Visibility -eq 'Collapsed')) { $panel.Visibility = 'Visible' } else { $panel.Visibility = 'Collapsed' }
      })

      foreach ($it in $sessList) {
        $sid = [string]$it.id
        $label = [string]$it.title
        if (-not $label) {
          # ⚠️ 没标题的**别直接甩一串 uuid**（58 段里有 28 段没标题，满屏 session-xxxx 看着像坏了）。
          #    用"未命名 + 最后活动时间"，至少能区分、能看出新旧。
          $when = ''
          try {
            if ($it.updatedAt -and [long]$it.updatedAt -gt 0) {
              $when = ([datetimeoffset]::FromUnixTimeMilliseconds([long]$it.updatedAt)).LocalDateTime.ToString('MM-dd HH:mm')
            }
          } catch {}
          if ($when) { $label = '（未命名 ' + $when + '）' } else { $label = '（未命名）' }
        }
        if ($label.Length -gt 34) { $label = $label.Substring(0, 26) + '…' + $label.Substring($label.Length - 8) }
        if ($sid -eq $curId) { $label = '✓  ' + $label }
        if ($it.running) { $label = $label + '   ·跑着' }

        $sBtn = New-Object System.Windows.Controls.Button
        $sBtn.Content = $label
        $sBtn.Tag = $sid
        $sBtn.FontSize = 12.5
        $sBtn.HorizontalContentAlignment = 'Left'
        $sBtn.Cursor = [System.Windows.Input.Cursors]::Hand
        $sBtn.Foreground = Br $C_INK2
        $sBtn.Background = [System.Windows.Media.Brushes]::Transparent
        $sBtn.BorderThickness = New-Object System.Windows.Thickness(0)
        $sBtn.Padding = New-Object System.Windows.Thickness(8, 4, 6, 4)
        $sBtn.Margin = New-Object System.Windows.Thickness(0, 1, 0, 1)
        # 悬停变色（手写因为没走 XAML 样式）
        $sBtn.Add_MouseEnter({ param($s, $e) $s.Background = (BrA 32 49 112 0.10) })
        $sBtn.Add_MouseLeave({ param($s, $e) $s.Background = [System.Windows.Media.Brushes]::Transparent })
        # 点一下就选中并关框 —— 用户要的"选择完自动退出"
        $sBtn.Add_Click({
          param($s, $e)
          $script:pickResult = [string]$s.Tag
          $dlg.DialogResult = $true
        })
        [void]$sub.Children.Add($sBtn)
      }
    }

    if ($dlg.ShowDialog() -eq $true) { } else { $script:pickResult = $null }
  } catch {
    Log ("session picker failed: " + $_.Exception.Message)
    $script:pickResult = $null
  }
}

$btnAsk = New-MenuButton '截当前屏幕问会话'
$btnAsk.ToolTip = '把当前屏幕截图发给会话，让它看一眼再给指导'
$btnMsg = New-MenuButton '发消息（不截图）'
$btnMsg.ToolTip = '只发你写的那段文字，不截图 —— 想直接跟会话说句话时用'
$btnPick = New-MenuButton '选择会话…'
$btnPick.ToolTip = '切换消息发往哪段会话：点开 → 展开工作区 → 点会话即生效'
$btnQuit = New-MenuButton '收起鲸鱼球'
$btnQuit.ToolTip = '点页面右下角的鲸鱼胶囊可以再叫出来'

# —— 当前会话（只读一行，点开菜单时刷新）——
# 用户要求：「打开菜单的时候，需要能够知道当前是哪个会话」。
# 名字从 sessions.json 里按 ask.target 的 id 查；查不到就退化成短 id。
$curSessionTb = New-Object System.Windows.Controls.TextBlock
$curSessionTb.FontSize = 11.5
$curSessionTb.Foreground = Br $C_INK2
$curSessionTb.Margin = New-Object System.Windows.Thickness(2, 0, 2, 5)
$curSessionTb.TextTrimming = 'CharacterEllipsis'   # 太长了自动省略号，不换行撑高菜单
$curSessionTb.Text = '当前会话：…'

function Update-CurSessionLabel {
  try {
    $want = ''
    if (Test-Path -LiteralPath $AskTargetFile) {
      $want = ([System.IO.File]::ReadAllText($AskTargetFile, [System.Text.Encoding]::UTF8)).Trim()
    }
    if (-not $want) {
      $curSessionTb.Text = '当前会话：（默认，见配置 askSession）'
      return
    }
    $name = ''
    try {
      if (Test-Path -LiteralPath $SessionsFile) {
        $j = [System.IO.File]::ReadAllText($SessionsFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($it in @($j.items)) { if ([string]$it.id -eq $want) { $name = [string]$it.title; break } }
      }
    } catch {}
    if (-not $name) {
      # 列表里没有（归档/过滤掉了）→ 显示短 id，并标记失效
      $name = $want
      if ($name.Length -gt 22) { $name = $name.Substring(0, 9) + '…' + $name.Substring($name.Length - 6) }
      $curSessionTb.Text = '当前会话：（已失效）' + $name
      return
    }
    $curSessionTb.Text = '当前会话：' + $name
  } catch { $curSessionTb.Text = '当前会话：（读不到）' }
}

$menuStack.Children.Add((New-MenuRow '大小' $sizeCtl)) | Out-Null
$menuStack.Children.Add((New-MenuRow '翻转' $flipChk)) | Out-Null
# 当前会话放在两个"发请求"按钮上面 —— 点之前先看得见消息会发给谁
$menuStack.Children.Add($curSessionTb) | Out-Null
# 按钮**直接**挂到竖直 StackPanel 上 —— 横向 New-MenuRow 按内容量宽度，
# 会让三个按钮宽窄不一、还很右缩进（用户原话"菜单排版是一坨"）
$menuStack.Children.Add($btnAsk) | Out-Null
$menuStack.Children.Add($btnMsg) | Out-Null
$menuStack.Children.Add($btnPick) | Out-Null
$menuStack.Children.Add((New-MenuSep)) | Out-Null
$menuStack.Children.Add($btnQuit) | Out-Null
$win.Content = $grid

# ---------------------------------------------------------------- 状态
$script:hwnd = [IntPtr]::Zero
$script:physW = $physW
$script:physH = $physH
$script:regionOn = $false
$script:busy = $false
$script:drag = $false
$script:grabDX = 0
$script:grabDY = 0
$script:barRect = $null

# 诊断日志：在 WPF 事件处理器里 Write-Output 会被缓冲，落盘才看得见
$DbgFile = Join-Path $DataDir 'pet-ball.log'
$script:Verbose2 = [bool]$Log
function Log([string]$m) {
  if (-not $script:Verbose2) { return }
  try { [System.IO.File]::AppendAllText($DbgFile, ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m + "`r`n"), (New-Object System.Text.UTF8Encoding($false))) } catch {}
}

# 首次解析回传文件路径（放在 Log 定义之后，这样那一行日志能写出来）
Update-AnswerFile

function Update-BarRect {
  # 菜单按钮是右对齐的：窗口一缩放它就跟着移动。
  # ⚠️ 必须在**每次** Update-Region 之前重算，否则并进区域的是旧位置的矩形，
  #    表现就是"缩放之后菜单按钮点不到了"（实测踩到过）。
  # 面板展开时，把面板矩形也并进去（它是一个能点的浮层，被裁掉就点不了）。
  $script:barRect = $null
  try {
    $rects = @()
    $menuBtn.UpdateLayout()
    $sc = if ($grid.ActualWidth -gt 0) { $script:physW / $grid.ActualWidth } else { 1.5 }
    if ($grid.ActualWidth -gt 0 -and $menuBtn.ActualWidth -gt 0) {
      $p = $menuBtn.TranslatePoint((New-Object System.Windows.Point(0, 0)), $grid)
      $rects += (New-Object System.Windows.Rect(($p.X * $sc), ($p.Y * $sc), ($menuBtn.ActualWidth * $sc), ($menuBtn.ActualHeight * $sc)))
    }
    if ($menu.Visibility -eq 'Visible' -and $menu.ActualWidth -gt 0) {
      $pm = $menu.TranslatePoint((New-Object System.Windows.Point(0, 0)), $grid)
      $rects += (New-Object System.Windows.Rect(($pm.X * $sc), ($pm.Y * $sc), ($menu.ActualWidth * $sc), ($menu.ActualHeight * $sc)))
    }
    if ($rects.Count -gt 0) {
      $u = $rects[0]
      for ($i = 1; $i -lt $rects.Count; $i++) { $u = [System.Windows.Rect]::Union($u, $rects[$i]) }
      $script:barRect = $u
    } else {
      Log 'Update-BarRect: 布局未就绪，菜单不并入区域'
    }
  } catch { $script:barRect = $null; Log ("Update-BarRect ERROR: " + ($_ | Out-String).Trim()) }
}

function Update-Region {
  # 默认**不裁区域**：普通 AllowsTransparency 窗口自带逐像素跨进程穿透（见 param 区的实测说明）。
  if (-not $UseRegion) { return }
  if ($script:hwnd -eq [IntPtr]::Zero) { return }
  Update-BarRect
  # y 步长 2：矩形数减半，鲸鱼这种大块图形肉眼无差
  $rgn = [PetNative]::BuildAlphaRegion($Image, $script:physW, $script:physH, 8, 2)
  if ($rgn -eq [IntPtr]::Zero) { Write-Output 'region: build failed (alpha 全透明?)'; return }
  # 控制条那一小块也要可点：并入区域
  if ($script:barRect) {
    $r = $script:barRect
    $rgn = [PetNative]::UnionRects($rgn, @(,@([int]$r.X, [int]$r.Y, [int]($r.X + $r.Width), [int]($r.Y + $r.Height))))
  }
  $ok = [PetNative]::ApplyRegion($script:hwnd, $rgn)
  $script:regionOn = $ok
  Write-Output ("region: spans={0} bbox={1},{2}-{3},{4} applied={5}" -f `
    [PetNative]::LastSpanCount, [PetNative]::LastBBoxL, [PetNative]::LastBBoxT, [PetNative]::LastBBoxR, [PetNative]::LastBBoxB, $ok)
}

# ---------------------------------------------------------------- 字号自适应
# 用户反馈「气泡框远比字大」—— 其实是**字太小**。
# 之前字号是写死的：FontSize = Max(11, 14 * (dipW/413))。这个球才 265 DIP，
# 14*265/413 = 9，被 11 的下限顶住，于是永远 11 —— 塞在 ~190x150 DIP 的气泡里就显得空。
# 改成**按可用面积反推**：从大往小试字号，用 FormattedText 量（照 TextBlock 的实际换行宽度），
# 取第一个能塞进 (可用宽, 可用高) 的。这样字会自己把气泡填满，长文本也还有 Viewbox 兜底。
function Fit-BubbleText {
  try {
    # —— 把气泡当前显示的文字记进日志 ——
    # 为什么要有这一行：宿主起球时不带 -Log（见 lib/index.js 的 ballStartInner），
    # 于是 pet-ball.log 一片空白，我**完全看不到球上显示了什么**，只能靠用户口述／截图。
    # 排查"气泡上什么鬼"这类问题，这行是唯一能自证的证据。别删。
    try {
      $snip = ([string]$tb.Text) -replace "`r?`n", ' / '
      if ($snip.Length -gt 80) { $snip = $snip.Substring(0, 80) + '…' }
      Log ("bubble <- " + $snip)
    } catch {}
    $w = $script:bubbleTextW
    $h = $script:bubbleTextH
    if (-not $w -or -not $h -or $w -le 20 -or $h -le 20) { return }
    $txt = [string]$tb.Text
    if (-not $txt) { return }
    $typeface = New-Object System.Windows.Media.Typeface($FONT)
    $ci = [System.Globalization.CultureInfo]::CurrentUICulture
    $best = 8.0
    for ($fs = 22.0; $fs -ge 8.0; $fs -= 0.5) {
      $ft = New-Object System.Windows.Media.FormattedText($txt, $ci, [System.Windows.FlowDirection]::LeftToRight, $typeface, $fs, [System.Windows.Media.Brushes]::Black, 1.0)
      $ft.MaxTextWidth = $w
      if ($ft.Height -le $h) { $best = $fs; break }
    }
    if ([Math]::Abs($tb.FontSize - $best) -gt 0.05) {
      $tb.FontSize = $best
      $tb.LineHeight = $best * 1.35
      Log ("Fit-BubbleText: fs=$best w=$([Math]::Round($w,1)) h=$([Math]::Round($h,1))")
    }
  } catch { Log ("Fit-BubbleText ERROR: " + ($_ | Out-String).Trim()) }
}

function Layout-Children {
  # ⚠️ 单位：WPF 的 Width/Margin/FontSize 全是 **DIP**，不是物理像素。
  #    唯一权威来源是：**物理尺寸 ÷ 该窗口的 DPI 缩放**。
  #    别用 $grid.ActualWidth / $win.ActualWidth —— 前者会被子元素撑大（正反馈：
  #    字大 -> 框大 -> grid 更大 -> 字更大，实测跑成 gridDIP=1080 而窗口才 265），
  #    后者在 SetWindowPos 定尺寸时不跟着走。2026-10-13 真机踩到。
  $dpiScale = 1.5
  try { $d = [PetNative]::GetDpiForWindow($script:hwnd); if ($d -gt 0) { $dpiScale = $d / 96.0 } } catch {}
  if ($dpiScale -le 0) { $dpiScale = 1.0 }
  $dipW = $script:physW / $dpiScale
  $dipH = $script:physH / $dpiScale

  # 角色：贴右下
  $img.Width = $dipW * 0.62
  $img.Height = $dipH * 0.62
  $img.HorizontalAlignment = 'Right'
  $img.VerticalAlignment = 'Bottom'
  $img.Margin = New-Object System.Windows.Thickness(0, 0, ($dipW * 0.03), ($dipH * 0.02))

  # 气泡：左上。宽度固定（文字按这个宽换行），高度**自适应**但封顶 ——
  # 真正超过封顶时由 Viewbox 等比缩小，所以永远不会溢出去压桌面。
  # 气泡**跟着字走**：不给定宽，只给上限。
  #   之前是 Width 写死 0.70*dipW，字短的时候右边空一大块（用户："气泡框远比字大"）。
  #   现在改成：TextBlock 设 MaxWidth（超了才换行），Border 自然收紧到文字宽度；
  #   真超高了再由 Viewbox 等比缩小。
  $bubbleBox.MaxWidth = $dipW * 0.72
  $bubbleBox.MaxHeight = $dipH * 0.56
  $bubbleBox.HorizontalAlignment = 'Left'
  $bubbleBox.VerticalAlignment = 'Top'
  $bubbleBox.Margin = New-Object System.Windows.Thickness(($dipW * 0.03), ($dipH * 0.02), 0, 0)
  # 文字真正能用的宽高：减掉 Padding(左右14+14 / 上下10+10) 和 2.5 的边框。
  # 字号不写死了 —— 交给 Fit-BubbleText 按这块面积反推（见上面的长注释）。
  $tb.MaxWidth = ($dipW * 0.72) - 33   # **不设 Width**，短文本就窄
  $script:bubbleTextW = ($dipW * 0.72) - 33
  $script:bubbleTextH = ($dipH * 0.56) - 25
  $tb.FontSize = 15.0                    # 初值；Fit-BubbleText 会立刻重算
  $tb.LineHeight = $tb.FontSize * 1.35

  # 菜单按钮：放在**角色图的右上角**里，别放在窗口角上。
  #   原因：窗口是 AllowsTransparency 的分层窗口，**透明像素会穿透**（鼠标事件直接漏到下面的窗口），
  #   所以悬停只会在"画了东西的地方"成立。放在角色身上，鼠标从角色移过去一路都是实心，
  #   不会中途触发 MouseLeave 把按钮藏掉。余额挂件的按钮也正好在角色包围盒的右上角。
  # 角色：右下、宽 62%、右边距 3%、下边距 2% ⇒ 顶边 0.36、右边 0.97
  $menuBtn.Margin = New-Object System.Windows.Thickness(0, ($dipH * 0.36 + 4), ($dipW * 0.03 + 4), 0)
  # 菜单面板：挂在按钮正下方，右对齐。高度要能塞进窗口（265 DIP 左右），所以行做得紧凑。
  # 菜单面板：**贴着窗口底部**，不是挂在按钮正下方。
  #   理由：按钮在 y≈0.36*dipH，菜单有 6 行（≈150 DIP），挂在按钮下面会**超出窗口被裁掉**。
  #   贴底之后顶边大约在按钮下沿附近，既完整显示又基本不挡按钮。
  $menu.Width = $dipW * 0.80
  $menu.VerticalAlignment = 'Bottom'
  $menu.Margin = New-Object System.Windows.Thickness(0, 0, ($dipW * 0.03 + 4), ($dipH * 0.02))
  # 滑块宽度跟着菜单宽算，别写死 —— 球被缩放时排版才不会散
  $sizeSlider.Width = [Math]::Max(56, ($dipW * 0.80 - 26) - 44 - 42)

  Fit-BubbleText

  Log ("Layout: dip=$([Math]::Round($dipW,1))x$([Math]::Round($dipH,1)) phys=$($script:physW)x$($script:physH) scale=$dpiScale font=$([Math]::Round($tb.FontSize,1)) bubW=$([Math]::Round($bubble.ActualWidth,1))")
}

# ---------------------------------------------------------------- 自动翻转（仿余额挂件）
# 余额挂件怎么做的（whale-widget.js 的 refreshFlip + .dshwv-root.dshwv-left）：
#   · 判定看的是**角色图像的中心 x**，不是整个窗口中心：artCenter.cx < 翻转线 ⇒ 翻
#   · 翻了以后整个根容器 transform:scaleX(-1) —— 角色换到另一侧；
#     里面的 .dshwv-gif（角色）和 .dshwv-text（文字）再各 scaleX(-1) 翻回来，
#     否则角色倒着、字也是反的
#   · 动画是 transition:transform .3s ease（容器）+ cubic-bezier(.34,1.56,.64,1)（带回弹）
# WPF 里一一对应：$grid 挂一个 ScaleTransform，$tb / $menu / $menuBtn 各挂一个反向的，
# 全都用同一个 DoubleAnimation + BackEase 一起动。这样动画过程中净缩放 = 两个负数的积，
# **始终为正** —— 字不会在中途变成反的（代价是经过 0 时短暂"变薄"，余额挂件也一样）。
$gridScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
$grid.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
$grid.RenderTransform = $gridScale

# 这三个要在镜像里"翻回来"，否则字和按钮内容都是反的
$tbScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
$tb.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
$tb.RenderTransform = $tbScale

$menuScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
$menu.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
$menu.RenderTransform = $menuScale

$menuBtnScale = New-Object System.Windows.Media.ScaleTransform(1, 1)
$menuBtn.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
$menuBtn.RenderTransform = $menuBtnScale

$script:flipped = $false

function Set-Flip {
  param([bool]$On)
  if ($On -eq $script:flipped) { return }
  $script:flipped = $On
  $to = if ($On) { -1.0 } else { 1.0 }
  $dur = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(300))
  $ease = New-Object System.Windows.Media.Animation.BackEase
  $ease.Amplitude = 0.28
  $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
  foreach ($sc in @($gridScale, $tbScale, $menuScale, $menuBtnScale)) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation(($sc.ScaleX), $to, $dur)
    $a.EasingFunction = $ease
    $sc.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $a)
  }
  Log ("flip -> " + $On)
}

function Calc-Flip {
  try {
    if (-not $flipChk.IsChecked) { Set-Flip $false; return }
    if ($script:hwnd -eq [IntPtr]::Zero) { return }
    $r = New-Object PetNative+RECT
    if (-not [PetNative]::GetWindowRect($script:hwnd, [ref]$r)) { return }
    $wa = [PetNative]::WorkAreaAt($r.L, $r.T)
    $mid = ($wa.L + $wa.R) / 2.0
    # 角色图在窗口内的中心：右对齐、宽 62%、右边距 3% => 左边 35%、中心 66%。
    # 已经翻了的话它在左边：中心 34%。用当前朝向算，天然带一点迟滞（不会在中线附近抖）。
    $cx = if ($script:flipped) { $r.L + ($r.R - $r.L) * 0.34 } else { $r.L + ($r.R - $r.L) * 0.66 }
    Set-Flip ($cx -lt $mid)
  } catch { Log ("Calc-Flip ERROR: " + ($_ | Out-String).Trim()) }
}

function Save-Pos {
  if ($script:hwnd -eq [IntPtr]::Zero) { return }
  $r = New-Object PetNative+RECT
  if ([PetNative]::GetWindowRect($script:hwnd, [ref]$r)) {
    Write-Cfg $r.L $r.T ($r.R - $r.L) ($r.B - $r.T)
  }
}

# ---------------------------------------------------------------- 拖动
# 按下后不用 WPF 的 MouseMove（区域窗口一移出鲸鱼就收不到），改成 16ms 轮询 + 判松手。
$dragTimer = New-Object System.Windows.Threading.DispatcherTimer
$dragTimer.Interval = [TimeSpan]::FromMilliseconds(16)
$dragTimer.Add_Tick({
  if (-not $script:drag) { $dragTimer.Stop(); return }
  if (-not [PetNative]::LeftButtonDown()) {
    $script:drag = $false
    $dragTimer.Stop()
    [void][PetNative]::ReleaseCapture()
    Save-Pos
    Calc-Flip
    Log 'drag end (left button released) -> saved'
    return
  }
  Move-Drag
  Calc-Flip      # 拖动过程中实时翻（余额挂件也是边拖边转）
})

function Start-Drag {
  $script:drag = $true
  $p = [System.Windows.Forms.Control]::MousePosition
  $r = New-Object PetNative+RECT
  if ([PetNative]::GetWindowRect($script:hwnd, [ref]$r)) {
    $script:grabDX = $p.X - $r.L
    $script:grabDY = $p.Y - $r.T
  } else { $script:grabDX = 60; $script:grabDY = 30 }
  # Win32 捕获：让光标离开窗口后仍把消息发给我们（轮询兜底，双保险）
  try { [void][PetNative]::SetCapture($script:hwnd) } catch {}
  if (-not $dragTimer.IsEnabled) { $dragTimer.Start() }
  Log ("Start-Drag mouse=$($p.X),$($p.Y) rect=$($r.L),$($r.T) grab=$($script:grabDX),$($script:grabDY)")
}
function Move-Drag {
  Log 'Move-Drag entered'
  if (-not $script:drag) { Log 'Move-Drag: drag flag false -> return'; return }
  try {
    $p = [System.Windows.Forms.Control]::MousePosition
    $nx = $p.X - $script:grabDX
    $ny = $p.Y - $script:grabDY
    # clamp 到**该点所在显示器**的工作区（多屏正确；SPI_GETWORKAREA 只看主屏）
    $wa = [PetNative]::WorkAreaAt(($nx + [int]($script:physW / 2)), ($ny + [int]($script:physH / 2)))
    $mx = $wa.R - $script:physW
    $my = $wa.B - $script:physH
    if ($nx -lt $wa.L) { $nx = $wa.L }
    if ($ny -lt $wa.T) { $ny = $wa.T }
    if ($nx -gt $mx) { $nx = $mx }
    if ($ny -gt $my) { $ny = $my }
    [void][PetNative]::MoveWindow($script:hwnd, $nx, $ny)
    Log ("Move-Drag mouse=$($p.X),$($p.Y) -> window=$nx,$ny")
  } catch {
    Log ("Move-Drag ERROR: " + ($_ | Out-String).Trim())
  }
}

# ---------------------------------------------------------------- 生命周期
$win.Add_Loaded({
  $script:hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
  $dpi = [PetNative]::GetDpiForWindow($script:hwnd)
  Write-Output ("hwnd={0} dpi={1} physical={2}x{3} image={4}" -f $script:hwnd, $dpi, $script:physW, $script:physH, $Image)
  Layout-Children

  # 位置：配置里有效就还原（夹到所在显示器工作区），否则主屏右下角
  $x = $null; $y = $null
  if ($cfg) {
    $wa0 = [PetNative]::WorkAreaAt([int]$cfg.x, [int]$cfg.y)
    $maxX = $wa0.R - $script:physW; $maxY = $wa0.B - $script:physH
    $x = [Math]::Max($wa0.L, [Math]::Min([int]$cfg.x, $maxX))
    $y = [Math]::Max($wa0.T, [Math]::Min([int]$cfg.y, $maxY))
  } else {
    $x = $primary.R - $script:physW - 24
    $y = $primary.B - $script:physH - 24
  }
  [void][PetNative]::ResizeAndMove($script:hwnd, $x, $y, $script:physW, $script:physH)

  # 第一次算翻转（还原位置之后才知道在屏幕哪半边）
  Calc-Flip

  # 区域：等布局量完再建（需要菜单的真实位置）
  Update-Region

  # ---- WM_DPICHANGED：拖到不同缩放的显示器时，Windows 会给一个建议矩形 ----
  # 必须处理：区域是按**物理像素**建的，窗口被系统缩放后区域就和鲸鱼错开了。
  # ⚠️ 本机是单屏 150%，**没法实测**，这里是防御式实现。
  try {
    $src = [System.Windows.Interop.HwndSource]::FromHwnd($script:hwnd)
    $src.AddHook([System.Windows.Interop.HwndSourceHook]{
      param([IntPtr]$hwnd, [int]$msg, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
      if ($msg -eq 0x02E0) {
        try {
          $newDpi = $wParam.ToInt32() -band 0xFFFF
          $rc = [System.Runtime.InteropServices.Marshal]::PtrToStructure($lParam, [type][PetNative+RECT])
          $nw = $rc.R - $rc.L; $nh = $rc.B - $rc.T
          Log ("WM_DPICHANGED dpi=$newDpi suggested=$($rc.L),$($rc.T) ${nw}x${nh}")
          $script:physW = $nw; $script:physH = $nh
          [void][PetNative]::ResizeAndMove($script:hwnd, $rc.L, $rc.T, $nw, $nh)
          Layout-Children
          Calc-Flip
          Update-Region
          Save-Pos
        } catch { Log ("WM_DPICHANGED ERROR: " + ($_ | Out-String).Trim()) }
        $handled.Value = $true
        return [IntPtr]::Zero
      }
      return [IntPtr]::Zero
    })
  } catch { Log ("AddHook failed: $($_.Exception.Message)") }

  # 菜单按钮：开/关设置面板
  $menuBtn.Add_Click({
    if ($menu.Visibility -eq 'Visible') {
      $menu.Visibility = 'Collapsed'
      Log 'menu closed'
    } else {
      # 每次打开菜单都重读一次"当前会话" —— 选完会话回来立刻能看见新的
      Update-CurSessionLabel
      $menu.Visibility = 'Visible'
      Log ('menu opened  [' + $curSessionTb.Text + ']')
    }
    Update-Region
  })

  # 球过不了宿主的 token 门，所以用**文件当总线**：写请求文件 → 宿主监听到就投递。
  # 两个入口只是模式不同，投递和回传链路共用 Send-Ask。
  $btnAsk.Add_Click({
    Show-AskDialog -Title '问一下' -Tip '要补充的说明就写这里。留空 = 只发截图。'
    Send-Ask -Note $script:dlgResult -NoShot $false
  })

  $btnMsg.Add_Click({
    Show-AskDialog -Title '发消息' -Tip '只把这段文字发给会话，不截图。'
    Send-Ask -Note $script:dlgResult -NoShot $true
  })

  # 选择会话：先落一个"要最新列表"的信号让宿主立刻 dump，再读 sessions.json
  $btnPick.Add_Click({
    try { [System.IO.File]::WriteAllText($SessionsWantFile, [string](Get-Date).Ticks) } catch {}
    Start-Sleep -Milliseconds 250     # 给宿主读信号 + 写文件的时间（它一看到就 dump）
    $cur = ''
    try { $cur = ([System.IO.File]::ReadAllText($AskTargetFile, [System.Text.Encoding]::UTF8)).Trim() } catch {}
    Show-SessionPicker -Current $cur
    if ($script:pickResult) {
      try {
        [System.IO.File]::WriteAllText($AskTargetFile, $script:pickResult, (New-Object System.Text.UTF8Encoding($false)))
        $short = $script:pickResult
        if ($short.Length -gt 22) { $short = $short.Substring(0, 14) + '…' + $short.Substring($short.Length - 6) }
        $tb.Text = '已切到这一段会话：' + $short
        if ($bubbleBox.Visibility -ne 'Visible') { $bubbleBox.Visibility = 'Visible'; Update-Region }
        Fit-BubbleText
        Log ('ask.target -> ' + $script:pickResult)
        Update-CurSessionLabel   # 菜单里那行"当前会话"立刻跟上
      } catch { Log ('ask.target 写失败: ' + $_.Exception.Message) }
    }
    $menu.Visibility = 'Collapsed'
    Update-Region
  })

  # —— 大小滑块 ——
  # 记下"100% 时多大"，之后按百分比缩放。改完立刻存盘，重启还是这个大小。
  $script:baseW = $script:physW
  $script:baseH = $script:physH
  $script:sizeSyncing = $false
  $sizeSlider.Add_ValueChanged({
    if ($script:sizeSyncing) { return }
    try {
      $pct = [double]$sizeSlider.Value
      $sizeVal.Text = "" + [int]$pct + "%"
      $newW = [int]([Math]::Max(160, [Math]::Round($script:baseW * $pct / 100.0)))
      $newH = [int]([Math]::Max(160, [Math]::Round($script:baseH * $pct / 100.0)))
      if ($newW -eq $script:physW -and $newH -eq $script:physH) { return }
      $script:physW = $newW; $script:physH = $newH
      $r = New-Object PetNative+RECT
      [void][PetNative]::GetWindowRect($script:hwnd, [ref]$r)
      [void][PetNative]::ResizeAndMove($script:hwnd, $r.L, $r.T, $newW, $newH)
      Layout-Children; Update-Region; Save-Pos
      Calc-Flip
    } catch { Log ("size slider ERROR: " + ($_ | Out-String).Trim()) }
  })

  # —— 自动翻转开关 ——
  $flipChk.Add_Click({ Calc-Flip })

  $btnQuit.Add_Click({ Save-Pos; $win.Close() })})

# 悬停显隐：菜单按钮默认隐身（避免常驻一个方块在球上），鼠标进球才出现。
# 面板一旦展开就保持，直到再点一次按钮 / 点"问一下" / 鼠标离开窗口。
# （之前试过用 DispatcherTimer 做淡入淡出，Tick 里 `$bar.Opacity = ...` 的赋值读回来
#   永远是 0 —— 对象引用确认是同一个、分支也确实进了，就是不生效。不纠缠，直接切 Visibility。）
# ⚠️ 为什么要有宽限期：
#   窗口是 AllowsTransparency 的分层窗口，**透明像素会穿透** —— 鼠标事件只在"画了东西的地方"成立。
#   角色图是 Uniform 铺在右下 62% 的方框里，方框内还有大量 alpha=0 的像素（角色轮廓之外）。
#   而菜单按钮在角色方框的右上角，鼠标从大头挪过去很可能**中途经过透明区** → MouseLeave 立刻触发。
#   机器一卡，这个"一闪而过"就更明显：还没走到按钮，按钮就没了。
#   所以：MouseLeave **不当场藏**，起一个 0.9 秒的计时器；期间只要又 MouseEnter（挪到按钮上了）
#   就取消。真人伸手去点按钮远用不了 0.9 秒，够用。
$hideTimer = New-Object System.Windows.Threading.DispatcherTimer
$hideTimer.Interval = [TimeSpan]::FromMilliseconds(900)
$script:hovering = $false
$hideTimer.Add_Tick({
  $hideTimer.Stop()
  if ($script:hovering) { return }
  $menuBtn.Visibility = 'Collapsed'
  $menu.Visibility = 'Collapsed'
})

$showBar = {
  $script:hovering = $true
  $hideTimer.Stop()
  if ($menuBtn.Visibility -ne 'Visible') { $menuBtn.Visibility = 'Visible' }
}
$hideBar = {
  $script:hovering = $false
  $hideTimer.Stop()
  $hideTimer.Start()
}
$win.Add_MouseEnter($showBar)
$win.Add_MouseLeave($hideBar)

$win.Add_MouseLeftButtonDown({ Start-Drag })
$win.Add_MouseLeftButtonUp({ if ($script:drag) { $script:drag = $false; if ($dragTimer.IsEnabled) { $dragTimer.Stop() }; [void][PetNative]::ReleaseCapture(); Save-Pos; Calc-Flip; Log 'mouse up -> saved' } })
$win.Add_Closed({
  Save-Pos    # 任何关闭路径（含被外部 WM_CLOSE/taskkill 之前的正常退出）都记住位置
  if (-not $NoPidFile) { try { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue } catch {} }
})

# 状态文字：每 1 秒读一次 $DataDir\pet-state.json（文件当总线，与数据端解耦）
# 顺便每 3 秒做一次**位置自动落盘**：宿主的关闭走的是 taskkill /PID，宽限期内没退就强杀，
# 而强杀**不保证**触发 Add_Closed（P1 实测过）。所以持久化不能只挂在关闭事件上。
$script:lastSavedKey = ''
$script:saveTick = 0
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(1000)
$timer.Add_Tick({
  # —— 停信号：宿主在 $DataDir\stop.flag 落一个文件，我们读到就自己关窗 ——
  # 为什么不用 taskkill /PID（不带 /F）发 WM_CLOSE：实测 5.35 秒内关不掉，
  # 最后只能强杀，而强杀不保证跑 Add_Closed。自己读信号最确定。
  if (Test-Path -LiteralPath $StopFile) {
    try { Remove-Item -LiteralPath $StopFile -Force } catch {}
    Log 'stop.flag seen -> closing'
    $win.Close()
    return
  }
  # —— 位置自动落盘（只在真的变了的时候写）——
  try {
    if ($script:hwnd -ne [IntPtr]::Zero) {
      $script:saveTick++
      if ($script:saveTick % 3 -eq 0) {
        $r = New-Object PetNative+RECT
        if ([PetNative]::GetWindowRect($script:hwnd, [ref]$r)) {
          $key = "$($r.L),$($r.T),$($r.R-$r.L),$($r.B-$r.T)"
          if ($key -ne $script:lastSavedKey) {
            $script:lastSavedKey = $key
            Save-Pos
          }
        }
      }
    }
  } catch {}
  # —— 状态文字 ——
  if ($script:busy) { return }
  Update-AnswerFile   # 目标会话可能刚被换掉，路径跟着变
  # ⚠️ **球刚起来、还没被用过 ⇒ 气泡什么都不显示。**
  #   用户原话：「打开自动显示上一次的话，我需要每次重启，气泡清零不显示，使用再一直显示」。
  #   所以启动时先收起气泡；一旦点过「问一下 / 发消息 / 选择会话」（Send-Ask 里置 true），
  #   之后就一直按下面那套逻辑显示（回答 / 正在思考 / 状态），不再收。
  if (-not $script:bubbleArmed) {
    if ($bubbleBox.Visibility -ne 'Collapsed') { $bubbleBox.Visibility = 'Collapsed'; Update-Region; Log 'bubble hidden (未使用过)' }
    return
  }
  try {
    # —— 等回答期间显示「正在思考…」 ——
    # 用户原话：「她思考的时候，气泡窗里面为什么是这个东西，直接写正在思考不行吗」
    # 点了「问一下」/「发消息」之后，会话要花几秒到几十秒才把回答写进 $AnswerFile；
    # 这段时间里数据端还在每 1~2 秒重写 pet-state.json，于是气泡上一直是那条
    # 「【在哪】…缺：…」的诊断 —— 看着跟这次提问毫无关系，像坏了。
    # 所以：发了请求就进入"等回答"状态，气泡固定显示「正在思考…」，
    #       直到 ① 回答到了 ② 等太久（$script:ASK_WAIT_MIN 分钟）放弃。
    if ($script:askingSince -ne [datetime]::MinValue) {
      $ansNewer = $false
      if (Test-Path -LiteralPath $AnswerFile) {
        try { $ansNewer = (Get-Item -LiteralPath $AnswerFile).LastWriteTime -gt $script:askingSince } catch {}
      }
      $waitedMin = ([datetime]::Now - $script:askingSince).TotalMinutes
      if ($ansNewer -or $waitedMin -gt $script:ASK_WAIT_MIN) {
        $script:askingSince = [datetime]::MinValue      # 结束等待，往下走正常显示
      } else {
        $t = "正在思考…"
        if ($tb.Text -ne $t) { $tb.Text = $t; Fit-BubbleText }
        return
      }
    }

    # 两个来源：agent 的回答（$AnswerFile）和规则引擎/宿主的状态（$StateFile）。
    $src = ''
    $srcT = [datetime]::MinValue
    if (Test-Path -LiteralPath $StateFile) { $src = $StateFile; $srcT = (Get-Item -LiteralPath $StateFile).LastWriteTime }
    if (Test-Path -LiteralPath $AnswerFile) {
      try {
        $aT = (Get-Item -LiteralPath $AnswerFile).LastWriteTime
        # ⚠️ 回答只要**比最近一次提问新**就一直显示 —— **不设时限**。
        #   理由：① CDP 连不上时数据端每 1~2 秒重写 pet-state.json，按 mtime 抢的话
        #            回答活不过一个 tick（之前的 bug）；
        #         ② 原来给的是 300 秒窗口，结果用户"我刚刚没看到"—— 上个厕所回来就没了。
        #   用户原话：「会话不傻，自己把什么输出放到气泡里面」→ 由会话决定，别定时抢。
        #   新一轮提问时 Send-Ask 会删掉旧回答、并刷新 $script:lastAskAt，所以不会一直挂着陈年答案。
        if ($aT -gt $script:lastAskAt) { $src = $AnswerFile; $srcT = $aT }
      } catch {}
    }
    if ($src -eq $AnswerFile) {
      # 有回答 → 气泡必须显示出来（可能上一轮因为"没事可说"被收起了）
      if ($bubbleBox.Visibility -ne 'Visible') { $bubbleBox.Visibility = 'Visible'; Update-Region }
      $t = ([string](Get-Content -LiteralPath $AnswerFile -Raw -Encoding UTF8)).Trim()
      if ($t -eq '') { $t = '(空)' }
      if ($tb.Text -ne $t) { $tb.Text = $t; Fit-BubbleText }
    } elseif ($src -eq $StateFile) {
      # ⚠️ 必须显式 -Encoding UTF8：数据端写的是**无 BOM 的 UTF-8**，
      #    而 PowerShell 5.1 的 Get-Content 默认按**系统 ANSI 代码页**（中文机上是 GBK）解码 ——
      #    不加这个参数，球上的中文全是「鈺?漹鍕嘔€悏nitHub」那种乱码。真机踩到过。
      $j = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
      # ⚠️ no-browser / no-page = **跟用户无关的技术状态**，气泡直接收起，一个字都不显示。
      #    用户原话：「她没有连上给我看干什么，给会话看啊，连不上妨碍我使用这个插件吗」
      #    答案：不妨碍。问答那条链路不依赖 CDP（截图是 Win32 整屏截，不走 CDP），
      #    CDP 只服务"读 DOM 跑规则表"那一半。而且会话那边本来就拿到了整屏截图，它自己看得见。
      #    这种状态只在数据端日志里留痕就够了。
      $knd = ''
      if ($j -and $j.kind) { $knd = [string]$j.kind }
      if ($knd -eq 'no-browser' -or $knd -eq 'no-page') {
        if ($bubbleBox.Visibility -ne 'Collapsed') { $bubbleBox.Visibility = 'Collapsed'; Update-Region; Log ('bubble hidden (kind=' + $knd + ')') }
        return
      }
      if ($bubbleBox.Visibility -ne 'Visible') { $bubbleBox.Visibility = 'Visible'; Update-Region; Log 'bubble shown' }
      $t = if ($j -and $j.text) { [string]$j.text } else { '(空)' }
      if ($tb.Text -ne $t) { $tb.Text = $t; Fit-BubbleText }
    } else {
      $tb.Text = "等数据端…`n$StateFile"; Fit-BubbleText
    }
  } catch { $tb.Text = "读状态失败`n$($_.Exception.Message)" }
})
$timer.Start()

$win.ShowDialog() | Out-Null
$timer.Stop()
Write-Output 'pet-ball exited'
