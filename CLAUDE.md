# BOG_TOOL — Agent 工作约定

Mac 产测/Debug 应用（Swift / Xcode）。BLE 连 DUT；产线气路阀规划见 WiFi 辅材（`../BOG_VALVE_WIFI`）。

## 规划文档（实现前必读）

| 文档 | 主题 |
|------|------|
| [`docs/plans/remove-gas-leak-open-step.md`](docs/plans/remove-gas-leak-open-step.md) | 废除 `step_gas_leak_open`，仅保留关阀漏气 |
| [`docs/plans/auto-valve-wifi-system.md`](docs/plans/auto-valve-wifi-system.md) | WiFi 入口阀、工位 UI、规则联动、禁止硬编码 |

实现 WiFi 气阀时以规划为准；HTTP 契约以 `BOG_VALVE_WIFI/docs/API.md` 为准。

---

## 强制规则（必须遵守）

### 1. 改完代码必须编译成功

- 任何 Swift / 工程配置改动后，在交付或请用户验收前，**必须**在本机完成一次成功构建。
- 推荐命令（仓库根目录）：

```bash
xcodebuild -project BOG_TOOL.xcodeproj -scheme BOG_TOOL -destination 'platform=macOS' build
```

- 若构建失败：先修到通过，再汇报完成；不要把「编译未验证」的 diff 交给用户。

### 2. 未经明确允许，不得提交

- **禁止**主动 `git add` / `git commit` / `git push`，除非用户当次对话里**明确要求**提交（或指定 commit message / 分支策略）。
- 可以准备变更说明、建议的 commit 分批方案；由用户决定是否入库与推送。
- 文档-only 改动同样适用，除非用户明确说「提交文档」。

### 3. 改代码必须全局考虑，复用既有框架

- 动手前：读相关模块（`BLEManager`、`ProductionTestView`、`ServerSettings`、`ProductionRules`、`UIDesignSystem` 等），对齐现有命名、分层与数据流。
- **优先扩展**已有类型（如仿 `ServerSettings` 做 `AuxValveSettings`），避免在单个 View 里堆一次性逻辑。
- **禁止**「到处打补丁」：同一能力只应有一处编排入口（Coordinator / Settings / Client），不散落魔法数、重复 mDNS/HTTP、重复弹窗分支。
- 可调参数：工位级 → `UserDefaults` + 设置 Sheet；产测阈值/时长 → `ProductionRules` JSON；协议常量 → 集中 `Protocol` 文件（见 WiFi 规划 §4.11）。
- 改动范围尽量小，但小 diff 不等于局部 hack；若需新模块，先说明边界再实现。
- **BLE 产测核心**（GATT、`runProductionGasLeakStep` 判定公式）无规划批准不得改。

---

## 仓库结构（简）

| 路径 | 说明 |
|------|------|
| `BOG_TOOL/` | App 源码 |
| `BOG_TOOL/Config/GattServices.json` | BLE UUID（勿在 Swift 硬编码 UUID） |
| `docs/plans/` | 产品/实现规划 |
| `server/` | 上报 API、规则说明 |
| `../BOG_VALVE_WIFI` | WiFi 阀辅材固件（独立仓） |

## 常用约定

- 产测规则真源：`BOG_TOOL/default_production_rules.json`
- 服务器设置模式参考：`BOG_TOOL/ServerSettings.swift`、`ContentView` 底栏 `ServerStatusFooter`
- 用户可见文案：同步 `zh-Hans.lproj` / `en.lproj` `Localizable.strings`
