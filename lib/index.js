// ============================================================================
// dsh-pet —— 宿主半区（Node）
// ============================================================================
// 职责：① 把前端脚本注入页面（web 走 tapIndex、桌面端走 index-inject 内联行）
//       ② 对外提供 /dsh-pet/* 路由（带信任栅栏 + 方法白名单）
//       ③ 桌面球的进程管理（P1）、截图投递（P3）
//
// 本插件**不依赖任何其它插件**：不读余额挂件的文件、不碰它的路由、不复用它的注入。
// ============================================================================

import fs from 'node:fs'
import path from 'node:path'
import { spawn, execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { fileURLToPath } from 'node:url'
import { CONFIG, DSH_HOME, DATA_DIR, explainConfig } from './config.js'

const execFileAsync = promisify(execFile)

// `@deepseek-ai/dsh-llm` **惰性**加载，不用顶层静态 import。
// 理由：那个包只在 DSH 运行时里（宿主从 dsh 安装目录解析）。顶层静态 import 会让整个插件
// 在"拿不到该包"的环境里**加载即失败**（比如脱离运行时跑单测），而它只在 /ball/ask 里用到。
// 惰性化之后：拿得到就正常投递；拿不到就只有这一个接口报错，插件其余部分照常。
let _createUserMessage = null
async function getCreateUserMessage() {
  if (_createUserMessage) return _createUserMessage
  const mod = await import('@deepseek-ai/dsh-llm')
  _createUserMessage = mod.createUserMessage
  return _createUserMessage
}

// 包根：lib/index.js -> 包根。这样以 npm 包或 link: 安装都能定位到 assets/。
const PACKAGE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
// DSH_HOME / DATA_DIR 由 lib/config.js 统一给出（那边还负责读 config.json）

const PREFIX = '/dsh-pet'
const UI_SCRIPT = PREFIX + '/ui.js'

// 自述用的计数器（见 /dsh-pet/diag）。
// index-inject 是**桌面端唯一**能生效的注入通道，而且那张表是宿主启动时**一次性收集**的 ——
// 所以"这一行到底进没进表"是排障第一问，必须能直接看到。
const DIAG = {
  startedAt: Date.now(),
  indexInjectPushed: 0,
  indexInjectReused: 0,
  indexInjectLastAt: 0,
  indexInjectError: '',
  tapIndexCalls: 0,
  routes: [],
}

// 本插件需要这几个宿主服务。服务名变了 = 插件起不来，自检会直接说出来。
// ⚠️ 起进程是**异步且慢**的：球要 ~5 秒才写出 pid 文件（PowerShell + WPF 要载 5 个程序集和一张
// PNG），宿主这边陪着等最多 12.5 秒。这整个窗口里 ballPidRaw() 都是 0 —— 也就是"看起来没在跑"。
// 没有这两把锁的话，用户连点几下开关，每一次点击都会在这段窗口里**再 spawn 一个**，
// 屏幕上就冒出好几个球（2026-10-14 真机踩到：用户原话"卡了，我多点了几下开关，就出现好几个"）。
// 锁住之后，并发的第二次调用直接复用第一次的结果，不会再 spawn。
let ballStarting = null

// ⚠️ **只列真正必需的**。Cordis 的 root.inject(names, cb) 是"全部就绪才回调"——
//    多列一个名字，只要它在某个 DSH 版本里被改名/移除，整个回调就永远不跑，
//    表现为"插件装了、日志一片空、路由 404、界面上什么都没有"，而且**不报错**。
//    2026-10-31 在别人的机器上就撞到这个：日志里连"服务就绪"都没有，但上一次运行的
//    sessions dump 还在（日志是跨启动追加的），看上去像"回调跑了"，其实是假象。
//    所以这里只留 webServer（路由要它），其余全部改成"用到时再取"。
const REQUIRED_SERVICES = ['webServer']

const BALL_SCRIPT = path.join(PACKAGE_ROOT, 'assets', 'pet-ball.ps1')
const SHOT_SCRIPT = path.join(PACKAGE_ROOT, 'assets', 'pet-shot.ps1')
// 「问一下」按钮在**桌面球**上，但球是独立进程、又过不了宿主的 token 门，
// 所以球只写一个请求文件，这边监听到就投递。文件当总线，和状态文件同一套路子。
const ASK_REQ_FILE = path.join(DATA_DIR, 'ask.request')
// 球上弹框写的文字说明（可空）。读一次就删，免得下次没写还带着上一次的。
const ASK_TEXT_FILE = path.join(DATA_DIR, 'ask.text')
const BALL_PID_FILE = path.join(DATA_DIR, 'pet-ball.pid')
const STATE_FILE = path.join(DATA_DIR, 'pet-state.json')
const SHOT_FILE = path.join(DATA_DIR, '_ask.png')
// 会话选择：球里的「选择会话」用到的两个文件
const SESSIONS_FILE = path.join(DATA_DIR, 'sessions.json')   // 宿主写：会话树，球读来渲染选择框
const ASK_TARGET_FILE = path.join(DATA_DIR, 'ask.target')
// 回传文件路径由宿主算好写在这里，球读它决定去哪儿读回答（见 resolveAnswerPath）
const ANSWER_PATH_FILE = path.join(DATA_DIR, 'answer-path')    // 球写：用户选中的会话 id
const SESSIONS_WANT_FILE = path.join(DATA_DIR, 'sessions.want') // 球写：一闪而过的"我要最新列表"信号

// —— 桌面端（Electron）注入行 ——
// 桌面壳的 index.html 从安装包静态 dist 直出，tapIndex（html→html 函数）永远过不去；
// 唯一通道是 `webserver/index-inject` 推的结构化行，经 IPC 交给页面侧解释器逐行应用。
// 而解释器对两种 script 行**不对称**：
//   kind:'script'     → createElement + textContent + append，没有 await，不可能"加载失败"
//   kind:'script-src' → await loadScript(src)，失败即 reject，而那个 reject 会 reject 掉
//                       __DSH_BOOT_READY__，也就是**整个应用起不来**
// 再加上外壳把注入表在宿主启动时收集一次后缓存、没有刷新路径 ⇒ 插件在运行期被关掉时
// 表里仍留着那一行，而路由已注销 ⇒ 404。
// 所以这里统一用**内联行**：由我们自己建 <script src> 并吞掉 onerror —— 路由在就正常加载，
// 路由不在就静默失败，宿主永远不会因为我们起不来。
const DESKTOP_UI_ROW_TEXT =
  '(function(){try{var d=document.body||document.head||document.documentElement;if(!d)return;' +
  'var s=document.createElement("script");s.src="' + UI_SCRIPT + '";' +
  's.onerror=function(){};d.appendChild(s)}catch(e){}})()'

const JSON_HEADERS = {
  'Content-Type': 'application/json; charset=utf-8',
  'Cache-Control': 'no-store',
}

// —— 回环判定 ——
// 逐段校验，防 `127.0.0.1.evil.com` 这类相似域名；只认 localhost / *.localhost / 127.0.0.0/8 / ::1。
function isLoopbackHostname(hn) {
  const h = String(hn || '').toLowerCase().replace(/^\[/, '').replace(/\]$/, '')
  if (!h) return false
  if (h === 'localhost' || h.endsWith('.localhost')) return true
  if (h === '::1') return true
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h)
  if (!m) return false
  if (Number(m[1]) !== 127) return false
  return [m[2], m[3], m[4]].every((x) => Number(x) <= 255)
}

function splitList(v) {
  return String(v || '').split(',').map((s) => s.trim().toLowerCase()).filter(Boolean)
}

function readIfExists(p) {
  try { return fs.readFileSync(p) } catch (err) { return null }
}

function ensureDir(d) {
  try { fs.mkdirSync(d, { recursive: true }); return true } catch (err) { return false }
}

// 兼容旧参数 ?only=ball（现在只有球一个进程，留着不报错）
function onlyParam(url) {
  try {
    const v = new URL(String(url || ''), 'http://127.0.0.1').searchParams.get('only')
    return v === 'ball' ? v : ''
  } catch (err) { return '' }
}

// 读请求体（带上限，别让一个坏请求把内存吃掉）
function readBody(req, limit = 64 * 1024) {
  return new Promise((resolve) => {
    let size = 0
    const chunks = []
    req.on('data', (c) => {
      size += c.length
      if (size > limit) { try { req.destroy() } catch (err) {} ; resolve(''); return }
      chunks.push(c)
    })
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', () => resolve(''))
  })
}

