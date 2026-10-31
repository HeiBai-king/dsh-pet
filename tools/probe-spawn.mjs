// probe-spawn.mjs -- 用不同 spawn 选项起 pet-ball.ps1，看哪种能让窗口真的活下来
import { spawn } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const BALL = path.resolve(HERE, '..', 'assets', 'pet-ball.ps1')

const variants = [
  { name: 'D plain ignore',              opts: { stdio: 'ignore' } },
  { name: 'E plain ignore + hideWindow', opts: { stdio: 'ignore', windowsHide: true } },
  { name: 'F detached + hideWindow=false', opts: { detached: true, stdio: 'ignore', windowsHide: false } },
  { name: 'G plain ignore + hideWindow (again, 复查)', opts: { stdio: 'ignore', windowsHide: true } },
]

function run(v) {
  return new Promise((resolve) => {
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', BALL, '-NoPidFile']
    const c = spawn('powershell', args, v.opts)
    let out = ''
    if (c.stdout) c.stdout.on('data', (d) => { out += d })
    if (c.stderr) c.stderr.on('data', (d) => { out += '[err]' + d })
    c.on('error', (e) => resolve({ ...v, err: e.message }))
    const t0 = Date.now()
    c.on('exit', (code) => resolve({ ...v, code, ms: Date.now() - t0, out }))
    // 6 秒还活着 = 成功（窗口活着）
    setTimeout(async () => {
      if (c.exitCode === null) {
        resolve({ ...v, code: 'ALIVE', ms: Date.now() - t0, out })
        try { c.kill() } catch {}
      }
    }, 6000)
  })
}

for (const v of variants) {
  const r = await run(v)
  console.log(`--- ${v.name}`)
  console.log(`    exit=${r.code} ms=${r.ms}${r.err ? ' err=' + r.err : ''}`)
  if (r.out) console.log('    stdout: ' + JSON.stringify(r.out.slice(0, 300)))
  await new Promise((r) => setTimeout(r, 1200))
}
