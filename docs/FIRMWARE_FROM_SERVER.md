# 固件从服务器拉取：改造方案

## 一、当前工程理解

### 1.1 固件从哪里来（现状）

- **App 侧**：固件由用户本地管理。
  - **FirmwareManager**（`Config/FirmwareManager.swift`）：维护 `entries: [FirmwareEntry]`，每条为**本地文件的安全作用域书签**，持久化在 UserDefaults。
  - **新增固件**：菜单「固件 → 固件管理」或 FirmwareManagerView 里「新增固件」→ NSOpenPanel 选 `.bin` → `manager.add(url:)` 写书签、解析版本、保存。
  - **使用固件**：
    - **Debug OTA**（OTASectionView）：下拉 Picker 绑定 `firmwareManager.entries`，选 id → `firmwareManager.url(forId:)` → `ble.selectFirmware(url:)`。
    - **产测 OTA**（ProductionTestView / ProductionTestRulesView）：规则里配置目标版本（如 1.0.5）→ `firmwareManager.url(forVersion:)` → `ble.startOTA(firmwareURL:)`。
  - **BLEManager**：OTA 时从**本地文件 URL** 读二进制并分包发送，不涉及网络。

### 1.2 服务器侧（已有能力）

- **bog-test-server** 已提供固件管理与下载（需管理员鉴权）：
  - **列表**：`GET /api/admin/firmware?usage_type=ota_app&channel=production|debugging`  
    返回 `{ "items": [ { "id", "version", "fileName", "downloadUrl", "fileSizeBytes", ... } ] }`。
  - **下载**：`GET /api/admin/firmware/{firmware_id}/download`  
    返回文件流，需与列表接口相同的 **admin 鉴权**（Cookie）。
- 固件文件在服务器上存放在 `BOG_FIRMWARE_ROOT`（默认 `server/firmware_files/`），按 `usage_type`（如 `ota_app`）和 `channel` 分子目录。

### 1.3 已有相关配置

- **ServerSettings**：已持久化 `serverBaseURL`、`uploadToServerEnabled`，用于产测上报、健康检查等；**未**包含 admin 登录态或固件拉取。
- **ServerClient**：仅实现产测上报、固件升级记录上报、健康检查，**未**实现固件列表/下载。

---

## 二、改造目标

- **从服务器拉取固件**：App 不再（或不仅）依赖本地选择的 bin 文件，而是从已配置的 bog-test-server 拉取固件列表，选择后下载到本地再执行 OTA。
- **可选**：保留「本地管理」作为补充（混合模式），或完全改为仅用服务器（纯服务器模式）。

---

## 三、推荐改造思路

### 3.1 方案概览

| 项目 | 说明 |
|------|------|
| **数据源** | 增加「服务器固件源」：按当前 ServerSettings.baseURL 请求 `/api/admin/firmware?usage_type=ota_app`（及可选 channel），得到列表。 |
| **鉴权** | 列表与下载接口目前均 `require_admin`。二选一或组合：**(1)** App 内增加「服务器管理员登录」流程，登录后存 Cookie，请求 list/download 时带 Cookie；**(2)** 服务端新增只读 API（如 `GET /api/firmware`，API Key 或内网免鉴权），供 App 专用。 |
| **选择与下载** | 用户在下拉/列表中选「某条服务器固件」→ 按需下载该 id 对应文件到本地缓存/临时目录 → 得到本地 URL → 沿用现有 `ble.selectFirmware(url:)` / `ble.startOTA(firmwareURL:)` 流程。 |
| **本地与服务器** | **推荐先做混合**：保留现有 FirmwareManager 本地条目；增加「服务器列表」入口；Picker 可显示「本地」+「服务器」两类，或分两个区；产测规则中的「目标 FW 版本」可从服务器列表选择，按版本匹配时优先用服务器拉取的版本。 |

### 3.2 模块级改动建议

1. **ServerClient（或新建 FirmwareServerClient）**
   - 增加：
     - `listFirmware(usageType:channel:) async throws -> [ServerFirmwareItem]`  
       请求 `GET /api/admin/firmware`，解析 `items`。
     - `downloadFirmware(id: String) async throws -> URL`  
       请求 `GET /api/admin/firmware/{id}/download`，将 body 写入临时文件（如 `FileManager.temporaryDirectory` 下按 id 或 id+version 命名），返回本地 URL。  
   - 若使用 admin 鉴权：在登录成功后保存 Cookie，上述请求使用同一 URLSession（或注入携带 Cookie 的 session）。

