# VPN 一键部署文档（Xboard 面板 + Xboard-Node 节点）

> 基于本会话**实测成功**的完整流程整理。目标：在**全新空白服务器**上，一键搭建可对客户按月售卖订阅的 Xboard 商业面板，配合 Cloudflare 做防护与加速。

---

## 一、架构总览

```
客户端 (v2rayN / v2rayNG / Shadowrocket ...)
   │ VLESS + WS + TLS
   ▼
xb.example.com:443  (Cloudflare Proxied 橙云)
   │
   ▼
服务器 nginx:443
   ├─ location /          → 127.0.0.1:7001  (面板)
   │     容器内 Caddy(7001) 统一入口
   │        ├─ /ws        → 8076 (Workerman)  [面板↔节点通信]
   │        └─ 其他       → 7002 (Octane/PHP)
   │
   └─ location /xbws      → 127.0.0.1:2102  (Xboard-Node sing-box)
                            [客户端真实流量]
                 │
                 ▼
        └── 节点再连 wss://xb.example.com/ws 同步用户 ──┘
```

**核心要点（踩坑总结）：**

| # | 组件 | 正确做法 | 常见错误 |
|---|------|---------|---------|
| 1 | Redis | 容器内置 **socket`/data/redis.sock`**，`REDIS_PORT=0` | 配 TCP 6379 → 连接失败 |
| 2 | 数据库 | **SQLite** `database.sqlite`（无需 MySQL 密码） | 配 MySQL → 密码/权限坑 |
| 3 | APP_KEY | 必须随机生成 `base64:...` | 为空 → 容器崩溃循环 |
| 4 | 容器 OOM | `mem_limit: 700m` + swapfile + `RESOURCE_PROFILE=minimal` + 关 Horizon | 2G 内存默认起 4 进程必 OOM |
| 5 | `/ws` 反代 | **不要**单独反代到 8076，全部交给容器内 **7001/Caddy** | 直连 8076 → Workerman 不接受裸 HTTP |
| 6 | Xboard-Node 安装 | **跳过** `install_dependencies`（apt update 在部分源会挂死） | 走官方安装脚本 → 卡死在 apt |
| 7 | 用户 group_id | 由 **plan_id** 推导，POST user/update 传 plan_id | 直接传 group_id → 不生效 |

---

## 二、准备

### 1. 服务器
- 全新 **Ubuntu 22.04 / 20.04**，root 或 sudo
- 建议内存 ≥ 2G（脚本会自动加 swap）
- 放行端口：`80`、`443`（安全组/防火墙）

### 2. 域名 + Cloudflare（关键！国内访问必需）
- 在 Cloudflare 加一个域名，如 `example.com`
- 建子域名 `xb.example.com`
- 解析到服务器 IP，**橙色云朵（Proxied）**——这样隐藏真实 IP，国内可连
- Cloudflare **SSL/TLS 加密模式选 `Full`**（否则源站自签证书会报 525/526）

### 3. 下载部署包后
一键运行即可。

---

## 三、一键部署步骤

### 第 0 步：下载
```bash
git clone <你的仓库> vpn-deploy && cd vpn-deploy
# 或直接上传 deploy_all.sh 到 /root/
```

### 第 1 步：编辑配置
编辑 `deploy_all.sh` 顶部的【配置区】：
```bash
DOMAIN="xb.example.com"                    # 你的域名（已 CF 橙云）
ADMIN_EMAIL="admin@example.com"
ADMIN_PASS="你的强密码"
NODE_PORT=2102
WS_PATH="/xbws"
```

### 第 2 步：一键安装
```bash
sudo bash deploy_all.sh
```

脚本自动完成：
```
SWAP避OOM → 装Docker/Compose → 生成.env与compose →
启动容器+初始化数据库 → 写nginx(含/ws与/xbws反代) →
装Xboard-Node(singbox)并注册systemd服务
```

**部署完成会打印：**
```
前台    : https://xb.example.com/
后台    : 登录后可看（secure_path 见容器日志）
管理员  : admin@example.com
节点token: <随机32位>
```

---

## 四、面板配置（登录后台）

### 1. 找到后台地址（secure_path）
Xboard 首次启动会生成一个随机 `secure_path`。查看：
```bash
docker logs xboard 2>&1 | grep -i -E 'admin|path|http.*:' | tail
```
通常形如 `/#/4d79dfcb`。后续可用脚本指定。

