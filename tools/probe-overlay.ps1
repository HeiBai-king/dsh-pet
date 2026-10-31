# probe-overlay.ps1 -- transparent top-most overlay with selectable hit-test behaviour.
# Answers: does WM_NCHITTEST/HTTRANSPARENT let a click reach the window BELOW, cross-process?
# ASCII-only on purpose (PS 5.1 + non-BOM UTF-8 .ps1 files = mojibake).
#
# NOTE 1: PowerShell variables are case-insensitive, so the window variable is $win (NOT $w),
#         otherwise it collides with the [int]$W parameter and the assignment fails.
# NOTE 2: every step runs inside one try/catch that ALWAYS writes the result file, because an
#         exception inside a WPF Loaded handler is otherwise swallowed and the process just dies.
#
# -Mode none      : no hook              -> baseline, whole window is solid to the mouse
# -Mode hittest   : WM_NCHITTEST -> HTCLIENT over the opaque patch, HTTRANSPARENT elsewhere
# -Mode wsextrans : WS_EX_TRANSPARENT|WS_EX_LAYERED -> whole window ignores the mouse
param(
  [ValidateSet('none', 'hittest', 'wsextrans', 'region')] [string]$Mode = 'hittest',
  [int]$X = 200, [int]$Y = 200, [int]$W = 400, [int]$H = 400,
  [int]$Patch = 100,
  [switch]$Click,
  [int]$AutoCloseMs = 8000
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Probe {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr h, IntPtr rgn, bool redraw);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateEllipticRgn(int l, int t, int r, int b);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
'@
[void][Probe]::SetProcessDPIAware()

$script:RESULT = [ordered]@{}
$script:RESULTPATH = Join-Path $PSScriptRoot ("_probe-result-$Mode.txt")
function Save-Result {
  $lines = @()
  foreach ($k in $script:RESULT.Keys) { $lines += "$k=$($script:RESULT[$k])" }
  [System.IO.File]::WriteAllText($script:RESULTPATH, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
  $lines | ForEach-Object { Write-Output $_ }
}
$script:RESULT['mode'] = $Mode
Save-Result

$win = New-Object System.Windows.Window
$win.WindowStyle = [System.Windows.WindowStyle]::None
$win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.Topmost = $true
$win.ShowInTaskbar = $false
$win.Width = $W; $win.Height = $H; $win.Left = $X; $win.Top = $Y
$win.Title = 'PROBE_OVERLAY'

$grid = New-Object System.Windows.Controls.Grid
$patchRect = New-Object System.Windows.Shapes.Rectangle
$patchRect.Width = $Patch; $patchRect.Height = $Patch
$patchRect.Fill = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(40, 200, 90))
$patchRect.HorizontalAlignment = 'Center'; $patchRect.VerticalAlignment = 'Center'
$grid.Children.Add($patchRect) | Out-Null
$win.Content = $grid

$script:rect = $null
$script:PatchSize = $Patch
$script:ClickFlag = [bool]$Click

function Test-Opaque([int]$sx, [int]$sy) {
  $r = $script:rect
  if (-not $r) { return $false }
  $cx = ($r.L + $r.R) / 2; $cy = ($r.T + $r.B) / 2
  return ([Math]::Abs($sx - $cx) -le $script:PatchSize / 2) -and ([Math]::Abs($sy - $cy) -le $script:PatchSize / 2)
}

$win.Add_Loaded({
  try {
    $h = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
    $r = New-Object Probe+RECT
    [void][Probe]::GetWindowRect($h, [ref]$r)
    $script:rect = $r
    $script:RESULT['overlay_hwnd'] = $h
    $script:RESULT['rect'] = "$($r.L),$($r.T),$($r.R),$($r.B)"

    if ($Mode -eq 'wsextrans') {
      $GWL_EXSTYLE = -20; $WS_EX_TRANSPARENT = 0x20; $WS_EX_LAYERED = 0x80000
      $cur = [Probe]::GetWindowLong($h, $GWL_EXSTYLE)
      [void][Probe]::SetWindowLong($h, $GWL_EXSTYLE, ($cur -bor $WS_EX_TRANSPARENT -bor $WS_EX_LAYERED))
      $script:RESULT['exstyle_set'] = 'ok'
    } elseif ($Mode -eq 'region') {
      # SetWindowRgn: coordinates are relative to the window's upper-left corner.
      # Scale the DIP patch size into physical pixels using the measured window size.
      $wPhys = $r.R - $r.L; $hPhys = $r.B - $r.T
      $sc = if ($W -gt 0) { $wPhys / $W } else { 1 }
      $rad = [int](($Patch / 2) * $sc)
      $cx = [int]($wPhys / 2); $cy = [int]($hPhys / 2)
      $hrgn = [Probe]::CreateEllipticRgn($cx - $rad, $cy - $rad, $cx + $rad, $cy + $rad)
      $rc = [Probe]::SetWindowRgn($h, $hrgn, $true)
      $script:RESULT['region'] = "ellipse r=$rad at $cx,$cy  setrc=$rc  window=${wPhys}x${hPhys}  scale=$sc"
    } elseif ($Mode -eq 'hittest') {
      $src = [System.Windows.Interop.HwndSource]::FromHwnd($h)
      $src.AddHook([System.Windows.Interop.HwndSourceHook]{
        param([IntPtr]$hwnd, [int]$msg, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
        if ($msg -eq 0x0084) {
          $v = $lParam.ToInt64()
          $sx = [int]($v -band 0xFFFF); if ($sx -ge 0x8000) { $sx -= 0x10000 }
          $sy = [int](($v -shr 16) -band 0xFFFF); if ($sy -ge 0x8000) { $sy -= 0x10000 }
          $handled.Value = $true
          if (Test-Opaque $sx $sy) { return [IntPtr]2 }
          return [IntPtr](-1)
        }
        return [IntPtr]::Zero
      })
      $script:RESULT['hook'] = 'installed'
    } else {
      $script:RESULT['hook'] = 'none'
    }
    Save-Result

    Start-Sleep -Milliseconds 400
    $r = $script:rect
    $opaquePt = New-Object Probe+POINT
    $opaquePt.X = [int](($r.L + $r.R) / 2); $opaquePt.Y = [int](($r.T + $r.B) / 2)
    $clearPt = New-Object Probe+POINT
    $clearPt.X = $r.L + 12; $clearPt.Y = $r.T + 12

    $hOverlay = $h
    $hOpacity = [Probe]::WindowFromPoint($opaquePt)
    $hClear = [Probe]::WindowFromPoint($clearPt)

    $groundHwnd = 0
    $gfile = Join-Path $PSScriptRoot '_probe-ground.hwnd'
    if (Test-Path -LiteralPath $gfile) { $groundHwnd = [int64](Get-Content -LiteralPath $gfile -Raw).Trim() }

    function Describe($hh) {
      if ([int64]$hh -eq [int64]$hOverlay) { return 'OVERLAY(self)' }
      if ($groundHwnd -ne 0 -and [int64]$hh -eq $groundHwnd) { return 'GROUND(below)' }
      return 'other/foreign'
    }

    $script:RESULT['ground_hwnd'] = $groundHwnd
    $script:RESULT['opaque_pt'] = "$($opaquePt.X),$($opaquePt.Y) wfp=$hOpacity -> $(Describe $hOpacity)"
    $script:RESULT['clear_pt'] = "$($clearPt.X),$($clearPt.Y) wfp=$hClear -> $(Describe $hClear)"

    if ($script:ClickFlag) {
      $clickFile = Join-Path $PSScriptRoot '_probe-ground-clicks.txt'
      Remove-Item -LiteralPath $clickFile -ErrorAction SilentlyContinue
      function DoOneClick([int]$cx, [int]$cy) {
        # 关键：点第一下会把下层窗口激活并抬到 topmost 带的最前面，
        # 于是第二下必然被它接走 —— 每次点击前先把上层重新压回最顶。
        [void][Probe]::SetWindowPos($hOverlay, [IntPtr](-1), 0, 0, 0, 0, 0x0002 -bor 0x0001 -bor 0x0010)
        Start-Sleep -Milliseconds 180
        [void][Probe]::SetCursorPos($cx, $cy)
        Start-Sleep -Milliseconds 200
        [Probe]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
        [Probe]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 450
      }
      # 先点不透明处（应当被上层自己接走），再点透明处（应当穿到下层）
      DoOneClick $opaquePt.X $opaquePt.Y
      $nAfterOpaque = if (Test-Path -LiteralPath $clickFile) { @(Get-Content -LiteralPath $clickFile).Count } else { 0 }
      DoOneClick $clearPt.X $clearPt.Y
      $nAll = if (Test-Path -LiteralPath $clickFile) { @(Get-Content -LiteralPath $clickFile).Count } else { 0 }
      $script:RESULT['click_opaque_pt'] = "ground_got_it=$($nAfterOpaque -gt 0) (n=$nAfterOpaque)  [期望 False]"
      $script:RESULT['click_clear_pt'] = "ground_got_it=$($nAll -gt $nAfterOpaque) (n=$nAll)  [期望 True]"
    } else {
      $script:RESULT['click'] = 'not-run'
    }
    Save-Result
  } catch {
    $script:RESULT['FATAL'] = ($_ | Out-String).Trim() -replace "`r?`n", ' | '
    Save-Result
  }
  try { $win.Close() } catch {}
})

# 自关兜底：绝不在用户屏幕上留一个关不掉的无边框窗口
$autoClose = New-Object System.Windows.Threading.DispatcherTimer
$autoClose.Interval = [TimeSpan]::FromMilliseconds($AutoCloseMs)
$autoClose.Add_Tick({ try { $autoClose.Stop(); $script:RESULT['autoClosed'] = 'yes'; Save-Result; $win.Close() } catch {} })
$autoClose.Start()

$win.ShowDialog() | Out-Null
$autoClose.Stop()
