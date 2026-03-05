#!/bin/bash
# 诊断 nginx/tengine 与 BOG 代理
echo "=== 1. bog-test-server 服务状态 ==="
systemctl status bog-test-server --no-pager 2>/dev/null | head -5 || echo "服务未找到"
echo ""
echo "=== 2. 端口 8000 监听 ==="
ss -tlnp | grep 8000 || netstat -tlnp 2>/dev/null | grep 8000 || echo "8000 未监听"
echo ""
echo "=== 3. 直接访问 BOG 应用 ==="
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:8000/ 2>/dev/null || echo "curl 失败"
echo ""
echo "=== 4. 通过 Tengine 访问（Host: bog.generalquin.top）==="
curl -s -o /tmp/bog_test.html -w "HTTP %{http_code}, size %{size_download}\n" -H "Host: bog.generalquin.top" http://127.0.0.1/
head -5 /tmp/bog_test.html
echo ""
echo "=== 5. 通过 Tengine 访问（无 Host，走默认）==="
curl -s -o /tmp/default_test.html -w "HTTP %{http_code}, size %{size_download}\n" http://127.0.0.1/
head -5 /tmp/default_test.html
echo ""
echo "=== 6. conf.d 中的 BOG 配置 ==="
grep -l "bog.generalquin.top" /etc/tengine/conf.d/*.conf 2>/dev/null || echo "未找到"
echo ""
echo "=== 7. nginx.conf 中 location / 块（默认 server）==="
sed -n '/listen.*80 default_server/,/^    }/p' /etc/tengine/nginx.conf | head -25
