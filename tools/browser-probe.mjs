// 一次性的浏览器侧验证：新开一个标签打开目标 URL，等加载完，问页面「胶囊在不在」。
// 用法：node tools/browser-probe.mjs "<url>" ["<要 eval 的表达式>"]
const URL_ = process.argv[2]
const EXPR = process.argv[3] || `JSON.stringify({
  hasToggle: !!document.getElementById('dshpet-toggle'),
  hasWrap:   !!document.getElementById('dshpet-wrap'),
  hasStyle:  !!document.querySelector('style') && document.documentElement.outerHTML.indexOf('dshpet-toggle') >= 0,
  label:     (document.getElementById('dshpet-toggle')||{}).textContent || null,
  zIndexOf:  document.getElementById('dshpet-toggle') ? getComputedStyle(document.getElementById('dshpet-toggle')).zIndex : null,
  position:  document.getElementById('dshpet-toggle') ? (function(e){var r=e.getBoundingClientRect();return {right:Math.round(innerWidth-r.right),bottom:Math.round(innerHeight-r.bottom),w:Math.round(r.width),h:Math.round(r.height)}})(document.getElementById('dshpet-toggle')) : null,
  title:     document.title
})`

const PORT = 9222
const r = await fetch(`http://127.0.0.1:${PORT}/json/new?${encodeURIComponent(URL_)}`, { method: 'PUT' })
if (!r.ok) { console.error('开标签失败', r.status, await r.text()); process.exit(1) }
const target = await r.json()
console.log('新标签:', target.id, target.url || '')

function evaluate(wsUrl, expression, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl)
    const timer = setTimeout(() => { try { ws.close() } catch {} ; reject(new Error('超时')) }, timeoutMs)
    const done = (e, v) => { clearTimeout(timer); try { ws.close() } catch {} ; e ? reject(e) : resolve(v) }
    ws.addEventListener('error', () => done(new Error('ws 连不上')))
    ws.addEventListener('open', () => {
      ws.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { expression, returnByValue: true, awaitPromise: true } }))
    })
    ws.addEventListener('message', (ev) => {
      let m; try { m = JSON.parse(ev.data) } catch { return }
      if (m.id !== 1) return
      if (m.error) return done(new Error(JSON.stringify(m.error)))
      if (m.result?.exceptionDetails) return done(new Error(m.result.exceptionDetails.text))
      done(null, m.result?.result?.value)
    })
  })
}

// 等页面 load + 给注入脚本一点时间
await new Promise((res) => setTimeout(res, 6000))
const out = await evaluate(target.webSocketDebuggerUrl, EXPR)
console.log('结果:', out)

// 关掉标签
try { await fetch(`http://127.0.0.1:${PORT}/json/close/${target.id}`) } catch {}
