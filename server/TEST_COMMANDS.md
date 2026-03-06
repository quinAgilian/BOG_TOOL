# 测试数据推送命令（curl）

用于区分**产测环境**与**调试环境**的 API 测试。部署后通过 HTTPS 访问时，使用不同路径前缀即可写入对应库。

- **产测（生产）**：`https://generalquin.top/bog/prod` → 写入产测服务（8000）数据库  
- **调试（Debug）**：`https://generalquin.top/bog/dev` → 写入调试服务（8001）数据库  

本地直连时：
- 产测：`http://127.0.0.1:8000`
- 调试：`http://127.0.0.1:8001`

---

## 1. 产测结果（Production Test）— 写入生产

```bash
# 单条上报到【产测/生产】环境（HTTPS）
curl -s -X POST 'https://generalquin.top/bog/prod/api/production-test' \
  -H 'Content-Type: application/json' \
  -d '{
    "deviceSerialNumber": "TEST-SN-PROD-001",
    "overallPassed": true,
    "needRetest": false,
    "durationSeconds": 12,
    "deviceFirmwareVersion": "1.1.3",
    "deviceBootloaderVersion": "2",
    "deviceHardwareRevision": "P02V02R00"
  }'
```

```bash
# 单条失败记录 — 产测环境
curl -s -X POST 'https://generalquin.top/bog/prod/api/production-test' \
  -H 'Content-Type: application/json' \
  -d '{
    "deviceSerialNumber": "TEST-SN-PROD-002",
    "overallPassed": false,
    "durationSeconds": 10,
    "deviceFirmwareVersion": "1.1.3",
    "deviceBootloaderVersion": "2",
    "deviceHardwareRevision": "P02V02R00"
  }'
```

---

## 2. 产测结果 — 写入调试（Debug）

```bash
# 单条上报到【调试】环境（HTTPS）
curl -s -X POST 'https://generalquin.top/bog/dev/api/production-test' \
  -H 'Content-Type: application/json' \
  -d '{
    "deviceSerialNumber": "TEST-SN-DEV-001",
    "overallPassed": true,
    "needRetest": false,
    "durationSeconds": 15,
    "deviceFirmwareVersion": "1.1.3",
    "deviceBootloaderVersion": "2",
    "deviceHardwareRevision": "P02V02R00"
  }'
```

```bash
# 单条失败记录 — 调试环境
curl -s -X POST 'https://generalquin.top/bog/dev/api/production-test' \
  -H 'Content-Type: application/json' \
  -d '{
    "deviceSerialNumber": "TEST-SN-DEV-002",
    "overallPassed": false,
    "durationSeconds": 8,
    "deviceFirmwareVersion": "1.1.3"
  }'
```

---

## 3. 使用变量（便于批量切换环境）

**产测（生产）：**
```bash
export BOG_BASE='https://generalquin.top/bog/prod'
curl -s -X POST "$BOG_BASE/api/production-test" \
  -H 'Content-Type: application/json' \
  -d '{"deviceSerialNumber":"PROD-001","overallPassed":true,"durationSeconds":11}'
```

**调试（Debug）：**
```bash
export BOG_BASE='https://generalquin.top/bog/dev'
curl -s -X POST "$BOG_BASE/api/production-test" \
  -H 'Content-Type: application/json' \
  -d '{"deviceSerialNumber":"DEV-001","overallPassed":true,"durationSeconds":11}'
```

---

## 4. 烧录记录（Burn Record）

**产测环境：**
```bash
curl -s -X POST 'https://generalquin.top/bog/prod/api/burn-record' \
  -H 'Content-Type: application/json' \
  -d '{
    "deviceSerialNumber": "BURN-PROD-001",
    "macAddress": "AA:BB:CC:DD:EE:01",
    "burnTestResult": "passed",
    "flowType": "P+T",
    "toVersion": "1.1.3",
    "burnDurationSeconds": 50
  }'
```

**调试环境：**
```bash
curl -s -X POST 'https://generalquin.top/bog/dev/api/burn-record' \
  -H 'Content-Type: application/json' \
  -d '{
    "deviceSerialNumber": "BURN-DEV-001",
    "macAddress": "AA:BB:CC:DD:EE:02",
    "burnTestResult": "passed",
    "flowType": "P+T",
    "toVersion": "1.1.3",
    "burnDurationSeconds": 48
  }'
```

---

## 5. 本地直连（不经过 Nginx）

产测服务（8000）：
```bash
curl -s -X POST 'http://127.0.0.1:8000/api/production-test' \
  -H 'Content-Type: application/json' \
  -d '{"deviceSerialNumber":"LOCAL-PROD","overallPassed":true,"durationSeconds":10}'
```

调试服务（8001）：
```bash
curl -s -X POST 'http://127.0.0.1:8001/api/production-test' \
  -H 'Content-Type: application/json' \
  -d '{"deviceSerialNumber":"LOCAL-DEV","overallPassed":true,"durationSeconds":10}'
```

---

## 6. 验证数据是否分离

- 打开 **https://generalquin.top/bog/prod/dashboard**：应只看到产测环境的数据（含 `TEST-SN-PROD-*`、`BURN-PROD-*` 等）。
- 打开 **https://generalquin.top/bog/dev/dashboard**：应只看到调试环境的数据（含 `TEST-SN-DEV-*`、`BURN-DEV-*` 等）。
- 标题旁角标分别为「产测环境」「调试环境」。
