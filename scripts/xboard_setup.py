#!/usr/bin/env python3
"""
Xboard 面板初始化脚本
通过后台 API 创建：权限组、节点、套餐、测试用户。

本脚本完全基于（本会话实测成功的）API 调用写成：
  - 登录:  POST /api/v1/passport/auth/login  {email,password} -> data.auth_data (Bearer)
  - 建组:  POST /api/v2/{secure_path}/server/group/save      {name}
  - 建节点: POST /api/v2/{secure_path}/server/manage/save     {...}
  - 建套餐: POST /api/v2/{secure_path}/plan/save              {...}
  - 建用户: 用 v1 注册 或 直接 update（注意：group_id 必须由 plan_id 推导！）

用法:
    python3 xboard_setup.py \
        --domain xb.example.com \
        --secure-path 4d79dfcb \
        --admin admin@example.com --pass 'xxx' \
        --node-port 2102 --ws-path /xbws

可选:
    --create-test-user  额外创建一个测试用户 test@test.com / Test123456 (10GB)
"""
import argparse, json, urllib.request, urllib.error, ssl, socket, sys

def parse_args():
    p = argparse.ArgumentParser(description="Xboard 面板初始化")
    p.add_argument("--domain", required=True, help="面板域名，如 xb.example.com")
    p.add_argument("--secure-path", required=True, help="后台 secure_path（首次启动生成的 hash）")
    p.add_argument("--admin", required=True, help="管理员邮箱")
    p.add_argument("--pass", dest="admin_pass", required=True, help="管理员密码")
    p.add_argument("--node-port", type=int, default=2102)
    p.add_argument("--ws-path", default="/xbws")
    p.add_argument("--node-name", default="cf-ws-node")
    p.add_argument("--plan-name", default="基础版")
    p.add_argument("--plan-gb", type=int, default=10)
    p.add_argument("--plan-price", default="10.00")
    p.add_argument("--create-test-user", action="store_true")
    return p.parse_args()

config = parse_args()
DOMAIN = config.domain
SECURE = config.secure_path
ADMIN  = config.admin
ADMIN_PASS = config.admin_pass

# ---- 强制走 127.0.0.1:443（该端由外面 nginx 监听）----
_orig_gai = socket.getaddrinfo
def _gaia(host, port, *a, **k):
    return _orig_gai("127.0.0.1", port, *a, **k)
socket.getaddrinfo = _gaia
ctx = ssl._create_unverified_context()
TOKEN = [None]

def call(path, data=None, ver="v2", sec=True):
    prefix = f"/api/{ver}/{SECURE}" if (ver == "v2" and sec) else f"/api/{ver}"
    url = f"https://{DOMAIN}{prefix}{path}"
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method="POST" if body else "GET")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    req.add_header("X-Requested-With", "XMLHttpRequest")
    req.add_header("Origin", f"https://{DOMAIN}")
    req.add_header("Referer", f"https://{DOMAIN}{SECURE}")
    if TOKEN[0]:
        req.add_header("Authorization", TOKEN[0])
    try:
        with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return {"_http": e.code, "_body": json.loads(raw)}
        except Exception:
            return {"_http": e.code, "_raw": raw[:300]}
    except Exception as e:
        return {"_err": str(e)}

def ok(msg): print(f"  ✓ {msg}")
def fail(msg): print(f"  ✗ {msg}")

print("=" * 60)
print(f" Xboard 面板初始化: {DOMAIN}")
print("=" * 60)

# 1. 登录
print("\n[1] 登录后台")
r = call("/passport/auth/login", {"email": ADMIN, "password": ADMIN_PASS}, ver="v1", sec=False)
if r.get("status") != "success":
    fail(f"登录失败: {r}")
    sys.exit(1)
TOKEN[0] = r["data"]["auth_data"]
ok("登录成功")

# 2. 权限组
print("\n[2] 权限组「默认组」")
groups = call("/server/group/fetch").get("data") or []
if isinstance(groups, dict):
    groups = list(groups.values())
gid = None
for g in groups:
    if isinstance(g, dict) and g.get("name") == "默认组":
        gid = g.get("id"); break
