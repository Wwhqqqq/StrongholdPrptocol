#!/usr/bin/env bash
# ============================================================================
# 给卫戍协议服务器套上 HTTPS + WSS（Nginx 反代 + acme.sh 自动续期证书）
#
# 特点：用非标准端口（默认 8443）提供 HTTPS，并用 DNS 验证申请证书，
#       因此【不需要 80 端口、不需要 ICP 备案】。
#
# 用法：
#   sudo DP_Id=<你的ID> DP_Key=<你的Token> bash scripts/setup-https.sh game.example.com 8443
#   sudo bash scripts/setup-https.sh game.example.com 8443 --http     # 若 80 端口可用，用 HTTP 验证（免 API 密钥）
#
# 环境变量：
#   BACKEND_PORT  后端游戏端口，默认 8083
#   HTTPS_PORT    对外 HTTPS 端口，默认 8443
#   DP_Id/DP_Key  DNSPod（腾讯云解析）API 密钥，DNS 验证必需
#   CERT_EMAIL    证书到期通知邮箱（可选）
#   CERT_MODE     dns（默认）| http
#   BIND_LOCAL    设为 1 时，顺便把游戏后端改成只监听 127.0.0.1（只让 Nginx 访问）
#   SERVICE_NAME  systemd 服务名，默认 stronghold-protocol
#
# 前置条件：
#   1) 已有一个域名，并把 A 记录解析到本机公网 IP（脚本会帮你核对）
#   2) 腾讯云安全组放行 TCP 8443（用 --http 模式还要放行 TCP 80）
#   3) DNS 验证需要在 DNSPod 控制台创建 API Token：https://console.dnspod.cn/account/token/token
# ============================================================================
set -euo pipefail

DOMAIN="${1:-}"
HTTPS_PORT="${2:-${HTTPS_PORT:-8443}}"
BACKEND_PORT="${BACKEND_PORT:-8083}"
SERVICE_NAME="${SERVICE_NAME:-stronghold-protocol}"
CERT_EMAIL="${CERT_EMAIL:-}"
BIND_LOCAL="${BIND_LOCAL:-0}"
CERT_MODE="${CERT_MODE:-dns}"
[ "${3:-}" = "--http" ] && CERT_MODE="http"

SSL_DIR="/etc/nginx/ssl/${DOMAIN}"
SITE="/etc/nginx/sites-available/stronghold-https.conf"
ACME_HOME="/root/.acme.sh"
ACME="${ACME_HOME}/acme.sh"

log()  { printf '\033[36m[https]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[https]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[https] 失败：%s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 或 sudo 运行：sudo bash $0 <域名> [端口]"
[ -n "$DOMAIN" ] || die "缺少域名。用法：sudo bash $0 game.example.com 8443"
case "$DOMAIN" in *.*) ;; *) die "域名看起来不对：$DOMAIN" ;; esac

# ---------------------------------------------------------------------------
# 0. 前置检查：域名是否已解析到本机公网 IP
# ---------------------------------------------------------------------------
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
RESOLVED="$(getent hosts "$DOMAIN" | awk 'NR==1 {print $1}' || true)"
if [ -n "$PUBLIC_IP" ] && [ -n "$RESOLVED" ] && [ "$PUBLIC_IP" != "$RESOLVED" ]; then
  warn "域名 $DOMAIN 当前解析到 $RESOLVED，本机公网 IP 是 $PUBLIC_IP —— 不一致的话证书申请会失败。"
  warn "请到 DNSPod/域名控制台把 A 记录指向 $PUBLIC_IP，等解析生效后重跑。"
else
  log "域名解析检查：$DOMAIN -> ${RESOLVED:-（未解析）}，本机 ${PUBLIC_IP:-未知}"
fi

