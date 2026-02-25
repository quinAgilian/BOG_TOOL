# BOG Tool — Mac 桌面应用

用于通过 BLE 连接 **ESP32-C2** 设备的 Mac 图形界面工具，支持 Debug 模式、产测模式和 RTC 测试。

## 功能概览

1. **BLE 连接**  
   扫描并连接 ESP32-C2，支持按设备名称前缀过滤（在 `Config/GattServices.json` 中配置）。

2. **Debug 模式**  
   - 实时控制电磁阀：通过指定 UUID 写入 **开/关**（如 `0x01` 开、`0x00` 关）。  
   - 实时读取压力：通过另一 UUID 读取压力数值。

3. **产测模式**  
   连接后一键执行一次完整产测流程：  
   - **开阀前** 读一次压力  
   - **开阀**  
   - **开阀后** 读一次压力  
   - **关阀**  
   - **关阀后** 读一次压力  
   - 再次 **开阀**（完成 开→关→开 一次）

4. **RTC 测试**  
   向 RTC 对应 UUID 写入一串十六进制数据，触发设备返回 RTC 时间；应用再读取该特征值，用于确认 RTC 模块工作正常。

## 环境要求

- macOS 13.0+
- Xcode 15+（推荐）
- 已开启系统蓝牙

## 构建与运行

### 1. 打开工程

在终端执行（或在 Finder 里双击 `BOG_TOOL.xcodeproj`）：

```bash
cd /path/to/BOG_TOOL
open BOG_TOOL.xcodeproj
```

### 2. 选 Scheme 和运行目标（入口在这里）

在 Xcode 窗口**最上方正中间**有一条工具栏：

- **左边**：有一个 **▶ Run** 按钮和 **■ Stop** 按钮。  
- **中间**：有一个下拉框，格式一般是 **「BOG_TOOL」** + **「My Mac」**（或「BOG_TOOL > My Mac」）。  
  - 这个下拉框就是「选 target + 选运行目标」的**入口**。  
- **右边**：通常是设备/模拟器相关选项。

**操作：**

1. **点一下这个中间的下拉框**（显示 BOG_TOOL 或 BOG Tool.app 的那一栏）。  
2. 弹出菜单里会分两块：  
   - **上半部分**：可选的 **Scheme**（如 `BOG_TOOL`）。选中 **BOG_TOOL**。  
   - **下半部分**：**Run destination**（运行目标）。在 **Mac** / **macOS** 分类下选 **My Mac**（或带 Mac 图标的「My Mac」）。  
3. 若列表里没有 **BOG_TOOL**：点 **Manage Schemes…**，在列表里勾选 **BOG_TOOL**，并勾选 **Shared**，然后 OK。  
4. 若没有 **My Mac**：先选一次 **BOG_TOOL** scheme，再点同一下拉框，在运行目标里应会出现 **My Mac**（本机 Mac 应用只能选 My Mac）。

### 3. 运行

- 菜单栏选 **Product → Run**，或直接按 **⌘R**。  
- 第一次运行若弹出蓝牙权限，到 **系统设置 → 隐私与安全性 → 蓝牙** 里允许本应用使用蓝牙。

## GATT 与参数配置（不硬编码）

BLE 协议由 **`BOG_TOOL/Config/GattServices.json`** 定义，运行时由 **`GattMapping.swift`** 加载，代码中不硬编码 UUID。

- **`GattServices.json`**：从《GattServices 2025-04-11.xlsx》导出，包含所有 Service/Characteristic 的 UUID、描述、属性；其中 `appServiceUuids`、`appCharacteristicKeys` 指定本 App 使用的服务与特征 key。
- **`GattMapping.swift`**：从 Bundle 读取上述 JSON，提供 `deviceNamePrefix`、`appServiceCBUUIDs`、`characteristicUUID(forKey:)` 等，供 `BLEManager` 使用。
- 协议变更时只需更新 **`GattServices.json`**（或重新从 Excel 生成），无需改 Swift 代码。  
- 可选：**`UUIDConfig.swift`** 保留作后备或兼容旧固件时可参考。

