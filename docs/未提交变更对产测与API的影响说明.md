# 未提交变更对产测顺序、判定规则与 API 的影响说明

**文档目的**：在提交前，明确当前工作区未提交变更对产测顺序、判定规则及服务端 API 契约的影响，确保发布可追溯、可回滚。

**结论摘要**：

| 维度         | 是否受影响 | 说明 |
|--------------|------------|------|
| 产测顺序     | **是（实现规则 JSON 化）**     | 步骤顺序和启用状态现在统一来自 `ProductionRules`（JSON），不再依赖 `UserDefaults["production_test_steps_order"]` 作为规则来源；整体执行顺序与之前保持一致。 |
| 判定规则     | **是（规则来源切换为 JSON）**  | 所有阈值、判定线下限、limit 基准等均由 `ProductionRules` 加载（bundle 内置 `rules/default_production_rules.json` + 应用时写出的 `current_production_rules.json`），不再从 UserDefaults 读取；具体数值含义与单位（bar/mbar）保持不变，仅规则的存储介质与加载入口变更。 |
| API 契约     | **是（向后兼容扩展，已落地）** | 产测上传 payload 中新增可选字段 `rules`（本次产测使用的完整 `ProductionRules` JSON 快照），以及查询接口 `/api/production_rules/versions`，旧服务端与旧客户端在缺省 `rules` 字段时完全兼容。 |

---

## 1. 产测顺序

### 1.1 存储与使用

- **规则来源**：  
  - 首次启动或尚未有用户自定义规则时，从 bundle 内置的 `rules/default_production_rules.json` 解析一份 `ProductionRules` 作为默认 SOP。  
  - 规则页点击「Apply」后，会将当前 UI 状态转为 `ProductionRules`，经 `ProductionRulesStore` 持久化到应用支持目录下的 `BOG Tool/Rules/current_production_rules.json`，作为后续运行与下次启动时的规则来源。
- **顺序与启用状态**：  
  - 测试步骤顺序与启用状态均来自 `ProductionRules.steps` 中的 `order` 与 `enabled` 字段。  
  - 规则页的拖拽排序与开关切换只会修改内存中的 `ProductionRules` 并在 Apply 时整体写回 JSON，不再通过 `UserDefaults` 分散存储。

### 1.2 执行顺序

- 产测执行顺序仍由 `enabledSteps` 决定，其来源于 `ProductionRules.steps` 中按 `order` 排序后筛选 `enabled == true` 的步骤。
- `TestStep` 枚举与 stepId 字符串保持原有语义，执行顺序与之前逻辑对齐，仅数据来源从 UserDefaults 迁移为 JSON。

**结论**：产测顺序的「业务语义」未变，但**规则存储与加载路径已经切换为基于 `ProductionRules` 的 JSON 配置**，从而实现规则的版本化与导入导出。

---

## 2. 判定规则

### 2.1 压力步骤（读取压力值）

- **闭/开压力区间**：`pressureClosedMin/Max`、`pressureOpenMin/Max`（单位 mbar），现在来自 `ProductionRules` 中 `read_pressure` 步骤的 `config` 字段（对应 JSON 中的 `closed_min_mbar` 等），不再读写 UserDefaults。  
- **压差区间**：`pressureDiffMin/Max`（mbar）同样来自 `ProductionRules` 的 JSON 配置。  
- **逻辑**：仍用 `closedMbar`/`openMbar` 与上述阈值比较；仅界面与 stepResults 的**展示文案**使用 mbar 表述，判定公式与上传 payload 中的数值单位未改。

### 2.2 气体泄漏步骤

- **Limit 基准**：仍为 `phase1_avg` / `phase3_first`，对应 `ProductionRules` 中气体泄漏步骤配置里的 `limit_source`。  
- **判定线下限（limit floor）**：
  - **存储**：仍为 **bar**，现在来自 `ProductionRules` JSON 中的 `limit_floor_bar`。  
  - **逻辑**：`effectiveLimitBar = max(computedLimitBar, config.limitFloorBar)` 等仍使用 bar；内部与 API 继续按 bar 处理。  
  - **界面**：规则页该行的 **展示与输入** 仍以 mbar 呈现，通过 Binding 做 mbar↔bar 换算，底层持久化与判定仍使用 bar。
- **压降阈值、起始压力下限**：为 mbar，统一存储在 `ProductionRules` 气体泄漏步骤的 `config` 中，业务含义与以前保持一致。

### 2.3 其他规则

