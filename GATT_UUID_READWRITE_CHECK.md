# UUID 读写区域 · 服务/特征对照检查

基于 **GattServices 2026-01-09_044517.xlsx**（Overview 表）与 **BOG_TOOL/Config/GattServices.json** 对照。

---

## 1. UUID 读写区域的 Service 列表来源

- **来源**：`GattMapping.services`（来自 `GattServices.json` 的 `services` 数组）。
- **读写区实际展示的是「特征」**：下拉列表由 `UUIDDebugView.buildCharacteristicOptions` 生成，遍历 `GattMapping.services` 下每个服务的 `characteristics`，且 **仅包含 UUID 属于 `GattMapping.appCharacteristicUUIDSet` 的特征**（即 `appCharacteristicKeys` 的 value 集合）。
- **结论**：没有单独的「Service 下拉列表」；读写区是 **按特征（characteristic）** 选读/写，特征必须同时在 `services[].characteristics` 与 `appCharacteristicKeys` 中才会出现。

---

## 2. Excel 定义的 GATT 服务是否都在 JSON 的 service 列表中

| Excel Service UUID | Excel 服务名 | JSON services 中是否存在 |
|--------------------|-------------|--------------------------|
| 0x1800 | Generic Access | ✅ 有（name: "Generic Access"） |
| 0x1801 | Generic Attribute | ✅ 有（name: "Generic Attribute"） |
| 0x180A | Device Information | ✅ 有（name: "Device Information"） |
| 0x00000000-6037-c6a0-264e-309a67ceb3d1 | Schedule | ✅ 有（name: "Schedule"） |
| 0x00000000-b018-fcad-2244-c82e6b682734 | Valve | ✅ 有（name: "Valve"） |
| 0x00000000-aef1-ca85-fb4d-3aafeb7a605a | Gas System | ✅ 有（name: "Gas System"） |
| 0x00000000-d1d0-4b64-afcd-2f977ab4a11d | OTA | ✅ 有（name: "OTA"） |

**结论**：Excel 中定义的 **7 个 GATT 服务** 在 `GattServices.json` 的 `services` 列表中 **全部存在**。

---

## 3. 读写区域是否包含 Excel 已定的所有特征

Excel Overview 中定义的 **自定义/业务特征**（排除标准 1800/1801/180A 的纯标准特征）与 `appCharacteristicKeys` 对照如下。

### 3.1 已在 appCharacteristicKeys 中（会出现在读写区）

| Excel Characteristic | UUID (简写) | appCharacteristicKeys key |
|----------------------|-------------|---------------------------|
| Time Write | 00000002-6037-... | rtc |
| Valve State Read | 00000001-B018-... | valveState |
| Valve Mode Read And Write | 00000002-B018-... | valveControl |
| Gas system status | 00000001-AEF1-... | gasSystemStatus |
| CO2 Pressure when valve is closed | 00000002-AEF1-... | pressureRead |
| CO2 Pressure when valve is open | 00000003-AEF1-... | pressureOpen |
| CO2 Pressure Limits | 00000004-AEF1-... | co2PressureLimits |
| OTA Status | 00000001-D1D0-... | otaStatus |
| OTA Data | 00000002-D1D0-... | otaData |
| Testing | 00000003-D1D0-... | testing |

### 3.2 Excel 已定义但未在 appCharacteristicKeys 中（读写区不包含）

| Excel Characteristic | UUID (简写) | 说明 |
|----------------------|-------------|------|
| Schedule Read And Write | 00000001-6037-C6A0-264E-309A67CEB3D1 | Schedule 服务，可读可写，max 200 bytes |
| Valve Interval Read And Write | 00000003-B018-FCAD-2244-C82E6B682734 | Valve 周期/间隔 (ms) |
| CO2 Bottle | 00000005-AEF1-CA85-FB4D-3AAFEB7A605A | 气瓶/陷阱数等，可读可写 |

### 3.3 appCharacteristicKeys 中的特殊项

| key | value | 说明 |
|-----|-------|------|
| mainService | 00000000-AEF1-CA85-FB4D-3AAFEB7A605A | 这是 **服务** UUID（Gas System），不是特征；读写区下拉中不会出现（因无特征 UUID 与之匹配）。 |

**结论（修改前）**：  
- **读写区域未包含** Excel 中已定义的 3 个特征：**Schedule Read And Write**、**Valve Interval Read And Write**、**CO2 Bottle**。

---

## 4. 已做修改（使读写区包含 Excel 全部已定特征）

已在 `GattServices.json` 的 `appCharacteristicKeys` 中新增，并在 `GattMapping.swift` 的 `Key` 与 fallback 中同步：

| key | UUID |
|-----|------|
| scheduleReadWrite | 00000001-6037-C6A0-264E-309A67CEB3D1 |
| valveInterval | 00000003-B018-FCAD-2244-C82E6B682734 |
| co2Bottle | 00000005-AEF1-CA85-FB4D-3AAFEB7A605A |

**修改后结论**：UUID 读写区域（读/写下拉）现已包含 Excel（GattServices 2026-01-09）定义的全部业务特征；标准服务 1800/1801/180A 的特征未加入 `appCharacteristicKeys`（Device Information 由 App 另行发现与读取）。
