#!/usr/bin/env node
// post-restart-check.mjs -- 重启 DSH 之后跑这一条，看各环节到底起没起来。
//
// 为什么需要它：dsh-pet 横跨三块（页面胶囊 / 桌面球 / 数据端），
// 重启后"胶囊没出来"可能是五个不同原因（行没进表 / 路由没注册 / 脚本 404 / 槽位没渲染 / 走了兜底）。
// 一个个猜太慢 —— 这个脚本把每一环单独判一遍。
//
// 用法：
//   node tools/post-restart-check.mjs "http://127.0.0.1:43120/?token=XXXX"
//   node tools/post-restart-check.mjs "http://127.0.0.1:3099/?token=XXXX" --toggle
//
// 参数：
//   <url>       带 token 的地址（从浏览器地址栏整条复制即可）
//   --toggle    顺便真的开关一次球+数据端（会弹一个窗口，跑完自动关）
//   --cdp       顺便用调试浏览器查一下页面里真的有胶囊（需要 CDP 9222 在跑）
//   --json      只输出原始 diag JSON
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const argv = process.argv.slice(2)
const rawUrl = argv.find((a) => /^https?:\/\//.test(a))
const DO_TOGGLE = argv.includes('--toggle')
const DO_CDP = argv.includes('--cdp')
const JSON_ONLY = argv.includes('--json')

if (!rawUrl) {
  console.log('用法：node tools/post-restart-check.mjs "http://127.0.0.1:43120/?token=XXXX" [--toggle] [--cdp]')
  process.exit(2)
}

const u = new URL(rawUrl)
const token = u.searchParams.get('token') || ''
const base = u.origin
const PREFIX = '/dsh-pet'

let cookie = ''
async function req(pathname, opts = {}) {
  const r = await fetch(base + pathname, {
    ...opts,
    headers: Object.assign({ 'Cache-Control': 'no-cache' }, opts.headers || {}, cookie ? { Cookie: cookie } : {}),
    redirect: 'manual',
  })
  const setC = r.headers.getSetCookie ? r.headers.getSetCookie() : []
  if (setC.length) cookie = setC.map((c) => c.split(';')[0]).join('; ')
  return r
}

let pass = 0, fail = 0
function check(name, fn) {
  try {
    const r = fn()
    if (r === true || r === undefined) { console.log('  ✓ ' + name); pass++ }
    else if (r === 'skip') { console.log('  · ' + name + '（跳过）') }
    else { console.log('  ✗ ' + name + '  → ' + r); fail++ }
  } catch (e) { console.log('  ✗ ' + name + '  → ' + e.message); fail++ }
}

console.log('\n[dsh-pet 重启后检查] ' + base + '\n')

// ① 先建立会话 cookie（token 是通过 ?token= 换成 cookie 的）
try { await req('/?token=' + encodeURIComponent(token)) } catch (e) {
  console.log('  ✗ 连不上 ' + base + '：' + e.message + '\n'); process.exit(2)
}

// ② diag
const dRes = await req(PREFIX + '/diag')
if (dRes.status === 401) {
  console.log('  ✗ /dsh-pet/diag 返回 401 —— token 不对，或者插件根本没加载')
  console.log('     （整条地址栏 URL 复制过来，别只复制 token）\n'); process.exit(2)
}
if (dRes.status === 404) {
  console.log('  ✗ /dsh-pet/diag 返回 404 —— 插件没加载。（404 说明路由表里根本没有它）\n'); process.exit(2)
}
if (dRes.status !== 200) {
  console.log('  ✗ /dsh-pet/diag 返回 ' + dRes.status + '\n'); process.exit(2)
}
const diag = await dRes.json()

if (JSON_ONLY) { console.log(JSON.stringify(diag, null, 2)); process.exit(0) }

console.log('『插件本体』')
check('插件加载了：' + diag.plugin.name + '@' + diag.plugin.version, () => true)
check('运行了 ' + Math.round(diag.uptimeMs / 1000) + ' 秒', () => true)

console.log('\n『桌面端注入通道』（Electron 就靠这条）')
check('webserver/index-inject 的订阅被触发过（pushed=' + diag.desktopInject.pushed + ' reused=' + diag.desktopInject.reused + '）',
  () => (diag.desktopInject.pushed + diag.desktopInject.reused) > 0 ? true : '订阅一次都没被触发 —— 桌面端不会有胶囊')
check('注入行的错误字段是空的', () => diag.desktopInject.error ? diag.desktopInject.error : true)

console.log('\n『web 注入通道』（renderIndex / tapIndex）')
check('tapIndex 被调用过（' + diag.tapIndexCalls + ' 次）',
  () => diag.tapIndexCalls > 0 ? true : 'renderIndex 没走过 —— 但你可能是从 Electron 进的，这条可以不算失败')

console.log('\n『路由』')
const want = ['/ui.js', '/image.png', '/state.json', '/ball/toggle', '/ball/ask', '/shot.png', '/diag']
for (const w of want) {
  check('路由 ' + PREFIX + w + ' 已注册', () => diag.routes.some((r) => r.startsWith(PREFIX + w)) ? true : '没注册')
}

console.log('\n『进程』')
check('桌面球：' + (diag.processes.ball.running ? '在跑 pid=' + diag.processes.ball.pid : '没在跑'), () => true)
check('数据端：' + (diag.processes.brain.running ? '在跑 pid=' + diag.processes.brain.pid : '没在跑'), () => true)

console.log('\n『状态文件』')
check('状态文件存在，' + Math.round(diag.state.ageMs / 1000) + ' 秒前更新过（kind=' + diag.state.kind + '）',
  () => diag.state.exists ? true : '文件不存在 —— 数据端没在写')

console.log('\n『配置』')
check('配置文件：' + diag.config.file + (diag.config.exists ? '（已生成）' : '（不存在，全用默认）'), () => true)

// ③ 开关一次
if (DO_TOGGLE) {
  console.log('\n『真的开关一次球 + 数据端』')
  const on = await req(PREFIX + '/ball/toggle', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"action":"start"}',
  })
  const onJ = await on.json().catch(() => null)
  check('开：' + (onJ && onJ.detail ? JSON.stringify(onJ.detail) : JSON.stringify(onJ)),
    () => (onJ && onJ.ok) ? true : String(onJ && onJ.msg))
  await new Promise((r) => setTimeout(r, 3000))
  const d2 = await (await req(PREFIX + '/diag')).json()
  check('开之后：球=' + d2.processes.ball.running + ' 数据端=' + d2.processes.brain.running,
    () => (d2.processes.ball.running && d2.processes.brain.running) ? true : '有一个没起来')

  const off = await req(PREFIX + '/ball/toggle', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"action":"stop"}',
  })
  const offJ = await off.json().catch(() => null)
  check('关：' + (offJ && offJ.detail ? JSON.stringify(offJ.detail) : JSON.stringify(offJ)),
    () => (offJ && !offJ.running) ? true : String(offJ && offJ.msg))
}

