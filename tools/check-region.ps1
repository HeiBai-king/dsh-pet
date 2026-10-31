# check-region.ps1 -- prove that the ball window actually carries a non-rectangular window region,
# and that WindowFromPoint inside a transparent area falls through to whatever is underneath.
# ASCII-only on purpose (PS 5.1 + non-BOM UTF-8 = mojibake).
param([string]$Title = 'DSH-PET-BALL')
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class RCheck {
  [DllImport("user32.dll")] public static extern int GetWindowRgn(IntPtr h, IntPtr rgn);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateRectRgn(int l,int t,int r,int b);
  [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr o);
  [DllImport("gdi32.dll")] public static extern int GetRgnBox(IntPtr rgn, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

  public static IntPtr FindByTitle(string title) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(256);
      GetWindowText(h, sb, 256);
      if (sb.ToString() == title) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static string Report(IntPtr hwnd) {
    if (hwnd == IntPtr.Zero) return "window not found";
    var tmp = CreateRectRgn(0,0,1,1);
    int kind = GetWindowRgn(hwnd, tmp);
    RECT rb; GetRgnBox(tmp, out rb);
    DeleteObject(tmp);
    RECT wr; GetWindowRect(hwnd, out wr);
    int w = wr.R-wr.L, hh = wr.B-wr.T;

    var pts = new string[] { "corner+20", "corner+60", "center", "center+40x+40" };
    var xs = new int[] { wr.L+20, wr.L+60, wr.L+w/2, wr.L+w/2+40 };
    var ys = new int[] { wr.T+20, wr.T+60, wr.T+hh/2, wr.T+hh/2+40 };

    var sb = new StringBuilder();
    sb.AppendLine("hwnd=" + hwnd);
    sb.AppendLine("windowRect=" + wr.L+","+wr.T+","+wr.R+","+wr.B + "  (" + w + "x" + hh + ")");
    sb.AppendLine("rgnKind=" + kind + "   (1=SIMPLEREGION 2=COMPLEXREGION 0=none 3=error)");
    sb.AppendLine("rgnBox=" + rb.L+","+rb.T+","+rb.R+","+rb.B);
    for (int i = 0; i < xs.Length; i++) {
      var p = new POINT(); p.X = xs[i]; p.Y = ys[i];
      IntPtr got = WindowFromPoint(p);
      sb.AppendLine("wfp " + pts[i].PadRight(16) + " (" + xs[i] + "," + ys[i] + ") -> " + got + "  " + (got == hwnd ? "SELF(ball)" : "OTHER(below)"));
    }
    return sb.ToString();
  }
}
'@

$h = [RCheck]::FindByTitle($Title)
Write-Output ([RCheck]::Report($h))
