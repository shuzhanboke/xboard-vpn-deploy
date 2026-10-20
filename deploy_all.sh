#!/bin/bash
# ============================================================================
#  一键部署脚本：Xboard 面板 + Xboard-Node 节点（VLESS+WS+TLS+Cloudflare）
#
#  适用：全新 Ubuntu 22.04 服务器（root 或 sudo 用户）
#  用途：搭建可对客户按月售卖订阅的 Xboard 商业面板
#
#  架构（与实测一致）：
#    客户端 → xb.example.com:443 (Cloudflare Proxied)
#            → nginx:443 → 127.0.0.1:7001 (容器内 Caddy)
#              ├─ /ws   → 容器内 8076 (Workerman)   [节点↔面板通信]
#              └─ 其他  → 容器内 7002 (Octane/PHP)  [面板业务]
#    节点服务器 → nginx /xbws → 127.0.0.1:2102 (Xboard-Node sing-box) [客户端流量]
#
#  使用方法：
#    1. 编辑下方【配置区】
#    2. sudo bash deploy_all.sh
#    3. 若被防火墙/内存卡住，参照 README 的「故障排查」
#
#  注意：本脚本已内置本会话踩过的所有坑的修复
#        （Redis socket、SQLite、APP_KEY、容器 OOM、/ws 必须走 Caddy 等）。
# ============================================================================
set -u
set -o pipefail

# ============================================================================
# 【配置区】部署前必须修改
# ============================================================================
DOMAIN="xb.example.com"        # 面板/节点共用域名（已在 Cloudflare 加为 Proxied 橙云）
ADMIN_EMAIL="admin@example.com"
ADMIN_PASS="CHANGE_ME_STRONG_PASSWORD"
NODE_PORT=2102                 # 节点 sing-box 监听端口
WS_PATH="/xbws"                # 节点客户端 WebSocket 路径（可用随机串增强隐蔽性，如 /a1b2c3）
PANEL_SERVER_TOKEN="$(openssl rand -hex 16)"   # 节点认证 token（部署后打印）
NODE_NAME="cf-ws-node"

# 域名对应的 nginx 配置路径（自动检测宝塔/原生）
if [ -d "/www/server/panel" ]; then
    NGX_CONF_DIR="/www/server/panel/vhost/nginx"
    NGX_BIN="/www/server/nginx/sbin/nginx"
    CERT_DIR_BASE="/www/server/panel/vhost/cert"
else
    NGX_CONF_DIR="/etc/nginx/conf.d"
    NGX_BIN="nginx"
    CERT_DIR_BASE="/etc/nginx/cert"
fi
VHOST="$NGX_CONF_DIR/$DOMAIN.conf"
CERT_DIR="$CERT_DIR_BASE/$DOMAIN"

# Xboard 数据目录
XB_DIR="/opt/xboard"
# 版本
XB_IMAGE="ghcr.io/cedar2025/xboard:latest"
XBN_REPO="https://github.com/cedar2025/xboard-node/releases"

# ============================================================================
# 工具函数
# ============================================================================
say()  { echo -e "\033[36m[STEP]\033[0m $1"; }
ok()   { echo -e "\033[32m  ✓\033[0m $1"; }
warn() { echo -e "\033[33m  ⚠\033[0m $1"; }
die()  { echo -e "\033[31m[错误]\033[0m $1" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "请以 root 运行（sudo bash deploy_all.sh）"
}