// ============================================================================
// 桌面球进程管理
// ============================================================================
// 设计要点（对应评审 #10：旧版只看 pid 是否活着，pid 被复用时会误杀别的进程）：
//   ① 读 pid 文件后**先验进程名**（tasklist），不是 powershell/pwsh 就当作"没在跑"
//   ② 关闭走 `taskkill /PID`（**不带 /F**）—— 那是发 WM_CLOSE，能触发 pet-ball.ps1 的
//      Add_Closed，位置会被存下来、pid 文件会被清掉。
//      （P1 实测：Stop-Process -Force 硬杀不会触发 Add_Closed。）
//   ③ 宽限期过了还活着才 /F
function readPidFrom(file) {  try {
    const n = parseInt(String(fs.readFileSync(file, 'utf8')).trim(), 10)
    return Number.isFinite(n) && n > 0 ? n : 0
  } catch (err) { return 0 }
}

function writePidTo(file, pid) {
  try { ensureDir(DATA_DIR); fs.writeFileSync(file, String(pid), 'utf8') } catch (err) {}
}

function readBallPid() { return readPidFrom(BALL_PID_FILE) }

async function procImageName(pid) {
  try {
    const { stdout } = await execFileAsync('tasklist', ['/FI', 'PID eq ' + pid, '/FO', 'CSV', '/NH'], { windowsHide: true, timeout: 5000 })
    const m = /^\s*"([^"]+)"/.exec(String(stdout))
    return m ? m[1] : ''
  } catch (err) { return '' }
}

function pidAlive(pid) {
  try { process.kill(pid, 0); return true } catch (err) { return false }
}

// 只读 pid + 探活。**不查进程名**，所以快 —— 给"等它起来"的轮询用。
function ballPidRaw() {
  const pid = readBallPid()
  if (!pid || !pidAlive(pid)) return 0
  return pid
}

// 返回活着的球进程 pid；不是我们的球（进程名不对 / pid 被复用）一律返回 0。
// ⚠️ 比 ballPidRaw 慢（要起一次 tasklist），**只在准备杀进程之前用** —— 评审 #10 的防线。
async function ballPidIfOurs() {
  const pid = ballPidRaw()
  if (!pid) return 0
  const name = await procImageName(pid)
  if (!/^(powershell|pwsh)/i.test(name)) return 0
  return pid
}

// （数据端 pet-brain.cjs 已在公共版移除 —— 这个插件只做「截图 → 会话 → 回答」的管道，
//   不读页面、不带规则表、不需要 CDP。见 README 的定位说明。）

// ============================================================================
// 开关：只有桌面球这一个进程
// ============================================================================
async function petStart(only) {
  const out = {}
  out.ball = await ballStart()
  const bad = Object.values(out).find((r) => r && r.ok === false)
  // running 的语义是"现在它起来了没有"，不是"pid 文件读得到吗" —— 后者的口径在 dry-run
  // 和"刚起完还没落盘"时都会给出反的答案。
  return { ok: !bad, running: !bad, msg: bad ? bad.msg : 'started', detail: out }
}

async function petStop(only) {
  const out = {}
  out.ball = await ballStop()
  const running = !!ballPidRaw()
  return { ok: true, running, msg: 'stopped', detail: out }
}

// 自检/CI 用：不真的起进程、不真的杀进程
const DRY_RUN = process.env.DSHW_PET_DRY_RUN === '1'

// 宿主的进程日志。子进程是 detached + stdio:'ignore' 起的，出了错没人看得见 ——
// 所以 spawn 的 error/exit 一律落盘，排障时不用猜。
function hostLog(msg) {
  try {
    ensureDir(DATA_DIR)
    fs.appendFileSync(path.join(DATA_DIR, 'pet-host.log'),
      new Date().toISOString() + ' ' + msg + '\n', 'utf8')
  } catch (err) {}
}

function spawnDetached(file, args, tag) {
  // ⚠️ **绝对不要加 `detached: true`**（实测踩过，见 tools/probe-spawn.mjs）：
  //    加了之后 `powershell` 会被以 DETACHED_PROCESS 起，而 WPF 的 ShowDialog() 会**立刻返回**，
  //    球进程 200ms 内正常退出（exit code 0，不报任何错，pid 文件写了又被 Add_Closed 删掉）。
  //    对照实测：detached 的三种变体全部 exit=0；非 detached 的三种变体全部 ALIVE。
  //    不加 detached 也不会被宿主拖死 —— Windows 下 Node 的 spawn 不建 Job Object，
  //    子进程在父进程退出后照常活着；球靠 pid 文件自证存在。
  // `windowsHide: true`（CREATE_NO_WINDOW）是安全的，留着防黑框闪一下。
  const child = spawn('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', file].concat(args || []), {
    stdio: 'ignore', windowsHide: true,
  })
  child.on('error', (err) => hostLog((tag || 'spawn') + ' spawn-error: ' + ((err && err.message) || err)))
  child.on('exit', (code, sig) => hostLog((tag || 'spawn') + ' exit code=' + code + ' signal=' + sig + ' pid=' + child.pid))
  child.unref()
  hostLog((tag || 'spawn') + ' spawned pid=' + child.pid + ' file=' + file)
  return child
}

async function ballStart() {
  if (DRY_RUN) return { ok: true, running: true, msg: 'dry-run:started' }
  if (ballPidRaw()) return { ok: true, running: true, msg: 'already-running' }
  if (ballStarting) {
    hostLog('ball-start 已在进行中 → 复用这次的结果，不重复起')
    return await ballStarting
  }
  ballStarting = ballStartInner()
  try { return await ballStarting } finally { ballStarting = null }
}

async function ballStartInner() {
  if (!fs.existsSync(BALL_SCRIPT)) return { ok: false, running: false, msg: 'ball script not found: ' + BALL_SCRIPT }
  // 裁剪区域是可选项（配置中心 ball.useRegion），默认关 —— 理由见 assets/pet-ball.ps1 的 param 区
  // ⚠️ **一定带 -Log**：不带的话 pet-ball.log 一片空白，出问题只能靠用户口述"气泡上什么鬼"。
  //    2026-10-31 就因为宿主起球没带这个参数，我完全看不到球上显示了什么。
  const ballArgs = ['-Log']
  if (CONFIG.ball.useRegion) ballArgs.push('-UseRegion')
  spawnDetached(BALL_SCRIPT, ballArgs, 'ball-start')
  // 等一小会儿确认它真的活着。别给前端一个"started"然后其实没起 —— 但也不能等太久：
  // 球是 PowerShell + WPF，要载 5 个程序集和一张 466KB PNG，实测约 5 秒才写出 pid 文件。
  for (let i = 0; i < 50; i++) {
    await new Promise((r) => setTimeout(r, 250))
    const pid = ballPidRaw()
    if (pid) return { ok: true, running: true, msg: 'started', pid }
  }
  return { ok: false, running: false, msg: 'spawned but never came up（看 ' + path.join(DATA_DIR, 'pet-host.log') + '）' }
}

async function ballStop() {
  if (DRY_RUN) return { ok: true, running: false, msg: 'dry-run:stopped' }
  const pid = await ballPidIfOurs()
  if (!pid) {
    try { fs.unlinkSync(BALL_PID_FILE) } catch (err) {}
    return { ok: true, running: false, msg: 'not-running' }
  }
  // ① 优雅：落一个停信号文件，球自己的 1 秒定时器读到就 Close()。
  //    为什么不用 `taskkill /PID`（不带 /F，即 WM_CLOSE）：实测 5.35 秒内关不掉，
  //    最后只能强杀，而强杀不保证跑 Add_Closed。自己读信号最确定、跨进程语义最干净。
  const t0 = Date.now()
  const stopFlag = path.join(DATA_DIR, 'stop.flag')
  try { fs.writeFileSync(stopFlag, String(Date.now()), 'utf8') } catch (err) {}
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 200))
    if (!pidAlive(pid)) {
      hostLog('ball-stop closed gracefully pid=' + pid + ' in ' + (Date.now() - t0) + 'ms')
      try { fs.unlinkSync(stopFlag) } catch (err) {}
      try { fs.unlinkSync(BALL_PID_FILE) } catch (err) {}
      return { ok: true, running: false, msg: 'closed' }
    }
  }
  // ② 宽限期过了 → 强杀。球那边每 3 秒自动落盘位置，所以走这条路位置也不会丢。
  hostLog('ball-stop graceful close timed out after ' + (Date.now() - t0) + 'ms, force-killing pid=' + pid)
  try { await execFileAsync('taskkill', ['/F', '/PID', String(pid)], { windowsHide: true, timeout: 5000 }) } catch (err) {}
  try { fs.unlinkSync(stopFlag) } catch (err) {}
  try { fs.unlinkSync(BALL_PID_FILE) } catch (err) {}
  return { ok: true, running: false, msg: 'killed-after-timeout' }
}

