/* dsh-pet —— 浏览器半区：页面入口胶囊（官方 dsh.client / slot 路线）
 *
 * 一个**很小的鲸鱼图标**，浮在 DSH 页面右下角（位置可拖，会记住）。
 *   左键  → 叫出 / 收回桌面鲸鱼球（球浮在所有窗口之上，看酒馆也在）
 *   右键拖动 → 挪胶囊的位置（松开即记住）
 *
 * 设计取舍（2026-10-13 按用户要求改的）：
 *   - **删掉「指导」两个字的文字**，只留鲸鱼图标（用户嫌丑）
 *   - **「问一下」不放这儿了，挪到桌面球上**。理由：胶囊在 DSH 页面里，
 *     而「问一下」的用处恰恰是"人不在 DSH 页面时"（比如在酒馆里）—— 放在胶囊上够不着；
 *     在 DSH 页面里又不需要它（直接说话就行）。
 *   - **页面气泡去掉**。它显示的内容和桌面球完全一样，而桌面球才是能一直看见的那个。
 *   - **所有闪现文字都去掉**（"位置已记住" / "开" / "关"）—— 用户说"不要这玩意"。
 *     点了有没有生效，看球出没出来就知道，不需要胶囊再喊一嗓子。
 *   - **边框不再随运行状态变绿** —— 固定一种颜色。用户说"为什么胶囊有绿色边框，不要"。
 *
 * ⚠️ 桌面端（Electron）的槽位路线已实测可用；assets/pet-ui.js 那条手写注入**保留**当兜底，
 *    它先检查 window.__dshPetSlot —— 这个标志由 Capsule 组件**挂载成功时**置位（不是 apply 里），
 *    所以槽位不可用时兜底路一定顶得上。那边等一会儿没等到才自己挂载。
 *    两条路只会有一条真正生效。
 *
 * 格式来自官方模板：
 *   ...\dsh-agent-preset\skills\cordis-plugin-development\templates\decoration\client.js
 */
