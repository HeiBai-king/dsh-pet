#!/usr/bin/env bash
# test-passthrough-ab.sh -- decisive A/B on the PRODUCTION ball window.
#
# Question: does plain WPF AllowsTransparency (no SetWindowRgn) already let clicks
#           through alpha=0 pixels to another process's window?
#
# Layout (PHYSICAL px; the ball reads window.json as physical, the ground takes DIP):
#   ball   : window.json x=1000 y=400 w=500 h=500   -> physical 1000,400 .. 1500,900
#   ground : -X 667 -Y 267 -W 80 -H 80              -> physical 1000,400 .. 1120,520
#   click  : physical 1020,420  = ball-local (20,20) -> outside the alpha region (transparent)
#
# Expected if pass-through works : ground logs the click (n>=1)
# Expected if it does not       : ground logs nothing (n=0)
set -u
cd "$(dirname "$0")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v cygpath >/dev/null 2>&1 && ROOT="$(cygpath -m "$ROOT")"
PET="${PET:-$ROOT}"
WJ="${WJ:-$HOME/.dsh/pet/window.json}"
CLICKS="_probe-ground-clicks.txt"

kill_ball() {
  powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { \$_.CommandLine -match 'pet-ball\.ps1' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" >/dev/null 2>&1
}
kill_ground() {
  powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { \$_.CommandLine -match 'probe-ground\.ps1' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" >/dev/null 2>&1
}

run_case() {
  local label="$1"; shift
  kill_ball; kill_ground; sleep 1
  rm -f _probe-ground.hwnd "$CLICKS"
  printf '{"v":1,"x":1000,"y":400,"w":500,"h":500}' > "$WJ"

  # 下层窗口（它自己记录每次左键按下）
  powershell -NoProfile -ExecutionPolicy Bypass -File ./probe-ground.ps1 -X 667 -Y 267 -W 80 -H 80 -AutoCloseMs 30000 >/dev/null 2>&1 &
  for i in $(seq 1 30); do [ -f _probe-ground.hwnd ] && break; sleep 0.5; done

  # 上层：生产球
  powershell -NoProfile -ExecutionPolicy Bypass -File "$PET/assets/pet-ball.ps1" -NoPidFile "$@" >/dev/null 2>&1 &
  sleep 6

  rm -f "$CLICKS"
  # 点 1：透明处 (local 20,20) —— 期望穿透到下层
  powershell -NoProfile -ExecutionPolicy Bypass -File ./click-at.ps1 -X 1020 -Y 420 2>&1 | tail -1
  sleep 1
  local nT=0
  [ -f "$CLICKS" ] && nT=$(wc -l < "$CLICKS")
  # 点 2：鲸鱼身上 (local 420,420) —— 期望被球自己接住，下层不再增加
  powershell -NoProfile -ExecutionPolicy Bypass -File ./click-at.ps1 -X 1420 -Y 820 2>&1 | tail -1
  sleep 1
  local nO=0
  [ -f "$CLICKS" ] && nO=$(wc -l < "$CLICKS")
  echo "  [$label] transparent-pt reached ground: $([ "$nT" -gt 0 ] && echo YES || echo NO)  (n=$nT)   [expect YES]"
  echo "  [$label] opaque-pt  reached ground:      $([ "$nO" -gt "$nT" ] && echo YES || echo NO)  (n=$nO)   [expect NO]"
  cat "$CLICKS" 2>/dev/null | sed 's/^/      /'
  kill_ball
}

echo "================ A: OPT-IN SetWindowRgn (-UseRegion) ================"
run_case "use-region" -UseRegion
echo
echo "================ B: DEFAULT (no region -- plain WPF AllowsTransparency) ================"
run_case "default"

kill_ground
echo
echo "done"
