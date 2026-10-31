// write-config.mjs -- 打印当前生效的配置、各值的来源；加 --write 就把默认配置写到盘上。
//
// 用法：
//   node tools/write-config.mjs            只看（不写任何文件）
//   node tools/write-config.mjs --write    把默认配置写到 $DSH_HOME\pet\config.json
//                                          已存在就**不覆盖**，只提示（免得把你改过的冲掉）
//   加 --force 才覆盖。
import fs from 'node:fs'
import path from 'node:path'
import { explainConfig, DEFAULTS, CONFIG_FILE, DATA_DIR, DSH_HOME } from '../lib/config.js'

const argv = process.argv.slice(2)
const wantWrite = argv.includes('--write')
const force = argv.includes('--force')

const info = explainConfig()

console.log('\n[dsh-pet 配置]\n')
console.log('  DSH_HOME   ' + DSH_HOME)
console.log('  数据目录    ' + DATA_DIR)
console.log('  配置文件    ' + CONFIG_FILE + (info.exists ? '  （存在）' : '  （不存在，当前全用默认/环境变量）'))
console.log('')
for (const [key, value, src] of info.rows) {
  const shown = typeof value === 'string' ? JSON.stringify(value) : String(value)
  console.log('  ' + key.padEnd(22) + shown.padEnd(46) + ' ← ' + (src === '(默认)' ? '(默认)' : '来自 ' + src))
}
console.log('\n  优先级：环境变量 > config.json > 内置默认')

if (!wantWrite) {
  console.log('\n  （只读模式。要生成默认配置文件加 --write）\n')
  process.exit(0)
}

if (fs.existsSync(CONFIG_FILE) && !force) {
  console.log('\n  配置文件已存在，没有覆盖。要覆盖加 --force\n')
  process.exit(0)
}

// 默认配置里 rulesFile 留空的话，写上约定位置，方便用户直接看到并改
const out = JSON.parse(JSON.stringify(DEFAULTS))
if (!out.rulesFile) out.rulesFile = path.join(DSH_HOME, 'bot', 'workspace', '领航', '触发表.json')
try {
  fs.mkdirSync(DATA_DIR, { recursive: true })
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(out, null, 2) + '\n', 'utf8')
  console.log('\n  已写入 ' + CONFIG_FILE + '\n')
} catch (err) {
  console.log('\n  写入失败：' + err.message + '\n')
  process.exit(2)
}