wait_http() { # wait_http URL 秒数
    local url="$1" max="$2" i=0
    while [ $i -lt "$max" ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$url" 2>/dev/null)
        [ "$code" = "200" ] && return 0
        sleep 5; i=$((i+5))
    done
    return 1
}

# ============================================================================
# 0. 前置检查
# ============================================================================
require_root
say "前置环境检查"
command -v curl >/dev/null || apt-get install -y curl >/dev/null 2>&1
command -v docker >/dev/null || warn "未检测到 Docker，即将安装"
command -v docker-compose >/dev/null 2>&1 || docker compose version >/dev/null 2>&1 || \
    warn "未检测到 Compose V2，即将安装"
ok "环境就绪"

# ============================================================================
# 1. 系统调优：SWAP（防容器 OOM）—— 本会话的关键修复
# ============================================================================
say "系统调优（SWAP，防 OOM）"
MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_GB=$((MEM_KB/1024/1024))
if [ "$MEM_GB" -lt 3 ]; then
    if command -v swapoff >/dev/null && command -v mkswap >/dev/null; then
        if ! grep -q '/swapfile' /etc/fstab 2>/dev/null; then
            fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile >/dev/null 2>&1
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            ok "已创建 1G swapfile（内存仅 ${MEM_GB}G，需要 swap 防止 Xboard 启动 OOM）"
        else
            ok "swap 已存在"
        fi
    else
        warn "无 swap 工具，跳过（若内存<2G 面板可能 OOM）"
    fi
else
    ok "内存 ${MEM_GB}G 充足，无需 swap"
fi

# ============================================================================
# 2. 安装 Docker + Compose
# ============================================================================
say "安装 Docker + Compose"
if ! command -v docker >/dev/null; then
    curl -fsSL https://get.docker.com | bash >/dev/null 2>&1 || die "Docker 安装失败"
    ok "Docker 已安装"
fi
systemctl enable --now docker >/dev/null 2>&1
docker compose version >/dev/null 2>&1 || {
    warn "安装 Compose V2 插件"
    apt-get install -y docker-compose-plugin >/dev/null 2>&1 || die "Compose 插件安装失败"
}
ok "Docker $(docker --version 2>/dev/null | grep -o '[0-9.]*' | head -1) / Compose V2"

# ============================================================================
# 3. 准备 Xboard 目录与 .env  —— 关键修复点
# ============================================================================
say "准备 Xboard 数据目录与配置"
mkdir -p "$XB_DIR" "$XB_DIR/.docker/.data"
cd "$XB_DIR" || die "无法进入 $XB_DIR"

# APP_KEY 用随机生成（密钥为空会导致容器崩溃循环）
APP_KEY="base64:$(openssl rand -base64 32)"
cat > "$XB_DIR/.env" <<EOF
APP_NAME=Xboard
APP_ENV=production
APP_KEY=$APP_KEY
APP_DEBUG=false
APP_URL=https://$DOMAIN

# 数据库：用 SQLite（经实测可用，避免 MySQL 密码/权限坑）
DB_CONNECTION=sqlite
DB_HOST=
DB_PORT=3306
DB_DATABASE=/www/.docker/.data/database.sqlite
DB_USERNAME=
DB_PASSWORD=

# Redis：使用容器内置 socket（不是 TCP 6379！）
REDIS_HOST=/data/redis.sock
REDIS_PORT=0
REDIS_PASSWORD=

# WebSocket（面板↔节点）
# Caddyfile 里 @ws path /ws -> WS_PORT(8076)
WS_PORT=8076
# Octane 内部端口（Caddy 统一入口）
OCTANE_INTERNAL_PORT=7002
CADDY_LISTEN_PORT=7001

LOG_CHANNEL=stack
BROADCAST_DRIVER=log
SESSION_DRIVER=file
CACHE_DRIVER=file
QUEUE_DRIVER=redis
EOF
chmod 644 "$XB_DIR/.env"
ok ".env 已生成（APP_KEY 随机，REDIS 用 socket）"

# ============================================================================
# 4. 生成 docker-compose.yml（含内存限制，防 OOM）
# ============================================================================
say "生成 docker-compose.yml"
cat > "$XB_DIR/docker-compose.yml" <<YAML
services:
  xboard:
    image: $XB_IMAGE
    container_name: xboard
    restart: unless-stopped
    ports:
      - "127.0.0.1:7001:7001"
    networks:
      - default
    volumes:
      - ./.env:/www/.env
      - ./.docker/.data/:/www/.docker/.data
      - ./storage/logs:/www/storage/logs
      - ./storage/theme:/www/storage/theme
      - ./plugins:/www/plugins
      - redis-data:/data
    environment:
      - RESOURCE_PROFILE=minimal
      - ENABLE_HORIZON=false
      - docker=true
    mem_limit: 700m
    memswap_limit: 900m

volumes:
  redis-data:
YAML
ok "docker-compose.yml 已生成（mem_limit 700m 防 OOM）"

# ============================================================================
# 5. 启动容器并初始化数据库
# ============================================================================
say "启动 Xboard 容器"
docker compose up -d 2>&1 | tail -3
ok "容器已启动，等待就绪（容器启动时 4 个进程同时起，内存高峰需等待）"
maxloop=24
i=0
while [ $i -lt $maxloop ]; do
    c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:7001/" 2>/dev/null)
    st=$(docker inspect xboard --format '{{.State.Status}}' 2>/dev/null || echo unknown)
    echo "  [try $((i+1))] HTTP=$c 状态=$st"
    [ "$c" = "200" ] && break
    [ "$st" = "exited" ] && { echo; warn "容器退出（可能 OOM）。回看泄漏: docker logs xboard --tail 50。"; }
    sleep 5; i=$((i+1))
done
[ "$c" = "200" ] || die "Xboard 未就绪，请查看 docker logs xboard"

# --- 安装数据库表（首次必须 --no-interaction，且会自动选 SQLite）---
say "初始化数据库表"
if docker exec xboard sh -c 'php artisan xboard:install --no-interaction' 2>&1 | tail -8; then
    ok "数据库表已初始化"
fi

echo
ok "面板已可访问（conslo 稍后用 nginx 打通外部）"

# ============================================================================
# 6. 创建自动后台管理入口 secure_path 与管理员
# ============================================================================
# Xboard 后台默认在 /#/{secure_path}，secure_path 由首次启动生成（随机）。这里通过 artisan 生成管理员
say "创建管理员账号"
docker exec xboard sh -c "\
  php artisan xboard:init-admin --email='$ADMIN_EMAIL' --password='$ADMIN_PASS' --no-interaction \
" 2>&1 | tail -5 || warn "若提示命令不存在，请到容器 http://127.0.0.1:7001 后台首次注册管理员"

echo
ok "准备就绪，后台 secure_path 见容器日志或访问 /s 重定向。"
ok "生产环境请记住：后台地址为 https://$DOMAIN/#/{secure_path}"

# ============================================================================
# 7. 写入 server_token（节点认证用），提示用户回填面板
# ============================================================================
say "节点认证 token"
echo "  server_token = $PANEL_SERVER_TOKEN"
echo "  请把此 token 稍后填到 Xboard 后台「系统设置 → 节点设置 → Server Token」"
echo "  （也可直接写入 /etc/xboard-node/config.yml 后重启节点）"
echo "$PANEL_SERVER_TOKEN" > /tmp/xb_server_token.txt

# ============================================================================
# 8. 配置域名 nginx（含 /ws 走 Caddy、/xbws 走节点）
# ============================================================================
say "配置域名 nginx 证书与反代"
mkdir -p "$CERT_DIR"
# 若没有真证书，生成自签（Cloudflare 橙云 Full 模式可用；上线建议换 LE/CF Origin Cert）
if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" \
        -subj "/CN=$DOMAIN" >/dev/null 2>&1
    chmod 600 "$CERT_DIR/privkey.pem"
    ok "已生成自签证书（Cloudflare 橙云 Full 模式可用）"
fi

# 全局 map（宝塔已带；原生 nginx 需确保）
if ! grep -q 'connection_upgrade' /etc/nginx/nginx.conf "$NGX_CONF_DIR"/*.conf 2>/dev/null; then
    MAP_DEF='map $http_upgrade $connection_upgrade { default upgrade; ""      close; }'
else
    MAP_DEF=""
fi

cat > "$VHOST" <<NGINXEOF
$MAP_DEF
server {
    listen 80;
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache   shared:SSL:10m;

    client_max_body_size 100m;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    # Xboard-Node 客户端入站（VLESS+WS）
    location = $WS_PATH {
        proxy_pass http://127.0.0.1:$NODE_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 10s;
        proxy_buffering off;
    }

    # 主站与 /ws：全部交给容器内 Caddy 统一分发（不要单独反代到 8076！）
    location / {
        proxy_pass http://127.0.0.1:7001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 60s;
        proxy_buffering off;
    }
}
NGINXEOF
ok "nginx vhost 已写入 $VHOST"

# 测试并重载
if "$NGX_BIN" -t 2>&1 | grep -q 'successful'; then
    "$NGX_BIN" -s reload >/dev/null 2>&1 && ok "nginx 已重载"
else
    warn "nginx -t 失败，请检查 $VHOST"
    [ -f /usr/sbin/nginx ] && /usr/sbin/nginx -t 2>&1 | tail -5
fi

# ============================================================================
# 9. 安装 Xboard-Node —— 关键修复：跳过 install_dependencies（apt update 会失败挂死）
# ============================================================================
say "安装 Xboard-Node"
if ! command -v /usr/local/bin/xboard-node >/dev/null 2>&1; then
    ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/' -e 's/armv7l/armv7/')
    TMPD=$(mktemp -d)
    cd "$TMPD"
    ok "下载二进制（架构 $ARCH）"
    curl -fsSL -o xboard-node "$XBN_REPO/latest/download/xboard-node-linux-$ARCH" || \
        curl -fsSL -o xboard-node "$XBN_REPO/latest/download/xboard-node-linux-$ARCH" || die "下载 xboard-node 失败"
    curl -fsSL -o xbctl "$XBN_REPO/latest/download/xbctl-linux-$ARCH" || warn "xbctl 下载失败（不影响节点运行）"
    chmod +x xboard-node xbctl
    install -m 755 xboard-node /usr/local/bin/xboard-node
    [ -f xbctl ] && install -m 755 xbctl /usr/local/bin/xbctl && ln -sf /usr/local/bin/xbctl /usr/bin/xbctl
    cd /
    rm -rf "$TMPD"
    ok "二进制已安装到 /usr/local/bin"
fi

# 生成节点配置（本会话实测有效的直写方式）
say "生成节点配置"
mkdir -p /etc/xboard-node
cat > /etc/xboard-node/config.yml <<YML
mode: node
panel_url: https://$DOMAIN
token: $PANEL_SERVER_TOKEN
node_id: 1
kernel: singbox
health_port: 65530
YML
chmod 600 /etc/xboard-node/config.yml
ok "节点配置已写入 /etc/xboard-node/config.yml"

# systemd 服务
say "注册并启动节点服务"
cat > /etc/systemd/system/xboard-node.service <<UNIT
[Unit]
Description=Xboard Node Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/etc/xboard-node
ExecStart=/usr/local/bin/xboard-node -c /etc/xboard-node/config.yml
Restart=always
RestartSec=5
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable xboard-node >/dev/null 2>&1
systemctl restart xboard-node
ok "Xboard-Node 已启动"

# 若面板还未到 server_token/节点，日志会出现 502/403；稍后在面板创建节点后再等同步
sleep 8
echo "  --- 节点日志 ---"
journalctl -u xboard-node -n 15 --no-pager 2>/dev/null | tail -12 | sed 's/^/    /'

# ============================================================================
# 10. 汇总
# ============================================================================
echo
echo "====================================================================="
echo "  部署完成"
echo "====================================================================="
echo "  前台     : https://$DOMAIN/"
echo "  后台     : 登录后可看（secure_path 见容器日志或访问 /s）"
echo "  管理员   : $ADMIN_EMAIL"
echo "  节点 token: $PANEL_SERVER_TOKEN"
echo "  nginx    : $VHOST"
echo "  以上配置已写入 /tmp/xb_server_token.txt 备份"
echo
echo "  接下来（见 README）:"
echo "   1. Cloudflare 把 $DOMAIN 设成 Proxied(橙云)，SSL 用 Full"
echo "   2. 登录后台建 权限组→节点(server_port=$NODE_PORT, path=$WS_PATH)→套餐→用户"
echo "   3. 回填 server_token，重启节点，日志出现 'config updated, N users' 即通"
echo "====================================================================="