// —— 状态文件（球读它来显示文字；「问一下」的结果也写回这里）——
function writeState(text, kind, ruleId) {
  try {
    ensureDir(DATA_DIR)
    const payload = JSON.stringify({ text: String(text || ''), kind: kind || 'info', ruleId: ruleId || null, at: Date.now() })
    fs.writeFileSync(STATE_FILE, payload, 'utf8')
    return true
  } catch (err) { return false }
}

// 把**会话树** dump 成 JSON 给球（球是独立 PowerShell 进程，读不到 DSH 内部服务）。
//
// 标题从哪来 —— 2026-10-31 实测走了一大圈才定下来，记在这里免得再踩：
//   ① `ctx.get('sessionQuery').listSessions()` 能用（返回 132 段），但每条只有
//      `{ header: {id, createdAt, cwd, version, ...}, live: bool, persisted: bool }`
//      —— **没有标题**。我按 `projections.values.sessionListMetadata.title` 猜的全是空。
//   ② 会话日志 `session.v4.jsonl.zstd` 是**多帧** zstd，Node 只解得出第一帧（215 字节的会话头），
//      流式解到第二帧直接 "Unknown frame descriptor"。走不通。
//   ③ **标题在投影缓存里**：`$DSH_HOME\storages\session_projcache\sessions\<uuid>.json`
//      形状是 `{ record: { identity: { cwd }, rows: { title: { val } } } }`。
//      这才是对的源，而且不需要任何宿主 API。
//
// 所以：**会话列表**从 ① 拿（它是权威的"存在哪些会话"），**标题/工作区**从 ③ 补。
const PROJCACHE_DIR = path.join(DSH_HOME, 'storages', 'session_projcache', 'sessions')
const projCacheMemo = new Map()   // file -> { mtimeMs, title, cwd }，按 mtime 增量读，别每 20 秒重解 5MB

function readProjCache() {
  const out = new Map()   // sessionId -> { title, cwd }
  let files = []
  try { files = fs.readdirSync(PROJCACHE_DIR) } catch (err) { return out }
  for (const f of files) {
    if (!f.endsWith('.json')) continue
    const full = path.join(PROJCACHE_DIR, f)
    let st
    try { st = fs.statSync(full) } catch (err) { continue }
    const memo = projCacheMemo.get(f)
    if (memo && memo.mtimeMs === st.mtimeMs) {
      // ⚠️⚠️ 这条分支**必须跟下面 set 的字段名一致**。
      //   2026-10-31 我把键从 `id` 改名成 `bare`，漏改这里 —— 于是缓存命中的条目全被塞进
      //   `undefined` 键，第二轮 dump 之后**所有标题消失**，变成清一色"未命名"。
      //   教训：改名的时候，同一个结构的所有读写点都要一起改。
      if (memo.title || memo.cwd) {
        out.set(memo.bare, {
          title: memo.title, cwd: memo.cwd,
          lastAt: memo.lastAt || 0, blank: memo.blank === true, turns: memo.turns || 0,
        })
      }
      continue
    }
    let title = '', cwd = '', lastAt = 0, blank = false, turns = 0
    try {
      const j = JSON.parse(fs.readFileSync(full, 'utf8'))
      const rec = (j && j.record) || {}
      title = String((rec.rows && rec.rows.title && rec.rows.title.val) || '').trim()
      cwd = String((rec.identity && rec.identity.cwd) || '')
      // lastPromptAt = 最后一次提问的时间，用来排序（比 header.createdAt 有意义）
      const slm = rec.rows && rec.rows.sessionListMetadata && rec.rows.sessionListMetadata.val
      lastAt = (slm && typeof slm.lastPromptAt === 'number') ? slm.lastPromptAt : 0
      // ⚠️ blank = **空会话**（建了但一次没用过：turns=0、titleInput.count=0、title.val=null）。
      //    2026-10-31：选择框里 58 段有 39 段是这种，用户问"怎么这么多未命名，子会话吗"。
      //    它们不是子会话（实测 0 个是 childId），就是**空壳**。侧边栏不显示，这里也不能显示。
      blank = !!(slm && slm.blank)
      const st = rec.rows && rec.rows.sessionStats && rec.rows.sessionStats.val
      turns = (st && typeof st.turns === 'number') ? st.turns : 0
    } catch (err) { /* 坏文件跳过 */ }
    // ⚠️⚠️ **不能**用"文件名推出完整 id"去配 —— 两边前缀都不统一：
    //   · 缓存文件名：`session-xxx.json`（95 个）和裸 `xxx.json`（38 个）混着
    //   · listSessions() 给的 sessionId：`session-xxx` 和**裸 `xxx`** 也混着（实测两种都有）
    //   2026-10-31 就因为这里对不上，58 段里 37 段标题是空的，用户问"怎么这么多未命名"。
    //   解法：两边都**去掉 session- 前缀，只用裸 uuid** 当键。
    const stem = f.replace(/\.json$/, '')
    const bare = stem.replace(/^session-/, '')
    projCacheMemo.set(f, { mtimeMs: st.mtimeMs, title, cwd, bare, lastAt, blank, turns })
    if (title || cwd) out.set(bare, { title, cwd, lastAt, blank, turns })
  }
  return out
}

// **工作区**的真名在 `$DSH_HOME\storages\workspace.json`：
//   { tables: { workspaces: { <id>: { path, title, sessionIds: [...] } } },
//     global: { archivedSessionIds: [...] } }
// 侧边栏那四个名字（DS Bot / deep seek / QQ 聊天 / QQ 黑话学习）就是这里的 `title`。
// ⚠️ 别拿 cwd 的最后一段当工作区名 —— `qq-bridge\state\agents` 会显示成 "agents"，
//    而侧边栏叫它 "QQ 聊天"。用户一开始就是拿这个怼的。
const WORKSPACE_FILE = path.join(DSH_HOME, 'storages', 'workspace.json')

function normPath(p) {
  return String(p || '').replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase()
}

function readWorkspaces() {
  const byPath = new Map()     // 归一化 path -> title
  const bySession = new Map()  // sessionId -> title
  const archived = new Set()
  try {
    const j = JSON.parse(fs.readFileSync(WORKSPACE_FILE, 'utf8'))
    const ws = (j && j.tables && j.tables.workspaces) || {}
    for (const w of Object.values(ws)) {
      if (!w) continue
      const title = String(w.title || '').trim() || String(w.path || '')
      if (w.path) byPath.set(normPath(w.path), title)
      for (const sid of (Array.isArray(w.sessionIds) ? w.sessionIds : [])) bySession.set(String(sid), title)
    }
    const arc = (j && j.global && j.global.archivedSessionIds) || []
    for (const sid of (Array.isArray(arc) ? arc : [])) archived.add(String(sid))
  } catch (err) { /* 没这个文件就退化成按 cwd 分组 */ }
  return { byPath, bySession, archived }
}

// 上一次 dump 的"指纹" —— 只在变化时记日志，免得每 20 秒刷一行把日志淹了
let lastDumpSig = ''

