#Requires -Version 5.1
<#
.SYNOPSIS
    dsh-pet 诊断脚本（只读，不改任何东西）。
.DESCRIPTION
    右下角没有胶囊 / 点了没反应时，先跑这个，把输出整段发回给作者。
    **只读取信息，不修改任何文件、不杀进程、不发请求到外网。**
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\doctor.ps1
#>
[CmdletBinding()]
param(
    [string]$PackageDir = ''
)

$ErrorActionPreference = 'Continue'

# DSH 的家目录。优先级：$env:DSH_HOME > $env:USERPROFILE\.dsh
# ⚠️ 别写死 $env:USERPROFILE\.dsh —— DSH 支持自定义家目录（实测有用户用 D:\25602\dsh\dsh-desktop-home），
#    写死的话这类用户会被装到错的地方，或者诊断脚本查错目录。
function Get-DshHome {
    if ($env:DSH_HOME -and (Test-Path -LiteralPath $env:DSH_HOME)) { return $env:DSH_HOME }
    return (Join-Path $env:USERPROFILE '.dsh')
}
if (-not $PackageDir) { $PackageDir = Split-Path -Parent $PSScriptRoot }

function SaySection($m) { Write-Host ''; Write-Host ('=== ' + $m) -ForegroundColor Cyan }
function SayKey($k, $v) { Write-Host ('  ' + $k.PadRight(22) + ' : ' + $v) }

