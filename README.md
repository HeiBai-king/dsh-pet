# dsh-pet

**一键截图问 DSH** —— 让 DSH 看见并指导你操作它自己够不到的地方。

> ## ⚠️ 装之前先看这个：环境要求
>
> | 要求 | 具体 |
> |---|---|
> | **操作系统** | **必须是 Windows**。`package.json` 里写死了 `os: ["win32"]`。Linux / macOS 装不了，装了也不显示球 —— 球是 PowerShell + WPF 做的 |
> | **DSH** | 已安装并能正常开页面。**验证过的版本：`0.2.0-rc.2`（web profile）**。用的是 DSH 内部接入点，版本差太多可能完全不显示挂件 |
> | **Node** | `>= 20`（DSH 自带，正常不用管） |
> | **PowerShell** | 5.1（Windows 10/11 自带） |
> | **不需要** | npm 装包、改浏览器调试端口、任何配置文件、任何外部服务 |
>
> **不满足上面任何一条就别装。** 装完还要做两件事才生效：
> **① 重启 DSH　② 先选一段会话**（不选就点「问一下」会提示"还没选会话"）。

DSH 只能看到自己的窗口和它能读的文件。别的软件、系统弹框、装机界面、游戏、
别人电脑上那个报错窗口 —— 它看不见，也摸不着。这个插件补的就是这一段。

---

## 它到底干什么

屏幕上浮着一只鲸鱼娘（叫"桌面球"）。你卡在某个 DSH 够不到的界面上时：

```
点一下球 → 截当前屏 → 发给 DSH 里某一段会话 → 会话看一眼告诉你点什么 → 答案回到球上的气泡
```

**你自己动手，它只负责递画面和拿答案。**

不用切回 DSH、不用复制粘贴、不用费劲描述"我屏幕上现在是啥"。

> **它不能替你操作。** 点击、装软件、改设置都是你自己来。
> 这不是自动化工具，是一个"让 DSH 长出一双眼睛"的通讯器。

---

## 长什么样 / 怎么用

**① 页面右下角有个鲸鱼小圆图标（叫"胶囊"）**

- 左键点它 → 桌面球出现 / 消失
- 右键拖着它 → 挪位置（会记住）

**② 桌面球浮在所有窗口之上**

- 可以直接拖，也能缩放，位置大小都会记住
- 拖到屏幕左半边，角色会自己转过来面向屏幕内

**③ 鼠标移到角色身上 → 右上角浮出菜单按钮 → 点开，有这些：**

| 菜单项 | 干什么 |
|---|---|
| 大小 | 滑块调球的大小 |
| 翻转 | 自动翻转开关 |
| **当前会话：XXX** | 只读。告诉你消息会发给谁 —— **点之前先看这行** |
| **截当前屏幕问会话** | 截整屏，可以附一句补充说明，发给会话 |
| **发消息（不截图）** | 只发一句话过去 |
| **选择会话…** | 弹窗选会话（按工作区分组），点一下即选中并关闭 |
| 收起鲸鱼球 | 关掉球（胶囊还在，能再叫出来） |

**④ 气泡上会显示什么**

- 球刚启动时**什么都不显示**（不会把上一轮的话又翻出来）
- 点过按钮之后才开始显示
- 点「问一下」→ 先显示「正在思考…」
- 回答回来后 → 一直挂着，直到你下次提问

### 第一次用，就三步

1. 点右下角胶囊 → 球出来
2. 鼠标移到角色上 → 点菜单 → **「选择会话…」** → 展开工作区 → 点一段会话
3. 回到菜单，看「当前会话」是不是你选的那段 → 点「截当前屏幕问会话」

**第 2 步不做就点「问一下」的话，球上会提示「还没选会话」。**

---

## 安装

### 前置条件