async function dumpSessions(ctx) {
  try {
    const q = (ctx && ctx.get && ctx.get('sessionQuery')) || (ctx && ctx.sessionQuery)
    if (!q || typeof q.listSessions !== 'function') {
      hostLog('sessions dump: 这个 DSH 版本没有 sessionQuery.listSessions —— 选择会话功能不可用')
      fs.writeFileSync(SESSIONS_FILE, JSON.stringify({ at: Date.now(), items: [], err: 'no-api' }), 'utf8')
      return
    }
    const recs = await q.listSessions()
    const list = Array.isArray(recs) ? recs : []
    const meta = readProjCache()
    const wsr = readWorkspaces()
    // 只显示这几个工作区（配置 pickWorkspaces，空 = 全都显示）
    const only = (Array.isArray(CONFIG.pickWorkspaces) ? CONFIG.pickWorkspaces : []).map((s) => String(s).trim()).filter(Boolean)

    let skippedArchived = 0, skippedWs = 0, skippedSub = 0, skippedBlank = 0
    const items = []
    for (const r of list) {
      if (!r) continue
      const h = (r && r.header) || {}
      const id = String(h.id || r.sessionId || r.id || '')
      if (!id) continue
      if (wsr.archived.has(id)) { skippedArchived++; continue }   // 归档的不显示
      // ⚠️ **子会话（子 agent 派出的一段）不显示**。
      //   2026-10-31：选择框里 58 段有 39 段没标题，全是这种 —— 用户问"怎么这么多未命名，子会话吗"。
      //   会话头里 delegationDepth > 0 或者带 parentSession 的就是子会话，它们不是给人挑的，
      //   挑中了也没意义（主人会话才是消息该进去的地方）。
      const depth = (typeof h.delegationDepth === 'number') ? h.delegationDepth : 0
      if (depth > 0 || h.parentSession) { skippedSub++; continue }
      // 用裸 uuid 查（见 readProjCache 末尾那段注释）
      const m = meta.get(String(id).replace(/^session-/, '')) || {}
      // 空会话（一次没用过）不显示 —— 见 readProjCache 里 blank 那段注释
      if (m.blank === true) { skippedBlank++; continue }
      const cwd = String(h.cwd || m.cwd || '')
      // 工作区名：先按"这个会话被归到哪个工作区"，再按路径匹配
      const wsTitle = wsr.bySession.get(id) || wsr.byPath.get(normPath(cwd)) || ''
      if (only.length && !only.includes(wsTitle)) { skippedWs++; continue }
      items.push({
        id,
        cwd,
        ws: wsTitle || '未分组',
        title: String(m.title || '').trim(),
        depth,
        updatedAt: (m.lastAt || (typeof h.createdAt === 'number' ? h.createdAt : 0)),
      })
    }
    items.sort((a, b) => b.updatedAt - a.updatedAt)
    const withTitle = items.filter((i) => i.title).length
    fs.writeFileSync(SESSIONS_FILE, JSON.stringify({ at: Date.now(), items }), 'utf8')
    // ⚠️ **别每次都记**。这个函数每 20 秒跑一次，无条件写日志的话 pet-host.log 会被刷爆 ——
    //    实测跑一天就是 314KB，排障时"最后 40 行"全是同一句话，等于没有日志。
    //    只在**数字变了**的时候记一行。
    const sig = items.length + '/' + withTitle + '/' + skippedArchived + '/' + skippedWs + '/' + skippedSub + '/' + skippedBlank
    if (sig !== lastDumpSig) {
      lastDumpSig = sig
      hostLog('sessions dump: ' + items.length + ' 段（有标题 ' + withTitle
        + '，跳过归档 ' + skippedArchived + '、其他工作区 ' + skippedWs + '、子会话 ' + skippedSub + '、空会话 ' + skippedBlank + '）')
    }
  } catch (err) { hostLog('sessions dump 失败: ' + ((err && err.message) || err)) }
}

// 回传文件该落在哪 —— **按目标会话的 cwd 算**。
// 为什么不能写死：agent 被沙箱限死在它自己的 cwd，只能往那儿写；
// 而不同用户、不同会话的 cwd 完全不一样。以前这个路径写死在球脚本里，换个环境就收不到回答。
function resolveAnswerPath(sessionId) {
  try {
    const dump = JSON.parse(fs.readFileSync(SESSIONS_FILE, 'utf8'))
    const hit = (Array.isArray(dump.items) ? dump.items : []).find((it) => it && it.id === sessionId)
    if (hit && hit.cwd) return path.join(hit.cwd, 'pet-answer.txt')
  } catch (err) {}
  // 拿不到 cwd（会话没 dump 过 / 没 cwd）→ 退回插件自己的数据目录。
  // 这种情况下 agent 可能写不进去（沙箱限在它的 cwd），**回答就到不了气泡** ——
  // 但消息本身照样投递，用户只是看不到气泡回话。别假装成功。
  return path.join(DATA_DIR, 'pet-answer.txt')
}

function resolveAskSession() {
  // ⚠️ 优先级：**球上选的** > 配置里的 askSession > bot/state.json 的主 Bot
  //    球上选的是用户当前的意图，配置里那个只是默认值。
  //
  // ⚠️⚠️ 但 ask.target **必须校验它还活着**。
  //   2026-10-31 实测：选择框那次 bug 让用户点到了 QQ 黑话学习的一段，
  //   写进 ask.target 之后那段被归档/过滤掉了 —— 而这里无条件优先返回它，
  //   于是**所有消息都会投到一段已经不在列表里的会话**，用户只会看到"发出去没反应"。
  //   所以拿当前 dump 对一下：不在列表里就当没选过，退到下一级。
  try {
    const picked = String(fs.readFileSync(ASK_TARGET_FILE, 'utf8')).trim()
    if (picked) {
      let stillThere = true
      try {
        const dump = JSON.parse(fs.readFileSync(SESSIONS_FILE, 'utf8'))
        const items = Array.isArray(dump.items) ? dump.items : []
        // dump 是空的（宿主刚起、还没 dump 过）就先信它，别把用户的选择白扔了
        if (items.length > 0) stillThere = items.some((it) => it && it.id === picked)
      } catch (err) { /* 没 dump：信它 */ }
      if (stillThere) return { id: picked, how: 'ask.target' }
      hostLog('ask.target 指向的会话已不在列表里（归档或删了）→ 忽略它: ' + picked)
    }
  } catch (err) {}
  const explicit = String(CONFIG.askSession || '').trim()
  if (explicit) return { id: explicit, how: 'env' }
  try {
    const st = JSON.parse(fs.readFileSync(path.join(DSH_HOME, 'bot', 'state.json'), 'utf8'))
    const raw = st.bots
    const entries = Array.isArray(raw)
      ? raw.map((b) => [b && b.id, b])
      : Object.entries(raw && typeof raw === 'object' ? raw : {})
    const mains = Array.isArray(st.mainBotIds) ? st.mainBotIds : []
    // bots[].sessionId 才是它**现在真正活着**的那段（分段/压缩后会换）
    const hit = entries.find(([key, b]) => b && (mains.includes(key) || mains.includes(b.id) || /chief|首席/i.test(String(b.name || ''))))
    const id = hit && (hit[1].sessionId || hit[1].id || hit[0])
    if (typeof id === 'string' && id) return { id, how: 'bot/state.json' }
  } catch (err) { /* 没这个文件 / 解析失败 */ }
  return { id: '', how: 'none' }
}

// 截屏 → 投给目标会话。手动（点「问一下」）和自动（降级链）共用这一份。
// 返回结果对象，不抛；失败原因写进状态文件，让球和胶囊都能显示。
//
// ⚠️ 必须互斥：三条路（球的请求文件 / 降级链 / 手动路由）可能同时进来，
//    而截屏是"两个 PowerShell 进程写同一个 PNG" —— 实测会报 GDI+ 一般性错误。
// 互斥锁按**模式**分开：带截图和不带截图是两件事，撞在一起不该互相复用结果。
const askInFlight = { shot: null, noshot: null }
async function doAsk(ctx, reason, opts) {
  const key = (opts && opts.noShot) ? 'noshot' : 'shot'
  if (askInFlight[key]) { hostLog('doAsk skipped (already in flight: ' + key + ')'); return await askInFlight[key] }
  askInFlight[key] = doAskInner(ctx, reason, opts)
  try { return await askInFlight[key] } finally { askInFlight[key] = null }
}

