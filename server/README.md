# BOG 产测数据服务

接收 BOG_TOOL 产测结果、烧录程序烧录记录、PCBA 测试记录，落库（SQLite），并提供汇总、记录查询、导出。  
**推荐部署到远程服务器，BOG_TOOL APP、烧录工具等作为 HTTP 客户端连接。**

- **产测**：`POST /api/production-test`，用于 BOG_TOOL 产测结束上报
- **烧录**：`POST /api/burn-record`，用于烧录程序（含命令行工具）上报烧录记录
- **PCBA 测试**：`POST /api/pcba-test-record`，独立接口，MAC 地址为主标识

---

## 项目结构

```
bog-test-server/
├── main.py              # FastAPI 应用、API、Dashboard 页面
├── schemas.py           # Pydantic 请求/响应模型（含 BurnRecordPayload、PcbaTestRecordPayload）
├── API_SPEC.md          # API 规范（供其他工程/Agent 集成）
├── requirements.txt     # 依赖
├── run_auto_test.sh     # 本地自动化测试脚本
├── deploy/
│   ├── bog-test-server.service      # systemd 服务配置
│   ├── bog-test-server-dev.service  # 测试环境 systemd 配置
│   ├── nginx-bog-test-server.conf   # Nginx 生产配置
│   ├── nginx-bog-test-server-dev.conf # Nginx 测试配置（8081）
│   ├── debug-nginx.sh               # Nginx/Tengine 调试脚本
│   └── fix-tengine-default.sh       # 修复 Tengine 默认站点匹配
└── .github/workflows/
    └── deploy.yml       # GitHub Actions 自动部署
```

---

## 环境要求

- Python 3.6+（生产环境已测试 3.6；本地开发建议 3.9+）
- 依赖：FastAPI 0.83、uvicorn 0.16

---

## 一、本地快速开始

```bash
cd bog-test-server
python3 -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
uvicorn main:app --host 127.0.0.1 --port 8000 --reload
```

- 数据概览：<http://127.0.0.1:8000/>
- API 文档：<http://127.0.0.1:8000/docs>

### 自动化测试

```bash
./run_auto_test.sh
```

启动服务、执行 API 测试、打开预览页。

### 手动测试 POST

```bash
curl -X POST http://127.0.0.1:8000/api/production-test \
  -H "Content-Type: application/json" \
  -d '{
    "deviceSerialNumber": "SN-TEST-001",
    "overallPassed": true,
    "needRetest": false,
    "stepsSummary": [{"stepId": "step1", "status": "passed"}]
  }'
```

---

## 二、API 说明

