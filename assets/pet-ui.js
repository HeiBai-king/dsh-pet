/* dsh-pet —— 页面内入口胶囊（**手写兜底路线**）
 *
 * ⚠️ 这是**兜底**，不是首选。首选是 assets/client.js（官方 dsh.client + shell.overlay 槽位）。
 *    这条路只在槽位没生效时才挂（等 3 秒观察窗）。两条路的行为保持一致。
 *
 * 一个很小的鲸鱼图标，浮在页面右下角（位置可拖，会记住）：
 *   左键     → 叫出 / 收回桌面鲸鱼球（+ 数据端）
 *   右键拖动 → 挪位置（松开即记住）
 *
 * 和 client.js 一致的取舍（2026-10-13 按用户要求改）：
 *   - 去掉「指导」文字，只留鲸鱼（嫌丑）
 *   - 「问一下」挪到桌面球上 —— 它有用的时候恰恰是人不在 DSH 页面时（在酒馆里），
 *     放在页面胶囊上够不着；在 DSH 页面里又用不上
 *   - 页面气泡去掉（内容和桌面球重复，而球才是能一直看见的那个）
 *   - **所有闪现文字去掉**（"位置已记住" / "开" / "关"）—— 用户说"不要这玩意"
 *   - **边框不再随运行状态变绿**，固定一种颜色
 *
 * 幂等：两条注入通道（web 的 tapIndex、桌面的 index-inject 内联行）在同一宿主里**都会触发**，
 *      所以必须有 window.__dshPetUi 守卫，否则脚本被求值两次就挂出两个胶囊。
 */
(function () {
  if (window.__dshPetUi) return;
  window.__dshPetUi = true;

  var API = '/dsh-pet';
  var PKEY = 'dsh-pet-capsule-pos';
  var SIZE = 30;

  var css = document.createElement('style');
  css.textContent = [
    '#dshpet-toggle{position:fixed;right:16px;bottom:74px;z-index:2147483001;',
    '  width:' + SIZE + 'px;height:' + SIZE + 'px;display:flex;align-items:center;justify-content:center;',
    '  border-radius:50%;cursor:pointer;user-select:none;-webkit-user-select:none;',
    '  background:rgba(38,42,52,.82);border:1px solid rgba(120,140,200,.45);',
    '  box-shadow:0 2px 8px rgba(0,0,0,.35);font-size:16px;line-height:1;',
    '  transition:background .15s}',
    '#dshpet-toggle:hover{background:rgba(52,58,72,.92)}',
    '#dshpet-toggle:active{transform:scale(.94)}',
  ].join('\n');
  document.head.appendChild(css);

  var btn = document.createElement('div');
  btn.id = 'dshpet-toggle';
  btn.title = '\u5DE6\u952E\uFF1A\u53EB\u51FA/\u6536\u56DE\u684C\u9762\u9CB8\u9C7C\u7403\uFF5C\u53F3\u952E\u62D6\u52A8\uFF1A\u632A\u4F4D\u7F6E';
  btn.textContent = '\uD83D\uDC0B';                   // 🐋

  // —— 位置记忆 ——
  function clampPos(l, t) {
    var vw = window.innerWidth || 1280, vh = window.innerHeight || 800;
    return {
      l: Math.min(Math.max(l, 0), Math.max(0, vw - SIZE)),
      t: Math.min(Math.max(t, 0), Math.max(0, vh - SIZE)),
    };
  }
  function applyPos(p) {
    btn.style.left = p.l + 'px'; btn.style.top = p.t + 'px';
    btn.style.right = 'auto'; btn.style.bottom = 'auto';
  }
  function savePos() {
    try {
      var r = btn.getBoundingClientRect();
      localStorage.setItem(PKEY, JSON.stringify({ l: r.left, t: r.top }));
    } catch (e) {}
  }
  try {
    var saved = JSON.parse(localStorage.getItem(PKEY) || 'null');
    if (saved && typeof saved.l === 'number' && typeof saved.t === 'number') applyPos(clampPos(saved.l, saved.t));
  } catch (e) {}

  // —— 左键：开关桌面球（不再闪任何文字，球出没出来就是反馈） ——
  // 防抖：宿主起球要等最多 12.5 秒才回包，机器卡的时候用户会连点。
  var busy = false;
  btn.addEventListener('click', function (e) {
    if (e.button !== 0) return;
    if (busy) return;
    busy = true;
    fetch(API + '/ball/toggle', { method: 'POST', cache: 'no-store' })
      .catch(function () {})
      .then(function () { setTimeout(function () { busy = false; }, 1500); });
  });

  // —— 右键拖动 ——
  // 用 pointer 事件 + setPointerCapture：一次只跟一个指针，比在 window 上挂 mousemove 稳
  var drag = null;
  btn.addEventListener('contextmenu', function (e) { e.preventDefault(); });
  btn.addEventListener('pointerdown', function (e) {
    if (e.button !== 2) return;                      // 只认右键
    e.preventDefault();
    var r = btn.getBoundingClientRect();
    try { btn.setPointerCapture(e.pointerId); } catch (err) {}
    drag = { sx: e.clientX, sy: e.clientY, l: r.left, t: r.top, moved: false, id: e.pointerId };
  });
  btn.addEventListener('pointermove', function (e) {
    if (!drag || drag.id !== e.pointerId) return;
    var dx = e.clientX - drag.sx, dy = e.clientY - drag.sy;
    if (!drag.moved && Math.abs(dx) + Math.abs(dy) < 4) return;   // 4px 以内当没动
    drag.moved = true;
    applyPos(clampPos(drag.l + dx, drag.t + dy));
  });
  btn.addEventListener('pointerup', function (e) {
    if (!drag || drag.id !== e.pointerId) return;
    var moved = drag.moved;
    drag = null;
    try { btn.releasePointerCapture(e.pointerId) } catch (err) {}
    if (moved) savePos();
  });

  function mount() { document.body.appendChild(btn); }

  // —— 让位给官方 slot 路线 ——
  // assets/client.js（dsh.client 半区）一跑 apply() 就置 window.__dshPetSlot。
  // 它渲染出来的胶囊在 React 树里（不怕 SPA 切路由、不用抢 z-index），所以优先用它。
  // 槽位不生效时观察窗过了就自己挂。
  var WAIT_MS = 5000, waited = 0, STEP = 250;   // 放宽到 5s：槽位那边是 React 渲染，慢机器可能要等一会儿
  var waiter = setInterval(function () {
    if (window.__dshPetSlot) { clearInterval(waiter); return; }   // 有人接管了，静默退出
    waited += STEP;
    if (waited >= WAIT_MS) {
      clearInterval(waiter);
      if (window.__dshPetSlot) return;
      try { window.__dshPetFallback = true; } catch (e) {}
      if (document.body) mount();
      else document.addEventListener('DOMContentLoaded', mount);
    }
  }, STEP);
})();
