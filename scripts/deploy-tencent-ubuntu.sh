#!/usr/bin/env bash
# ============================================================================
# 卫戍协议：盟约 · Stronghold Protocol: Alliance
# 腾讯云 Ubuntu 一键部署脚本：克隆 → 依赖 → 素材 → systemd 常驻服务
# Tencent Cloud Ubuntu one-shot deploy: clone → deps → assets → systemd service
#
# 支持系统：Ubuntu 22.04 / 24.04（x86_64 或 arm64 均可）
# 用法（root 或 sudo）：
#   sudo bash scripts/deploy-tencent-ubuntu.sh
#   # 或者先克隆再跑：
#   git clone <仓库地址> /opt/stronghold-protocol && cd /opt/stronghold-protocol
#   sudo bash scripts/deploy-tencent-ubuntu.sh
#
# 可用环境变量覆盖默认值：
#   REPO_URL=https://github.com/Wwhqqqq/StrongholdPrptocol.git
#   BRANCH=master            APP_DIR=/opt/stronghold-protocol
#   PORT=3000                SERVICE_NAME=stronghold-protocol
#   SERVICE_USER=stronghold  NODE_MAJOR=22
#   SP_GH_PROXY="https://ghfast.top/,https://gh-proxy.com/,https://ghproxy.net/"
#     ↑ 内地服务器直连 raw.githubusercontent.com 被墙时的 GitHub 加速镜像（按顺序回退）
#
# 磁盘/内存参考：主程序 + 依赖 ≈ 90 MB，美术/音频素材 ≈ 270 MB，整机占用 < 1 GB。
#   系统盘 ≥ 20 GB、内存 ≥ 1 GB（推荐 2 GB）即可；战斗在玩家浏览器里模拟，服务器很轻。
#   注意：每位玩家首次进入游戏要从服务器下载素材（数十 MB ~ 270 MB，之后走浏览器缓存），
#   公网带宽 1 Mbps 会非常慢，建议 ≥ 5 Mbps 或按流量计费（素材流量会计费）。
#
# 重跑：脚本是幂等的 —— 已存在的仓库会 git pull 更新，素材会续传，服务会重启。
# ============================================================================
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Wwhqqqq/StrongholdPrptocol.git}"
BRANCH="${BRANCH:-master}"
APP_DIR="${APP_DIR:-/opt/stronghold-protocol}"
PORT="${PORT:-3000}"
SERVICE_NAME="${SERVICE_NAME:-stronghold-protocol}"
SERVICE_USER="${SERVICE_USER:-stronghold}"
NODE_MAJOR="${NODE_MAJOR:-22}"
GH_PROXY_LIST="${SP_GH_PROXY:-https://ghfast.top/,https://gh-proxy.com/,https://ghproxy.net/}"