2. **鉴权（若用现有 admin 接口）**
   - 在 ServerSettings 或单独「服务器登录」处：
     - 提供管理员账号/密码输入；
     - 调用 `POST /api/admin/login`，成功后由 URLSession 自动存储服务端 Set-Cookie（若用同一 session 请求 list/download 即可带 Cookie）。
   - 或：服务端新增 `GET /api/firmware`、`GET /api/firmware/{id}/download`，用 API Key header 或内网白名单，App 只存 baseURL + 可选 API Key，不存管理员密码。

3. **FirmwareManager 扩展（推荐）**
   - 保持现有 `entries`（本地书签）与 `add(url:)`、`remove(id:)`、`url(forVersion:)`、`url(forId:)`。
   - 增加「服务器固件」状态与能力：
     - `serverItems: [ServerFirmwareItem]`（从 ServerClient 拉取的结果）；
     - `fetchServerFirmware(usageType:channel:) async`：调用 ServerClient.listFirmware，更新 serverItems；
     - `downloadServerFirmware(id:) async throws -> URL`：调用 ServerClient.downloadFirmware，返回本地缓存 URL；
     - 可选：内存或轻量持久化「id → 本地缓存 URL」的映射，避免重复下载。
   - **统一入口**（供 UI 使用）：
     - 方式 A：`url(forId:)` 与 `url(forVersion:)` 仅处理本地；UI 侧对「服务器项」单独用 `downloadServerFirmware(id:)` 得到 URL 再传给 BLE。
     - 方式 B：抽象一层「固件来源」（本地 / 服务器），`url(forId:)` / `url(forVersion:)` 增加「若为服务器 id 则先下载再返回缓存 URL」的逻辑，这样 OTASectionView / 产测 OTA 可尽量少改。

4. **UI**
   - **OTASectionView**：下拉数据源从「仅 firmwareManager.entries」改为「本地 entries + 服务器 serverItems」；选择服务器项时，先 `downloadServerFirmware(id:)`，再 `ble.selectFirmware(url:)`；可显示「版本 + 来源(本地/服务器)」。
   - **产测规则 / ProductionTestView**：目标版本选择可增加「从服务器列表选」；执行 OTA 时若该版本来自服务器，则先按 id 下载再 `ble.startOTA(firmwareURL:)`。
   - **FirmwareManagerView**：可增加「从服务器刷新」按钮、展示 serverItems 列表；可选「仅用服务器」时隐藏本地「新增固件」。

5. **缓存与清理**
   - 下载的 bin 放在临时目录或 Application Support 下固定子目录；可约定「同一 id 若已存在且未过期则直接返回」；App 退出或定期清理过期缓存即可。

### 3.3 服务端可选增强（若希望 App 不碰 admin 账号）

- 新增只读接口，例如：
  - `GET /api/firmware?usage_type=ota_app&channel=...`  
    返回与 admin 列表同结构的列表，鉴权方式：Query/Header 中 API Key 或 IP 白名单。
  - `GET /api/firmware/{id}/download`  
    同上鉴权，返回文件流。
- 这样 App 只需配置 baseURL + 可选 API Key，无需管理员账号密码。

---

## 四、实施顺序建议

1. **分支**：已在 `feature/firmware-from-server`，后续改动均在此分支。
2. **鉴权与 API**：先确定用「admin 登录」还是「只读 API」；若只读 API，先在 server 实现并记入 API_SPEC。
3. **ServerClient**：实现 listFirmware + downloadFirmware（含鉴权方式）。
4. **FirmwareManager**：增加 serverItems、fetchServerFirmware、downloadServerFirmware；必要时抽象「按 id/version 解析出本地 URL」供 OTA 使用。
5. **UI**：OTASectionView、产测规则/执行处，接入「服务器列表」与「下载后 OTA」。
6. **测试**：无网/服务器不可用时列表为空或提示；有网时列表拉取、下载、OTA 全流程验证。

---

## 五、与现有文档的关系

- 固件**加载与使用**的 App 内流程（书签、OTA 调用链、沙盒）仍见 [FIRMWARE_LOADING_LOGIC.md](FIRMWARE_LOADING_LOGIC.md)。
- 服务端 API 规范见 [../server/API_SPEC.md](../server/API_SPEC.md)；若新增只读固件接口，需在该文档中补充。
