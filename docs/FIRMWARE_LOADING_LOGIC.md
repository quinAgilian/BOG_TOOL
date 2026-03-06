# 固件加载逻辑梳理

## 一、整体架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           固件管理入口                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│  1. 菜单「固件 → 固件管理」(Cmd+F) → ContentView.sheet → FirmwareManagerView  │
│  2. Debug 模式 OTA 区 → OTASectionView 下拉选择 / 浏览                        │
│  3. 产测规则 → ProductionTestRulesView 选择目标 FW 版本                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

## 二、核心组件

### 2.1 FirmwareManager (`Config/FirmwareManager.swift`)

**职责**：固件条目的增删查、持久化（UserDefaults）

| 方法 | 说明 |
|------|------|
| `add(url: URL) -> Bool` | 从文件 URL 创建安全作用域书签，解析版本，追加到 entries 并保存 |
| `remove(id: UUID)` | 删除指定 id 的固件 |
| `url(forVersion version: String) -> URL?` | 按版本号返回第一个匹配的 URL（产测 OTA 用） |
| `url(forId id: UUID) -> URL?` | 按 id 返回 URL（Debug OTA 下拉用） |
| `entry(forId id: UUID) -> FirmwareEntry?` | 根据 id 取 entry |

**存储**：`UserDefaults` key = `firmware_manager_entries`，值为 `[FirmwareEntry]` 的 JSON

### 2.2 FirmwareEntry

```swift
struct FirmwareEntry {
    let id: UUID
    let bookmarkData: Data      // 安全作用域书签
    var pathDisplay: String    // 仅用于列表显示
    var parsedVersion: String  // 如 "1.0.5"
    
    func resolveURL() -> URL?  // 从书签解析 URL
}
```

### 2.3 版本解析 (`BLEManager.parseFirmwareVersion`)

**规则**：
1. 文件名去掉扩展名，按 `_` 分割，过滤出纯数字部分
2. 若数字部分 ≥ 3 个，取最后 3 个拼接为 `x.y.z`
3. 否则用正则匹配：
   - `(\d+)_(\d+\.\d+\.\d+)` → 取固件部分
   - `(\d+)_(\d+)_(\d+)_(\d+)` → 取后 3 个拼接

**示例**：
- `CO2ControllerFW_0_4_2.bin` → `0.4.2`
- `CO2ControllerFW_1_1_3.bin` → `1.1.3`

## 三、新增固件流程（FirmwareManagerView）

```
用户点击「新增固件」
    ↓
addFirmware() → NSOpenPanel
    ↓
panel.allowedContentTypes = [.bin]
panel.runModal()
    ↓
for url in panel.urls:
    manager.add(url: url)   ← 返回值被忽略，无失败反馈
```

### 3.1 FirmwareManager.add(url:) 内部逻辑

```swift
func add(url: URL) -> Bool {
    // 1. 创建安全作用域书签（沙盒下持久化访问必需）
    guard let bookmarkData = try? url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    ) else { return false }  // 失败时静默返回 false

    // 2. 解析版本
    let parsedVersion = BLEManager.parseFirmwareVersion(from: url) ?? "—"

    // 3. 创建 entry 并保存
    let entry = FirmwareEntry(...)
    entries.append(entry)
    save()
    return true
}
```

**潜在问题**：
- `bookmarkData(options: .withSecurityScope, ...)` 失败时返回 `false`，但 UI 不提示
- 沙盒下需 `com.apple.security.files.bookmarks.app-scope` 权限才能创建安全作用域书签
- NSOpenPanel 返回的 URL 已有隐式安全作用域，但创建书签前建议显式 `startAccessingSecurityScopedResource()`

## 四、固件使用流程

### 4.1 Debug OTA（OTASectionView）

1. 下拉 Picker 绑定 `firmwareManager.entries`
2. `onChange(of: pickerChoice)` → `firmwareManager.url(forId: id)` → `ble.selectFirmware(url:)`
3. `ble.selectFirmware` 内部调用 `applySelectedFirmwareURL`：
   - 释放旧的安全作用域
   - 对新 URL 调用 `startAccessingSecurityScopedResource()`
   - 保存书签到 UserDefaults
   - 更新 `selectedFirmwareURL`

### 4.2 产测 OTA（ProductionTestView）

1. 产测规则中配置目标 FW 版本（如 `1.0.5`）
2. step2 确认固件版本时，若 FW 不匹配且开启 OTA，检查 `firmwareManager.url(forVersion: rules.firmwareVersion)` 是否存在
3. OTA 步骤执行时：`firmwareManager.url(forVersion: rules.firmwareVersion)` → `ble.startOTA(firmwareURL:)`

### 4.3 resolveURL 与安全作用域

`FirmwareEntry.resolveURL()` 仅解析书签为 URL，**不**调用 `startAccessingSecurityScopedResource`。

调用方（BLEManager.selectFirmware / applySelectedFirmwareURL）在使用 URL 前会调用 `url.startAccessingSecurityScopedResource()`，逻辑正确。

## 五、沙盒与权限

**当前配置**（project.pbxproj）：
- `ENABLE_APP_SANDBOX = YES`
- `ENABLE_USER_SELECTED_FILES = readwrite`

**当前 entitlements**（BOG_TOOL.entitlements）：
- `com.apple.security.network.client`

**可能缺失**（用于安全作用域书签持久化）：
- `com.apple.security.files.bookmarks.app-scope` — 创建/解析 app-scoped 书签
- `com.apple.security.files.user-selected.read-write` — 用户选择文件（Xcode 可能通过 build 设置自动添加）

## 六、已知问题与修复建议

| 问题 | 影响 | 修复 |
|------|------|------|
| add() 失败无反馈 | 用户不知道添加失败 | 检查返回值，失败时弹窗或 Toast 提示 |
| 书签创建可能失败 | 沙盒权限不足 | 添加 `com.apple.security.files.bookmarks.app-scope` |
| 创建书签前未显式申请作用域 | 某些环境下书签创建失败 | 在 add 中调用 `startAccessingSecurityScopedResource()` 后再创建书签 |
| OneDrive 路径 | 云同步文件可能离线 | 建议将固件放在本地非同步目录 |