async function doAskInner(ctx, reason, opts) {
  const noShot = !!(opts && opts.noShot)
  const out = { ok: false, msg: '', shot: '', session: '', how: '', reason: reason || 'manual' }
  const tag = reason === 'auto' ? '自动' : ''
  try {
    // ① 截屏（pet-shot.ps1 会打 OK:/ERROR: 并把失败变成退出码 2）
    //    noShot 模式（球上的「发消息」）整段跳过 —— 用户就是要发纯文字，不要截图。
    if (noShot) { out.skippedShot = true } else {
    if (!fs.existsSync(SHOT_SCRIPT)) throw new Error('shot script not found: ' + SHOT_SCRIPT)
    ensureDir(DATA_DIR)
    try { fs.unlinkSync(SHOT_FILE) } catch (err) {}
    let shotOut = '', shotCode = 0
    try {
      const r = await execFileAsync('powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SHOT_SCRIPT, '-Out', SHOT_FILE],
        { windowsHide: true, timeout: 30000 })
      shotOut = String(r.stdout || '')
    } catch (e) {
      shotCode = (e && e.code) || 1
      shotOut = String((e && (e.stdout || e.message)) || e)
    }
    // ⚠️ 不能写 /OK:([^:]+):(\d+)/ —— 路径里的盘符自带冒号（OK:D:\...\a.png:12345:2160x1440），
    //    那个 [^:] 会匹配不上，结果是"截图明明成功却被判失败"。
    //    从**尾部**解析： (...):bytes:WxH
    const okLine = /OK:([\s\S]+):(\d+):(\d+)x(\d+)\s*$/.exec(String(shotOut).trim())
    if (!okLine || !fs.existsSync(SHOT_FILE)) {
      const errLine = /ERROR:([\s\S]*)$/.exec(String(shotOut))
      throw new Error('screenshot failed (exit ' + shotCode + '): ' + (errLine ? errLine[1].trim() : String(shotOut).slice(0, 200)))
    }
    out.shot = SHOT_FILE
    }  // ← noShot 时整段截屏都跳过

    // ② 找目标会话（不写死兜底 id —— 评审 #13）
    const target = resolveAskSession()
    out.session = target.id
    out.how = target.how
    if (!target.id) {
      // 给**普通用户**看的错误：告诉他去点哪儿，不是让他配环境变量。
      throw new Error('还没选会话 —— 点球上的菜单 →「选择会话…」选一段再发')
    }
    // ⚠️ 取 agent 有三层坑，都踩过（2026-10-14 ~ 10-16）：
    //   ① 判断"拿到了没有"必须看**能不能投递**，不能只看非空。
    //      `ctx.agents.get(id)` 会返回一个非空但没 `.followup` 的东西（会话没解析好时的占位），
    //      旧写法 `if (!agent)` 不成立 → 跳过回退 → 在 `agent.followup(...)` 上炸
    //      "agent.followup is not a function"。实测间歇性（10-14 11:18 失败、22 秒后 11:19 成功）。
    //   ② **`resolveAgent` 返回的不是 agent，是包了一层的 `{ agent }` 或 `{ error }`**
    //      （见 dsh-api-session-controller/lib/types/agent.js 的 resolve()：`return published ?? { agent }`）。
    //      直接拿返回值当 agent 用 → 同样没有 `.followup` → 变成"拿不到可投递的 agent"。
    //   ③ 所以这里**三种形状都拆**：agent 本身 / { agent } / { error }。
    //
    //    Agent 的接口（dsh-session-reference 的声明）：
    //      followup(message): void   ← 同步方法，投一条消息进去
    //    userMessage 必须是 `{ content: [块数组], source: {...} }`，见下面 ③ 那段注释。
    const describe = (v) => {
      if (v === null) return 'null'
      if (v === undefined) return 'undefined'
      if (typeof v !== 'object') return typeof v
      const keys = Object.keys(v).slice(0, 8).join(',')
      const fns = ['followup', 'steer', 'inject', 'send'].filter((k) => typeof v[k] === 'function').join('/')
      return '{' + keys + '} fn=[' + fns + ']'
    }
    let agent = null
    let why = 'nothing'
    try {
      const agentsSvc = (ctx.get && ctx.get('agents')) || ctx.agents
      const a = agentsSvc && agentsSvc.get(target.id)
      if (a && typeof a.followup === 'function') { agent = a; why = 'agents.get' }
      else { hostLog('ask diag: agents.get 不是可投递的 agent → ' + describe(a)) }
    } catch (err) { hostLog('ask diag: agents.get threw ' + ((err && err.message) || err)) }
    if (!agent) {
      try {
        const sc = ctx.get('sessionController') || ctx.sessionController
        if (!sc || typeof sc.resolveAgent !== 'function') {
          hostLog('ask diag: 没有 sessionController.resolveAgent')
        } else {
          const r = await sc.resolveAgent(target.id)
          if (r && typeof r.followup === 'function') { agent = r; why = 'resolveAgent(直接)' }
          else if (r && r.agent && typeof r.agent.followup === 'function') { agent = r.agent; why = 'resolveAgent(.agent)' }
          else {
            hostLog('ask diag: resolveAgent 返回 → ' + describe(r)
              + (r && r.error ? ' error=' + ((r.error && r.error.message) || String(r.error)) : ''))
          }
        }
      } catch (err) { hostLog('ask diag: resolveAgent threw ' + ((err && err.message) || err)) }
    }
    if (!agent || typeof agent.followup !== 'function') {
      throw new Error('目标会话拿不到可投递的 agent: ' + target.id + '（看 pet-host.log 里的 ask diag 那几行）')
    }
    hostLog('ask diag: 拿到 agent（来源 ' + why + '）→ ' + describe(agent))

    // ③ 投递。两个坑都会让**整份会话日志拒载**：
    //    ⚠️ 注入消息必须带 source；
    //    ⚠️ content 必须是**块数组**，传字符串会写出一条 v4 校验不过的 user/message
    //       （2026-10-14 实测：seq 38 "message with invalid content"，会话直接打不开）。
    let note = ''
    try { note = fs.readFileSync(ASK_TEXT_FILE, 'utf8').trim() } catch (err) {}
    try { fs.unlinkSync(ASK_TEXT_FILE) } catch (err) {}

    // —— 回传文件路径：**按目标会话的 cwd 算，不能写死** ——
    // agent 被沙箱限死在它自己的 cwd，只能往那儿写。
    // 以前这里默认落在 `%USERPROFILE%\.dsh\bot\workspace`（本机 DS Bot 那目录），
    // 换个用户、换段会话就收不到回答 —— 这是要发给所有人的插件，必须自动推。
    const answerPath = resolveAnswerPath(target.id)
    // 旧回答先清掉，免得这一轮还没回，球上挂着上一轮的
    try { fs.unlinkSync(answerPath) } catch (err) {}
    // 告诉球"这一轮的回答会落在哪"，它好去读（见 assets/pet-ball.ps1 的 $AnswerFile）
    try { fs.writeFileSync(ANSWER_PATH_FILE, answerPath, 'utf8') } catch (err) {}
    // 回传提示由**宿主**加，不靠球 —— 球不知道目标会话的 cwd
    const answerHint = '\n[悬浮球回传] 回答完，把指导原文（不要前言、不要解释）覆盖写进：' + answerPath

    const createUserMessage = await getCreateUserMessage()
    await agent.followup(createUserMessage({
      content: [{
        type: 'text',
        // 两种模式的消息正文完全不同：
        //   带截图  → 报上截图路径，明确要求 read_image
        //   纯文字  → 就是用户那句话，不提截图（noShot 时 SHOT_FILE 可能还是上一张的旧图，绝不能提）
        text: (noShot
          ? '[桌宠] 用户从悬浮球直接发来一条消息（没有截图）：\n' + (note || '（空消息）')
          : '[桌宠] 用户点了「问一下」。'
            + (note ? '\n用户补的说明：' + note : '')
            + '\n这是屏幕截图文件：' + SHOT_FILE
            + '\n请用 read_image 读它，然后给一句能照做的操作指导。') + answerHint,
      }],
      source: { kind: 'dsh-pet', form: 'ask' },
    }))
    out.ok = true
    out.msg = 'sent'
    writeState(noShot ? '消息已发出，等回复…' : '已截屏发给会话，等回复…', 'ask-sent')
  } catch (err) {
    out.msg = String((err && err.message) || err)
    writeState('问一下失败：' + out.msg, 'ask-failed')
  }
  return out
}

// ============================================================================
// （原来的「降级链：规则判不出来就自动截屏问一次」已随数据端一起移除 ——
//   公共版里没有"自动"这个模式：截图永远由你点那个按钮触发，不会自己截你的屏。）