| 要什么 | 说明 |
|---|---|
| **Windows** | 只能 Windows（球是 PowerShell + WPF 做的） |
| **DSH** | 装好能用。验证过 `0.2.0-rc.2` |
| **别的** | 没了。**不用 npm 装包、不用改浏览器设置、不用配置文件** |

### 装法一：一条命令（推荐）

```powershell
git clone https://github.com/HeiBai-king/dsh-pet.git "$env:USERPROFILE\dsh-pet"
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\dsh-pet\tools\install.ps1"
```

脚本会做三件事（和手工装完全一样）：建目录联接、往 `profile\package.json` 的
`dependencies` 里加一条、往 `dsh.profile.bundles` 里加一条。**改之前自动备份 package.json。**

没有 git 就下载 zip 解开，然后：

```powershell
powershell -ExecutionPolicy Bypass -File "<解压出来的目录>\tools\install.ps1"
```

### 装法二：DSH 没在跑时用命令行

```powershell
dsh plugin --profile web add link:"<包目录，正斜杠>"
```

（DSH 正在跑的话这条会报 EPERM —— native 模块被占用。这时用装法一。）

### 装完必须重启 DSH

模块图和注入表都是 DSH 启动时定死的，不重启不生效。

### 装完怎么自查（三件事，缺一不可）

1. **页面右下角出现鲸鱼小圆图标** ← 没有就是没装上
2. **点它，桌面球出来** ← 出不来就看日志
3. **菜单里选一段会话，点「截当前屏幕问会话」，球上出现「正在思考…」然后出回答**

日志在两个地方，出问题先看这个：

```
C:\Users\<你>\.dsh\pet\pet-host.log     宿主日志（起停、投递、自检、报错）
C:\Users\<你>\.dsh\pet\pet-ball.log     球日志（气泡上显示过的每句话）
```

