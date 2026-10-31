// ============================================================================
// dsh-pet 宿主半区自检（不依赖 DSH，直接拿 mock ctx 跑 apply）
// ----------------------------------------------------------------------------
// 用法：node tools/selfcheck.mjs
// 验的是「插件契约」本身：注入行、路由注册、方法白名单、信任栅栏、去重幂等。
// 不验浏览器那一半（那要真启动 DSH + 浏览器）。
// ============================================================================

import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

// 自检绝不允许真的起/杀一个桌面球进程。
// ⚠️ 必须是**动态** import：ESM 的静态 import 会被提升到赋值之前执行，
//    那样 lib/index.js 读到的 DSHW_PET_DRY_RUN 还是空的。
process.env.DSHW_PET_DRY_RUN = '1'

// ⚠️ 自检必须用**自己的** DSH_HOME。
//    之前没设，于是它读的是用户真实的 ~/.dsh/pet/pet-state.json ——
//    真机上数据端一跑起来，自检就冒出"state.json 的 kind 不是 unknown"这种假失败；
//    更糟的是它可能真的去读/写用户的真实数据目录。2026-10-13 真机踩到。
const TMP_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-pet-selfcheck-'))
process.env.DSH_HOME = TMP_HOME
process.on('exit', () => { try { fs.rmSync(TMP_HOME, { recursive: true, force: true }) } catch (e) {} })

const { default: plugin } = await import('../lib/index.js')

const PREFIX = '/dsh-pet'
let pass = 0, fail = 0
function ok(name, fn) {
  try { fn(); pass++; console.log('  ✓ ' + name) }
  catch (e) { fail++; console.log('  ✗ ' + name + '\n      ' + (e && e.message)) }
}

// ---------------------------------------------------------------- mock DSH
function buildHarness({ connection = null }) {
  const routes = new Map()
  const taps = []
  const injectSubs = []
  const effcts = []
  const webServer = {
    register(route) {
      if (routes.has(route.path)) throw new Error('webserver: duplicate exact route "' + route.path + '"')
      routes.set(route.path, route)
      return () => routes.delete(route.path)
    },
    tapIndex(fn) { taps.push(fn); return () => { const i = taps.indexOf(fn); if (i >= 0) taps.splice(i, 1) } },
  }
  const ctx = {
    webServer,
    connection,
    effect(fn) { const d = fn(); effcts.push(d); return d },
    get(name) { return name === 'connection' ? connection : null },
  }
  const root = {
    on(event, cb) {
      if (event === 'webserver/index-inject') injectSubs.push(cb)
      return () => { const i = injectSubs.indexOf(cb); if (i >= 0) injectSubs.splice(i, 1) }
    },
    effect(fn) { const d = fn(); effcts.push(d); return d },
    inject(list, cb) { cb(ctx) },
  }
  return { root, routes, taps, injectSubs, webServer }
}

// 极简 req/res
// ⚠️ req 必须是个 EventEmitter：宿主用 readBody(req) 读请求体（监听 data/end），
//    如果给个死对象，handler 会永远挂在那个 Promise 上。
function call(routes, path, opts = {}) {
  // 真实 webServer 是**按路径**匹配路由的，查询串不参与 —— 这里也得这么查，
  // 否则 `/x?only=brain` 会被当成一个没注册过的路径。
  const pathname = String(path).split('?')[0]
  const route = routes.get(pathname)
  if (!route) return Promise.resolve({ status: 404, body: null, headers: {} })
  const res = {
    statusCode: 200,
    headers: {},
    setHeader(k, v) { this.headers[k.toLowerCase()] = v },
    writeHead(code, h) { this.statusCode = code; if (h) for (const k of Object.keys(h)) this.headers[k.toLowerCase()] = h[k]; return this },
    end(body) { this.body = body },
  }
  const req = new EventEmitter()
  req.method = opts.method || 'GET'
  req.url = path
  req.headers = Object.assign({ host: '127.0.0.1:43120' }, opts.headers || {})
  req.destroy = () => {}
  process.nextTick(() => {
    if (opts.body) req.emit('data', Buffer.from(String(opts.body)))
    req.emit('end')
  })
  return Promise.resolve(route.handler(req, res)).then(() => ({
    status: res.statusCode, body: res.body, headers: res.headers,
  }))
}

// ---------------------------------------------------------------- 跑
console.log('\n[dsh-pet 宿主自检]\n')

const H = buildHarness({})
ok('插件对象形状正确', () => {
  assert.equal(plugin.name, 'dsh-pet')
  assert.equal(typeof plugin.apply, 'function')
})