**完整 API 字段与说明**见 [API_SPEC.md](API_SPEC.md)；以下为速览与常用接口说明。

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/production-test` | 接收产测结果 |
| POST | `/api/production-test/batch` | 批量产测结果（最多 500 条） |
| GET  | `/api/summary` | 汇总统计（支持 `sn`、`date_from`、`date_to`） |
| POST | `/api/burn-record` | 烧录程序上报烧录记录 |
| POST | `/api/burn-record/batch` | 批量烧录记录（最多 500 条） |
| GET  | `/api/burn-records` | 烧录记录查询（支持 `sn`、`mac`、`date_from`、`date_to`、`burn_test_result`、`flow_type`、`bin_file`、`limit`），返回 `records`、`totalCount` |
| GET  | `/api/burn-bin-list` | 烧录记录中不重复的 bin 文件名列表（供下拉选择） |
| POST | `/api/pcba-test-record` | PCBA 测试记录上报 |
| POST | `/api/pcba-test-record/batch` | 批量 PCBA 测试记录（最多 500 条） |
| GET  | `/api/pcba-test-records` | PCBA 测试记录查询（支持 `mac`、`date_from`、`date_to`、`test_result`、`limit`），返回 `records`、`totalCount` |
| GET  | `/api/pcba-mac-list` | PCBA 记录中不重复的 MAC 地址列表 |
| GET  | `/api/firmware-history` | 固件历史（烧录/升级）查询 |
| GET  | `/api/records` | 分页记录（支持 `sn`、`date_from`、`date_to`、`limit`、`offset`） |
| GET  | `/api/sn-list` | 设备 SN 列表（供下拉建议） |
| GET  | `/api/export` | 导出 CSV |
| GET  | `/api/viewers` | 当前预览观众数（心跳） |
| GET  | `/api/deploy-info` | 最近部署时间 |
| DELETE | `/api/clear-test-data` | 清空测试数据（仅 dev 环境） |
| GET  | `/` | 数据概览页（Dashboard） |

### POST 请求体（`/api/production-test`）

| 字段 | 必填 | 说明 |
|------|------|------|
| `deviceSerialNumber` | ✓ | 设备序列号 |
| `overallPassed` | ✓ | 是否通过 |
| `needRetest` | | 否，默认 false |
| `startTime` / `endTime` / `durationSeconds` | | 时间信息 |
| `deviceName` / `deviceFirmwareVersion` / `deviceBootloaderVersion` / `deviceHardwareRevision` | | 设备信息 |
| `stepsSummary` | | `[{"stepId":"step1","status":"passed"}, ...]` |
| `stepResults` | | `{"step1":"详情", ...}` |
| `testDetails` | | RTC、压力、Gas 状态等 |

### 烧录记录 API（`/api/burn-record`）

烧录程序在每次烧录完成后，向本服务 POST 烧录记录。**其他工程（如命令行烧录工具）需按以下规范上报。**

**请求：**
- 方法：`POST`
- URL：`{BASE_URL}/api/burn-record`（生产：80/8080 端口；测试：8081 端口）
- Content-Type：`application/json`

**请求体字段定义**（完整字段见 [API_SPEC.md](API_SPEC.md)）：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `deviceSerialNumber` | string | ✓ | 设备序列号，至少 1 字符（T-only 无 SN 可传 `"-"`） |
| `macAddress` | string \| null | | 设备 MAC 地址；T-only 无 MAC 时可传 `null` |
| `burnStartTime` | string | | 烧录启动时间，如 `2025-02-26 08:30:00` 或 ISO 8601 |
| `burnDurationSeconds` | number | | 烧录/自检耗时（秒）：P=烧录耗时，T=自检耗时，P+T=总耗时 |
| `computerIdentity` | string | | 烧录所用电脑的身份信息（如主机名、工位编号） |
| `deviceWrittenTimestamp` | string | | 设备被写入固件完成的时间戳 |
| `binFileName` | string | | 烧录的 bin 文件名称，如 `firmware_v1.0.5.bin` |
| `deviceWrittenSerialNumber` | string | | 烧录时写入设备的序列号（可与 deviceSerialNumber 不同） |
| `burnTestResult` | string | | 烧录前自检结果：`passed`、`failed`、`self_check_failed`、`key_abnormal`（按键超时用 self_check_failed + failureReason） |
| `failureReason` | string | | 自检失败原因：`rtc_error`、`pressure_sensor_error`、`button_timeout`、`button_user_exit`、`factory_config_incomplete`、`other` |
| `flowType` | string | | 流程类型：`P`=仅烧录，`T`=仅自检，`P+T`=烧录+自检 |
| `buttonWaitSeconds` | number | | 按键等待时间（秒），自检中从出现按键提示到用户操作的耗时 |
| `fromVersion` / `toVersion` | string | | 烧录前后固件版本（填 toVersion 会写入固件历史） |

**响应：**
```json
{"ok": true, "id": "uuid", "createdAt": "2025-02-26T08:31:00Z"}
```

**完整示例（供其他工程集成）：**
```bash
curl -X POST "http://127.0.0.1:8001/api/burn-record" \
  -H "Content-Type: application/json" \
  -d '{
    "deviceSerialNumber": "SN-001",
    "macAddress": "AA:BB:CC:DD:EE:FF",
    "burnStartTime": "2025-02-26T08:30:00Z",
    "burnDurationSeconds": 52.3,
    "computerIdentity": "PC-产线A-01",
    "deviceWrittenTimestamp": "2025-02-26T08:30:52Z",
    "binFileName": "firmware_v1.0.5.bin",
    "deviceWrittenSerialNumber": "SN-001-20250226",
    "burnTestResult": "passed"
  }'
