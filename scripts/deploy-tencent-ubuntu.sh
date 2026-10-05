#!/usr/bin/env bash
# ============================================================================
# 卫戍协议：盟约 · Stronghold Protocol: Alliance
# Ubuntu 一键部署：在 /opt/apps 下克隆 → 安装依赖 → 下载素材 → systemd 常驻服务
# Ubuntu one-shot deploy: clone into /opt/apps → deps → assets → systemd service
#
# 一键用法（腾讯云 Ubuntu 22.04 / 24.04，ubuntu 用户）：
#   cd /opt/apps
#   sudo bash deploy.sh                 # 本脚本；默认端口 8083
#
# 默认值（都可以用环境变量覆盖）：
#   REPO_URL      https://github.com/Wwhqqqq/StrongholdPrptocol.git
#   BRANCH        master
#   APP_DIR       /opt/apps/StrongholdPrptocol        ← 克隆到这里
#   PORT          8083                               ← 记得在腾讯云安全组放行该端口
#   SERVICE_USER  触发 sudo 的用户（一般是 ubuntu）
#   NODE_MAJOR    22
#   SP_GH_PROXY   内地直连 raw.githubusercontent.com 被墙时的 GitHub 镜像，按顺序回退
#   SKIP_ASSETS   设为 1 时跳过 270 MB 素材下载（磁盘紧张时用；游戏用替代图仍可玩）
#
# 覆盖示例：
#   sudo PORT=9000 bash deploy.sh
#   sudo APP_DIR=/opt/apps/game bash deploy.sh
#   sudo REPO_URL=https://ghfast.top/https://github.com/Wwhqqqq/StrongholdPrptocol.git bash deploy.sh
#
# 资源占用：代码 40 MB + 依赖 90 MB + 素材 270 MB，合计 < 1 GB；
#   内存 1 GB 可跑（推荐 2 GB），1~2 核即可（战斗在玩家浏览器里模拟，服务器很轻）。
#   注意：每位玩家首次进入游戏要从服务器下载数十 MB 素材（之后走浏览器缓存），
#   公网带宽 1 Mbps 会非常慢，建议 ≥ 5 Mbps 或按流量计费（素材流量会计费）。
#
# 幂等：可重复执行 —— 已存在的仓库会更新，素材会续传，服务会重启。
# ============================================================================
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Wwhqqqq/StrongholdPrptocol.git}"
BRANCH="${BRANCH:-master}"
APP_DIR="${APP_DIR:-/opt/apps/StrongholdPrptocol}"
PORT="${PORT:-8083}"
SERVICE_NAME="${SERVICE_NAME:-stronghold-protocol}"
NODE_MAJOR="${NODE_MAJOR:-22}"
GH_PROXY_LIST="${SP_GH_PROXY:-https://ghfast.top/,https://gh-proxy.com/,https://ghproxy.net/}"
SKIP_ASSETS="${SKIP_ASSETS:-0}"

log()  { printf '\033[36m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[deploy]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[deploy] 失败：%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 或 sudo 运行：sudo bash $0"

# 运行账号：显式指定 -> 触发 sudo 的用户 -> ubuntu -> 专用系统账号
if [ -z "${SERVICE_USER:-}" ]; then
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    SERVICE_USER="$SUDO_USER"
  elif id -u ubuntu >/dev/null 2>&1; then
    SERVICE_USER="ubuntu"
  else
    SERVICE_USER="stronghold"
  fi
fi

# ---------------------------------------------------------------------------
# 1. 基础软件包
# ---------------------------------------------------------------------------
log "安装基础软件包（git / curl / ca-certificates / xz-utils / sudo）…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends git curl ca-certificates xz-utils sudo

# ---------------------------------------------------------------------------
# 2. Node.js ≥ 22（已满足则跳过）
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

# ---------------------------------------------------------------------------
# 4. 克隆 / 更新代码到 $APP_DIR
# ---------------------------------------------------------------------------
PARENT_DIR="$(dirname "$APP_DIR")"
install -d "$PARENT_DIR"

# 磁盘预检：代码 + 依赖约 150 MB；素材另需约 300 MB（含解压/临时文件留余量）
if [ "$SKIP_ASSETS" = "1" ]; then NEED_MB=800; else NEED_MB=1600; fi
FREE_MB="$(df -Pk "$PARENT_DIR" | awk 'NR==2 {print int($4/1024)}')"
if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt "$NEED_MB" ]; then
  die "磁盘空间不足：$PARENT_DIR 所在分区只剩 ${FREE_MB} MB，本次部署需要约 ${NEED_MB} MB。
  处理办法（任选）：
   1) 清理空间：sudo apt-get clean && sudo journalctl --vacuum-size=200M；再看看 df -h / df -i
   2) 扩容云硬盘：控制台扩容后执行 sudo growpart /dev/vda 1 && sudo resize2fs /dev/vda1
   3) 先跳过素材（约省 270 MB，游戏用替代图仍可玩）：sudo SKIP_ASSETS=1 bash $0"
fi