log()  { printf '\033[36m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[deploy]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[deploy] 失败：%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 或 sudo 运行：sudo bash $0"

# ---------------------------------------------------------------------------
# 1. 基础软件包
# ---------------------------------------------------------------------------
log "安装基础软件包（git / curl / ca-certificates / xz-utils / sudo）…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends git curl ca-certificates xz-utils sudo

# ---------------------------------------------------------------------------
# 2. Node.js（≥ 22；已满足则跳过）
# ---------------------------------------------------------------------------
node_ok() {
  command -v node >/dev/null 2>&1 &&
    node -e "process.exit(Number(process.versions.node.split('.')[0])>=${NODE_MAJOR}?0:1)"
}
if node_ok; then
  log "已安装 Node.js $(node -v)，跳过。"
else
  log "安装 Node.js ${NODE_MAJOR}.x（NodeSource）…"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource_setup.sh
  bash /tmp/nodesource_setup.sh
  apt-get install -y nodejs
  node_ok || die "Node.js 安装失败，请手动安装 ${NODE_MAJOR} LTS 后重跑。"
  log "Node.js $(node -v) / npm $(npm -v)"
fi

# ---------------------------------------------------------------------------
# 3. 运行账号
# ---------------------------------------------------------------------------
if id -u "$SERVICE_USER" >/dev/null 2>&1; then
  log "运行账号 $SERVICE_USER 已存在。"
else
  log "创建系统账号 $SERVICE_USER …"
  useradd --system --create-home --home-dir "/var/lib/${SERVICE_USER}" \
    --shell /usr/sbin/nologin "$SERVICE_USER"
fi
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" "$APP_DIR"

# ---------------------------------------------------------------------------
# 4. 拉取代码（克隆 / 更新）
# ---------------------------------------------------------------------------
if [ -d "$APP_DIR/.git" ]; then
  log "更新已有仓库：git fetch + reset --hard origin/$BRANCH"
  git -C "$APP_DIR" fetch --prune origin
  git -C "$APP_DIR" checkout -B "$BRANCH" "origin/$BRANCH"
  git -C "$APP_DIR" reset --hard "origin/$BRANCH"
else
  log "克隆 $REPO_URL （分支 $BRANCH）到 $APP_DIR …"
  git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$APP_DIR"
fi
chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_DIR"

as_user() { sudo -u "$SERVICE_USER" -H bash -lc "cd '$APP_DIR' && $*"; }

# ---------------------------------------------------------------------------
# 5. 依赖（npm ci；postinstall 会把 pixi / preact / three 复制到 public/vendor）
# ---------------------------------------------------------------------------
log "安装 npm 依赖（约 90 MB）…"
as_user "npm ci --no-audit --no-fund" || as_user "npm install --no-audit --no-fund"

# ---------------------------------------------------------------------------
# 6. 美术 / 音频素材（约 270 MB，可中断续传）
#    内地服务器直连 raw.githubusercontent.com 会被墙，这里先直连、失败自动走 GitHub 镜像。
#    如果本机已经有一份完整的 public/assets，也可以直接同步过来，跳过这一步：
#      rsync -az --delete ./public/assets/ root@<服务器>:$APP_DIR/public/assets/
# ---------------------------------------------------------------------------
if [ -f "$APP_DIR/data/assets.json" ] && [ -d "$APP_DIR/public/assets" ]; then
  log "准备素材下载（直连 GitHub，失败自动回退镜像：$GH_PROXY_LIST）…"
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" "$APP_DIR/.cache"
  cat > "$APP_DIR/.cache/gh-proxy-preload.mjs" <<'PRELOAD'
// 直连失败时自动回退到 GitHub 加速镜像（仅用于 raw.githubusercontent.com）。
// 由 scripts/deploy-tencent-ubuntu.sh 生成，位于 .cache/（不纳入版本控制）。
const PROXIES = (process.env.SP_GH_PROXY ||
  'https://ghfast.top/,https://gh-proxy.com/,https://ghproxy.net/')
  .split(',').map((s) => s.trim()).filter(Boolean);

const RAW = 'https://raw.githubusercontent.com/';
const original = globalThis.fetch.bind(globalThis);

globalThis.fetch = async function patchedFetch(input, init) {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input?.url;
  if (typeof url !== 'string' || !url.startsWith(RAW)) return original(input, init);

  try {
    const direct = await original(input, init);        // 服务器能直连时走直连
    if (direct.ok || (direct.status !== 404 && direct.status < 500)) return direct;
    try { await direct.body?.cancel(); } catch { /* ignore */ }
  } catch { /* 直连失败，继续走镜像 */ }

  let lastErr;
  let lastRes;
  for (const proxy of PROXIES) {
    const target = proxy.replace(/\/+$/, '') + '/' + url;
    try {
      const res = await original(target, init);
      if (res.ok || (res.status !== 404 && res.status < 500)) return res;
      try { await res.body?.cancel(); } catch { /* ignore */ }
      lastRes = res;
    } catch (e) { lastErr = e; }
  }
  if (lastRes) return lastRes;
  throw lastErr || new Error('all sources failed for ' + url);
};
PRELOAD
  chown "$SERVICE_USER:$SERVICE_USER" "$APP_DIR/.cache/gh-proxy-preload.mjs"
  # 个别敌方图标上游本身就缺失（客户端会自动回退），因此这里忽略退出码。
  as_user "SP_GH_PROXY='$GH_PROXY_LIST' node --import ./.cache/gh-proxy-preload.mjs tools/fetch-assets.mjs" || \
    warn "素材下载未全部完成（多为上游缺文件），可稍后重跑本脚本续传；游戏仍可运行。"
else
  warn "未找到 data/assets.json，跳过素材下载。"
fi

# ---------------------------------------------------------------------------
# 7. systemd 常驻服务
# ---------------------------------------------------------------------------
NODE_BIN="$(command -v node)"
log "写入 systemd 单元 /etc/systemd/system/${SERVICE_NAME}.service …"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<UNIT
[Unit]
Description=Stronghold Protocol: Alliance (unofficial fan remake)
Documentation=https://github.com/Wwhqqqq/StrongholdPrptocol
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${APP_DIR}
Environment=NODE_ENV=production
Environment=PORT=${PORT}
Environment=HOST=0.0.0.0
Environment=SP_NO_BROWSER=1
ExecStart=${NODE_BIN} server/index.js
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# ---------------------------------------------------------------------------
# 8. 防火墙（ufw 开启时才处理；腾讯云还需要在控制台「安全组」放行端口）
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
  log "放行 ufw 端口 ${PORT}/tcp …"
  ufw allow "${PORT}/tcp" || true
fi

# ---------------------------------------------------------------------------
# 9. 自检 + 输出
# ---------------------------------------------------------------------------
sleep 2
if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null; then
  log "健康检查通过：http://127.0.0.1:${PORT}/healthz"
else
  warn "健康检查未通过，查看日志：journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
fi

PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
cat <<SUMMARY

================= 部署完成 =================
目录      : ${APP_DIR}
服务      : systemctl status ${SERVICE_NAME}
日志      : journalctl -u ${SERVICE_NAME} -f
本机访问  : http://127.0.0.1:${PORT}
公网访问  : http://${PUBLIC_IP:-<服务器公网IP>}:${PORT}
玩家入口  : 把上面的公网地址发给朋友，创建「同盟模拟」房间后分享 4 位同盟密钥
资源占用  : 磁盘 < 1 GB（代码 30 MB + 依赖 90 MB + 素材 270 MB）；内存空闲约 100 MB

还要做两件事玩家才能连进来：
  1. 腾讯云控制台 → 该实例「安全组」→ 放行 TCP ${PORT}（生产环境建议只放行 80/443，用 Nginx 反代）
  2. 用 Nginx + HTTPS 反代时记得转发 WebSocket（路径 /ws）：
     proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade";

常用命令：
  更新到最新代码 : REPO_URL=... sudo bash ${APP_DIR}/scripts/deploy-tencent-ubuntu.sh
  重启 / 停止    : systemctl restart|stop ${SERVICE_NAME}
  换端口         : sudo PORT=8080 bash ${APP_DIR}/scripts/deploy-tencent-ubuntu.sh
===========================================
SUMMARY