function readState() {
  try { return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')) } catch (err) { return null }
}

// 桌面球上的「问一下」按钮 → 球写 ask.request → 这里响应
// ⚠️ 用"**读走就删**"而不是比 mtime：fs.watch 在 Windows 上对一次写入常常发多个事件，
//    而同一文件的 mtime 在两次 stat 之间会变（写入分两步），mtime 去重挡不住。
async function handleAskRequest(ctx) {
  let seen
  try { seen = fs.statSync(ASK_REQ_FILE) } catch (err) { return }   // 文件不在 = 没有请求
  // 球写进来的**内容就是模式**（以前只当时间戳用，现在拿来区分两种按钮）：
  //   'shot'   球上的「截屏问一下」（也兼容老版本球写的纯时间戳 → 默认走这条）
  //   'noshot' 球上的「发消息」= 只要那段文字，不截图
  let mode = ''
  try { mode = fs.readFileSync(ASK_REQ_FILE, 'utf8').trim() } catch (err) {}
  try { fs.unlinkSync(ASK_REQ_FILE) } catch (err) {}                // 先删，防重复
  const noShot = mode === 'noshot'
  hostLog('ask.request seen (mode=' + (mode || '(空)') + ' mtime=' + seen.mtimeMs + ') -> doAsk(manual, noShot=' + noShot + ')')
  const r = await doAsk(ctx, 'manual', { noShot })
  hostLog('ask.request result ok=' + r.ok + ' msg=' + r.msg)
}



export default {
  name: 'dsh-pet',

  // ⚠️ 这里**有意不写对象级 `inject`**。
  //   对象级 inject 会把整个 apply() 推迟到服务就绪之后，而桌面端的注入表是**宿主启动时
  //   一次性收集**的（collectIndexInjections() → IPC → 渲染层）——订阅一旦晚于那次收集，
  //   这一行就永远进不了表 = 桌面端挂件完全不出现（而且不报错，只是静静没有）。
  //   所以 apply() 立刻执行、**第一件事就是注册注入行**（它不依赖任何服务），
  //   其余逻辑放进 root.inject([...], cb) 局部等待。
  apply(root) {
    const rowDisposers = []
    root.effect(() => () => {
      for (const d of rowDisposers) { try { d() } catch (err) {} }
    })

    // ① 结构化注入行：桌面端唯一能生效的通道（web 形态另有 tapIndex，两条并存、各自去重）
    rowDisposers.push(root.on('webserver/index-inject', (table) => {
      try {
        if (!Array.isArray(table)) return
        // 只检查**我们自己**那一行；不要去检查别的插件的行，也不要因为别人的行而提前 return。
        for (const row of table) {
          if (!row) continue
          if (row.kind === 'script' && typeof row.text === 'string'
            && row.text.indexOf(UI_SCRIPT) >= 0) { DIAG.indexInjectReused++; return }
        }
        table.push({ kind: 'script', placement: 'body', text: DESKTOP_UI_ROW_TEXT })
        DIAG.indexInjectPushed++
        DIAG.indexInjectLastAt = Date.now()
      } catch (err) { DIAG.indexInjectError = String((err && err.message) || err) }
    }))

    // ② 其余逻辑：等 webServer 就绪
    //
    //    ⚠️ 升级 DSH 后如果挂件没反应，**先看这条自检日志**（$DSH_HOME\pet\pet-host.log）。
    //    本插件依赖下面这几个「内部接入点」，DSH 换版本时它们最可能变：
    //      · webserver/index-inject 这张表 → 桌面端唯一的注入通道
    //      · webServer.tapIndex          → web 形态的注入通道
    //      · 服务名 webServer / agents / sessionController
    //      · 客户端半区的槽位名 shell.overlay
    //    哪个点了没动，日志会直接说出来，不用猜。
    let servicesReady = false

    // —— 自动把桌面球拉起来（**不等任何服务**）——
    // ⚠️ 球是这个插件的核心，所有功能都在球上（截图 / 发消息 / 选会话 / 菜单）。
    //    它是个独立 PowerShell 进程，**完全不依赖 webServer / 页面 / 注入**。
    //    所以它必须在 apply() 里就拉起，不能放在"等服务就绪"的回调里 ——
    //    那个回调只要有一个服务名对不上就永远不跑，球也就永远不出来（2026-10-31 实测）。
    //    不想要就写 {"ball":{"autoStart":false}}。
    if (CONFIG.ball.autoStart) {
      const autoStartTimer = setTimeout(() => {
        try {
          if (ballPidRaw()) { hostLog('自动起球：已经在跑，跳过'); return }
          hostLog('自动起球：直接把球拉起来（不依赖任何服务）')
          ballStart().then((r) => hostLog('自动起球结果 ok=' + r.ok + ' msg=' + r.msg))
            .catch((err) => hostLog('自动起球失败: ' + ((err && err.message) || err)))
        } catch (err) { hostLog('自动起球异常: ' + ((err && err.message) || err)) }
      }, 3000)
      if (autoStartTimer && typeof autoStartTimer.unref === 'function') autoStartTimer.unref()
      try { root.effect(() => () => clearTimeout(autoStartTimer)) } catch (err) {}
    }

    // —— 桌面球上的「问一下」：文件当总线，不依赖任何服务 ——
    // 球是独立 PowerShell 进程、过不了宿主的 token 门，所以它只往 $DataDir 写一个 ask.request。
    // 这里是**唯一**的投递入口，必须在 apply() 层就跑起来 —— 放进注入回调的话，
    // 一旦 webServer 对不上，球能出来但点了「问一下」永远没反应。
    try {
      ensureDir(DATA_DIR)
      const watcher = fs.watch(DATA_DIR, (evt, filename) => {
        const fn = String(filename)
        // 球打开「选择会话」时落一下这个信号 → 立刻 dump 一份最新的给它（不用等 20 秒周期）
        if (fn === 'sessions.want') {
          try { fs.unlinkSync(SESSIONS_WANT_FILE) } catch (err) {}
          dumpSessions(root).catch(() => {})
          return
        }
        if (fn !== 'ask.request') return
        handleAskRequest(root).catch((err) => hostLog('ask.request error: ' + ((err && err.message) || err)))
      })
      try { root.effect(() => () => { try { watcher.close() } catch (err) {} }) } catch (err) {}
    } catch (err) {
      hostLog('ask.request 监听失败（会退化成 20 秒轮询）: ' + ((err && err.message) || err))
    }

    // —— 会话列表：也不依赖 webServer ——
    // 球打开「选择会话」时要读 sessions.json；球能起来，这份列表就得跟着刷新。
    // 原来这个循环写在注入回调里，回调不跑 = 选择框永远空。
    if (CONFIG.ball.autoStart || true) {
      const sessLoop = setInterval(() => { dumpSessions(root).catch(() => {}) }, 20000)
      if (sessLoop && typeof sessLoop.unref === 'function') sessLoop.unref()
      try { root.effect(() => () => clearInterval(sessLoop)) } catch (err) {}
      const firstDump = setTimeout(() => { dumpSessions(root).catch(() => {}) }, 500)
      if (firstDump && typeof firstDump.unref === 'function') firstDump.unref()
      try { root.effect(() => () => clearTimeout(firstDump)) } catch (err) {}
    }

    // —— 服务清单探针 ——
    // 如果 8 秒后 root.inject 还没回调，说明我们要的服务名和这个 DSH 构建对不上。
    // 光说"没就绪"没法查，所以把**候选名字逐个探一遍**打出来，一眼就知道该叫什么。
    const SERVICE_CANDIDATES = [
      'webServer', 'webserver', 'web', 'httpServer', 'server',
      'agents', 'agent', 'sessionController', 'sessionQuery', 'sessions',
      'connection', 'loader', 'registry',
    ]
    const probeTimer = setTimeout(() => {
      if (servicesReady) return
      try {
        const found = []
        for (const name of SERVICE_CANDIDATES) {
          let v = null
          try { v = ctx.get ? ctx.get(name) : null } catch (err) {}
          if (v) found.push(name)
        }
        hostLog('⚠️ 8 秒内 webServer 没就绪 —— 这个 DSH 构建里可能叫别的名字')
        hostLog('   探到的服务：' + (found.length ? found.join(', ') : '(一个都没探到)'))
        hostLog('   我们需要：webServer（注册路由用）。请把这两行发给作者。')
      } catch (err) { hostLog('服务探针本身出错: ' + ((err && err.message) || err)) }
    }, 8000)
    if (probeTimer && typeof probeTimer.unref === 'function') probeTimer.unref()
    try { root.effect(() => () => clearTimeout(probeTimer)) } catch (err) {}
    const t0 = Date.now()
    const selfCheckTimer = setTimeout(() => {
      try {
        const problems = []
        if (!servicesReady) {
          problems.push('服务 ' + REQUIRED_SERVICES.join('/') + ' 一直没就绪 —— 服务名可能改了')
        }
        if (DIAG.indexInjectPushed + DIAG.indexInjectReused === 0) {
          // ⚠️ 这条**不等于**"通道改名了"。注入表是**每次页面渲染**时发一次事件，
          //    所以 0 只说明"插件加载后的这 60 秒里，页面没渲染过"。
          //    2026-10-31 实测：有个用户看到这句就以为是"桌面端不支持 web 形态的注入"，
          //    结论完全错了 —— 同一台机器上别人（同样是桌面版）pushed=2 正常。
          //    所以文案要说清楚"先按 Ctrl+R 重载页面再判断"。
          problems.push('自检：这 60 秒内没见到页面渲染（注入表是每次渲染才发的）'
            + ' —— 如果右下角没有胶囊，先在 DSH 窗口按 Ctrl+R 重载一次，再看这条')
        }
        if (DIAG.tapIndexCalls === 0) {
          // web 形态才有 tapIndex；桌面端一辈子也等不到，所以只提示、不算错
          hostLog('自检：tapIndex 还没被调用（web 形态才有；桌面端等不到是正常的）')
        }
        if (problems.length) {
          hostLog('⚠️ 自检发现问题：' + problems.join('；'))
          hostLog('   这一般意味着 DSH 换版本后上述接入点变了。README 的「兼容性」一节列了全部依赖点。')
        } else {
          hostLog('自检：接入点正常（服务=就绪，注入行 pushed=' + DIAG.indexInjectPushed
            + ' reused=' + DIAG.indexInjectReused + '）')
        }
      } catch (err) { hostLog('自检本身出错了: ' + ((err && err.message) || err)) }
    }, 60000)
    try { root.effect(() => () => clearTimeout(selfCheckTimer)) } catch (err) {}

    const setupAll = (ctx) => {
      servicesReady = true
      hostLog('服务就绪（等了 ' + (Date.now() - t0) + 'ms）：' + REQUIRED_SERVICES.join('/'))

      const disposers = []
      const keep = (d) => { disposers.push(d); return d }

      // —— 信任栅栏（对齐余额挂件那套三层设计，但这里是独立实现）——
      //   ① 插件自校验：Host 必须是回环权威或显式声明；Sec-Fetch-Site: cross-site 一律拒；
      //      带 Origin 时必须与 Host 同源。
      //   ② 宿主栅栏可用 → 委托它，返回码照用；它抛异常按拒绝处理（fail-closed）。
      //   ③ **每条路由显式声明允许的方法** —— 写方法额外要求来自本机回环。
      //      这一条是必须的：只靠"写方法必须回环"挡不住用 GET 触发的有副作用接口。
      const TRUSTED_AUTHORITIES = splitList(CONFIG.trustedHosts.join(','))
      const ADMIN_AUTHORITIES = splitList(process.env.DSHW_PET_ADMIN_HOSTS)
      const WRITE_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE'])

      function connectionFence() {
        try {
          const conn = ctx.get('connection') || ctx.connection
          return conn && typeof conn.requestRejection === 'function' ? conn : null
        } catch (err) { return null }
      }
      const haveFence = !!connectionFence()
      if (!haveFence) {
        try {
          console.warn('[dsh-pet] 宿主信任栅栏不可用（connection.requestRejection 缺失）：'
            + '已启用插件自带的回环/同源校验 + 方法白名单。若本机 DSH 部署在非回环地址，'
            + '请用环境变量 DSHW_PET_TRUSTED_HOSTS 声明允许的 Host（逗号分隔，可带端口）。')
        } catch (err) {}
      }

      function deny(res, code) {
        try { res.statusCode = code || 403; res.end() } catch (err) {}
        return true
      }

      // 通过 → false；被拒（并已回应）→ true
      function rejected(req, res, allowedMethods) {
        try {
          const method = String((req && req.method) || 'GET').toUpperCase()
          const headers = (req && req.headers) || {}
          // ① 方法白名单：不在列表里直接 405。这条永远先跑。
          if (Array.isArray(allowedMethods) && allowedMethods.indexOf(method) < 0) {
            try { res.setHeader('Allow', allowedMethods.join(', ')) } catch (err) {}
            return deny(res, 405)
          }
          // ② Host / Origin / Sec-Fetch-Site 自校验
          let hostUrl = null
          try { hostUrl = new URL('http://' + String(headers.host || '')) } catch (err) { return deny(res, 403) }
          const hostname = hostUrl.hostname
          const authority = hostUrl.host
          if (!isLoopbackHostname(hostname)) {
            const listed = TRUSTED_AUTHORITIES.some((e) => (e.indexOf(':') >= 0 ? e === authority.toLowerCase() : e === hostname.toLowerCase()))
            if (!listed && !haveFence) return deny(res, 403)
          }
          const site = String(headers['sec-fetch-site'] || '').toLowerCase()
          if (site === 'cross-site') return deny(res, 403)
          const origin = headers.origin
          if (typeof origin === 'string' && origin && origin !== 'null') {
            let originUrl = null
            try { originUrl = new URL(origin) } catch (err) { return deny(res, 403) }
            if (originUrl.host.toLowerCase() !== authority.toLowerCase()) return deny(res, 403)
          }
          // ③ 写方法必须来自本机（改配置 = 决定本机要跑什么，与"坐在这台机器前"绑定）
          if (WRITE_METHODS.has(method) && !isLoopbackHostname(hostname)) {
            const isAdmin = ADMIN_AUTHORITIES.some((e) => (e.indexOf(':') >= 0 ? e === authority.toLowerCase() : e === hostname.toLowerCase()))
            if (!isAdmin) return deny(res, 403)
          }
          // ④ 委托宿主栅栏；它抛异常按拒绝处理
          const conn = connectionFence()
          if (!conn) return false
          let code
          try { code = conn.requestRejection(req) }
          catch (err) { return deny(res, 403) }
          if (code === undefined || code === null || code === false) return false
          return deny(res, typeof code === 'number' ? code : 403)
        } catch (err) {
          return deny(res, 403) // 校验器自身出错 → 拒绝（fail-closed）
        }
      }

      // 统一注册入口：强制要求 route.methods（数组），handler 不再需要自己判方法。
      function registerRoute(route) {
        const methods = Array.isArray(route.methods) ? route.methods.map((m) => String(m).toUpperCase()) : null
        if (!methods || !methods.length) throw new Error('dsh-pet: route ' + route.path + ' 必须声明 methods')
        DIAG.routes.push(route.path + ' [' + methods.join(',') + ']')
        const inner = route.handler
        return ctx.webServer.register({
          kind: 'exact',
          path: route.path,
          handler: async (req, res) => {
            if (rejected(req, res, methods)) return
            return inner(req, res)
          },
        })
      }

      // ---------------------------------------------------------------- 静态资源
      keep(registerRoute({
        methods: ['GET', 'HEAD'],
        path: UI_SCRIPT,
        handler: (req, res) => {
          const bytes = readIfExists(path.join(PACKAGE_ROOT, 'assets', 'pet-ui.js'))
          if (!bytes) {
            res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
            res.end('pet-ui.js unavailable')
            return
          }
          res.writeHead(200, {
            'Content-Type': 'application/javascript; charset=utf-8',
            'Cache-Control': 'no-store',
            'Content-Length': String(bytes.length),
          })
          res.end(bytes)
        },
      }))

      // （原计划加一个 /dsh-pet/panel 兜底页面，已放弃：实测 DSH 的 web 服务连首页都 403，
      //   只认浏览器里已有的凭证。用普通 URL 打开的页面调不动接口，等于假兜底。
      //   真正的兜底是 ball.autoStart —— 球不依赖页面，插件起来自己把它拉出来。）


      keep(registerRoute({
        methods: ['GET', 'HEAD'],
        path: PREFIX + '/image.png',
        handler: (req, res) => {
          const bytes = readIfExists(path.join(PACKAGE_ROOT, 'assets', 'whale.png'))
          if (!bytes) {
            res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
            res.end('whale image unavailable')
            return
          }
          res.writeHead(200, {
            'Content-Type': 'image/png',
            'Cache-Control': 'no-store',
            'Content-Length': String(bytes.length),
          })
          res.end(bytes)
        },
      }))

      // ---------------------------------------------------------------- 状态（只读）
      // pet-state.json 现在**只有宿主自己写**（每次投递的状态：已发出/等回复/失败）。
      // 原来是数据端写的，公共版不带了 —— 但球的显示逻辑还读这个文件，所以路由保留。
      keep(registerRoute({
        methods: ['GET', 'HEAD'],
        path: PREFIX + '/state.json',
        handler: (req, res) => {
          let out = ''
          let kind = 'unknown'
          try {
            const o = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'))
            out = (o && typeof o.text === 'string') ? o.text : ''
            if (o && typeof o.kind === 'string') kind = o.kind
          } catch (err) { /* 没文件 / 解析失败 → 空状态 */ }
          res.writeHead(200, JSON_HEADERS)
          res.end(JSON.stringify({ text: out, kind, at: Date.now() }))
        },
      }))

      // ---------------------------------------------------------------- 桌面球开关
      // 三态：不带 body / body 为空 → 切反当前状态；{"action":"start"|"stop"} → 明确指定。
      // 显式声明 POST：GET 进来会被 405 挡掉，不会触发副作用（评审 #2）。
      keep(registerRoute({
        methods: ['POST'],
        path: PREFIX + '/ball/toggle',
        handler: async (req, res) => {
          let result
          try {
            const body = await readBody(req)
            let action = ''
            if (body) { try { action = String((JSON.parse(body) || {}).action || '') } catch (err) {} }
            const running = !!ballPidRaw()   // 快查即可；真正杀进程时会再验进程名
            const only = onlyParam(req.url)
            if (action === 'stop' || (!action && running)) result = await petStop(only)
            else result = await petStart(only)
          } catch (err) {
            result = { ok: false, running: false, msg: String((err && err.message) || err) }
          }
          res.writeHead(200, JSON_HEADERS)
          res.end(JSON.stringify(result))
        },
      }))

      // ---------------------------------------------------------------- 「问一下」：截屏 → 投给会话
      keep(registerRoute({
        methods: ['POST'],
        path: PREFIX + '/ball/ask',
        handler: async (req, res) => {
          // 实现抽到模块级 doAsk()，给这里和降级链定时器共用
          const out = await doAsk(ctx, 'manual')
          res.writeHead(200, JSON_HEADERS)
          res.end(JSON.stringify(out))
        },
      }))

      // （ask.request 的监听已挪到 apply() 层 —— 球上「问一下」不该依赖 webServer）

      // ---------------------------------------------------------------- 自述（排障用）
      // 重启之后一条 curl 就能看清"到底哪一环没起来"，不用一个个猜。
      keep(registerRoute({
        methods: ['GET', 'HEAD'],
        path: PREFIX + '/diag',
        handler: async (req, res) => {
          let pkg = {}
          try { pkg = JSON.parse(fs.readFileSync(path.join(PACKAGE_ROOT, 'package.json'), 'utf8')) } catch (err) {}
          let stateAgeMs = null
          let stateKind = null
          try {
            const st = fs.statSync(STATE_FILE)
            stateAgeMs = Date.now() - st.mtimeMs
            const j = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'))
            stateKind = j && j.kind
          } catch (err) {}
          const ballPid = ballPidRaw()
          const cfg = explainConfig()
          res.writeHead(200, JSON_HEADERS)
          res.end(JSON.stringify({
            plugin: { name: pkg.name, version: pkg.version },
            uptimeMs: Date.now() - DIAG.startedAt,
            // 桌面端能不能出胶囊，就看 indexInjectPushed 是不是 >0
            desktopInject: {
              pushed: DIAG.indexInjectPushed,
              reused: DIAG.indexInjectReused,
              lastAt: DIAG.indexInjectLastAt || null,
              error: DIAG.indexInjectError || null,
              rowText: DESKTOP_UI_ROW_TEXT,
            },
            // web 形态走这条（宿主的 renderIndex 被调用次数）
            tapIndexCalls: DIAG.tapIndexCalls,
            routes: DIAG.routes,
            processes: {
              ball: { pid: ballPid, running: ballPid > 0 },
            },
            state: { file: STATE_FILE, exists: stateAgeMs !== null, ageMs: stateAgeMs, kind: stateKind },
            dataDir: DATA_DIR,
            config: { file: cfg.CONFIG_FILE, exists: cfg.exists, effective: CONFIG },
          }, null, 2))
        },
      }))

      // ---------------------------------------------------------------- 最近一次截图（给页面气泡显示用，可选）
      keep(registerRoute({
        methods: ['GET', 'HEAD'],
        path: PREFIX + '/shot.png',
        handler: (req, res) => {
          const bytes = readIfExists(SHOT_FILE)
          if (!bytes) {
            res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
            res.end('no screenshot yet')
            return
          }
          res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store', 'Content-Length': String(bytes.length) })
          res.end(bytes)
        },
      }))

      // ---------------------------------------------------------------- web 形态注入
      // 桌面端这条不生效（index.html 不经过 renderIndex），所以两条并存、各自去重。
      keep(ctx.webServer.tapIndex((html) => {
        DIAG.tapIndexCalls++
        let out = html
        if (out.indexOf(UI_SCRIPT) === -1) {
          const tag = '<script defer src="' + UI_SCRIPT + '"></script>'
          out = out.indexOf('</body>') !== -1 ? out.replace('</body>', tag + '</body>') : out + tag
        }
        return out
      }))

      ensureDir(DATA_DIR)

      ctx.effect(() => () => {
        for (const d of disposers) { try { d() } catch (err) {} }
      })
    }

    // —— 装配（注册路由 + 注入）：两条路，谁先到谁用 ——
    //
    // ⚠️ 为什么不能只靠 root.inject：
    //    Cordis 的 root.inject(names, cb) 是"**名单里全部就绪**才回调"。只要有一个服务名
    //    在某个 DSH 构建里不叫这个（或干脆没有），它就**永远不回调，而且不报错** ——
    //    插件于是变成一个完全静默的空壳：路由 404、日志一片空、界面上什么都没有。
    //    2026-10-31 在别人的机器上就是这个现象，而且因为日志是跨启动追加的，
    //    上一次运行的 sessions dump 还在，看上去像"回调跑了"，排查方向全被带偏。
    //    所以这里再加一条自己轮询的路：能观察到、超时会喊、拿到就装配。
    let didSetup = false
    const runSetup = (ctx, how) => {
      if (didSetup) return
      didSetup = true
      try {
        hostLog('装配开始（' + how + '，等了 ' + (Date.now() - t0) + 'ms）')
        setupAll(ctx)
      } catch (err) {
        hostLog('装配失败: ' + ((err && err.message) || err))
      }
    }

    try { root.inject(REQUIRED_SERVICES, (ctx) => runSetup(ctx, 'root.inject')) }
    catch (err) { hostLog('root.inject 抛错: ' + ((err && err.message) || err)) }

    const setupStart = Date.now()
    const setupPoll = setInterval(() => {
      if (didSetup) { clearInterval(setupPoll); return }
      let ws = null
      try { ws = (root.get && root.get('webServer')) || root.webServer || null } catch (err) {}
      if (ws) {
        // ⚠️ **不能**在这里调 runSetup(root) 去注册路由。
        //    官方教程（dsh-plugin.org/tutorials/fix-rpc-handle-webcontext-inject）说得很清楚：
        //    ctx.webServer 的访问守卫检查的是**发起访问的那个 fiber** 自己的 inject 映射
        //    （"adding an injection to your own plugin has no effect whatsoever" 讲的是另一头）。
        //    root 这个 fiber 没声明 webServer，所以 root.webServer.register 必然拿不到。
        //    这里只做**诊断**：服务已经可见、但 root.inject 还没回调 —— 这本身就是一条有价值的信息。
        clearInterval(setupPoll)
        hostLog('⚠️ webServer 已经可见（root.get 能取到），但 root.inject 的回调没触发 —— '
          + '路由和胶囊不会有。把这条和上面 8 秒服务探针的结果发给作者。')
        return
      }
      if (Date.now() - setupStart > 30000) {
        clearInterval(setupPoll)
        hostLog('⚠️ 30 秒没等到 webServer —— 路由和胶囊都不会有。'
          + '球不受影响（它在 apply() 层就起来了）。把上面 8 秒那条服务探针的结果发给作者。')
      }
    }, 300)
    if (setupPoll && typeof setupPoll.unref === 'function') setupPoll.unref()
    try { root.effect(() => () => clearInterval(setupPoll)) } catch (err) {}
  },
}
