# 产测废除「开阀泄漏」步骤（`step_gas_leak_open`）规划

> **本文专题**：从产线 SOP 与 BOG_TOOL 中**彻底移除** `step_gas_leak_open`（leakage-open / 开阀泄漏检测），仅保留 **`step_gas_leak_closed`**。  
> **与 WiFi 入口阀辅材无关** — 见 [`auto-valve-wifi-system.md`](./auto-valve-wifi-system.md)。

> **修订说明**
>
> | 版本 | 结论 | 状态 |
> |------|------|------|
> | v1.0 | 代码已不执行 open 步骤；文档/样例清理清单 | 边界仍有效 |
> | **v1.1（本文）** | 对齐 WiFi 规划：读压开阀弹窗、§4.10 规则联动、§7 交叉核对表 | 当前 |

---

## 1. 背景与结论

历史上曾存在两条漏气产测步骤：

| 步骤 ID | 名称 | 判定通道 |
|---------|------|----------|
| `step_gas_leak_open` | 开阀泄漏检测 | 开阀压力（**已废除**） |
| `step_gas_leak_closed` | 关阀泄漏检测 | 关阀压力（**唯一保留**） |

**产品结论（与当前 App 一致）**：

- 产测 **不再提供、不再执行、不再配置** `step_gas_leak_open`。
- **安全**：现行预览/发布代码中 **没有任何路径** 启用或运行 open 泄漏步骤（见 §3）。
- **允许保留**：服务端/API 中 `gasLeakOpen*` 等字段仅用于**旧记录只读**；新产测不得再产生 open 步骤结果。

---

## 2. 与 Phase 4、Debug 的区分（避免混淆）

| 概念 | 是否独立产测步骤 | 控制/判定对象 |
|------|------------------|---------------|
| **`step_gas_leak_open`（废除）** | 曾是 | 整条开阀泄漏 SOP |
| **`step_gas_leak_closed`** | **是，唯一漏气步骤** | 关阀压力 + 泄漏判定 |
| **Phase 4**（`step_gas_leak_closed` 内可选） | 否 | **DUT** 内电磁阀 BLE 开阀 + 开阀压力泄压监测 |
| **Debug「判定压力源 = 开阀」** | 否（非产测步骤） | Debug 漏气 UI 选通道，**不是** `step_gas_leak_open` |
| **入口管阀人工确认 / WiFi 开·关阀** | 否 | 产线**入口阀**：读压前 WiFi **开**、漏气 Phase 2 WiFi **关**（见 WiFi 规划 §4.7/§4.4） |

废除 open 步骤 **不等于** 取消 Phase 4，也 **不等于** 取消 Debug 里「开阀压力源」选项。

---

## 3. 代码现状审计（BOG_TOOL App）

以下均为 **2026-05 当前主分支行为**，说明 **已可安全视为移除完成**（App 侧）；剩余工作主要是文档与样例一致性（§5）。

### 3.1 不执行、不启用

| 检查项 | 结果 |
|--------|------|
| `ProductionTestView.baseSteps` | 仅含 `step_gas_leak_closed`，**无** open |
| FQC `switch` | 仅 `case "step_gas_leak_closed"` |
| `runProductionGasLeakStep` | **只**被关阀步骤调用 |
| `loadProductionGasLeakConfig()` | 只读 `TestStep.gasLeakClosed.id` |
| 上报 `testDetails` | 仅 `gasLeakClosed*` / `capturedGasLeakClosed*`，Swift **无** `gasLeakOpen*` 写入 |
| `ProductionRules.swift` | 仅 `step_gas_leak_closed` 配置结构 |
| 规则 UI | 仅 `gasLeakClosed*` 表单项，**无** open 步骤配置区 |
| `default_production_rules.json` | **无** `step_gas_leak_open` 条目 |
| `production_rules_for_DEV.json` | **无** open 步骤 |

### 3.2 规则与迁移防护

| 机制 | 行为 |
|------|------|
| `ProductionTestRulesView` 构建步骤列表 | 若含 `step_gas_leak_open` → **`removeAll`** |
| `loadTestRules` + `mergedWithTemplate` | 持久化 JSON 与 bundle 模板步骤集合不一致时 → **按模板同步并移除 open**，写回 `current_production_rules.json`（日志：`已按内置模板同步步骤列表…`）→ **同步后正常开测** |
| `applyRules` 严格校验 | 同步后 JSON 仍含未知 id（不应出现）→ **`[JSON非法] steps 包含未知 id`** → 产测无法启动 |
| 旧 `step_gas_leak` 启用状态 | 只迁到 **`step_gas_leak_closed`**（open 已从列表剔除） |
| 旧 UserDefaults `step_gas_leak_open: true` | 步骤被删，**不生效** |

### 3.3 操作员弹窗（入口阀，非 open 步骤）

**入口阀开**（`step_read_pressure`，非漏气步骤内）：

| 条件 | 弹窗 |
|------|------|
| 人工模式 / WiFi 失败 | `production_test.pressure_pipeline_ready_*`（入口+出口确认） |
| WiFi 自动成功（`canUseAuxValveAutomation`） | **无**（见 WiFi 规划 §4.3/§4.7） |