---

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File "<包目录>\tools\uninstall.ps1"
```

会删联接、把 `package.json` 里那两条去掉（同样先备份），**不动你的数据目录**
（`~\.dsh\pet\`，里面有选过的会话和日志）。要一起清掉加 `-PurgeData`。

卸完也要重启 DSH。

---

## 配置（可选，不配也能用）

一个文件：`~\.dsh\pet\config.json`。**没有它就是全默认。**

| 键 | 默认 | 干什么 |
|---|---|---|
| `askSession` | 空 | 默认发给哪段会话。留空 = 先看你上次在球上选的，再退回 DSH 主 Bot 当前会话 |
| `pickWorkspaces` | `[]` | 选择框里只列这几个工作区。**留空 = 全部**。例：`["工作", "测试"]` |
| `trustedHosts` | `[]` | 只有 DSH 部署在非回环地址时才要填 |
| `ball.useRegion` | `false` | 把球窗裁成鲸鱼形状。**默认别开**，见「踩过的坑」第 2 条 |

```powershell
# 看当前生效的值
node "<包目录>\tools\write-config.mjs"
```

---

## 出问题怎么办

先看日志，再看这张表：

| 症状 | 多半是 | 怎么办 |
|---|---|---|
| **右下角没胶囊** | 插件没加载 / 没重启 DSH | 看 `pet-host.log` 有没有 `自检：接入点正常（… pushed=N …）`，N 必须 > 0；N=0 就是注入行没进表（DSH 版本不对） |
| 胶囊有，点了球不出来 | 球进程起不来 | `pet-host.log` 找 `ball-start spawned` 和随后的 `ball exit code=` |
| **点了没反应** | 请求文件没写 / 投递失败 | `pet-host.log` 找 `ask.request seen`；有但是失败就看同一行的 `msg=` |
| 提示「还没选会话」 | 没选过 | 菜单 →「选择会话…」选一段 |
| 一直「正在思考…」不换 | 会话没把回答写回来 | 看 `pet-ball.log` 有没有新的 `bubble <-`；超过 3 分钟会自动超时 |
| 选择框是空的 | 会话列表没 dump 出来 | 等 20 秒再看；还不能就看 `~\.dsh\pet\sessions.json` 的 `items` 长度 |
| 气泡全显示「未命名」 | 会话标题读不到 | `pet-host.log` 的 `sessions dump: N 段（有标题 M`，M 远小于 N 就是标题读不到（DSH 改了缓存格式） |

**拿日志去问人时记得脱敏** —— 里面有你的会话标题和目录路径。

---

## 环境与依赖

| 项 | 值 |
|---|---|
| 平台 | **只能 Windows**（`package.json` 里 `os: ["win32"]`） |
| 运行时 | 球是 **PowerShell 5.1 + WPF** 独立进程；宿主跑在 DSH 的 Node 里 |
| npm 依赖 | **零**。`dependencies` 是空的 |
| Node | `>=20`（DSH 自带） |
| DSH | 验证过 `0.2.0-rc.2`。用的是**内部接入点**，版本差太多可能完全不显示 |
| 额外配置 | 不需要 |

---

## 它明确不做的

- **不会自己截屏。** 只有你点按钮才截。
- **不会替你操作。** 见上面。
- **不读网页 DOM**、不带规则表、不需要浏览器调试端口（早期版本有，已移除）。
- **不联网。** 除了把消息投给你自己的 DSH 会话，不往外发任何东西。

---

## 已知限制

- **只能 Windows。**
- **多屏 + 不同缩放比没实测**（开发机是单屏 150%）。缩放变化有处理，但是防御式写法。
- **透明窗口的命中**：透明像素会穿透到下层。好处是球周围能点穿，
  代价是"鼠标只在画了东西的地方算进入" —— 所以菜单按钮放在角色身上，`MouseLeave` 有 0.9 秒宽限期。
- **宿主重启后要重新起球**（球是宿主拉起来的；宿主没了球还在，但点了没反应）。

---

# 给 AI 代理（帮人装的时候看这节）

> 这一节是给**代装 AI** 的。人类读者可以跳过。

## 硬约束

1. **不要自己重启 DSH。** 如果你就跑在 DSH 里，重启会杀掉你自己的会话。让用户来。
2. **每一步都要验证**，别假设成功。
3. `dsh plugin add` 在 DSH 运行时会 EPERM，用 `tools/install.ps1`。

## 步骤

```powershell
# 0. 环境
$env:OS                                    # 必须含 Windows
Test-Path "$env:USERPROFILE\.dsh"           # 必须 True
node -v                                    # 必须 >= v20
```

```powershell
# 1. 拿包
git clone https://github.com/HeiBai-king/dsh-pet.git "$env:USERPROFILE\dsh-pet"
(Get-Content "$env:USERPROFILE\dsh-pet\package.json" -Raw | ConvertFrom-Json).name   # 必须是 dsh-pet
```

```powershell
# 2. 装
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\dsh-pet\tools\install.ps1"
# 期望最后几行里有：建好联接 / profile package.json 已更新
```

```powershell
# 3. 单元自检（不需要 DSH）
node "$env:USERPROFILE\dsh-pet\tools\selfcheck.mjs"
# 期望最后一行：通过 29 项，失败 0 项
```

```
# 4. 告诉用户重启 DSH，然后停下来等他回来
```

```powershell
# 5. 重启后验证
Select-String -Path "$env:USERPROFILE\.dsh\pet\pet-host.log" -Pattern "自检：接入点正常" | Select-Object -Last 1
# 期望：自检：接入点正常（服务=就绪，注入行 pushed=N reused=M），N > 0