```

**集成建议：**
- 生产环境：POST 到 `http://{生产服务器}:8080/api/burn-record`（国内建议用 8080 避免 ICP 拦截）
- 测试/调试：POST 到 `http://{服务器}:8081/api/burn-record`，避免污染生产数据
- 建议上报的字段：除 `deviceSerialNumber` 外，尽量上报 `burnStartTime`、`burnDurationSeconds`、`binFileName`、`deviceWrittenSerialNumber`、`burnTestResult`，便于追溯

**Schema 参考：** 本仓库 `schemas.py` 中的 `BurnRecordPayload` 定义了完整字段，其他工程可据此构造 JSON 或生成客户端模型。

### PCBA 测试记录 API（`/api/pcba-test-record`）

PCBA 测试与烧录**独立接口**，按 MAC 地址为主标识存储。请求体需包含 `macAddress`（必填）、`deviceSerialNumber`、`testResult`（passed/failed）、`testTime`、`durationSeconds`、`computerIdentity` 等。详见 `API_SPEC.md` 及 `schemas.py` 中的 `PcbaTestRecordPayload`。

---

## 三、部署到云端

**推荐：使用阿里云香港等境外节点**，无需 ICP 备案，80/443 端口可直接访问。国内节点需备案，否则 80/8080 等端口均可能被拦截。

**迁移至香港节点步骤**：
1. 阿里云控制台 → 创建 ECS → 地域选择 **香港**
2. 按 3.1 在新区部署
3. 复制数据库（在本机执行）：`scp 国内IP:/var/lib/bog-test-server/bog_test.db .` → `scp bog_test.db 香港IP:/tmp/` → SSH 到香港执行 `sudo mkdir -p /var/lib/bog-test-server && sudo mv /tmp/bog_test.db /var/lib/bog-test-server/`
4. DNS 将 `bog`、`dev.bog` 的 A 记录改为香港服务器 IP
5. GitHub Actions 的 `DEPLOY_HOST` 改为香港服务器 IP

### 3.1 首次部署（手动）

```bash
cd /opt
sudo mkdir -p bog-test-server
sudo chown $USER:$USER bog-test-server
git clone https://github.com/generalquin1991/bog-test-server.git bog-test-server
cd bog-test-server

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

sudo cp deploy/bog-test-server.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable bog-test-server
sudo systemctl start bog-test-server
```

### 3.2 数据库

- **本地**：`bog_test.db`（项目目录）
- **生产**：`/var/lib/bog-test-server/bog_test.db`（systemd 已配置）
- 环境变量 `BOG_DB_PATH` 可自定义路径
- **BOG 产测/调试分离**（`/home`、`/bog` 入口）：产测服务监听 **8000**、调试服务监听 **8001**；经 Nginx 对外时产测为 80/8080、调试为 8081。设置 `BOG_PRODUCTION_BASE_URL` 与 `BOG_DEVELOPMENT_BASE_URL` 后，BOG 页「产测」链到生产、「调试」链到开发，数据分离。按实际访问方式配置即可：
  - 经 Nginx 访问：`BOG_PRODUCTION_BASE_URL=http://8.129.99.18:8080`，`BOG_DEVELOPMENT_BASE_URL=http://8.129.99.18:8081`
  - 直连应用端口：`BOG_PRODUCTION_BASE_URL=http://8.129.99.18:8000`，`BOG_DEVELOPMENT_BASE_URL=http://8.129.99.18:8001`
  - 生产环境也需提供 `/home`、`/bog`、`/bog/production_dashboard` 等路由（合并 `feature/firmware-admin` 到 `main` 并部署即可）。

数据库已加入 `.gitignore`，不会被 git 覆盖。

### 3.3 域名绑定（generalquin.top，前缀 bog）

域名使用 `bog` 前缀，与本工程对应：
- 生产：`bog.generalquin.top`（80 + **8080**）
- 测试：`dev.bog.generalquin.top`（8081）

