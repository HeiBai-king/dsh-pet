#!/usr/bin/env node
// verify-desktop-row.mjs -- 验证**桌面注入行**那段 payload 本身是好的。
//
// 桌面端（Electron）能不能出胶囊 = 两件事都成立：
//   ① 那段内联行进了 webserver/index-inject 的表（宿主侧，看 /dsh-pet/diag 的 desktopInject.pushed）
//   ② 那段行被求值时真的能建出 <script> 并加载到 ui.js（**本脚本验的就是这条**）
// 剩下的只有"Electron 外壳到底有没有应用这张表"—— 那个只能真重启才知道。
//
// 做法：把 diag 里的 rowText 原样拿到一个浏览器页面里求值，模拟外壳的注入动作，
//       然后看手写胶囊有没有挂上来。
//
// 用法：node tools/verify-desktop-row.mjs "http://127.0.0.1:3099/?token=XXXX"
const rawUrl = process.argv[2]
if (!rawUrl) { console.log('用法：node tools/verify-desktop-row.mjs "<带 token 的 url>"'); process.exit(2) }
const u = new URL(rawUrl)
const base = u.origin
const token = u.searchParams.get('token') || ''

let cookie = ''
async function req(p, opts = {}) {
  const r = await fetch(base + p, {
    ...opts,
    headers: Object.assign({}, opts.headers || {}, cookie ? { Cookie: cookie } : {}),
    redirect: 'manual',
  })
  const sc = r.headers.getSetCookie ? r.headers.getSetCookie() : []
  if (sc.length) cookie = sc.map((c) => c.split(';')[0]).join('; ')
  return r
}

await req('/?token=' + encodeURIComponent(token))
const diagRes = await req('/dsh-pet/diag')
if (diagRes.status !== 200) { console.log('拿不到 diag（HTTP ' + diagRes.status + '）'); process.exit(2) }
const diag = await diagRes.json()
const row = diag.desktopInject.rowText

console.log('\n[验证桌面注入行]\n')
console.log('  行内容：' + row)
console.log('  宿主侧已推入次数：' + diag.desktopInject.pushed + '（复用 ' + diag.desktopInject.reused + '）')

// 开一个干净标签
// 数据端已从插件里移除，diag 不再暴露 cdpPort —— 这里直接用 CDP 的默认端口
const port = 9222
const nr = await fetch('http://127.0.0.1:' + port + '/json/new?' + encodeURIComponent(rawUrl), { method: 'PUT' })
if (!nr.ok) { console.log('\n  开不了调试标签（CDP ' + port + ' 没在跑？）HTTP ' + nr.status + '\n'); process.exit(2) }
const page = await nr.json()
await new Promise((r) => setTimeout(r, 7000))

// 表达式：清掉两个标记（逼它走兜底）→ 求值那段行 → 看有没有挂上来
const expr = `(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  try { delete window.__dshPetSlot } catch (e) { window.__dshPetSlot = false }
  try { delete window.__dshPetUi } catch (e) { window.__dshPetUi = false }
  const before = document.querySelectorAll('#dshpet-toggle').length;
  const sBefore = document.querySelectorAll('script[src*="dsh-pet/ui.js"]').length;
  ${row}
  await sleep(1200);
  const sAfter = document.querySelectorAll('script[src*="dsh-pet/ui.js"]').length;
  await sleep(3400);
  return JSON.stringify({
    before, sBefore, sAfter,
    toggleCount: document.querySelectorAll('#dshpet-toggle').length,
    wrapCount: document.querySelectorAll('#dshpet-wrap').length,
    askBtn: !!document.querySelector('#dshpet-ask'),
    fallback: !!window.__dshPetFallback,
  });
})()`

const wsUrl = page.webSocketDebuggerUrl
const out = await new Promise((res, rej) => {
  const ws = new WebSocket(wsUrl)
  const t = setTimeout(() => { try { ws.close() } catch (e) {} ; rej(new Error('超时')) }, 25000)
  ws.addEventListener('error', () => { clearTimeout(t); rej(new Error('ws 连不上')) })
  ws.addEventListener('open', () => {
    ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression: expr, returnByValue: true, awaitPromise: true } }))
  })
  ws.addEventListener('message', (ev) => {
    let m; try { m = JSON.parse(ev.data) } catch (e) { return }
    if (m.id !== 1) return
    clearTimeout(t)
    try { ws.close() } catch (e) {}
    if (m.result?.exceptionDetails) return rej(new Error(m.result.exceptionDetails.text))
    res(m.result?.result?.value)
  })
})

if (!out) { console.log('\n  ✗ 没拿到结果\n'); process.exit(1) }
const j = JSON.parse(out)

let pass = 0, fail = 0
const chk = (name, ok, why) => { if (ok) { console.log('  ✓ ' + name); pass++ } else { console.log('  ✗ ' + name + '  → ' + why); fail++ } }

console.log('')
chk('求值前页面上没有手写胶囊', j.before === 0, '已有 ' + j.before + ' 个')
chk('那段行建出了 <script src*=dsh-pet/ui.js>', j.sAfter > j.sBefore, '脚本标签数没变（' + j.sBefore + ' → ' + j.sAfter + '）')
chk('手写胶囊挂上来了（1 个）', j.toggleCount === 1, '挂了 ' + j.toggleCount + ' 个')
chk('气泡容器也在', j.wrapCount === 1, '挂了 ' + j.wrapCount + ' 个')
chk('「问」按钮在', j.askBtn === true, '没找到')
chk('确实走的是兜底路线', j.fallback === true, 'fallback 标记没置位')

console.log('\n————————————————————————')
console.log('通过 ' + pass + ' 项，失败 ' + fail + ' 项')
console.log('\n含义：这段行的 payload 是好的 —— 只要 Electron 外壳把它应用了，桌面端就会出胶囊。')
console.log('外壳到底应没应用，只能真重启一次才知道（那个脚本里没有别的办法）。\n')
process.exit(fail ? 1 : 0)