window.__ModuleLoader__.load({
  id: 'dsh-pet',
  factory(require) {
    const React = require('react')
    const h = React.createElement
    const { useState, useEffect, useRef, useCallback } = React

    const API = '/dsh-pet'
    const PKEY = 'dsh-pet-capsule-pos'
    const SIZE = 30                                  // 胶囊是 30×30 的圆

    const clamp = (l, t) => {
      const vw = window.innerWidth || 1280
      const vh = window.innerHeight || 800
      return {
        l: Math.min(Math.max(l, 0), Math.max(0, vw - SIZE)),
        t: Math.min(Math.max(t, 0), Math.max(0, vh - SIZE)),
      }
    }

    function Capsule() {
      const [pos, setPos] = useState(null)           // {l,t}；null = 用默认右下角
      const dragRef = useRef(null)
      const pillRef = useRef(null)

      // ⚠️ 这个标志**必须等组件真的挂上才置位**，不能在 apply() 里无条件设。
      //    理由：assets/pet-ui.js 那条手写兜底就是靠它判断"该不该让位"。
      //    如果槽位名在这次 DSH 版本里改了、注册静默失败，而标志却已经置位 ——
      //    兜底路会让位、槽位又不渲染，最后**什么都不显示，而且不报错**（最难查的那种）。
      //    挪到这里就等价于"槽位真的能用"；槽位不能用时兜底会自己顶上。
      useEffect(() => {
        try { window.__dshPetSlot = true } catch (e) {}
      }, [])

      // —— 位置记忆 ——
      useEffect(() => {
        try {
          const p = JSON.parse(localStorage.getItem(PKEY) || 'null')
          if (p && typeof p.l === 'number' && typeof p.t === 'number') setPos(clamp(p.l, p.t))
        } catch (e) {}
      }, [])

      // —— 左键：开关桌面球 ——
      // ⚠️ 防抖：宿主起球要等最多 12.5 秒才回包（球是 PowerShell + WPF，起得慢）。
      //    机器一卡，用户会以为没反应、连点好几下 —— 宿主那边虽然也加了起进程锁，
      //    但这里再挡一层，别让请求风暴打到宿主上。
      const busyRef = useRef(false)
      const onToggle = useCallback(() => {
        if (busyRef.current) return
        busyRef.current = true
        fetch(API + '/ball/toggle', { method: 'POST', cache: 'no-store' })
          .then((r) => (r.ok ? r.json() : null))
          .catch(() => {})
          .then(() => { setTimeout(() => { busyRef.current = false }, 1500) })
      }, [])

      // —— 右键拖动：按住右键移动，松开记住位置 ——
      // 用 pointer capture，比在 window 上挂 mousemove 稳（React 里尤其）
      const onDown = useCallback((e) => {
        if (e.button !== 2) return                  // 只认右键
        e.preventDefault()
        const el = pillRef.current
        if (!el) return
        const r = el.getBoundingClientRect()
        try { e.currentTarget.setPointerCapture(e.pointerId) } catch (err) {}
        dragRef.current = { sx: e.clientX, sy: e.clientY, l: r.left, t: r.top, moved: false, id: e.pointerId }
      }, [])

      const onMove = useCallback((e) => {
        const d = dragRef.current
        if (!d || d.id !== e.pointerId) return
        const dx = e.clientX - d.sx
        const dy = e.clientY - d.sy
        if (!d.moved && Math.abs(dx) + Math.abs(dy) < 4) return   // 4px 以内当没动
        d.moved = true
        setPos(clamp(d.l + dx, d.t + dy))
      }, [])

      const onUp = useCallback((e) => {
        const d = dragRef.current
        if (!d || d.id !== e.pointerId) return
        dragRef.current = null
        if (!d.moved) return
        try {
          const el = pillRef.current
          if (el) {
            const r = el.getBoundingClientRect()
            localStorage.setItem(PKEY, JSON.stringify({ l: r.left, t: r.top }))
          }
        } catch (err) {}
      }, [])

      // 右键菜单要吃掉，不然会弹出浏览器自己的菜单
      const onCtx = useCallback((e) => { e.preventDefault() }, [])

      const box = pos
        ? { left: pos.l + 'px', top: pos.t + 'px', right: 'auto', bottom: 'auto' }
        : { right: '16px', bottom: '74px' }

      return h('div', {
        ref: pillRef,
        'data-dshpet-ui': 'pill',
        title: '\u5DE6\u952E\uFF1A\u53EB\u51FA/\u6536\u56DE\u684C\u9762\u9CB8\u9C7C\u7403\uFF5C\u53F3\u952E\u62D6\u52A8\uFF1A\u632A\u4F4D\u7F6E',
        onPointerDown: onDown,
        onPointerMove: onMove,
        onPointerUp: onUp,
        onContextMenu: onCtx,
        onClick: (e) => { if (e.button === 0) onToggle() },
        style: Object.assign({
          position: 'fixed', zIndex: 2147483001,
          width: SIZE + 'px', height: SIZE + 'px',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          borderRadius: '50%', cursor: 'pointer', userSelect: 'none',
          background: 'rgba(38,42,52,.82)',
          border: '1px solid rgba(120,140,200,.45)',   // 固定色；以前"球在跑"会变绿
          boxShadow: '0 2px 8px rgba(0,0,0,.35)',
          fontSize: '16px', lineHeight: 1,
          pointerEvents: 'auto',
        }, box),
      }, '\uD83D\uDC0B')                              // 🐋
    }

    return {
      inject: ['slots'],
      apply(ctx) {
        // 「让兜底路让位」的标志不在这里设 —— 见 Capsule() 里的说明。
        // 这里只负责注册；注册不成（比如这次 DSH 版本改了槽位名）就让兜底路上。
        //
        // 槽位名：目前是 shell.overlay（从装好的 dsh-client-ui-layout/lib/client.js 里读出来的）。
        // 万一升级后不显示挂件了，**先查这个字符串** —— 在那边搜 slots.register( 看现有名字。
        // 想临时试别的名字：在页面控制台先设 window.__dshPetSlotName，再刷新。
        const slotName = (typeof window !== 'undefined' && window.__dshPetSlotName) || 'shell.overlay'
        if (!ctx.slots || typeof ctx.slots.inject !== 'function') {
          // 这个半区在宿主里没有 slots 服务 —— 什么都不做，兜底路会顶上
          return
        }
        try {
          ctx.slots.inject(slotName, () => ctx.slots.register({
            name: slotName,
            id: 'dsh-pet-capsule',
          }, Capsule))
        } catch (err) {
          // 槽位不存在时 inject 可能直接抛。吞掉，让兜底路顶上，别把整个 client 半区带崩。
          try { console.warn('[dsh-pet] slot ' + slotName + ' 注册失败，改用兜底胶囊:', err) } catch (e) {}
        }
      },
    }
  },
})
