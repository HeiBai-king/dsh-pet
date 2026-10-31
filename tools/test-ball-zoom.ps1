# test-ball-zoom.ps1 -- click the ball's "+" button and prove the window really resizes,
# the window region is rebuilt, and the drag clamp follows the NEW size.
# ASCII-only on purpose (PS 5.1 + non-BOM UTF-8 = mojibake).
#
# How the "+" button is located without hard-coding the layout:
#   scan the top strip of the window for pixels where WindowFromPoint() == ball,
#   cluster them by x, and click the LEFTMOST cluster -- the control bar is "+ - x"
#   laid out left to right, so the leftmost cluster is "+".
param([string]$Title = 'DSH-PET-BALL', [int]$Clicks = 2)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class ZoomT {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern int GetWindowRgn(IntPtr h, IntPtr rgn);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateRectRgn(int l,int t,int r,int b);
  [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
  [DllImport("gdi32.dll")] public static extern int GetRgnBox(IntPtr rgn, out RECT r);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

  public static IntPtr FindByTitle(string title) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(256); GetWindowText(h, sb, 256);
      if (sb.ToString() == title) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static bool HitSelf(IntPtr hwnd, int x, int y) {
    var p = new POINT(); p.X = x; p.Y = y;
    return WindowFromPoint(p) == hwnd;
  }
  public static string RgnBox(IntPtr hwnd) {
    var tmp = CreateRectRgn(0,0,1,1);
    GetWindowRgn(hwnd, tmp);
    RECT rb; GetRgnBox(tmp, out rb);
    DeleteObject(tmp);
    return rb.L + "," + rb.T + "," + rb.R + "," + rb.B;
  }
}
'@
[void][ZoomT]::SetProcessDPIAware()

$h = [ZoomT]::FindByTitle($Title)
if ($h -eq [IntPtr]::Zero) { Write-Output "window '$Title' not found"; exit 1 }

function Rect() { $r = New-Object ZoomT+RECT; [void][ZoomT]::GetWindowRect($h, [ref]$r); return $r }

$r0 = Rect
Write-Output ("start : rect={0},{1},{2},{3}  size={4}x{5}  rgnBox={6}" -f $r0.L,$r0.T,$r0.R,$r0.B,($r0.R-$r0.L),($r0.B-$r0.T),([ZoomT]::RgnBox($h)))

# --- 找控制条：扫顶部横条，按 x 聚类 ---
# 注意：控制条是右对齐的，**窗口一缩放它就移位**。所以每次点击前都要重新定位 ——
# 这也正是被验的那条修复（Update-Region 之前必须先重算 barRect）。
function Find-PlusButton {
  $rr = Rect
  $strip = @()
  for ($yy = $rr.T + 4; $yy -lt $rr.T + 46; $yy += 3) {
    for ($xx = $rr.L + 4; $xx -lt $rr.R - 4; $xx += 3) {
      if ([ZoomT]::HitSelf($h, $xx, $yy)) { $strip += [pscustomobject]@{ X = $xx; Y = $yy } }
    }
  }
  if ($strip.Count -eq 0) { return $null }
  $xs = $strip | Sort-Object X
  $clusters = @(); $cur = @($xs[0])
  for ($i = 1; $i -lt $xs.Count; $i++) {
    if ($xs[$i].X - $xs[$i-1].X -le 12) { $cur += $xs[$i] } else { $clusters += ,$cur; $cur = @($xs[$i]) }
  }
  $clusters += ,$cur
  $target = $clusters[$clusters.Count - 1]        # 最右那簇 = 控制条（左边的是气泡描边）
  $tmin = ($target | Measure-Object -Property X -Minimum).Minimum
  $tmax = ($target | Measure-Object -Property X -Maximum).Maximum
  $ty = [int](($target | Measure-Object -Property Y -Average).Average)
  # 控制条从左到右是 "+ - x" => 最左端那一小块 = "+"
  $tx = [int]($tmin + [Math]::Max(6, ($tmax - $tmin) / 6))
  return [pscustomobject]@{ X = $tx; Y = $ty; BarX0 = $tmin; BarX1 = $tmax; Clusters = $clusters.Count; Pixels = $strip.Count }
}

$pb = Find-PlusButton
if (-not $pb) { Write-Output 'no hit-self pixels in the top strip'; exit 2 }
Write-Output ("control bar located: x {0}..{1}  (clusters={2}, hitPixels={3})" -f $pb.BarX0, $pb.BarX1, $pb.Clusters, $pb.Pixels)
Write-Output ("clicking near its LEFT edge (assumed '+'): {0},{1}" -f $pb.X, $pb.Y)
$tx = $pb.X; $ty = $pb.Y

for ($k = 1; $k -le $Clicks; $k++) {
  [void][ZoomT]::SetCursorPos($tx, $ty)
  Start-Sleep -Milliseconds 200
  [ZoomT]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  [ZoomT]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 700
  $rn = Rect
  Write-Output ("after click {0}: size={1}x{2}  rgnBox={3}" -f $k, ($rn.R-$rn.L), ($rn.B-$rn.T), ([ZoomT]::RgnBox($h)))
  # 关键：重新定位按钮。如果缩放后 barRect 没重算（新代码修的就是这个），
  # 控制条那一小块就不在窗口区域里，这里会定位失败 -> 直接暴露回归。
  $pb2 = Find-PlusButton
  if ($pb2) {
    Write-Output ("  relocate bar ok: x {0}..{1} -> click {2},{3}" -f $pb2.BarX0, $pb2.BarX1, $pb2.X, $pb2.Y)
    $tx = $pb2.X; $ty = $pb2.Y
  } else {
    Write-Output '  ⚠️ relocate FAILED: control bar is no longer clickable (region/barRect stale)'
  }
}

# --- 位置 clamp 是否跟着新尺寸：往右下角猛拖，看会不会出工作区 ---
$rn = Rect
$w = $rn.R - $rn.L; $hh = $rn.B - $rn.T
# 抓一个鲸鱼身上的点（右上角区域是控制条，往中间找）
$gx = -1; $gy = -1
for ($yy = $rn.T + 120; $yy -lt $rn.B - 20 -and $gx -lt 0; $yy += 15) {
  for ($xx = $rn.L + 20; $xx -lt $rn.R - 20; $xx += 15) {
    if ([ZoomT]::HitSelf($h, $xx, $yy)) { $gx = $xx; $gy = $yy; break }
  }
}
if ($gx -gt 0) {
  [void][ZoomT]::SetCursorPos($gx, $gy); Start-Sleep -Milliseconds 250
  [ZoomT]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 150
  for ($i = 1; $i -le 10; $i++) { [void][ZoomT]::SetCursorPos($gx + 90 * $i, $gy + 70 * $i); Start-Sleep -Milliseconds 40 }
  [ZoomT]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 500
  $rd = Rect
  Write-Output ("after drag-to-bottom-right: rect={0},{1},{2},{3}  size={4}x{5}" -f $rd.L,$rd.T,$rd.R,$rd.B,($rd.R-$rd.L),($rd.B-$rd.T))
  Write-Output ("  workarea check: rightEdge={0} bottomEdge={1} (screen is 2160x1440, taskbar ~72px)" -f $rd.R, $rd.B)
} else { Write-Output 'no grab point found for the clamp test' }
