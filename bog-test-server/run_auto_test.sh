#!/usr/bin/env bash
# 自动：安装依赖 → 启动服务 → 执行 API 测试 → 打开预览页 → 输出结果
set -e
cd "$(dirname "$0")"
PORT=8000
BASE="http://127.0.0.1:$PORT"

echo "========== 1. 检查依赖 =========="
if ! .venv/bin/python -c "import fastapi, uvicorn" 2>/dev/null; then
  echo "安装依赖中..."
  .venv/bin/pip install -q -r requirements.txt
fi
echo "依赖 OK"

echo ""
echo "========== 2. 初始化 DB =========="
.venv/bin/python -c "
from main import init_db
init_db()
print('DB 初始化 OK')
"

echo ""
echo "========== 3. 启动服务（后台） =========="
.venv/bin/uvicorn main:app --host 127.0.0.1 --port $PORT &
UV_PID=$!
cleanup() { kill $UV_PID 2>/dev/null || true; }
trap cleanup EXIT

# 等待就绪
for i in $(seq 1 15); do
  if curl -s -o /dev/null -w "%{http_code}" "$BASE/api/summary" 2>/dev/null | grep -q 200; then
    echo "服务已就绪"
    break
  fi
  sleep 1
  if [ $i -eq 15 ]; then echo "服务启动超时"; exit 1; fi
done

echo ""
echo "========== 4. API 测试 =========="

# POST 两条
for i in 1 2; do
  R=$(curl -s -X POST "$BASE/api/production-test" \
    -H "Content-Type: application/json" \
    -d "{
      \"deviceSerialNumber\": \"SN-AUTO-$i\",
      \"overallPassed\": $([ $i -eq 1 ] && echo true || echo false),
      \"needRetest\": false,
      \"deviceFirmwareVersion\": \"1.0.5\",
      \"stepsSummary\": [{\"stepId\": \"step1\", \"status\": \"passed\"}, {\"stepId\": \"step2\", \"status\": \"passed\"}]
    }")
  if echo "$R" | grep -q '"ok":true'; then
    echo "  POST 测试 $i: 通过"
  else
    echo "  POST 测试 $i: 失败 ($R)"
  fi
done

# GET summary
S=$(curl -s "$BASE/api/summary")
TOTAL=$(echo "$S" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total',0))" 2>/dev/null || echo "?")
PASS=$(echo "$S" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('passed',0))" 2>/dev/null || echo "?")
echo "  GET /api/summary: 总 $TOTAL 条, 通过 $PASS 条"

# GET records
R=$(curl -s "$BASE/api/records?limit=5")
N=$(echo "$R" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('items',[])))" 2>/dev/null || echo "?")
echo "  GET /api/records: 返回 $N 条"

# Export CSV
CSV_LINES=$(curl -s "$BASE/api/export" | wc -l)
echo "  GET /api/export: CSV $CSV_LINES 行"

echo ""
echo "========== 5. 打开预览页 =========="
if command -v open >/dev/null 2>&1; then
  open "$BASE/"
  echo "已用浏览器打开: $BASE/"
else
  echo "请手动打开: $BASE/"
fi

echo ""
echo "========== 结果汇总 =========="
echo "  服务: $BASE/"
echo "  概览页: $BASE/"
echo "  API 文档: $BASE/docs"
echo "  所有接口测试已执行，详见上方输出。"
echo "  关闭本窗口或 Ctrl+C 将停止服务。"

wait $UV_PID
