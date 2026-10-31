#Requires -Version 5.1
<#
.SYNOPSIS
    把 dsh-pet 从 DSH 的 web profile 里卸掉。

.DESCRIPTION
    做三件事（install.ps1 的逆操作）：
      ① 删掉 $ProfileRoot\node_modules\dsh-pet 这个联接
      ② 从 $ProfileRoot\package.json 的 dependencies 里删掉 "dsh-pet"
      ③ 从 $ProfileRoot\package.json 的 dsh.profile.bundles 里删掉 "dsh-pet"

    **不动**你的数据目录 "$env:USERPROFILE\.dsh\pet"（里面有选过的会话、日志、截图）。
    要一起清掉就加 -PurgeData。

    ⚠️ 卸完必须重启 DSH 才生效。

.PARAMETER ProfileRoot
    DSH 的 web profile 目录。默认 "$env:USERPROFILE\.dsh\profiles\web"。

.PARAMETER PurgeData
    连数据目录一起删（日志、截图、选过的会话都会没）。

.EXAMPLE
    powershell -EP Bypass -File tools\uninstall.ps1
#>
[CmdletBinding()]
param(
    [string]$ProfileRoot = '',
    [switch]$PurgeData
)

$ErrorActionPreference = 'Stop'

function Say($m) { Write-Host $m }
function Fail($m) { Write-Host ("✗ " + $m) -ForegroundColor Red; exit 1 }
function Ok($m)   { Write-Host ("✓ " + $m) -ForegroundColor Green }

if (-not $ProfileRoot) { $ProfileRoot = Join-Path $env:USERPROFILE '.dsh\profiles\web' }
if (-not (Test-Path -LiteralPath $ProfileRoot)) { Fail ("找不到 profile：" + $ProfileRoot) }
$ProfileRoot = (Resolve-Path -LiteralPath $ProfileRoot).ProviderPath

# ① 联接
$linkPath = Join-Path $ProfileRoot 'node_modules\dsh-pet'
$existing = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
if (-not $existing) {
    Ok 'node_modules\dsh-pet 不存在，跳过'
} else {
    $isLink = ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if (-not $isLink) {
        Say ("  ⚠️ node_modules\dsh-pet 是真实目录（不是联接），不删。要删请自己删：" + $linkPath)
    } else {
        # ⚠️ 别用 Remove-Item：PS 5.1 删 junction 会抛 NullReferenceException（实测）
        [System.IO.Directory]::Delete($linkPath, $false)
        Ok '删掉联接 node_modules\dsh-pet'
    }
}

# ② ③ package.json
$profilePkg = Join-Path $ProfileRoot 'package.json'
if (-not (Test-Path -LiteralPath $profilePkg)) { Fail ("profile 里没有 package.json：" + $profilePkg) }

$j = Get-Content -LiteralPath $profilePkg -Raw -Encoding UTF8 | ConvertFrom-Json
$changed = $false

if ($j.dependencies -and ($j.dependencies.PSObject.Properties.Name -contains 'dsh-pet')) {
    $j.dependencies.PSObject.Properties.Remove('dsh-pet')
    $changed = $true
    Ok 'dependencies 里删掉 dsh-pet'
}
if ($j.dsh -and $j.dsh.profile -and $j.dsh.profile.bundles) {
    $bundles = @($j.dsh.profile.bundles | Where-Object { $_ -ne 'dsh-pet' })
    if ($bundles.Count -ne @($j.dsh.profile.bundles).Count) {
        $j.dsh.profile | Add-Member -NotePropertyName 'bundles' -NotePropertyValue $bundles -Force
        $changed = $true
        Ok 'dsh.profile.bundles 里删掉 dsh-pet'
    }
}

if ($changed) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $bak = $profilePkg + '.bak-' + $stamp
    Copy-Item -LiteralPath $profilePkg -Destination $bak -Force
    Ok ("已备份 → " + (Split-Path -Leaf $bak))
    $out = $j | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($profilePkg, $out, (New-Object System.Text.UTF8Encoding($false)))
    Ok 'profile package.json 已更新'
} else {
    Ok 'package.json 里没有 dsh-pet，不用改'
}

# 数据目录
$dataDir = Join-Path $env:USERPROFILE '.dsh\pet'
if ($PurgeData) {
    if (Test-Path -LiteralPath $dataDir) {
        Remove-Item -LiteralPath $dataDir -Recurse -Force
        Ok ("删掉数据目录：" + $dataDir)
    }
} else {
    Say ("  数据目录保留着（要删加 -PurgeData）：" + $dataDir)
}

Say ''
Say '============================================================'
Say ' 卸完了，**重启 DSH 才生效**。'
Say ' 记得先把桌面球收掉（菜单 →「收起鲸鱼球」），否则它会挂在屏幕上没人管。'
Say '============================================================'