### 2. 填入 server_token
后台 → 系统设置 → 节点设置 → **Server Token**，填入部署输出 / `/tmp/xb_server_token.txt`。

### 3. 或直接用脚本初始化（推荐）
```bash
python3 scripts/xboard_setup.py \
  --domain xb.example.com --secure-path <你的secure_path> \
  --admin admin@example.com --pass '密码' \
  --node-port 2102 --ws-path /xbws \
  --create-test-user
```
自动建：权限组「默认组」→ 节点(VLESS+WS) → 套餐「基础版」10GB → 测试用户。

> 手动后台路径：**权限组 → 节点管理 → 套餐管理 → 用户管理**。
> 节点关键参数：
> ```
> 类型: vless, 地址: xb.example.com, 端口: 443
> server_port(内部): 2102
> 网络: ws, 路径: /xbws, TLS:开启, SNI: xb.example.com
> 权限组: 默认组
> ```

---

## 五、验证是否全链路打通

```bash
# 1. 节点服务正常
systemctl status xboard-node --no-pager | grep -E 'Active|active'

# 2. 重启节点，看日志（关键！）
sudo systemctl restart xboard-node
journalctl -u xboard-node -f

# 期望输出：
#   INFO [core] ws connected
#   INFO [vless:2102] config updated, N users
#   INFO [vless:2102] started, N users
```

`ws connected` = 节点↔面板通信 OK；
`started, N users` = 已拿到用户并启动入站。

```bash
# 3. 端口监听确认
ss -tlnp | grep -E '2102|65530'
#  *:2102      ← sing-box 客户端入站
#  *:65530     ← 节点健康检查
```

```bash
# 4. HTTP 三级验证
curl -sk -o /dev/null -w '主页:%{http_code}\n'  https://xb.example.com/
curl -sk -o /dev/null -w '后台:%{http_code}\n'  https://xb.example.com/4d79dfcb
curl -sk -o /dev/null -w '面板200:%{http_code}\n' --http1.1 \
  -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: x' \
  https://xb.example.com/ws
```

---

## 六、客户端订阅

### 单节点链接（从用户详情页拿 UUID）
```
vless://<用户UUID>@xb.example.com:443?encryption=none&security=tls&sni=xb.example.com&fp=chrome&type=ws&host=xb.example.com&path=%2Fxbws#Xboard
```

### 生成订阅
在用户详情页复制**订阅地址**，客户端（v2rayN 订阅）填入即可自动拉取节点列表，方便给客户分发。

---

## 七、故障排查（本会话踩过的全记录）

| 症状 | 原因 | 解决 |
|------|------|------|
| 502 Bad Gateway (CF 页面) | 源站不可达 / Octane 未就绪 | 等容器起来：`curl 127.0.0.1:7001`；`docker logs xboard --tail 50` |
| 容器反复 Exited(137) | OOM | 已自动加 mem_limit 700m + swap。仍爆则检查 free -m |
| 节点 `bad handshake` | nginx 把 /ws 反代到 8076 | **删除 /ws 单独反代，让全部走 7001/Caddy** |
| 节点 `handshake status 502` | 容器刚重启 Octane 未就绪 | 等 20s 自动恢复；或重启容器后再起节点 |
| 节点 `users payload empty` | 无用户 / 用户没绑 group | 面板建用户并把 plan_id 传对 |
| `config updated, 0 users` 且 2102 没监听 | 无有效用户 | 建用户 → 权限组→节点 关联 |
| 群组 `users_count=0, servers=0` | 用户/节点没挂到权限组 | 确保节点 group_ids、用户 plan_id.group 都对 |
| `token is error` (订阅) | 订阅 token 传法不对 | 用用户详情页的**订阅地址**而非手动拼 |

---

## 八、安全与合规提醒

- ⚠️ **在中国大陆销售或运营 VPN 属于违法行为**，本方案仅供技术学习与合规场景使用，请遵守当地法律法规。
- 生产上线请：
  - 替换自签证书为 Let's Encrypt 或 CF Origin Certificate；
  - 更换默认管理员，开启面板后台验证码/二步验证；
  - 不要把 server_token、UUID 明文留在脚本/仓库里。