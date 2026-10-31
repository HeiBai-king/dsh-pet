# test-ball-drag.ps1 -- synthesize a real drag on the ball's opaque area and report the result.
# ASCII-only on purpose (PS 5.1 + non-BOM UTF-8 = mojibake).
#
# DPI NOTE: this process calls SetProcessDPIAware() so GetWindowRect / SetCursorPos all work in
# PHYSICAL pixels -- otherwise everything is silently virtualized by the 150% scale and the
# synthesized clicks land in the wrong place (this exact trap already fooled cdp-pet.js).
param([string]$Title = 'DSH-PET-BALL', [int]$Dx = -220, [int]$Dy = -140)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class DragT {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, ref RECT r, uint c);
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
}
'@
[void][DragT]::SetProcessDPIAware()

$h = [DragT]::FindByTitle($Title)
if ($h -eq [IntPtr]::Zero) { Write-Output "window '$Title' not found"; exit 1 }
$r = New-Object DragT+RECT
[void][DragT]::GetWindowRect($h, [ref]$r)
Write-Output "before: $($r.L),$($r.T) - $($r.R),$($r.B)  ($($r.R-$r.L)x$($r.B-$r.T))"

# 找一个确实命中的抓取点：从窗口内部扫，取 WindowFromPoint==窗口 的第一个点
$sx = -1; $sy = -1
for ($yy = $r.T + 10; $yy -lt $r.B - 10 -and $sx -lt 0; $yy += 12) {
  for ($xx = $r.L + 10; $xx -lt $r.R - 10; $xx += 12) {
    $p = New-Object DragT+POINT; $p.X = $xx; $p.Y = $yy
    if ([DragT]::WindowFromPoint($p) -eq $h) { $sx = $xx; $sy = $yy; break }
  }
}
if ($sx -lt 0) { Write-Output 'no opaque pixel found to grab'; exit 2 }
Write-Output "grab at: $sx,$sy"

# 合成拖动：按下 -> 分步移动 -> 抬起
[void][DragT]::SetCursorPos($sx, $sy)
Start-Sleep -Milliseconds 250
[DragT]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 150
for ($i = 1; $i -le 8; $i++) {
  [void][DragT]::SetCursorPos($sx + [int]($Dx * $i / 8), $sy + [int]($Dy * $i / 8))
  Start-Sleep -Milliseconds 45
}
[DragT]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 500

$r2 = New-Object DragT+RECT
[void][DragT]::GetWindowRect($h, [ref]$r2)
Write-Output "after:  $($r2.L),$($r2.T) - $($r2.R),$($r2.B)  ($($r2.R-$r2.L)x$($r2.B-$r2.T))"
Write-Output "moved:  dx=$($r2.L - $r.L) dy=$($r2.T - $r.T)   (requested $Dx,$Dy)"
