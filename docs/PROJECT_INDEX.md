# BOG_TOOL 工程索引

本文档对当前仓库进行系统性索引，便于快速定位模块、文档与配置。

---

## 一、工程概览

| 项目 | 说明 |
|------|------|
| **名称** | BOG Tool — Mac 桌面应用 + 产测数据服务 |
| **用途** | 通过 BLE 连接 ESP32-C2 设备，支持 Debug、产测、RTC 测试；产测/烧录/PCBA 数据上报至远程服务 |
| **主入口** | macOS App：`BOG_TOOL.xcodeproj`；服务端：`server/main.py`（FastAPI） |
| **子模块** | `server` → [bog-test-server](https://github.com/generalquin1991/bog-test-server.git) |

---

## 二、仓库目录结构

```
BOG_TOOL/
├── README.md                    # 主说明（App 功能、构建、GATT 配置）
├── .gitmodules                  # server 子模块指向
├── .gitignore
├── VERSION                      # 版本号
├── docs/                        # 文档
│   ├── PROJECT_INDEX.md         # 本索引
│   ├── FIRMWARE_LOADING_LOGIC.md # 固件加载与 FirmwareManager 逻辑
│   └── FIRMWARE_FROM_SERVER.md   # 固件从服务器拉取改造方案（feature/firmware-from-server）
├── BOG_TOOL.xcodeproj/          # Xcode 工程
├── BOG_TOOL/                    # macOS SwiftUI 应用源码
├── server/                      # 产测数据服务（Git 子模块）
├── scripts/                     # 脚本
├── apk_extract/                 # 第三方提取内容（与主功能无关）
├── *.md                         # 根目录零散文档（见下文「文档索引」）
├── *.sh                         # 部署/权限脚本
└── *.bin, OTA说明.ini           # 固件/配置样本
```

---

## 三、BOG_TOOL 应用（macOS SwiftUI）

### 3.1 入口与全局

| 文件 | 说明 |
|------|------|
| `BOG_TOOLApp.swift` | 应用入口 |
| `AppLanguage.swift` | 多语言（中/英） |
| `ServerSettings.swift` | 服务器 base URL、上传开关 |
| `UIDesignSystem.swift` | UI 设计规范/样式 |

### 3.2 视图（Views/）

| 文件 | 说明 |
|------|------|
| `ContentView.swift` | 主界面：设备列表 + 模式切换 + 日志；固件管理 sheet |
| `DeviceListView.swift` | 设备列表与 BLE 连接 |
| `DebugModeView.swift` | Debug 模式：电磁阀控制、压力读取 |
| `ProductionTestView.swift` | 产测模式：一键产测流程、结果上报 |
| `ProductionTestRulesView.swift` | 产测规则与目标 FW 版本选择 |
| `RTCTestView.swift` | RTC 测试 |
| `OTASectionView.swift` | Debug 模式下的 OTA 区（固件选择/浏览） |
| `FirmwareManagerView.swift` | 固件管理 UI（新增/删除固件） |
| `GattProtocolView.swift` | GATT 协议展示 |
| `UUIDDebugView.swift` | UUID 调试 |

### 3.3 BLE（BLE/）

| 文件 | 说明 |
|------|------|
| `BLEManager.swift` | BLE 扫描、连接、读写；压力解析；固件版本解析 |
| `BLEDevice.swift` | 设备模型 |

### 3.4 配置（Config/）

| 文件 | 说明 |
|------|------|
| `GattServices.json` | GATT 协议定义（从 Excel 维护）；含 appServiceUuids、appCharacteristicKeys |
| `GattMapping.swift` | 从 Bundle 加载 JSON，提供 deviceNamePrefix、characteristicUUID(forKey:) 等 |
| `UUIDConfig.swift` | 可选后备 UUID 配置 |
| `FirmwareManager.swift` | 固件条目增删查、UserDefaults 持久化、安全作用域书签 |
| `OTA_Flow.md` | OTA 流程说明 |
| `Distribution_Guide.md` | 分发指南 |

### 3.5 网络（Networking/）

| 文件 | 说明 |
|------|------|
| `ServerClient.swift` | 产测结果上报、健康检查（HTTP） |
| `ServerModels.swift` | API 路径常量（与 server 路由一致） |

### 3.6 资源与配置

| 路径 | 说明 |
|------|------|
| `Assets.xcassets` | 图标、AccentColor |
| `Info.plist` | 蓝牙使用说明等 |
| `BOG_TOOL.entitlements` | 权限 |
| `zh-Hans.lproj/Localizable.strings` | 中文本地化 |
| `en.lproj/Localizable.strings` | 英文本地化 |

---

## 四、服务端（server/，子模块 bog-test-server）

### 4.1 核心文件

| 文件 | 说明 |
|------|------|
| `main.py` | FastAPI 应用：所有 API、Dashboard、固件管理、SSE、DB 初始化 |
| `schemas.py` | Pydantic 模型：ProductionTestPayload、BurnRecordPayload、PcbaTestRecordPayload、FirmwareUpgradePayload 等 |
| `API_SPEC.md` | API 规范（供其他工程/Agent 集成） |
| `README.md` | 服务说明、本地启动、部署 |
| `requirements.txt` | Python 依赖 |

### 4.2 API 分类速览（详见 API_SPEC.md）

- **产测**：`POST /api/production-test`、`/api/production-test/batch`，`GET /api/summary`、`/api/records`、`/api/sn-list`、`/api/export`
- **烧录**：`POST /api/burn-record`、`/api/burn-record/batch`，`GET /api/burn-records`、`/api/burn-bin-list`
- **PCBA**：`POST /api/pcba-test-record`、`/api/pcba-test-record/batch`，`GET /api/pcba-test-records`、`/api/pcba-mac-list`
- **固件升级**：`POST /api/firmware-upgrade-record`；`GET /api/firmware-history`
- **固件文件管理**（需管理员）：`GET /api/bog/firmware`，上传/删除/下载见 API_SPEC 2.5
- **其他**：`GET /api/deploy-info`、`/api/viewers`，`DELETE /api/clear-test-data`（仅 dev），Dashboard 与 admin 页面

### 4.3 部署（deploy/）

| 文件 | 说明 |
|------|------|
| `bog-test-server.service` | 生产 systemd 服务 |
| `bog-test-server-dev.service` | 测试环境 systemd |
| `nginx-bog-test-server.conf` | 生产 Nginx |
| `nginx-bog-test-server-dev.conf` | 测试 Nginx（如 8081） |
| `debug-nginx.sh` | Nginx/Tengine 调试 |
| `fix-tengine-default.sh` | 修复 Tengine 默认站点 |

### 4.4 自动化与 CI

| 文件 | 说明 |
|------|------|
| `run_auto_test.sh` | 本地自动化测试 |
| `.github/workflows/deploy.yml` | GitHub Actions 部署 |

### 4.5 数据与固件

- 数据库：SQLite，路径由环境变量 `BOG_DB_PATH` 或默认 `bog_test.db`
- 固件根目录：`BOG_FIRMWARE_ROOT` 或 `server/firmware_files`；子目录 `factory/{production|debugging}`、`ota/{production|debugging}`

---

## 五、文档索引（根目录与 docs）

| 文档 | 说明 |
|------|------|
| `README.md` | 主说明：功能、构建、Scheme/My Mac、GATT 配置、产测上报、固件约定 |
| `docs/PROJECT_INDEX.md` | 本索引 |
| `docs/FIRMWARE_LOADING_LOGIC.md` | 固件加载：FirmwareManager、FirmwareEntry、版本解析、OTA/产测规则入口 |
| `server/API_SPEC.md` | 服务端 API 规范 |
| `server/README.md` | 服务端使用与部署 |
| `VERSION_AND_RELEASE.md` | 版本与发布说明 |
| `OTA_SPEED_ANALYSIS.md` | OTA 速度分析 |
| `GATT_UUID_READWRITE_CHECK.md` | GATT UUID 读写检查 |
| `UUID_COMPARISON_FIX.md` | UUID 比较修复说明 |
| `DEVICE_INFO_DEBUG.md` | 设备信息调试 |
| `为什么直接打开应用不行的说明.md` | 直接打开应用限制说明 |
| `找不到Signing标签的解决方法.md` | Signing 设置 |
| `如何找到Signing设置-详细步骤.md` | Signing 详细步骤 |
| `快速设置指南-免费账号.md` | 免费账号快速设置 |
| `BOG_TOOL/Config/OTA_Flow.md` | OTA 流程 |
| `BOG_TOOL/Config/Distribution_Guide.md` | 分发指南 |

---

## 六、脚本与可执行

| 文件 | 说明 |
|------|------|
| `scripts/update_version.sh` | 版本号更新 |
| `deploy_to_other_mac.sh` | 部署到其他 Mac |
| `fix_app_permissions.sh` | 修复应用权限 |

---

## 七、关键配置与约定

- **GATT**：由 `BOG_TOOL/Config/GattServices.json` 定义，`GattMapping.swift` 加载；协议变更时优先改 JSON。
- **服务器 Base URL**：在 App 内「服务器设置」配置；默认生产 `http://8.129.99.18:8000`，测试可配 `http://8.129.99.18:8001` 或域名。
- **固件版本解析**：见 `docs/FIRMWARE_LOADING_LOGIC.md` 与 `BLEManager.parseFirmwareVersion`；文件名如 `CO2ControllerFW_1_1_3.bin` → `1.1.3`。
- **时间格式**：服务端接受 `YYYY-MM-DD HH:MM:SS`（本地）及 ISO 8601；与 flash_esp 一致。

---

## 八、构建与运行速查

- **Mac App**：`open BOG_TOOL.xcodeproj` → Scheme 选 BOG_TOOL，Destination 选 My Mac → ⌘R。
- **服务端**：`cd server && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && uvicorn main:app --host 127.0.0.1 --port 8000 --reload`。
- **服务端自动化测试**：`./server/run_auto_test.sh`。

---

*索引生成自当前工程结构，随仓库变更需人工更新。*