## 项目结构

本仓库为 **monorepo**，包含两部分：

| 目录 | 说明 |
|------|------|
| **`BOG_TOOL/`** | macOS SwiftUI 应用（BLE 连接、产测、调试） |
| **`bog-test-server/`** | Python FastAPI 产测数据服务（独立部署、独立仓库可拆） |

**服务端与 APP 隔离**：APP 仅通过 HTTP API 与服务器通信；服务器可部署到远程，APP 在「服务器设置」中配置 base URL 即可。

```
BOG_TOOL/
├── BOG_TOOL.xcodeproj
├── BOG_TOOL/
│   ├── BOG_TOOLApp.swift      # 应用入口
│   ├── Networking/
│   │   ├── ServerClient.swift # 产测结果上报、健康检查（仅 HTTP）
│   │   └── ServerModels.swift # API 路径常量
│   ├── ServerSettings.swift   # 服务器 base URL、上传开关
│   ├── Config/
│   │   ├── GattServices.json  # GATT 协议定义（从 Excel 维护）
│   │   ├── GattMapping.swift  # 加载 JSON，供 BLE 按 key 取 UUID
│   │   └── UUIDConfig.swift   # 可选后备配置
│   ├── BLE/
│   │   ├── BLEManager.swift   # BLE 扫描、连接、读写
│   │   └── BLEDevice.swift    # 设备模型
│   ├── Views/
│   │   ├── ContentView.swift       # 主界面（设备列表 + 模式 + 日志）
│   │   ├── DeviceListView.swift    # 设备列表与连接
│   │   ├── DebugModeView.swift     # Debug 模式 UI
│   │   ├── ProductionTestView.swift # 产测模式 UI
│   │   └── RTCTestView.swift       # RTC 测试 UI
│   ├── Assets.xcassets
│   └── Info.plist              # 蓝牙使用说明等
├── bog-test-server/           # 产测数据服务（见 bog-test-server/README.md）
│   ├── main.py
│   ├── schemas.py
│   └── requirements.txt
└── README.md
```

## 产测数据上报

产测结束后，若开启「上传至服务器」，APP 会将结果 POST 到 `bog-test-server`。  
- 在 **服务器设置**（菜单 `Server → 服务器设置`）中配置 **base URL**（如 `http://你的服务器IP:8000`）。  
- 服务器部署说明见 `bog-test-server/README.md`。

## 固件约定（供参考）

- **电磁阀控制**：向 `valveControlUUID` 写入 1 字节，`0x01` = 开，`0x00` = 关。  
- **压力**：从 `pressureReadUUID` 读取或订阅通知，数据格式可在 `BLEManager.formatPressureData` 中按实际协议解析。  
- **RTC**：向 `rtcUUID` 写入约定好的十六进制命令后，设备在该特征上返回 RTC 数据；应用再读该特征得到时间，用于产测校验。

若固件协议（字节序、单位、RTC 格式）有变化，只需在 `BLEManager` 中调整对应解析逻辑即可。

---

### 常见问题：找不到 Scheme 或「My Mac」

- **下拉框里没有 BOG_TOOL**  
  菜单栏 **Product → Scheme → Manage Schemes…**，在列表里找到 **BOG_TOOL**，勾选它并勾选 **Shared**，关闭。再点工具栏中间下拉框，应能看到 BOG_TOOL。

- **没有「My Mac」这一项**  
  本工程是 Mac 应用，只支持在「My Mac」上运行。先确保已选中 **BOG_TOOL** scheme，再点同一下拉框，在 **Destination** 区域应出现 **My Mac**（或 **My Mac (Mac Catalyst)** 等，选带 Mac 图标的即可）。若仍没有，可尝试 **Product → Destination → My Mac**。

- **入口位置总结**  
  Scheme 和运行目标都在 **Xcode 窗口最上方工具栏正中间** 的下拉框里，点一下即可切换 **BOG_TOOL** 和 **My Mac**。
