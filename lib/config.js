// ============================================================================
// dsh-pet 配置中心
// ============================================================================
// 一个文件：$DSH_HOME\pet\config.json
//
// 取值优先级：**环境变量 > config.json > 内置默认**
//   —— 环境变量优先是为了让测试床（端口 3099 + 独立 DSH_HOME + 一堆 DSHW_PET_* 覆盖）
//      不用改用户的配置文件就能跑；日常用就改 config.json。
//
// 文件不存在时**不会**自动创建 —— 写文件这种事不该在插件加载路径上偷偷发生。
// 想看它长什么样、想改，跑：node tools/write-config.mjs
// ============================================================================

import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'

export const DSH_HOME = process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
export const DATA_DIR = path.join(DSH_HOME, 'pet')
export const CONFIG_FILE = path.join(DATA_DIR, 'config.json')

// 每条都写了注释，但 JSON 不支持注释，所以说明放在这里 / 也放在 write-config 的输出里
export const DEFAULTS = {
  v: 1,

  // （cdpPort / targetHint / rulesFile / tavernDir / autoVision 都已随数据端移除。
  //   公共版不读页面、不带规则表、不会自己截你的屏 —— 截图只由你点按钮触发。）

  // —— 「问一下」投给哪个会话 ——
  // 留空 = 从 $DSH_HOME\bot\state.json 里解析主 Bot 当前那段会话。
  // **没有写死的兜底 id** —— 解析不出来就报错，不会投到一段可能早已不存在的会话。
  askSession: '',

  // 「选择会话…」里只显示这几个**工作区**（按 DSH 侧边栏的显示名，来自 storages\workspace.json）。
  // **留空 = 全部显示** —— 这是给所有人用的默认值，别人的工作区不叫这个。
  // 想只看某几个就填名字，例如 ['工作', '测试']。
  pickWorkspaces: [],

  // —— 宿主路由的外发白名单（插件自带回环/同源栅栏之外的额外放行）——
  // 只在"DSH 部署在非回环地址"时才需要填。例如 ['myhost.local:43120']
  trustedHosts: [],

  // —— 桌面球 ——
  ball: {
    // 用 SetWindowRgn 把窗口裁成鲸鱼形状。**默认 false**：
    // 实测普通 AllowsTransparency 窗口本来就自带逐像素跨进程穿透（alpha=0 的像素放行鼠标），
    // 裁区域是净损失 —— 抗锯齿边缘被 1 位区域切出硬边，而且微软明说复杂 region 会闪烁。
    useRegion: false,
    // 插件加载后**自动把球叫出来**（默认 true）。
    // 理由：胶囊靠页面注入，而注入表只在页面渲染时收集一次 —— 插件加载晚就永远赶不上，
    // 那时用户会看到"什么都没有"。球不依赖页面，所以让它自己出来兜底。
    // 嫌球一开 DSH 就冒出来，就写成 false，改成点胶囊叫。
    autoStart: true,
  },
}

function pickEnv(...names) {
  for (const n of names) {
    const v = process.env[n]
    if (v !== undefined && v !== '') return v
  }
  return undefined
}

function num(v, fallback) {
  const n = Number(v)
  return Number.isFinite(n) ? n : fallback
}

// 环境变量是字符串，'0' / 'false' 都算关；没给就退回文件值，再没有就用默认
function boolOf(envValue, fileValue, fallback) {
  if (envValue !== undefined) return envValue !== '0' && envValue !== 'false' && envValue !== 'no'
  if (typeof fileValue === 'boolean') return fileValue
  return !!fallback
}

function fileConfig() {
  try {
    const j = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'))
    return j && typeof j === 'object' ? j : {}
  } catch (err) { return {} }
}

export function loadConfig() {
  const raw = fileConfig()
  const ball = (raw.ball && typeof raw.ball === 'object') ? raw.ball : {}

  const cfg = {
    v: num(raw.v, DEFAULTS.v),

    askSession: String(pickEnv('DSHW_PET_ASK_SESSION') ?? raw.askSession ?? DEFAULTS.askSession),

    // ⚠️ 光在 DEFAULTS 里加字段是**不够的** —— loadConfig() 是逐字段手拼 cfg 的，
    //    没在这里列出来的字段就不会往外传。2026-10-31 就踩了这个坑：
    //    DEFAULTS 加了 pickWorkspaces，这里没加 → dump 日志一直是"跳过其他工作区 0"，
    //    选择框里 QQ 聊天 / 未分组 照样冒出来。
    pickWorkspaces: (() => {
      const env = pickEnv('DSHW_PET_PICK_WORKSPACES')
      if (env) return env.split(',').map((s) => s.trim()).filter(Boolean)
      if (Array.isArray(raw.pickWorkspaces)) return raw.pickWorkspaces.map(String)
      return DEFAULTS.pickWorkspaces
    })(),

    trustedHosts: (() => {
      const env = pickEnv('DSHW_PET_TRUSTED_HOSTS')
      if (env) return env.split(',').map((s) => s.trim()).filter(Boolean)
      if (Array.isArray(raw.trustedHosts)) return raw.trustedHosts.map(String)
      return DEFAULTS.trustedHosts.slice()
    })(),

    ball: {
      useRegion: boolOf(pickEnv('DSHW_PET_USE_REGION'), ball.useRegion, DEFAULTS.ball.useRegion),
      // ⚠️ 这个字段必须在 loadConfig 里显式列出 —— loadConfig 是逐字段手拼的，
      //    DEFAULTS 里加了但这里没加，外面就永远拿到 undefined（2026-10-31 在 pickWorkspaces 上栽过一次）。
      autoStart: boolOf(pickEnv('DSHW_PET_AUTO_START_BALL'), ball.autoStart, DEFAULTS.ball.autoStart),
    },
  }

  return cfg
}

export const CONFIG = loadConfig()

// 把当前生效的配置（含各值的来源）整理出来，给 tools/write-config.mjs 和排障用
export function explainConfig() {
  const f = fileConfig()
  const rows = [
    ['askSession', CONFIG.askSession || '(自动解析)', pickEnv('DSHW_PET_ASK_SESSION') ?? f.askSession ?? '(默认)'],
    ['pickWorkspaces', CONFIG.pickWorkspaces.length ? CONFIG.pickWorkspaces.join(', ') : '(空 = 全部工作区)',
      pickEnv('DSHW_PET_PICK_WORKSPACES') ?? (Array.isArray(f.pickWorkspaces) ? f.pickWorkspaces.join(', ') : '(默认)')],
    ['ball.useRegion', CONFIG.ball.useRegion, pickEnv('DSHW_PET_USE_REGION') ?? f.ball?.useRegion ?? '(默认)'],
    ['trustedHosts', CONFIG.trustedHosts.join(',') || '(空)', pickEnv('DSHW_PET_TRUSTED_HOSTS') ?? (Array.isArray(f.trustedHosts) ? f.trustedHosts.join(',') : '(默认)')],
  ]
  return { CONFIG_FILE, DSH_HOME, DATA_DIR, rows, exists: fs.existsSync(CONFIG_FILE) }
}