// ④ 页面里真的有胶囊吗（走 CDP）
if (DO_CDP) {
  console.log('\n『页面里的胶囊』（CDP）')
  try {
    // 数据端已从插件里移除，diag 不再暴露 cdpPort —— 这里直接用 CDP 的默认端口
const port = 9222
    const list = await (await fetch('http://127.0.0.1:' + port + '/json/list')).json()
    let page = list.find((t) => t.type === 'page' && String(t.url).includes(u.hostname))
    if (!page) {
      // 没现成的就自己开一个（开完要给它加载 + 注入的时间）
      console.log('  · 没有现成标签，自己开一个…')
      const nr = await fetch('http://127.0.0.1:' + port + '/json/new?' + encodeURIComponent(rawUrl), { method: 'PUT' })
      if (!nr.ok) throw new Error('开标签失败 ' + nr.status)
      page = await nr.json()
      await new Promise((res) => setTimeout(res, 7000))
      page = (await (await fetch('http://127.0.0.1:' + port + '/json/list')).json())
        .find((t) => t.id === page.id) || page
    }
    if (!page) {
      console.log('  · 调试浏览器里没有 ' + u.hostname + ' 的页面（跳过）')
    } else {
      // Node 22+ 自带全局 WebSocket，不用装 ws（browser-probe.mjs 也是这么连的）
      const ws = new WebSocket(page.webSocketDebuggerUrl)
      await new Promise((res, rej) => {
        ws.addEventListener('open', res, { once: true })
        ws.addEventListener('error', () => rej(new Error('CDP ws 连不上')), { once: true })
        setTimeout(() => rej(new Error('CDP ws 超时')), 8000)
      })
      const expr = `JSON.stringify({
          slotPill: !!document.querySelector('[data-dshpet-ui="pill"]'),
          fallbackPill: !!document.getElementById('dshpet-toggle'),
          askBtn: !!document.querySelector('[data-dshpet-ui="ask"]'),
          slotFlag: !!window.__dshPetSlot,
          fallbackFlag: !!window.__dshPetFallback,
          dshPetScript: !!document.querySelector('script[src*="dsh-pet"]')
        })`
      const out = await new Promise((res) => {
        ws.addEventListener('message', (ev) => {
          let m; try { m = JSON.parse(ev.data) } catch { return }
          if (m.id === 1) res(m.result?.result?.value)
        })
        ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: expr, returnByValue: true, awaitPromise: true } }))
        setTimeout(() => res(null), 8000)
      })
      try { ws.close() } catch (e) {}
      if (!out) { console.log('  · CDP 没回结果（跳过）'); }
      else {
        const j = JSON.parse(out)
        check('页面加载了 dsh-pet 的脚本', () => j.dshPetScript ? true : '没有 <script src*=dsh-pet>')
        check('槽位路线渲染出了胶囊（走 React 树）',
          () => j.slotPill ? true : (j.fallbackPill ? '没有 —— 但手写兜底顶上来了（说明这张卡走的是兜底）' : '两种都没有！'))
        check('手写兜底的状态：' + (j.fallbackFlag ? '已启用' : '未启用（槽位接管了）'), () => true)
        check('「问」按钮在', () => j.askBtn ? true : '没有')
        check('两种路线没有同时挂载（不该出现两个胶囊）',
          () => !(j.slotPill && j.fallbackPill) ? true : '两个都挂了 —— 会看到重复胶囊')
      }
    }
  } catch (e) {
    console.log('  · CDP 检查跳过：' + e.message)
  }
}

console.log('\n————————————————————————')
console.log('通过 ' + pass + ' 项，失败 ' + fail + ' 项')
if (fail) console.log('\n看 ' + path.join(diag.dataDir || '', 'pet-host.log') + ' 找进程侧的原因。')
console.log('')
process.exit(fail ? 1 : 0)