(Get-Content "$env:USERPROFILE\.dsh\pet\sessions.json" -Raw | ConvertFrom-Json).items.Count
# 期望：> 0
```

```
# 6. 让用户看右下角有没有鲸鱼小圆图标；有就教他：
#    点胶囊 → 菜单「选择会话…」选一段 → 「截当前屏幕问会话」
```

## 排查顺序

`pet-host.log` 的**自检行** → `ball-start spawned` / `ball exit code=` → `ask.request seen`
→ `pet-ball.log` 的 `bubble <-`。这四层依次对应：加载 / 起球 / 投递 / 回显。

---

## 兼容性（升级 DSH 后先看）

用的是 DSH 的**内部接入点**，不是稳定 API。启动 60 秒后宿主会往 `pet-host.log` 打一行自检：

| 依赖点 | 断了会怎样 |
|---|---|
| `webserver/index-inject` 表 | **桌面端完全不显示挂件**（且不报错） |
| `webServer.tapIndex` | web 形态不注入 |
| 服务名 `webServer` / `agents` / `sessionController` / `sessionQuery` | 插件起不来 / 选不了会话 |
| 客户端槽位名 `shell.overlay` | 胶囊不显示（会自动退回手写注入，仍能显示） |
| `agent.followup` + `createUserMessage` | 点了没反应，日志写"拿不到可投递的 agent" |
| 会话缓存格式 `session_projcache` | 选择框标题变成"未命名" |

设计上每处都 try/catch，缺什么降级，不崩。

---

## 几个踩过的坑（改代码前先看）

1. **别给球的 `spawn` 加 `detached: true`** —— WPF `ShowDialog()` 会立刻返回，球 200ms 内正常退出（exit 0、零报错）。
2. **`SetWindowRgn` 是多余的** —— `AllowsTransparency` 窗口本来就逐像素穿透，裁区域反而硬边+闪烁。
3. **用了 region 后光标移出区域收不到 `WM_MOUSEMOVE`** —— 球的拖动是「16ms 轮询 + `GetAsyncKeyState`」。
4. **别用 `taskkill /PID`（不带 /F）关球** —— 关不掉。球用的是停信号文件 `stop.flag`。
5. **位置持久化不能只挂关闭事件** —— 有强杀路径。球每 3 秒落盘一次。
6. **`Remove-Item` 删 Junction 在 PS 5.1 会抛 NullReferenceException** —— 用 `[System.IO.Directory]::Delete($p, $false)`。
7. **解析 `pet-shot.ps1` 的输出别写 `[^:]+`** —— 路径盘符自带冒号，会"截图成功却判失败"。
8. **含中文的 `.ps1` 必须 UTF-8 BOM**，否则 PS 5.1 按 GBK 解码 → 语法崩。
9. **PowerShell 变量名大小写不敏感** + `[string]` 参数强制转换 —— 别把控件叫 `$hint` 又给 `[string]$Hint` 赋值。
10. **`foreach` 里创建的回调用不了循环变量** —— 那是同一个变量，全指向最后一次。用 `$btn.Tag`。
11. **WPF `TextBox` 会先吃掉 Enter** —— 用 `PreviewKeyDown`。

---

## 来源说明与免责

**说清楚这插件是怎么来的：**

- **角色形象**是社区的「鲸鱼娘」，不是某个人的独占作品；仓库里的 `assets/whale.png`
  取自社区流传的素材，**非本仓库原创**。
- **外观与交互风格**（右下角小图标 + 可叫出的桌面角色 + 气泡）和 DSH 社区里流行的
  「余额挂件」那类挂件**相似** —— 这是常见形态，**风格相似不构成侵权**。
  **代码是本仓库独立写的，没有内嵌、复制或反编译对方的任何代码或资源。**
- 本项目是**非商业的个人作品**，未从分发中获利。

**如果权利人觉得哪里不妥**：请在仓库 Issues 说一声，会立刻改或下架，不需要走任何流程。

**风险自负**：插件会截取整块屏幕，并作为附件发给你**自己指定**的 DSH 会话；
落到哪台服务器、哪个模型取决于你自己的 DSH 配置。

---

## 许可

代码：MIT（见 `LICENSE`）。
`assets/whale.png` 不在 MIT 覆盖范围内 —— 那是社区素材，非本仓库原创。