plugin.apply(H.root)

// ① 注入行必须在 inject 之前就已注册（桌面端是宿主启动时一次性收集的）
console.log('\n① 桌面端注入行')
ok('apply() 立刻注册了 webserver/index-inject 订阅', () => {
  assert.equal(H.injectSubs.length, 1, '订阅数应为 1，实际 ' + H.injectSubs.length)
})
ok('推入的是 kind:script 内联行（不是 script-src —— 那个加载失败会搞崩 boot）', () => {
  const table = []
  H.injectSubs[0](table)
  assert.equal(table.length, 1)
  assert.equal(table[0].kind, 'script')
  assert.equal(table[0].placement, 'body')
  assert.ok(table[0].text.indexOf('/dsh-pet/ui.js') >= 0)
  assert.ok(table[0].text.indexOf('onerror') >= 0, '必须吞掉 onerror')
})
ok('重复收集不重复推（幂等）', () => {
  const table = []
  H.injectSubs[0](table); H.injectSubs[0](table)
  assert.equal(table.length, 1)
})
ok('表里已有别的插件的行时，不影响我们这一行被推入', () => {
  // 关键回归点：不能因为"发现别人的行"就提前 return
  const table = [{ kind: 'script', placement: 'body', text: '/* 别的插件 */' }]
  H.injectSubs[0](table)
  assert.equal(table.length, 2, '我们的行必须被追加，实际表长 ' + table.length)
})

// ② 路由
console.log('\n② 路由注册')
ok("7 条路由都注册上了", () => {
  const want = [PREFIX + "/ui.js", PREFIX + "/image.png", PREFIX + "/state.json", PREFIX + "/ball/toggle", PREFIX + "/ball/ask", PREFIX + "/shot.png", PREFIX + "/diag"]
  for (const p of want) assert.ok(H.routes.has(p), '缺路由 ' + p)
})
ok('路由都带 handler', () => {
  for (const [p, r] of H.routes) assert.equal(typeof r.handler, 'function', p)
})

