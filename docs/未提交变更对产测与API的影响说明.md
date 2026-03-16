# 未提交变更对产测顺序、判定规则与 API 的影响说明

**文档目的**：在提交前，明确当前工作区未提交变更对产测顺序、判定规则及服务端 API 契约的影响，确保发布可追溯、可回滚。

**结论摘要**：

| 维度         | 是否受影响 | 说明 |
|--------------|------------|------|
| 产测顺序     | **否**     | 步骤顺序仍由 `production_test_steps_order` 控制，逻辑与 key 未改。 |
| 判定规则     | **否**     | 阈值、判定线下限、limit 基准等仍按原 key 存 bar/mbar，仅 UI 展示改为 mbar。 |
| API 契约     | **是（向后兼容扩展）**     | 为上传当前规则快照与按规则版本统计历史记录，新增可选字段 `rules` 及查询接口 `/api/production_rules/versions`，旧客户端不受影响。 |

---

## 1. 产测顺序

### 1.1 存储与使用

- **Key**：`UserDefaults["production_test_steps_order"]`，类型 `[String]`（stepId 数组）。
- **读取**：`ProductionTestView` 与 `ProductionTestRulesView` 仍从该 key 加载顺序；未提交变更未修改该 key 及读写逻辑。
- **写入**：规则页拖拽/上下移动后仍调用 `defaults.set(ids, forKey: "production_test_steps_order")`，未改。

### 1.2 执行顺序

- 产测执行顺序仍由 `enabledSteps` 决定，其来源于上述 `production_test_steps_order` 与各步骤启用状态。
- 未提交变更未改动 `TestStep` 枚举、stepId 字符串或顺序推导逻辑。

**结论**：产测顺序**不受**本次未提交变更影响。

---

## 2. 判定规则

### 2.1 压力步骤（读取压力值）

- **闭/开压力区间**：仍为 `pressureClosedMin/Max`、`pressureOpenMin/Max`（单位 mbar），存于 UserDefaults，key 未改。
- **压差区间**：`pressureDiffMin/Max`（mbar），key 未改。
- **逻辑**：仍用 `closedMbar`/`openMbar` 与上述阈值比较；仅日志与 stepResults 的**展示文案**由 bar 改为 mbar，判定公式与写入 payload 的数值未改。

### 2.2 气体泄漏步骤

- **Limit 基准**：仍为 `phase1_avg` / `phase3_first`，key 如 `production_test_gas_leak_closed_limit_source` 未改。
- **判定线下限（limit floor）**：
  - **存储**：仍为 **bar**，key 仍为 `production_test_gas_leak_open_limit_floor_bar`、`production_test_gas_leak_closed_limit_floor_bar`。
  - **逻辑**：`effectiveLimitBar = max(computedLimitBar, config.limitFloorBar)` 等仍使用 bar；内部与 API 仍按 bar。
  - **变更点**：仅规则页该行的 **展示与输入** 改为 mbar（Binding 的 get/set 做 mbar↔bar 换算），持久化与判定仍用 bar。
- **压降阈值、起始压力下限**：仍为 mbar，key 与类型未改。

### 2.3 其他规则

- 失败时是否跳过恢复出厂/断开、压力失败是否重试、Phase 4 开关等：仅 UI/文案/设计系统相关改动，规则 key 与默认值未改。

**结论**：判定规则**不受**本次未提交变更影响；仅「判定线下限」在界面上以 mbar 展示与编辑，底层仍按 bar 存储与参与计算。

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

**结论**：在保持原有字段与单位不变的前提下，API 契约新增了**向后兼容的扩展字段与只读查询接口**：

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

- 提交时在 commit message 中注明：**展示单位统一为 mbar，不改变 API、产测顺序与判定规则存储/逻辑**。
- 若后续服务端或 Dashboard 需区分「stepResults 中为 bar 还是 mbar 文案」，可仅做展示层兼容，无需改客户端上报结构或单位。
