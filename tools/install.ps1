#Requires -Version 5.1
<#
.SYNOPSIS
    把 dsh-pet 装进 DSH 的 web profile。

.DESCRIPTION
    做三件事（和手工装完全一样，只是不让你手抖）：
      ① 在 $ProfileRoot\node_modules\dsh-pet 建目录联接（Junction），指向本包
      ② 在 $ProfileRoot\package.json 的 dependencies 里加 "dsh-pet": "link:<包目录>"
      ③ 在 $ProfileRoot\package.json 的 dsh.profile.bundles 数组末尾加 "dsh-pet"

    改 package.json 之前会**先备份**成 package.json.bak-<时间戳>。

    ⚠️ 装完必须重启 DSH 才生效。**如果 DSH 正在跑，而你就是跑在 DSH 里的 AI，
       别自己重启 —— 那会杀掉你自己的会话。让用户来。**

.PARAMETER PackageDir
    本包所在目录。默认是脚本所在目录的上一级（tools\install.ps1 → 包根）。

.PARAMETER ProfileRoot
    DSH 的 web profile 目录。默认 "$env:USERPROFILE\.dsh\profiles\web"。
    测试/多 profile 时可以用它指别处。

.EXAMPLE
    powershell -EP Bypass -File tools\install.ps1

.EXAMPLE
    powershell -EP Bypass -File tools\install.ps1 -PackageDir "D:\tools\dsh-pet"
#>
[CmdletBinding()]
param(
    [string]$PackageDir = '',
    [string]$ProfileRoot = ''
)

$ErrorActionPreference = 'Stop'

function Say($m) { Write-Host $m }
function Fail($m) { Write-Host ("✗ " + $m) -ForegroundColor Red; exit 1 }
function Ok($m)   { Write-Host ("✓ " + $m) -ForegroundColor Green }

# ---------------------------------------------------------------- 定位包目录
if (-not $PackageDir) { $PackageDir = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath (Join-Path $PackageDir 'package.json'))) {
    Fail ("这里不像包目录（找不到 package.json）：" + $PackageDir)
}
$pkgJsonPath = Join-Path $PackageDir 'package.json'
$pkg = Get-Content -LiteralPath $pkgJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($pkg.name -ne 'dsh-pet') {
    Fail ("package.json 里的 name 是 '" + $pkg.name + "'，不是 dsh-pet。装错包了？")
}
$PackageDir = (Resolve-Path -LiteralPath $PackageDir).ProviderPath
Say ("包目录    " + $PackageDir)

# ---------------------------------------------------------------- 定位 profile
if (-not $ProfileRoot) { $ProfileRoot = Join-Path $env:USERPROFILE '.dsh\profiles\web' }
if (-not (Test-Path -LiteralPath $ProfileRoot)) {
    Fail ("找不到 DSH 的 web profile：" + $ProfileRoot + "`n  DSH 装了吗？或者换别的 profile 名？")
}
$profilePkg = Join-Path $ProfileRoot 'package.json'
if (-not (Test-Path -LiteralPath $profilePkg)) {
    Fail ("profile 里没有 package.json：" + $profilePkg)
}
$ProfileRoot = (Resolve-Path -LiteralPath $ProfileRoot).ProviderPath
Say ("profile   " + $ProfileRoot)
Say ''

# ---------------------------------------------------------------- ② ③ 先打算好
# 注意 link: 里的路径要用**正斜杠**，Windows 的 json 也吃，但反斜杠会被当转义
$linkTarget = $PackageDir -replace '\\', '/'

$raw = Get-Content -LiteralPath $profilePkg -Raw -Encoding UTF8
$j = $raw | ConvertFrom-Json

if (-not $j.dependencies) {
    $j | Add-Member -NotePropertyName 'dependencies' -NotePropertyValue ([pscustomobject]@{}) -Force
}
$changed = $false

