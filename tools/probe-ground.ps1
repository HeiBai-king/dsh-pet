# probe-ground.ps1 -- opaque "ground" window = the LOWER layer of the hit-test probe.
# It logs every left-button-down it receives, so the overlay can prove whether a synthetic
# click actually travelled through to the window underneath (cross-process).
# ASCII-only on purpose: PowerShell 5.1 mis-decodes non-BOM UTF-8 .ps1 files.
param(
  [string]$Here = $PSScriptRoot,
  [int]$X = 200, [int]$Y = 200, [int]$W = 400, [int]$H = 400,
  [int]$AutoCloseMs = 25000
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class GndDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@
[void][GndDpi]::SetProcessDPIAware()

$hwndFile  = Join-Path $Here '_probe-ground.hwnd'
$clickFile = Join-Path $Here '_probe-ground-clicks.txt'
$doneFile  = Join-Path $Here '_probe-ground.done'
Remove-Item -LiteralPath $clickFile, $doneFile -ErrorAction SilentlyContinue

$win = New-Object System.Windows.Window
$win.WindowStyle = [System.Windows.WindowStyle]::None
$win.Topmost = $true
$win.ShowInTaskbar = $false
$win.Width = $W
$win.Height = $H
$win.Left = $X
$win.Top = $Y
$win.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(210, 40, 40))
$win.Title = 'PROBE_GROUND'
$win.Add_Loaded({
  $h = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
  [System.IO.File]::WriteAllText($hwndFile, "$h", (New-Object System.Text.UTF8Encoding($false)))
})
$win.Add_MouseLeftButtonDown({
  $line = (Get-Date).ToString('HH:mm:ss.fff') + " click at " + $_.GetPosition($win).X + "," + $_.GetPosition($win).Y
  [System.IO.File]::AppendAllText($clickFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
})
$win.Add_Closed({ [System.IO.File]::WriteAllText($doneFile, '1') })
$win.ShowDialog() | Out-Null
