# click-at.ps1 -- synthesize one left click at a PHYSICAL screen coordinate.
# ASCII-only on purpose (PS 5.1 + non-BOM UTF-8 = mojibake).
param([int]$X, [int]$Y, [int]$SettleMs = 700)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class ClickAt {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
}
'@
[void][ClickAt]::SetProcessDPIAware()
[void][ClickAt]::SetCursorPos($X, $Y)
Start-Sleep -Milliseconds 250
$p = New-Object ClickAt+POINT
[void][ClickAt]::GetCursorPos([ref]$p)
$hit = [ClickAt]::WindowFromPoint($p)
[ClickAt]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
[ClickAt]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds $SettleMs
Write-Output "clicked at $($p.X),$($p.Y)  WindowFromPoint=$hit"