# dependencies
$depNow = $null
if ($j.dependencies.PSObject.Properties.Name -contains 'dsh-pet') { $depNow = $j.dependencies.'dsh-pet' }
$wantDep = 'link:' + $linkTarget
if ($depNow -eq $wantDep) {
    Ok ("dependencies 已经是对的：" + $wantDep)
} else {
    if ($depNow) {
        Say ("  dependencies.dsh-pet 原值：" + $depNow + " → 改成 " + $wantDep)
    }
    $j.dependencies | Add-Member -NotePropertyName 'dsh-pet' -NotePropertyValue $wantDep -Force
    $changed = $true
    Ok ("dependencies 加上了：" + $wantDep)
}

# dsh.profile.bundles
if (-not $j.dsh) { $j | Add-Member -NotePropertyName 'dsh' -NotePropertyValue ([pscustomobject]@{}) -Force }
if (-not $j.dsh.profile) { $j.dsh | Add-Member -NotePropertyName 'profile' -NotePropertyValue ([pscustomobject]@{}) -Force }
if (-not $j.dsh.profile.bundles) {
    $j.dsh.profile | Add-Member -NotePropertyName 'bundles' -NotePropertyValue @() -Force
}
$bundles = @($j.dsh.profile.bundles)
if ($bundles -contains 'dsh-pet') {
    Ok 'dsh.profile.bundles 里已经有 dsh-pet'
} else {
    $bundles = $bundles + 'dsh-pet'
    $j.dsh.profile | Add-Member -NotePropertyName 'bundles' -NotePropertyValue $bundles -Force
    $changed = $true
    Ok 'dsh.profile.bundles 末尾加上了 dsh-pet'
}

# ---------------------------------------------------------------- 写回（先备份）
if ($changed) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $bak = $profilePkg + '.bak-' + $stamp
    Copy-Item -LiteralPath $profilePkg -Destination $bak -Force
    Ok ("profile package.json 已备份 → " + (Split-Path -Leaf $bak))
    $out = $j | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($profilePkg, $out, (New-Object System.Text.UTF8Encoding($false)))
    Ok 'profile package.json 已更新'
    Say ''
    Say '  ⚠️ 如果之后要还原：把那个 .bak-<时间戳> 复制回去就行。'
} else {
    Ok 'profile package.json 不用改'
}

# ---------------------------------------------------------------- ① Junction
$linkPath = Join-Path $ProfileRoot 'node_modules\dsh-pet'
$nmDir = Split-Path -Parent $linkPath
if (-not (Test-Path -LiteralPath $nmDir)) { New-Item -ItemType Directory -Force -Path $nmDir | Out-Null }

$existing = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
if ($existing) {
    $isLink = ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    $target = ''
    try { $target = @($existing.Target)[0] } catch {}
    if ($isLink -and $target -and ((Resolve-Path -LiteralPath $target -ErrorAction SilentlyContinue).ProviderPath -eq $PackageDir)) {
        Ok ("node_modules\dsh-pet 已经指向本包：" + $target)
    } elseif ($isLink) {
        Say ("  原来的联接指向：" + $target + " → 改指本包")
        # ⚠️ 别用 Remove-Item：PS 5.1 删 junction 会抛 NullReferenceException（实测）
        [System.IO.Directory]::Delete($linkPath, $false)
    } else {
        Fail ("node_modules\dsh-pet 是个**真实目录**（不是联接），我不敢动它。" +
              "`n  如果你确定要换成本包，先手动删掉：" + $linkPath)
    }
}
if (-not (Test-Path -LiteralPath $linkPath)) {
    New-Item -ItemType Junction -Path $linkPath -Target $PackageDir | Out-Null
    Ok ("建好联接：node_modules\dsh-pet → " + $PackageDir)
}

Say ''
Say '============================================================'
Say ' 装完了，但**还没生效** —— 必须重启 DSH。'
Say ''
Say ' 重启后自查（三件事）：'
Say '   ① 页面右下角出现鲸鱼小圆图标（胶囊）'
Say '   ② 点胶囊 → 桌面鲸鱼球出现'
Say '   ③ 球上菜单里点「选择会话…」选一段，然后点「截当前屏幕问会话」'
Say ''
Say ' 出问题看这两个日志：'
Say ("   " + (Join-Path $env:USERPROFILE '.dsh\pet\pet-host.log'))
Say ("   " + (Join-Path $env:USERPROFILE '.dsh\pet\pet-ball.log'))
Say '============================================================'
