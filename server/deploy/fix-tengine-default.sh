#!/bin/bash
# 修复 Tengine 默认欢迎页：将默认 server 的 location / 改为代理到 BOG
# 在服务器上执行：sudo bash deploy/fix-tengine-default.sh
# 查看配置结构（不修改）：sudo bash deploy/fix-tengine-default.sh --show

set -e
NGINX_CONF="${NGINX_CONF:-/etc/tengine/nginx.conf}"
BACKUP="${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)"
SHOW_ONLY=false
[[ "$1" == "--show" ]] && SHOW_ONLY=true

echo "=== 修复 Tengine 默认站点（改为代理到 BOG）==="

# 若已修复过（location / 已含 proxy_pass），直接跳过，节省 ~1.5 分钟
if grep -q 'proxy_pass http://127.0.0.1:8000' "$NGINX_CONF" 2>/dev/null; then
    echo "已修复，跳过"
    exit 0
fi

if $SHOW_ONLY; then
    echo "--- nginx.conf 第 30-70 行（含 default_server）---"
    sed -n '30,70p' "$NGINX_CONF"
    echo ""
    echo "--- conf.d 下的配置文件 ---"
    ls -la /etc/tengine/conf.d/
    for f in /etc/tengine/conf.d/*.conf; do
        [[ -f "$f" ]] && echo "=== $f ===" && cat "$f" && echo ""
    done
    exit 0
fi

# 1. 备份
cp "$NGINX_CONF" "$BACKUP"
echo "已备份到: $BACKUP"

# 2. 用 Python 替换默认 server 的 location / 块
python3 << 'PYEOF'
import re

conf_path = "/etc/tengine/nginx.conf"
with open(conf_path, "r") as f:
    content = f.read()

proxy = """        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;"""

# 替换 default_server 所在 server 块内的第一个 location / { ... }
# 匹配 location / { 任意内容 }，只替换第一个（即默认欢迎页）
patterns = [
    # location / { 任意内容 }（含空块、default.d 注入等）
    (r'(        )location\s+/\s*\{[^}]*\}', r'\1location / {\n' + proxy + '\n        }', re.DOTALL),
    # 兜底：无前导空格
    (r'location\s+/\s*\{[^}]*\}', '        location / {\n' + proxy + '\n        }', re.DOTALL),
]
new = content
for p in patterns:
    pat, repl = p[0], p[1]
    flags = p[2] if len(p) > 2 else 0
    try:
        new = re.sub(pat, repl, new, count=1, flags=flags)
    except re.error:
        continue
    if new != content:
        break

if new == content:
    # 调试：输出 default_server 附近的配置
    import sys
    for i, line in enumerate(content.split('\n'), 1):
        if 'default_server' in line or (i > 35 and i < 55 and ('location' in line or 'root' in line or 'server' in line)):
            print(f"  {i}: {line}", file=sys.stderr)
    print("未找到可替换的 location 块")
    print("请手动编辑", conf_path, "将默认 server 的 location / 改为：")
    print("  location / {")
    print("    proxy_pass http://127.0.0.1:8000;")
    print("    proxy_set_header Host $host;")
    print("    ...")
    print("  }")
    exit(1)
with open(conf_path, "w") as f:
    f.write(new)
print("已修改默认 server 的 location / 为代理到 BOG")
PYEOF

# 3. 测试并重载
echo "测试配置..."
if tengine -t 2>&1 || nginx -t 2>&1; then
    systemctl reload tengine 2>/dev/null || systemctl reload nginx 2>/dev/null
    echo "Tengine 已重载，请访问 http://bog.generalquin.top:8080 测试（国内 80 可能被 ICP 拦截）"
else
    echo "配置测试失败，恢复备份"
    cp "$BACKUP" "$NGINX_CONF"
    exit 1
fi