# ---------------------------------------------------------------------------
# 1. 依赖：nginx、git、socat、curl
# ---------------------------------------------------------------------------
log "安装 nginx / git / socat / curl …"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends nginx git socat curl ca-certificates
systemctl enable --now nginx >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 2. 写 Nginx 站点配置（先不启用，等证书就位再 reload）
#    /ws 必须转发 WebSocket 升级头，否则页面能开、进大厅就断连。
# ---------------------------------------------------------------------------
log "写入 Nginx 站点配置：$SITE"
cat > "$SITE" <<NGINX
# 由 scripts/setup-https.sh 生成 —— 卫戍协议 HTTPS/WSS 反代
server {
    listen ${HTTPS_PORT} ssl;
    listen [::]:${HTTPS_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${SSL_DIR}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    # 首次进入要下载几十 MB 素材，关掉缓冲直通后端
    proxy_buffering off;
    proxy_request_buffering off;

    location /ws {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }

    location / {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
    }
}
NGINX
ln -sf "$SITE" /etc/nginx/sites-enabled/stronghold-https.conf

# ---------------------------------------------------------------------------
# 3. 安装 acme.sh（GitHub 走镜像回退）
# ---------------------------------------------------------------------------
if [ ! -x "$ACME" ]; then
  log "安装 acme.sh …"
  TMP="$(mktemp -d)"
  cloned=0
  for src in \
    "https://ghfast.top/https://github.com/acmesh-official/acme.sh.git" \
    "https://gh-proxy.com/https://github.com/acmesh-official/acme.sh.git" \
    "https://github.com/acmesh-official/acme.sh.git"; do
    rm -rf "$TMP"; if git clone --depth 1 "$src" "$TMP" 2>/dev/null; then cloned=1; break; fi
    warn "下载失败，换源：$src"
  done
  [ "$cloned" = 1 ] || die "acme.sh 下载失败，请检查网络。"
  ( cd "$TMP" && ./acme.sh --install -m "${CERT_EMAIL:-admin@${DOMAIN}}" ) >/dev/null
  rm -rf "$TMP"
fi
[ -x "$ACME" ] || die "acme.sh 安装异常：$ACME 不存在"

# ---------------------------------------------------------------------------
# 4. 申请证书
#    dns  ：DNS-01（DNSPod API），不需要 80 端口、不怕未备案
#    http ：HTTP-01（standalone），需要 80 端口可从公网访问
# ---------------------------------------------------------------------------
if [ -f "${ACME_HOME}/${DOMAIN}_ecc/${DOMAIN}.cer" ]; then
  log "证书已存在，跳过申请（acme.sh 会在到期前自动续期并 reload nginx）。"
elif [ "$CERT_MODE" = "http" ]; then
  # standalone 模式要独占 80 端口，先把 nginx 停掉
  log "用 HTTP-01 申请证书（需要公网可达 TCP 80）…"
  systemctl stop nginx || true
  if ! "$ACME" --issue --server letsencrypt --standalone -d "$DOMAIN" --keylength ec-256; then
    systemctl start nginx || true
    die "HTTP 验证失败：确认安全组已放行 TCP 80，且 80 端口没有被别的服务占用。"
  fi
  systemctl start nginx || true
else
  [ -n "${DP_Id:-}" ] && [ -n "${DP_Key:-}" ] || die "DNS 验证需要 DP_Id / DP_Key。
  到 https://console.dnspod.cn/account/token/token 创建 API Token（ID + Token），然后：
    sudo DP_Id=<ID> DP_Key=<Token> bash $0 $DOMAIN $HTTPS_PORT
  （如果你的域名不在 DNSPod，请告诉我托管在哪家，我换成对应的验证方式。）"
  log "用 DNS-01 申请证书（DNSPod API，不需要 80 端口）…"
  DP_Id="$DP_Id" DP_Key="$DP_Key" \
    "$ACME" --issue --server letsencrypt --dns dns_dp -d "$DOMAIN" --keylength ec-256
fi

# ---------------------------------------------------------------------------
# 5. 装证书到 Nginx 目录 + 自动续期时自动 reload
# ---------------------------------------------------------------------------
log "安装证书到 $SSL_DIR …"
install -d "$SSL_DIR"
"$ACME" --install-cert -d "$DOMAIN" --ecc \
  --key-file       "${SSL_DIR}/key.pem" \
  --fullchain-file "${SSL_DIR}/fullchain.pem" \
  --reloadcmd      "systemctl reload nginx"

# ---------------------------------------------------------------------------
# 6. 校验并重载 Nginx
# ---------------------------------------------------------------------------
log "校验并重载 Nginx …"
nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------------
# 7. 可选：让游戏后端只监听 127.0.0.1（不再对外暴露 8083）
# ---------------------------------------------------------------------------
if [ "$BIND_LOCAL" = "1" ]; then
  UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
  if [ -f "$UNIT" ]; then
    log "把 $SERVICE_NAME 改成只监听 127.0.0.1 …"
    sed -i 's/^Environment=HOST=.*/Environment=HOST=127.0.0.1/' "$UNIT"
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
  else
    warn "没找到 $UNIT，跳过（先跑一次部署脚本再执行这条）。"
  fi
fi

# ---------------------------------------------------------------------------
# 8. 自检（用 --resolve 强制走本机，绕开 DNS 缓存）
# ---------------------------------------------------------------------------
sleep 2
if curl -fsS --resolve "${DOMAIN}:${HTTPS_PORT}:127.0.0.1" "https://${DOMAIN}:${HTTPS_PORT}/healthz" >/dev/null; then
  log "HTTPS 自检通过。"
  HTTPS_OK=1
else
  warn "HTTPS 自检未通过，看日志：journalctl -u nginx -n 50 --no-pager；tail -f /var/log/nginx/error.log"
  HTTPS_OK=0
fi

cat <<SUMMARY

================ HTTPS / WSS 配置完成 ================
证书域名   : ${DOMAIN}    （acme.sh 自动续期，到期前会自动 reload nginx）
证书目录   : ${SSL_DIR}
Nginx 配置 : ${SITE}
后端       : 127.0.0.1:${BACKEND_PORT}
对外地址   : https://${DOMAIN}:${HTTPS_PORT}
健康检查   : https://${DOMAIN}:${HTTPS_PORT}/healthz
WebSocket  : wss://${DOMAIN}:${HTTPS_PORT}/ws   （升级头已配好，客户端自动识别）
自检结果   : $( [ "$HTTPS_OK" = 1 ] && echo "通过" || echo "未通过（见上面的提示）" )

❗ 别忘了腾讯云控制台放行端口：
   安全组（轻量服务器是「防火墙」）→ 入站规则 → TCP ${HTTPS_PORT} → 允许 0.0.0.0/0
$( [ "$CERT_MODE" = "http" ] && echo "   （HTTP 验证模式还需要放行 TCP 80，验证完成后可以关掉）" )

常用命令：
  手动续期 : ${ACME} --renew -d ${DOMAIN} --ecc --server letsencrypt
  看证书期 : openssl x509 -in ${SSL_DIR}/fullchain.pem -noout -dates
  改端口   : sudo BACKEND_PORT=${BACKEND_PORT} bash scripts/setup-https.sh ${DOMAIN} <新端口>
=====================================================
SUMMARY