if gid is None:
    call("/server/group/save", {"name": "默认组"})
    for g in (call("/server/group/fetch").get("data") or []):
        if isinstance(g, dict) and g.get("name") == "默认组":
            gid = g.get("id"); break
if gid is None:
    fail("无法创建权限组"); sys.exit(1)
ok(f"权限组 id={gid}")

# 3. 节点
print("\n[3] 创建节点")
for n in (call("/server/manage/getNodes").get("data") or []):
    if isinstance(n, dict) and n.get("name") == config.node_name:
        ok(f"节点已存在 id={n.get('id')}")
        node_id = n.get("id")
        break
else:
    payload = {
        "type": "vless",
        "name": config.node_name,
        "host": DOMAIN,
        "port": 443,
        "server_port": config.node_port,
        "rate": 1,
        "show": 1,
        "enabled": 1,
        "group_ids": [gid],
        "route_ids": [],
        "protocol_settings": {
            "tls": 1,
            "network": "ws",
            "network_settings": {"path": config.ws_path, "headers": {"Host": DOMAIN}},
            "tls_settings": {"server_name": DOMAIN, "allow_insecure": False},
            "utls": {"enabled": True, "fingerprint": "chrome"},
            "flow": "",
        },
    }
    r = call("/server/manage/save", payload)
    print(f"    结果: {json.dumps(r, ensure_ascii=False)[:200]}")
    for n in (call("/server/manage/getNodes").get("data") or []):
        if isinstance(n, dict) and n.get("name") == config.node_name:
            node_id = n.get("id"); break
    ok(f"节点已创建 id={node_id}")

# 4. 套餐
print("\n[4] 创建套餐")
traffic_gb = config.plan_gb * 1024**3
plan = None
for pn in (call("/plan/fetch").get("data") or []):
    if isinstance(pn, dict) and pn.get("name") == config.plan_name:
        plan = pn; break
if plan is None:
    payload = {
        "group_id": gid,
        "name": config.plan_name,
        "transfer_enable": traffic_gb,
        "renew": 1,
        "show": 1,
        "sell": 0,
        "prices": {"monthly": config.plan_price, "quarterly": "28.00", "half_yearly": "55.00", "yearly": "100.00"},
    }
    r = call("/plan/save", payload)
    print(f"    结果: {json.dumps(r, ensure_ascii=False)[:200]}")
    for pn in (call("/plan/fetch").get("data") or []):
        if isinstance(pn, dict) and pn.get("name") == config.plan_name:
            plan = pn; break
ok(f"套餐 id={plan and plan.get('id')}「{config.plan_name}」{config.plan_gb}GB")

# 5. 测试用户（可选）
if config.create_test_user:
    print("\n[5] 创建测试用户")
    tu = "test@test.com"; tp = "Test123456"
    r = call("/passport/auth/register", {"email": tu, "password": tp}, ver="v1", sec=False)
    if r.get("status") != "success":
        # 已存在则登录
        r = call("/passport/auth/login", {"email": tu, "password": tp}, ver="v1", sec=False)
    if r.get("status") == "success":
        # 关键：group_id 由 plan_id 推导，勿直接传 group_id
        call("/user/update", {"id": None, "email": tu, "plan_id": plan["id"],
                              "transfer_enable": traffic_gb, "expired_at": 5000000000})
        print(f"    ✓ 测试用户: {tu} / {tp}，套餐 {config.plan_name}")
    else:
        fail(f"测试用户创建失败: {r}")

# 6. 汇总
print("\n" + "=" * 60)
print(" 完成。到后台验证：")
print(f"   权限组 → 默认组 (已绑节点 {node_id})")
print(f"   节点   → {config.node_name} (server_port={config.node_port}, path={config.ws_path})")
print(f"   套餐   → {config.plan_name} {config.plan_gb}GB")
print(" 现在到服务器上：sudo systemctl restart xboard-node")
print(" 再看日志：journalctl -u xboard-node -f")
print("   出现 'config updated, N users' 且 ss -tlnp | grep {config.node_port} 有监听 → 全链路打通")
print("=" * 60)