Write-Host '============================================================'
Write-Host ' dsh-pet 诊断（只读）'
Write-Host (' 时间 ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '   机器 ' + $env:COMPUTERNAME)
Write-Host '============================================================'

# ---------------------------------------------------------------- 1 环境
SaySection '1. 环境'
SayKey 'Windows' $env:OS
SayKey 'PowerShell' ($PSVersionTable.PSVersion.ToString())
$nodeV = try { (& node -v) 2>$null } catch { '' }
SayKey 'Node' ($(if ($nodeV) { $nodeV } else { '(不在 PATH)' }))
SayKey 'DSH_HOME' ((Get-DshHome))
SayKey 'DSH_HOME 存在' (Test-Path ((Get-DshHome)))

# ---------------------------------------------------------------- 2 包本身
SaySection '2. 这个包'
$pkgFile = Join-Path $PackageDir 'package.json'
SayKey '包目录' $PackageDir
SayKey 'package.json 存在' (Test-Path $pkgFile)
if (Test-Path $pkgFile) {
    try {
        $p = Get-Content $pkgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        SayKey 'name / version' ($p.name + ' / ' + $p.version)
    } catch { K 'package.json' '解析失败' }
}
SayKey 'lib\index.js 存在' (Test-Path (Join-Path $PackageDir 'lib\index.js'))
SayKey 'assets\pet-ball.ps1 存在' (Test-Path (Join-Path $PackageDir 'assets\pet-ball.ps1'))

# ---------------------------------------------------------------- 3 profile
SaySection '3. profile（插件装到哪了）'
$profilesRoot = Join-Path (Get-DshHome) 'profiles'
if (-not (Test-Path $profilesRoot)) {
    SayKey 'profiles 目录' '不存在 → DSH 没装好？'
} else {
    Get-ChildItem $profilesRoot -Directory | ForEach-Object {
        $name = $_.Name
        if ($name -eq 'node_modules') { return }
        $pj = Join-Path $_.FullName 'package.json'
        $hasPkg = Test-Path $pj
        $hasPet = $false
        $bundleCount = 0
        if ($hasPkg) {
            try {
                $j = Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($j.dependencies -and ($j.dependencies.PSObject.Properties.Name -contains 'dsh-pet')) { $hasPet = $true }
                $b = @($j.dsh.profile.bundles)
                $bundleCount = $b.Count
                if ($b -contains 'dsh-pet') { $hasPet = $true }
            } catch {}
        }
        $link = Join-Path $_.FullName 'node_modules\dsh-pet'
        $linkDesc = '(无)'
        $it = Get-Item $link -Force -ErrorAction SilentlyContinue
        if ($it) {
            if (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                $t = ''
                try { $t = @($it.Target)[0] } catch {}
                $linkDesc = 'Junction → ' + $t
            } else {
                $linkDesc = '真实目录（不是联接）'
            }
        }
        Write-Host ('  [' + $name + ']')
        SayKey '  package.json' $hasPkg
        SayKey '  bundles 数' $bundleCount
        SayKey '  含 dsh-pet' $hasPet
        SayKey '  node_modules\dsh-pet' $linkDesc
        SayKey '  package.json 改于' ($(if ($hasPkg) { (Get-Item $pj).LastWriteTime.ToString('yyyy-MM-dd HH:mm') } else { '-' }))
    }
}

# ---------------------------------------------------------------- 4 数据目录
SaySection '4. 数据目录 ~\.dsh\pet'
$dataDir = Join-Path (Get-DshHome) 'pet'
if (-not (Test-Path $dataDir)) {
    SayKey '目录' '不存在 → **插件从没被加载过**'
} else {
    Get-ChildItem $dataDir -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 12 |
        ForEach-Object { Write-Host ('  ' + $_.LastWriteTime.ToString('MM-dd HH:mm') + '  ' + $_.Name.PadRight(18) + $_.Length + ' B') }
}

# ---------------------------------------------------------------- 5 宿主日志
SaySection '5. 宿主日志（最后 40 行）'
$hostLog = Join-Path $dataDir 'pet-host.log'
if (-not (Test-Path $hostLog)) {
    Write-Host '  ✗ 没有 pet-host.log —— 插件根本没被 DSH 加载' -ForegroundColor Yellow
} else {
    Get-Content $hostLog -Tail 40 -Encoding UTF8 | ForEach-Object { Write-Host ('  ' + $_) }
    Write-Host ''
    Write-Host '  --- 关键行 ---'
    $key = Select-String -Path $hostLog -Pattern '自检|服务就绪|index-inject|没等到|报错|失败|error|ERR' -ErrorAction SilentlyContinue
    if ($key) { $key | Select-Object -Last 6 | ForEach-Object { Write-Host ('  ★ ' + $_.Line) } }
    else { Write-Host '  （没匹配到关键行）' }
}

# ---------------------------------------------------------------- 6 球日志
SaySection '6. 桌面球日志（最后 10 行）'
$ballLog = Join-Path $dataDir 'pet-ball.log'
if (-not (Test-Path $ballLog)) {
    Write-Host '  （没有 pet-ball.log —— 球还没被启动过，或者启动时没带 -Log）'
} else {
    Get-Content $ballLog -Tail 10 -Encoding UTF8 | ForEach-Object { Write-Host ('  ' + $_) }
}

# ---------------------------------------------------------------- 7 进程
SaySection '7. 进程'
$balls = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'pet-ball\.ps1' })
SayKey '桌面球进程数' $balls.Count
$balls | ForEach-Object { Write-Host ('  pid=' + $_.ProcessId + '  ' + $_.CommandLine.Substring(0, [Math]::Min(120, $_.CommandLine.Length))) }

# ---------------------------------------------------------------- 8 DSH 版本
SaySection '8. DSH 版本'
$dshPkg = Join-Path (Get-DshHome) 'profiles\web\node_modules\@deepseek-ai\dsh\package.json'
if (Test-Path $dshPkg) {
    try { K 'dsh 版本' ((Get-Content $dshPkg -Raw -Encoding UTF8 | ConvertFrom-Json).version) } catch {}
} else {
    Write-Host '  （找不到 web profile 里的 dsh 包）'
}

Write-Host ''
Write-Host '============================================================'
Write-Host ' 把上面全部内容发回给作者（里面的会话标题/路径请自行脱敏）'
Write-Host '============================================================'
