# BOG 产测数据服务

接收 BOG_TOOL 产测结束时 POST 的数据，落库（SQLite），并提供汇总（Summary）与记录查询、导出。  
**推荐部署到远程服务器，BOG_TOOL APP 作为 HTTP 客户端连接。**

## 环境要求

- Python 3.9+
- 无其它系统依赖（仅 FastAPI + uvicorn）

## 一、本地部署与测试

### 1. 安装依赖

```bash
cd bog-test-server
python3 -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

### 2. 启动服务

```bash
uvicorn main:app --host 127.0.0.1 --port 8000 --reload
```

- 本地访问：<http://127.0.0.1:8000>
- 数据概览页：<http://127.0.0.1:8000/>（Summary 卡片 + 最近记录表）
- API 文档：<http://127.0.0.1:8000/docs>

### 3. 本地测试 POST

数据库会在首次请求时自动创建，表名为 `production_tests`，数据文件默认为当前目录下的 `bog_test.db`。  
可通过环境变量 `BOG_DB_PATH` 指定数据库路径（绝对路径或相对当前目录的路径）。

用 curl 模拟 BOG_TOOL 上报一条记录：

```bash
curl -X POST http://127.0.0.1:8000/api/production-test \
  -H "Content-Type: application/json" \
  -d '{
    "deviceSerialNumber": "SN-TEST-001",
    "overallPassed": true,
    "needRetest": false,
    "deviceFirmwareVersion": "1.0.5",
    "deviceBootloaderVersion": "2",
    "deviceHardwareRevision": "P02V02R00",
    "stepsSummary": [
      {"stepId": "step1", "status": "passed"},
      {"stepId": "step2", "status": "passed"}
    ]
  }'
```

然后在浏览器打开 <http://127.0.0.1:8000/> 查看概览与记录。

### 4. BOG_TOOL 配置（本地测试）

在 BOG_TOOL 产测规则/设置中（待后续在 App 内增加）：

- **上报地址**：`http://127.0.0.1:8000/api/production-test`
- **启用上报**：打开

产测结束后，App 会向该地址 POST 一条产测记录。

---

## 二、部署到云端（腾讯云轻量等）

本地验证通过后，将同一套代码部署到云服务器。

### 1. 服务器准备

- 系统：Ubuntu 22.04 或 Debian
- 开放端口：80（若用 Nginx 反代）、或直接开放 8000（仅内网/测试用）

### 2. 安装 Python 与依赖

```bash
sudo apt update
sudo apt install -y python3 python3-pip python3-venv
cd /opt   # 或你希望的目录
sudo mkdir -p bog-test-server
sudo chown $USER:$USER bog-test-server
cd bog-test-server
```

将本地的 `main.py`、`schemas.py`、`requirements.txt` 上传到该目录（scp、git clone 或粘贴内容）。

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 3. 后台运行（systemd）

创建服务文件：

```bash
sudo nano /etc/systemd/system/bog-test-server.service
```

内容示例（注意路径与用户按实际修改）：

```ini
[Unit]
Description=BOG Production Test Data Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/bog-test-server
Environment="PATH=/opt/bog-test-server/.venv/bin"
Environment="BOG_DB_PATH=/opt/bog-test-server/bog_test.db"
ExecStart=/opt/bog-test-server/.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

然后：

```bash
sudo systemctl daemon-reload
sudo systemctl enable bog-test-server
sudo systemctl start bog-test-server
sudo systemctl status bog-test-server
```

此时服务监听在 `0.0.0.0:8000`。  
访问：`http://你的公网IP:8000/` 为数据概览，`http://你的公网IP:8000/api/production-test` 为 POST 接收地址。

### 4. 可选：Nginx + HTTPS

若希望用 80/443 和域名：

- 安装 Nginx，配置反向代理到 `127.0.0.1:8000`
- 用 Let's Encrypt 申请证书，配置 HTTPS  
则 BOG_TOOL 上报地址可设为：`https://你的域名/api/production-test`

---

## API 说明

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/production-test` | 接收一条产测结果（JSON body） |
| GET  | `/api/summary` | 汇总：总次数、今日次数、通过率等 |
| GET  | `/api/records` | 分页记录，支持 `sn`、`date_from`、`date_to` |
| GET  | `/api/export` | 导出 CSV，支持同上查询参数 |
| GET  | `/` | 数据概览页（Summary + 记录表） |

POST 请求体字段（与 BOG_TOOL 约定）：

- `deviceSerialNumber`（必填）
- `overallPassed`（必填）
- `needRetest`（可选，默认 false）
- `startTime` / `endTime` / `durationSeconds`（可选）
- `deviceName` / `deviceFirmwareVersion` / `deviceBootloaderVersion` / `deviceHardwareRevision`（可选）
- `stepsSummary`：`[{"stepId":"step1","status":"passed"}, ...]`
- `stepResults`：`{"step1":"详情", ...}`（可选）
