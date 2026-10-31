# pet-shot.ps1 -- take one full-screen screenshot and save it as PNG.
# ASCII-only on purpose: PowerShell 5.1 mis-decodes non-BOM UTF-8 .ps1 files.
#
# Migrated from 桌宠v1\pet-shot.ps1, with the two defects the review found fixed:
#   1. no try/catch at all -> any failure was a bare non-zero exit with no readable message
#   2. the caller never checked $LASTEXITCODE, so a failed shot was only discovered
#      much later on the host side (by "file does not exist")
# Now: every failure prints a machine-readable "ERROR: ..." line and exits 2,
# and success prints "OK:<path>:<bytes>" and exits 0.
param(
  [Parameter(Mandatory = $true)][string]$Out,
  [switch]$AllScreens
)
$ErrorActionPreference = 'Stop'

try {
  Add-Type -AssemblyName System.Drawing
  Add-Type -AssemblyName System.Windows.Forms

  # Make this process DPI-aware first: otherwise VirtualScreen returns the
  # virtualized (96-DPI) logical size and CopyFromScreen only grabs the
  # top-left physical block -- on a 150% display the bottom-right is lost.
  try {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public class ShotDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@ -ErrorAction Stop
    [void][ShotDpi]::SetProcessDPIAware()
  } catch {
    try { Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue } catch {}
  }

  $dir = Split-Path -Parent $Out
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
  if ($b.Width -le 0 -or $b.Height -le 0) { throw "bad virtual screen $($b.Width)x$($b.Height)" }

  $bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
  try {
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size) } finally { $g.Dispose() }
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally { $bmp.Dispose() }

  if (-not (Test-Path -LiteralPath $Out)) { throw "file not written: $Out" }
  $len = (Get-Item -LiteralPath $Out).Length
  if ($len -le 0) { throw "written file is empty: $Out" }
  Write-Output ("OK:{0}:{1}:{2}x{3}" -f $Out, $len, $b.Width, $b.Height)
  exit 0
} catch {
  Write-Output ("ERROR:{0}" -f ($_.Exception.Message -replace "`r?`n", ' '))
  exit 2
}