在 **`step_gas_leak_closed`** 内（与 open 步骤无关）：

| 规则开关 | 弹窗 | 是否要求动入口阀 |
|----------|------|------------------|
| `require_pipeline_ready_confirm: true` | 确认气路已连接 | **否**（文案不要求开/关入口阀） |
| `require_valve_closed_confirm: true` | **关闭入口阀门** | **是，关一次**（默认开） |
| 上述均为 false | 无对应弹窗 | — |

**WiFi 自动模式**（`canUseAuxValveAutomation`，WiFi 规划 §4.10）：规则页强制 `require_pipeline_ready_confirm=false`、`require_valve_closed_confirm=true` 且 Toggle 禁用；关阀成功 **0 次**关阀确认弹窗。

**每跑一轮漏气步骤（人工路径）**：至多 **1 次**「关入口阀」提醒。

**没有任何产测弹窗**要求操作员为 **open 泄漏步骤** 去开/关入口阀。

---

## 4. 废除后仍有效的配置（仅 `step_gas_leak_closed`）

`step_gas_leak_closed.config` 例如：

- `require_pipeline_ready_confirm` / `require_valve_closed_confirm`
- `pre_close_duration_seconds` / `post_close_duration_seconds` / `interval_seconds`
- `drop_threshold_mbar` / `start_pressure_min_mbar` / `limit_source` / `limit_floor_bar`
- `phase4_enabled` / `phase4_*`（DUT 泄压，非 open 步骤）

**不得**再新增或引用：

- `step_gas_leak_open` 或 `gasLeakOpen*` 规则键
- open 专用 UserDefaults 前缀、第二套漏气步骤 UI 块
- `gasLeakSkipClosedWhenOpenPasses` 等旧扁平规则字段（仅遗留样例中存在）

---

## 5. 待办：文档与样例清理（代码外）

App 产测逻辑 **无需** 为废除 open 再改功能；建议单独 PR 做仓库一致性：

| 项 | 路径 | 建议 |
|----|------|------|
| 服务端规则指南 | `server/PRODUCTION_RULES_JSON_GUIDE.md` | 删除或标注 §5.8 `step_gas_leak_open` 为**已废弃** |
| API 说明 | `server/API_SPEC.md` | `gasLeakOpen*` 注明**仅历史记录** |
| 样例上报脚本 | `server/scripts/submit_sample_report.py` | 改为仅 closed 或注释 open 为 legacy sample |
| 旧扁平样例 | `docs/samples/production/ProductionTestRules0313.json` | 删除 open 步骤条目或整文件标注 archive |
| 规则页注释 | `ProductionTestRulesView.swift` L382 | 可选：改注释「两个新步骤」→「关阀泄漏步骤」 |

**禁止**：恢复 `step_gas_leak_open`、双漏气步骤、或新产测写入 `gasLeakOpen*` 业务字段。

---

## 6. 测试与验收

| 场景 | 期望 |
|------|------|
| 默认 / DEV 规则跑 FQC | 只出现 **一条** 漏气步骤（关阀），结果只含 `gasLeakClosed*` |
| 规则 JSON 含 `step_gas_leak_open` | 首次开测时按模板**自动移除 open** 并保存；**不**执行 open 步骤 |
| 规则 UI 导入旧 JSON 含 open | 列表中 **无** open 步骤 |
| Dashboard 查旧记录 | 仍可显示历史 `gasLeakOpen*` |
| Debug  guided 漏气 | 仍可选开阀/关阀**压力源**；**不是** open 产测步骤 |

---

## 7. 与 WiFi 规划交叉核对（两文档一致性）

| 主题 | `remove-gas-leak-open-step` | `auto-valve-wifi-system` |
|------|----------------------------|---------------------------|
| 漏气步骤数量 | 仅 `step_gas_leak_closed` | 编排仅针对该步骤 + `step_read_pressure` 开阀 |
| `step_gas_leak_open` | **废除**，模板/迁移剔除 | 不引用 |
| Phase 4 | DUT BLE 泄压，保留 | 不 WiFi 开入口阀（§8.2） |
| 入口阀弹窗 | §3.3 表 | §4.3 成功无弹窗；失败 §4.9 Alert |
| 规则 `require_*_confirm` | §4 仍有效 | §4.10 自动模式下锁定 |
| 硬编码 | 阈值仍来自规则 JSON | 超时/阈值仅 `AuxValveSettings`（§4.11） |

---

## 8. 相关文档索引

| 文档 | 关系 |
|------|------|
| [`auto-valve-wifi-system.md`](./auto-valve-wifi-system.md) | 入口阀 WiFi：读压 **开** + 漏气 Phase 2 **关** + 规则联动 §4.10 |
| `BOG_TOOL/default_production_rules.json` | 现行 SOP 真源 |
| `ProductionTestView.swift` | `runProductionGasLeakStep` |
| `ProductionTestRulesView.swift` | 剔除 `step_gas_leak_open` |

---

*文档版本：v1.1 · 2026-05-21 · 专题：废除 step_gas_leak_open · 已与 WiFi 规划 §3.3/§7 对齐*