- 失败时是否跳过恢复出厂/断开、压力失败是否重试、Phase 4 开关、Gas status 期望值集合等规则，现在都集中在 `ProductionRules` 结构及其 JSON 中；规则页的 UI 仅负责编辑这份结构，并在 Apply 时整体写回。  

**结论**：各项判定规则的**业务逻辑与数值含义未变**，但其唯一来源已经切换为 `ProductionRules`（JSON），不再分散依赖 UserDefaults，便于版本管理与导入导出。

---

## 3. API 影响

### 3.1 请求体结构（POST /api/production-test）

与 `server/API_SPEC.md` 及现有服务端一致：

- **顶层**：`deviceSerialNumber`、`overallPassed`、`needRetest`、`startTime`、`endTime`、`durationSeconds`、`deviceName`、设备版本字段、`stepsSummary`、`stepResults`、`testDetails`，以及**新增的可选字段** `rules`（本次产测使用的完整规则 JSON 快照）。
- **stepsSummary**：仍为 `stepIndex`、`stepName`、`stepId`、`status`；顺序与 enabledSteps 一致，未改。
- **stepResults**：仍为 `{ [stepId: string]: string }`。仅 value 的**文案内容**由「x.xx bar」改为「xxx mbar」等，key 与类型未改；服务端按原样存并展示，契约不变。

### 3.2 testDetails（结构化测试详情）

- **压力**：`pressureClosedMbar`、`pressureOpenMbar` 仍为 number（mbar），来源仍为 `capturedPressureClosedMbar` / `capturedPressureOpenMbar`，未改。
- **泄漏**：  
  - `gasLeakOpenPhase1AvgBar` / `gasLeakClosedPhase1AvgBar`：bar，未改。  
  - `gasLeakOpenThresholdMbar` / `gasLeakClosedThresholdMbar`：mbar，未改。  
  - `gasLeakOpenLimitBar` / `gasLeakClosedLimitBar`：bar，未改。  
  - `gasLeakOpenDeltaMbar` / `gasLeakClosedDeltaMbar`：mbar，未改。  
  - 采样数组：元素仍含 `phase`、`t`、`pressureBar`（bar）等，未改。
- **其他**：RTC、阀门、gas status、duration、userActionSeconds 等字段与类型未改。

### 3.3 服务端与 Dashboard

- 服务端：`testDetails` 仍为 `Optional[Dict[str, Any]]`，未改 schema。
- Dashboard：仍按 `pressureClosedMbar`（mbar）、`pressureBar`（bar）、`gasLeakClosedLimitBar`（bar）等解析与展示；客户端上传单位未变，故**无影响**。

**结论**：在保持原有字段与单位不变的前提下，API 契约新增并已经实现了**向后兼容的扩展字段与只读查询接口**：

- `POST /api/production-test` / `/api/production-test/batch`：新增可选字段 `rules`，用于上传当前规则快照（`ProductionRules` JSON），旧客户端不传该字段仍然兼容；
- `GET /api/production_rules/versions`：新增只读查询接口，用于按规则版本维度查看历史使用情况。

---

## 4. 未提交变更内容归类（便于 Code Review）

| 类别           | 内容概要 |
|----------------|----------|
| 展示单位统一   | 界面与日志中压力统一为 mbar（规则页判定线下限仅展示/输入 mbar，存 bar）；BLE 压力字符串格式改为 mbar；Debug 图表 Y 轴与结果详情改为 mbar。 |
| 解析兼容       | `parseBarFromPressureString` 同时支持 `"x.xx bar"` 与 `"xxx mbar"`，保证 BLE 格式改为 mbar 后内部仍得到 bar。 |
| 文案与 Phase   | Phase 命名统一为 Phase 1/2/3/4；泄漏/压力报表文案精简与中英本地化；跳过恢复出厂/断开时以 error 级别记录。 |
| UI/UX          | 产测规则页 UIDesignSystem 统一；payload 日志改为「短文案 + 预览链接」；报表前后空行等。 |
| 其他           | 步骤结果格式（如压力行带区间与 criteria hint）、O TA 按钮宽度等小改动。 |

---

## 5. 建议

- 未来若继续演进规则（例如引入多套 SOP、按产线或批次选择不同规则），应始终以 `ProductionRules` JSON 为真源，在此基础上扩展版本号与元数据，而不要再回退到 UserDefaults 零散 key。  
- 若后续服务端或 Dashboard 需区分「stepResults 中为 bar 还是 mbar 文案」，可仅做展示层兼容，无需改客户端上报结构或单位。