if [ -e "$APP_DIR" ] && [ ! -d "$APP_DIR/.git" ]; then
  die "目录 $APP_DIR 已存在且不是 git 仓库。请先移走它，或改用 APP_DIR=/opt/apps/<别的名字>。"
fi

if [ -d "$APP_DIR/.git" ]; then
  log "更新已有仓库 $APP_DIR（分支 $BRANCH）…"
  git -C "$APP_DIR" fetch --prune origin
  git -C "$APP_DIR" checkout -B "$BRANCH" "origin/$BRANCH"
  git -C "$APP_DIR" reset --hard "origin/$BRANCH"
else
  log "克隆 $REPO_URL （分支 $BRANCH）到 $APP_DIR …"
  cloned=0
  for base in "" $(printf '%s\n' "$GH_PROXY_LIST" | tr ',' ' '); do
    url="${base:+${base%/}/}${REPO_URL}"
    if git clone --branch "$BRANCH" --depth 1 "$url" "$APP_DIR"; then cloned=1; break; fi
    warn "克隆失败，换下一个源：$url"
    rm -rf "$APP_DIR"
  done
  [ "$cloned" = 1 ] || die "克隆失败。可试：sudo REPO_URL=<镜像地址> bash $0"
fi
chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_DIR"

# 以运行账号在项目目录里执行命令
app_run() { sudo -u "$SERVICE_USER" -H -- bash -lc "cd '$APP_DIR' && $*"; }

# ---------------------------------------------------------------------------
# 5. 依赖（npm ci；postinstall 会把 pixi / preact / three 复制到 public/vendor）
# ---------------------------------------------------------------------------
log "安装 npm 依赖（约 90 MB）…"
app_run "npm ci --no-audit --no-fund" || app_run "npm install --no-audit --no-fund"

# ---------------------------------------------------------------------------
# 6. 美术 / 音频素材（约 270 MB，可中断续传）
#    内地服务器直连 raw.githubusercontent.com 会被墙：先直连，失败自动走 GitHub 镜像。
#    若本机已有一份完整的 public/assets，也可以直接同步过来，跳过这一步：
#      rsync -az --progress ./public/assets/ ubuntu@111.229.87.157:/opt/apps/StrongholdPrptocol/public/assets/
# ---------------------------------------------------------------------------
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" "$APP_DIR/.cache"
cat > "$APP_DIR/.cache/gh-proxy-preload.mjs" <<'PRELOAD'
// 直连失败时自动回退到 GitHub 加速镜像（仅作用于 raw.githubusercontent.com）。
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

if [ "$SKIP_ASSETS" = "1" ]; then
  warn "SKIP_ASSETS=1：已跳过素材下载（约 270 MB）。客户端会使用替代图 / 静音，之后随时可以不带这个参数重跑本脚本补全。"
else
  log "下载美术 / 音频素材（约 270 MB，可中断后续传）…"
  # 个别敌方图标上游本身就缺失（客户端会自动回退），因此这里忽略退出码。
  app_run "SP_GH_PROXY='$GH_PROXY_LIST' node --import ./.cache/gh-proxy-preload.mjs tools/fetch-assets.mjs" || \
    warn "素材未全部完成（多为上游缺文件），可重跑本脚本续传；游戏仍可运行，缺的用替代图。"
fi

# ---------------------------------------------------------------------------
# 7. systemd 常驻服务
# ---------------------------------------------------------------------------
NODE_BIN="$(command -v node)"
log "写入 systemd 单元 /etc/systemd/system/${SERVICE_NAME}.service （端口 ${PORT}）…"
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
# 8. 防火墙（ufw 开着才处理；腾讯云还需在控制台「安全组 / 防火墙」放行端口）
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
  warn "健康检查未通过：journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
fi

PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
cat <<SUMMARY

=================== 部署完成 ===================
代码目录  : ${APP_DIR}
端口      : ${PORT}
运行账号  : ${SERVICE_USER}
服务状态  : systemctl status ${SERVICE_NAME}
实时日志  : journalctl -u ${SERVICE_NAME} -f
本机访问  : http://127.0.0.1:${PORT}
公网访问  : http://${PUBLIC_IP:-<服务器公网IP>}:${PORT}
健康检查  : http://${PUBLIC_IP:-<服务器公网IP>}:${PORT}/healthz
玩家入口  : 打开上面的公网地址 → 输入昵称 → 同盟模拟 → 创建房间，把 4 位同盟密钥发给朋友
资源占用  : 磁盘 < 1 GB（代码 40 MB + 依赖 90 MB + 素材 270 MB）；内存空闲约 100 MB

❗ 还需要在腾讯云控制台放行端口，否则外网打不开：
   实例 → 安全组（轻量服务器是「防火墙」）→ 添加入站规则 → TCP ${PORT} → 允许 0.0.0.0/0

常用命令：
  更新代码 : cd /opt/apps && sudo bash deploy.sh
  改端口   : sudo PORT=9000 bash deploy.sh
  重启/停止: systemctl restart|stop ${SERVICE_NAME}
  反代(可选): Nginx 转发到 127.0.0.1:${PORT}，记得转发 WebSocket（路径 /ws）
===============================================
SUMMARY
