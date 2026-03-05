# BOG 产测服务 API 规范（供其他工程/Agent 集成）

**Base URL**：`http://{服务器IP}:8080`（生产）或 `http://{服务器IP}:8081`（测试）。对应应用端口：产测 8000、调试 8001；经 Nginx 对外时为 8080/8081（或生产 80）。

**数据存储原则**：烧录与 PCBA 测试记录**优先按 MAC 地址**存储和显示。MAC 为设备主标识。

**文档关系**：本文件为 API 的规范说明；服务端使用说明与部署见同目录 [README.md](README.md)；请求体与 `bog-test-server/schemas.py` 中 Pydantic 模型一致。

---

## 目录

- [Table 1：产测结果](#table-1产测结果production-test)
- [Table 2：烧录 + PCBA + 固件](#table-2烧录--pcba-测试burn--pcba-testing)
  - [2.1 烧录记录](#21-烧录记录burn-record)
  - [2.2 PCBA 测试记录](#22-pcba-测试记录pcba-test-record)
  - [2.3 设备固件升级记录](#23-设备固件升级记录firmware-upgrade-record)
  - [2.4 设备固件历史](#24-设备固件历史firmware-history)
- [响应格式](#响应格式)
- [时间戳上传规则](#时间戳上传规则给-agent--烧录端)
- [集成提示](#集成提示给-agent)

---

## Table 1：产测结果（Production Test）

由产测 App 单独上报，与烧录/PCBA 独立。

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/production-test` | 单条 |
| POST | `/api/production-test/batch` | 批量（最多 500 条） |
| GET | `/api/summary` | 汇总统计（支持 `sn`、`date_from`、`date_to`） |
| GET | `/api/records` | 分页查询（支持 `sn`、`date_from`、`date_to`、`limit`、`offset`） |
| GET | `/api/sn-list` | 设备 SN 列表 |
| GET | `/api/export` | 导出 CSV |

**请求体**：`deviceSerialNumber`(必填)、`overallPassed`(必填)、`needRetest`、`startTime`、`endTime`、`durationSeconds`、`stepsSummary`

---

## Table 2：烧录 + PCBA 测试（Burn + PCBA Testing）

烧录与 PCBA 测试**独立接口**，不一定同时上报。数据按 **MAC 地址** 优先存储和展示。

### 2.1 烧录记录（Burn Record）

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/burn-record` | 单条 |
| POST | `/api/burn-record/batch` | 批量（最多 500 条） |
| GET | `/api/burn-records` | 查询（支持 `sn`、`mac`、`date_from`、`date_to`、`burn_test_result`、`flow_type`、`bin_file`、`limit`） |
| GET | `/api/burn-bin-list` | bin 文件名下拉列表 |

**请求体**（`macAddress` 建议填写以利于存储与展示；**T-only 流程可传 `null`**，服务器接受无 MAC 记录）：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `deviceSerialNumber` | string | ✓ | 设备序列号（至少 1 字符；T-only 无 SN 时可传 `"-"`） |
| `macAddress` | string \| null | | **MAC 地址**，优先用于存储和显示；T-only 无 MAC 时可传 `null` |
| `burnStartTime` | string | | 烧录开始时间，`YYYY-MM-DD HH:MM:SS`（本地格式，与 flash_esp 一致） |
| `burnDurationSeconds` | number | | 烧录/自检耗时（秒）：P=烧录耗时，T=自检耗时，P+T=烧录+自检总耗时 |
| `computerIdentity` | string | | 烧录/自检所用电脑身份（如主机名、工位编号） |
| `binFileName` | string | | bin 文件名 |
| `deviceWrittenTimestamp` | string | | **设备被写入的 RTC 时间戳**，`YYYY-MM-DD HH:MM:SS`（本地格式），设备上传 |
| `deviceWrittenSerialNumber` | string | | 写入设备的 SN |
| `burnTestResult` | string | | passed / failed / self_check_failed / key_abnormal（按键超时视为 self_check_failed + failureReason=button_timeout） |
| `failureReason` | string | | 自检失败原因（仅当 burnTestResult=self_check_failed 时有意义）：rtc_error / pressure_sensor_error / button_timeout / button_user_exit / factory_config_incomplete / other |
| `flowType` | string | | 流程类型：P=仅烧录，T=仅自检，P+T=烧录+自检 |
| `fromVersion` | string | | 烧录前固件版本，如 N.A |
| `toVersion` | string | | 烧录后固件版本，如 1.1.1（填写后同时写入固件历史） |
| `targetFileSizeBytes` | number | | 烧录目标文件大小（字节） |
| `buttonWaitSeconds` | number | | 按键等待时间（秒），自检流程中从出现按键提示到用户按键/ESC/空格的耗时 |

**示例**：
```json
{
  "deviceSerialNumber": "SN-001",
  "macAddress": "AA:BB:CC:DD:EE:FF",
  "burnStartTime": "2025-02-26 08:30:00",
  "burnDurationSeconds": 52.3,
  "binFileName": "firmware_v1.0.5.bin",
  "deviceWrittenTimestamp": "2025-02-26 08:30:52",
  "deviceWrittenSerialNumber": "SN-001-20250226",
  "burnTestResult": "passed",
  "flowType": "P+T"
}
```

**自检失败示例**（burnTestResult=self_check_failed 时建议填写 failureReason）：
```json
{
  "deviceSerialNumber": "-",
  "macAddress": "AA:BB:CC:DD:EE:FF",
  "burnStartTime": "2025-02-26 08:30:00",
  "burnDurationSeconds": 52.3,
  "binFileName": "firmware_v1.0.5.bin",
  "burnTestResult": "self_check_failed",
  "failureReason": "rtc_error",
  "flowType": "P+T"
}
```

**T-only 示例**（仅自检、无 MAC 时 macAddress 传 null）：
```json
{
  "deviceSerialNumber": "-",
  "macAddress": null,
  "burnStartTime": "2025-02-26 09:00:00",
  "burnDurationSeconds": 45.2,
  "burnTestResult": "passed",
  "flowType": "T",
  "buttonWaitSeconds": 3.5
}
```

> 时间戳格式统一为 `YYYY-MM-DD HH:MM:SS`（无毫秒、无时区），与 flash_esp.py 一致。服务端兼容该格式及 ISO 8601，存储并展示。

---

### 2.2 PCBA 测试记录（PCBA Test Record）

**独立接口**，与烧录分开上报。

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/pcba-test-record` | 单条 |
| POST | `/api/pcba-test-record/batch` | 批量（最多 500 条） |
| GET | `/api/pcba-test-records` | 查询（支持 `mac`、`date_from`、`date_to`、`test_result`、`limit`） |
| GET | `/api/pcba-mac-list` | MAC 地址下拉列表 |

**请求体**（`macAddress` 必填，为主标识）：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `macAddress` | string | ✓ | **MAC 地址，主键标识** |
| `deviceSerialNumber` | string | | 设备序列号 |
| `testResult` | string | | passed / failed |
| `testTime` | string | | 测试时间，`YYYY-MM-DD HH:MM:SS`（本地格式，与 flash_esp 一致） |
| `durationSeconds` | number | | 测试耗时秒 |
| `computerIdentity` | string | | 电脑/工位标识 |
| `testDetails` | object | | 扩展测试详情 |

**示例**：
```json
{
  "macAddress": "AA:BB:CC:DD:EE:FF",
  "deviceSerialNumber": "SN-001",
  "testResult": "passed",
  "testTime": "2025-02-26 09:00:00",
  "durationSeconds": 12.5
}
```

**批量示例**：
```json
{
  "records": [
    {"macAddress": "AA:BB:CC:DD:EE:01", "testResult": "passed"},
    {"macAddress": "AA:BB:CC:DD:EE:02", "testResult": "failed", "deviceSerialNumber": "SN-002"}
  ]
}
```

---

### 2.3 设备固件升级记录（Firmware Upgrade Record）

设备 OTA 升级完成后上报，与烧录独立。**deviceSerialNumber 与 macAddress 至少填一个**。

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/firmware-upgrade-record` | 单条 |

**请求体**：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `deviceSerialNumber` | string | 二选一 | 设备序列号 |
| `macAddress` | string | 二选一 | MAC 地址 |
| `currentVersion` | string | ✓ | 升级前固件版本 |
| `upgradeSuccess` | boolean | ✓ | 是否升级成功 |
| `newVersion` | string | | 升级成功后固件版本（失败时可不填） |
| `failureReason` | string | | 失败原因：user_cancelled / connection_lost / timeout / checksum_failed / flash_failed / other |
| `finalVersion` | string | | 最终固件版本（成功/失败均建议上报；未填时成功用 newVersion，失败用 currentVersion） |
| `computerIdentity` | string | | 电脑/工位标识 |
| `targetFileSizeBytes` | number | | OTA 目标文件大小（字节） |
| `durationSeconds` | number | | OTA 执行耗时（秒） |

**示例（成功）**：
```json
{
  "macAddress": "AA:BB:CC:DD:EE:FF",
  "deviceSerialNumber": "SN-001",
  "currentVersion": "1.1.0",
  "upgradeSuccess": true,
  "newVersion": "1.1.1"
}
```

**示例（失败）**：
```json
{
  "macAddress": "AA:BB:CC:DD:EE:FF",
  "currentVersion": "1.1.0",
  "upgradeSuccess": false
}
```

---

### 2.4 设备固件历史（Firmware History）

烧录（含 fromVersion/toVersion）与升级记录统一存储，Dashboard 提供「设备固件历史」标签页。烧录记录的 finalVersion 取自 toVersion；升级记录的 finalVersion 由客户端上报或按 newVersion/currentVersion 推导。

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/firmware-history` | 查询（支持 `sn`、`mac`、`date_from`、`date_to`、`record_type`、`limit`） |

**record_type**：`burn` 烧录 / `upgrade` 升级

**响应**：`{"records": [...], "totalCount": N}`

---

## 响应格式

单条成功：`{"ok": true, "id": "uuid", "createdAt": "..."}`  
批量成功：`{"ok": true, "count": N, "results": [{"ok": true, "id": "...", "createdAt": "..."}, ...]}`  
失败：HTTP 4xx/5xx，JSON 含 `detail` 字段

**查询接口**：
- `GET /api/summary`：`{"totalRecords": N, "total": 设备数, "passed": N, "failed": N, "passRatePercent": N, "today": {...}}`（支持 `sn`、`date_from`、`date_to`）
- `GET /api/records`：`{"total": N, "limit": N, "offset": N, "items": [...]}`（产测记录分页）
- `GET /api/burn-records`：`{"records": [...], "totalCount": N}`（totalCount 为当前筛选条件下的总条数）
- `GET /api/pcba-test-records`：`{"records": [...], "totalCount": N}`
- `GET /api/firmware-history`：`{"records": [...], "totalCount": N}`（固件版本变更历史）

---

## 时间戳上传规则（给 Agent / 烧录端）

**统一格式**：`YYYY-MM-DD HH:MM:SS`（无毫秒、无时区），与 flash_esp.py 一致。

| 规则项 | 说明 |
|--------|------|
| **格式** | `YYYY-MM-DD HH:MM:SS`，如 `2025-02-26 08:30:52` |
| **适用字段** | 烧录：`burnStartTime`、`deviceWrittenTimestamp`；PCBA：`testTime` |
| **含义** | `deviceWrittenTimestamp`：烧录完成后写入设备 RTC 的时间戳（设备侧读取并上报） |
| **时机** | 随记录一起上报 |
| **可选性** | 非必填，但建议上报，便于追溯 |
| **展示** | 服务端 Dashboard 原样存储并展示，兼容 ISO 8601 历史数据 |

---

## 集成提示（给 Agent）

1. **烧录与 PCBA 分开上报**：使用 `/api/burn-record` 与 `/api/pcba-test-record`，互不依赖
2. **MAC 地址优先**：尽量填写 `macAddress`，用于存储、查询和展示
3. **批量上传**：优先使用 `.../batch` 接口，单次最多 500 条
4. **生产 Base URL**：`http://8.129.99.18:8080` 或 `http://bog.generalquin.top:8080`（直连应用可用 `:8000`）
5. **测试 Base URL**：`http://8.129.99.18:8081`（直连应用可用 `:8001`）
6. **Schema 参考**：`schemas.py` 中 `BurnRecordPayload`、`PcbaTestRecordPayload`、`FirmwareUpgradePayload`
7. **固件历史**：烧录时填写 `fromVersion`、`toVersion` 可自动写入固件历史；OTA 升级通过 `/api/firmware-upgrade-record` 上报