**国内服务器**：80/8080 等端口均可能被 ICP 备案拦截。**推荐改用阿里云香港等境外节点**，无需备案，80 端口可直接访问。

1. **DNS 配置**（腾讯云 DNSPod 等）：添加 A 记录
   - 主机记录 `bog`，记录值：服务器 IP
   - 主机记录 `dev.bog`，记录值：服务器 IP

2. **Nginx 配置**：已配置上述域名，生产同时监听 80 和 8080

3. **部署后**：`sudo tengine -t && sudo systemctl reload tengine`

### 3.4 反向代理

**Ubuntu/Debian：**
```bash
sudo apt install -y nginx
sudo cp deploy/nginx-bog-test-server.conf /etc/nginx/conf.d/
sudo nginx -t && sudo systemctl reload nginx
```

**CentOS / 阿里云 Linux（Tengine）：**
```bash
sudo dnf install -y tengine
sudo cp deploy/nginx-bog-test-server.conf /etc/tengine/conf.d/
sudo systemctl start tengine
```

**若访问 bog.generalquin.top 仍显示 Tengine 欢迎页**：默认站点可能优先匹配。执行修复脚本将默认 server 改为代理到 BOG：
```bash
cd /opt/bog-test-server  # 或你的项目路径
git pull
sudo bash deploy/fix-tengine-default.sh
```

### 3.5 GitHub Actions 自动部署

push 到 `main` 或 `dev` 时自动 SSH 部署。在仓库 **Settings → Secrets and variables → Actions** 中配置：

| Secret | 说明 |
|--------|------|
| `DEPLOY_HOST` | 服务器 IP（如 `8.129.99.18`） |
| `DEPLOY_USER` | SSH 用户名（如 `admin`） |
| `DEPLOY_SSH_KEY` | 本机 SSH 私钥全文（`cat ~/.ssh/id_rsa` 输出） |

> 公钥需已在服务器 `~/.ssh/authorized_keys` 中。未配置时部署 job 自动跳过。

**分支与数据隔离：**

| 分支 | 部署路径 | 内网端口 | 访问端口 | 数据库 | 用途 |
|------|----------|----------|----------|--------|------|
| `main` | `/opt/bog-test-server` | 8000 | 80, **8080** | `/var/lib/bog-test-server/bog_test.db` | 生产 |
| `dev` | `/opt/bog-test-server-dev` | 8001 | 8081 | `/var/lib/bog-test-server-dev/bog_test.db` | 测试 |

- 生产访问：`http://bog.generalquin.top`（境外节点 80 端口）或 `http://bog.generalquin.top:8080`（国内临时方案）
- 测试访问：`http://dev.bog.generalquin.top:8081` 或 `http://IP:8081`（需安全组放行 8081）

测试与生产数据完全隔离：不同目录、不同端口、不同数据库文件。dev 首次部署时会从 prod 目录复制代码并创建独立 venv。**注意**：dev 部署前需先完成 main（prod）的首次部署。

**常见问题：**
- `ssh: no key found`：私钥需完整复制（含 `-----BEGIN...-----` 和 `-----END...-----`）
- `unable to authenticate`：先用 `ssh-copy-id` 将公钥加入服务器
- dev 部署失败：可在 GitHub **Actions** 页查看日志；常见原因：`git safe.directory`、`sudo cp` 相对路径、权限。脚本已改用绝对路径和 `set -e` 便于定位

---

## 四、故障排查

**生产服务：**
```bash
sudo systemctl status bog-test-server
sudo journalctl -u bog-test-server -n 50 --no-pager
```

**测试服务（dev）：**
```bash
sudo systemctl status bog-test-server-dev
sudo journalctl -u bog-test-server-dev -n 50 --no-pager
# 若 502，检查服务是否运行；手动启动：
sudo systemctl start bog-test-server-dev
```

手动测试启动：

```bash
cd /opt/bog-test-server
source .venv/bin/activate
uvicorn main:app --host 0.0.0.0 --port 8000 --loop asyncio --app-dir /opt/bog-test-server
```
