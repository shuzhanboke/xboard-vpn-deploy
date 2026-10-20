#!/bin/bash
# ============================================================
# 一键安装入口：整合 deploy_all.sh + 面板初始化
#
# 用法：
#   sudo bash install.sh
#   sudo bash install.sh --setup-panel   # 部署后自动跑面板初始化(v2ray脚本)
#
# 说明：install.sh 只是包一层，真正的部署逻辑在 deploy_all.sh。
#       先编辑 deploy_all.sh 顶部的【配置区】。
# ============================================================
set -e
cd "$(dirname "$0")"

echo "==> 一键部署 Xboard 面板 + 节点"
echo "    部署脚本: $(pwd)/deploy_all.sh"
echo
read -r -p "是否开始部署？[y/N]: " ans
case "$ans" in
  y|Y|yes|YES) ;;
  *) echo "已取消"; exit 0 ;;
esac

# 确保脚本可执行
[ -x deploy_all.sh ] || chmod +x deploy_all.sh

# 真正执行
sudo bash deploy_all.sh

echo
echo "==> 部署完成。"
echo "    可继续：面板初始化（建组/节点/套餐/用户）"
read -r -p "是否运行 xboard_setup.py 初始化面板？[y/N]: " setup
if [[ "$setup" =~ ^[yY] ]]; then
    echo "  你需要提供后台 secure_path（见 docker logs xboard 或访问 /s）"
    read -r -p "  secure_path: " sp
    read -r -p "  管理员邮箱: " admin
    read -r -s -p "  管理员密码: " pwd; echo
    python3 scripts/xboard_setup.py \
        --domain "$(grep '^DOMAIN=' deploy_all.sh | head -1 | cut -d= -f2)" \
        --secure-path "$sp" \
        --admin "$admin" --pass "$pwd" \
        --create-test-user
fi
echo "==> 退出前提示：参考 README.md 的「验证」章节确认节点上线。"