await (async () => {
  console.log('\n③ 方法白名单（评审 #2 的修法）')
  const gGet = await call(H.routes, PREFIX + '/ball/toggle', { method: 'GET' })
  ok('GET /ball/toggle → 405（不再能用 GET 触发副作用）', () => {
    assert.equal(gGet.status, 405)
    assert.equal(gGet.headers.allow, 'POST')
  })
  const pOk = await call(H.routes, PREFIX + '/ball/toggle', { method: 'POST' })
  ok('POST /ball/toggle（回环）→ 200 + {ok:true}', () => {
    assert.equal(pOk.status, 200)
    const j = JSON.parse(pOk.body)
    assert.equal(j.ok, true)
  })
  const ui = await call(H.routes, PREFIX + '/ui.js', { method: 'GET' })
  ok('GET /ui.js → 200 且是 js、且 no-store', () => {
    assert.equal(ui.status, 200)
    assert.match(ui.headers['content-type'], /javascript/)
    assert.equal(ui.headers['cache-control'], 'no-store')
    assert.ok(String(ui.body).indexOf('__dshPetUi') >= 0, '返回的应该是 pet-ui.js 内容')
  })
  const img = await call(H.routes, PREFIX + '/image.png', { method: 'GET' })
  ok('GET /image.png → 200 且是 png', () => {
    assert.equal(img.status, 200)
    assert.equal(img.headers['content-type'], 'image/png')
  })
  const st = await call(H.routes, PREFIX + '/state.json', { method: 'GET' })
  ok('GET /state.json（没有状态文件时）→ 200 + 空 text（不是 500）', () => {
    assert.equal(st.status, 200)
    const j = JSON.parse(st.body)
    assert.equal(typeof j.text, 'string')
    assert.equal(j.kind, 'unknown')
  })
  const askGet = await call(H.routes, PREFIX + '/ball/ask', { method: 'GET' })
  ok('GET /ball/ask → 405（截屏这种有副作用的接口不能被 GET 触发）', () => {
    assert.equal(askGet.status, 405)
    assert.equal(askGet.headers.allow, 'POST')
  })
  const shot404 = await call(H.routes, PREFIX + '/shot.png', { method: 'GET' })
  ok('GET /shot.png（还没截过图）→ 404，不是 500', () => {
    assert.equal(shot404.status, 404)
  })
  const toggleP = await call(H.routes, PREFIX + '/ball/toggle', { method: 'POST', body: '{"action":"start"}' })
  ok('POST /ball/toggle {action:start} → 200 + running:true（dry-run，不真起进程）', () => {
    assert.equal(toggleP.status, 200)
    const j = JSON.parse(toggleP.body)
    assert.equal(j.ok, true)
    assert.equal(j.running, true)
    assert.match(j.detail.ball.msg, /dry-run/)
  })
  const toggleStop = await call(H.routes, PREFIX + '/ball/toggle', { method: 'POST', body: '{"action":"stop"}' })
  ok('POST /ball/toggle {action:stop} → 200 + running:false（dry-run）', () => {
    const j = JSON.parse(toggleStop.body)
    assert.equal(j.ok, true)
    assert.equal(j.running, false)
    assert.equal(j.msg, 'stopped')
    assert.match(j.detail.ball.msg, /dry-run/)
  })
  const toggleOnly = await call(H.routes, PREFIX + '/ball/toggle?only=brain', { method: 'POST', body: '{"action":"start"}' })
  ok('POST /ball/toggle?only=brain → 数据端已移除，参数被忽略、照样开关球', () => {
    const j = JSON.parse(toggleOnly.body)
    assert.equal(j.ok, true)
    assert.equal(j.detail.brain, undefined, '不该再有数据端')
    assert.ok(j.detail.ball, '球照常处理')
  })

  console.log('\n④ 信任栅栏')
  const nonLoop = await call(H.routes, PREFIX + '/ball/toggle', { method: 'POST', headers: { host: '192.168.1.9:43120' } })
  ok('非回环 Host 的 POST → 403', () => { assert.equal(nonLoop.status, 403) })
  const crossSite = await call(H.routes, PREFIX + '/state.json', { method: 'GET', headers: { 'sec-fetch-site': 'cross-site' } })
  ok('Sec-Fetch-Site: cross-site → 403', () => { assert.equal(crossSite.status, 403) })
  const badOrigin = await call(H.routes, PREFIX + '/state.json', { method: 'GET', headers: { origin: 'https://evil.example' } })
  ok('Origin 与 Host 不同源 → 403', () => { assert.equal(badOrigin.status, 403) })
  const sameOrigin = await call(H.routes, PREFIX + '/state.json', { method: 'GET', headers: { origin: 'http://127.0.0.1:43120' } })
  ok('Origin 与 Host 同源 → 放行', () => { assert.equal(sameOrigin.status, 200) })
  const lookalike = await call(H.routes, PREFIX + '/state.json', { method: 'GET', headers: { host: '127.0.0.1.evil.com' } })
  ok('相似域名 127.0.0.1.evil.com → 403（逐段校验生效）', () => { assert.equal(lookalike.status, 403) })
  const noHost = await call(H.routes, PREFIX + '/state.json', { method: 'GET', headers: { host: '' } })
  ok('缺 Host → 403', () => { assert.equal(noHost.status, 403) })

  console.log('\n⑤ tapIndex（web 形态注入）')
  ok('注册了 1 个 tapIndex', () => { assert.equal(H.taps.length, 1) })
  ok('往 </body> 前插 <script defer src="/dsh-pet/ui.js">', () => {
    const out = H.taps[0]('<html><body><div>x</div></body></html>')
    assert.ok(out.indexOf('<script defer src="/dsh-pet/ui.js"></script></body>') >= 0, out)
  })
  ok('已有该 tag 时不重复插', () => {
    const once = H.taps[0]('<html><body></body></html>')
    const twice = H.taps[0](once)
    assert.equal(once, twice)
  })
  ok('没有 </body> 时退化为追加到末尾', () => {
    const out = H.taps[0]('<div>bare</div>')
    assert.ok(out.endsWith('</script>'))
  })

  console.log('\n⑥ 栅栏可用时委托给宿主（connection 存在）')
  const seen = []
  const H2 = buildHarness({ connection: { requestRejection(req) { seen.push(req.method); return 401 } } })
  plugin.apply(H2.root)
  const delegated = await call(H2.routes, PREFIX + '/state.json', { method: 'GET' })
  ok('宿主拦下（401）→ 原样采用 401', () => {
    assert.equal(delegated.status, 401)
    assert.deepEqual(seen, ['GET'])
  })
  const throwing = buildHarness({ connection: { requestRejection() { throw new Error('boom') } } })
  plugin.apply(throwing.root)
  const t = await call(throwing.routes, PREFIX + '/state.json', { method: 'GET' })
  ok('宿主栅栏抛异常 → 403（fail-closed，不是静默放行）', () => { assert.equal(t.status, 403) })
})()

console.log('\n————————————————————————')
console.log('通过 ' + pass + ' 项，失败 ' + fail + ' 项')
process.exit(fail ? 1 : 0)
