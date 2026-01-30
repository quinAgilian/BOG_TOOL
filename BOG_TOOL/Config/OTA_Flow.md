# OTA 升级完整逻辑（基于 GattServices.json 与正常设备日志）

根据 `GattServices.json` 中 OTA 服务与特征的描述，以及**正常 OTA 时的设备端日志**，可推断出 App 端应执行的完整流程如下。

---

## 0. 基于正常设备日志的 App 流程推断

正常 OTA 时设备端日志顺序为：

| 设备日志 | 含义 | App 应执行的动作 |
|----------|------|------------------|
| `connection established; status=0` | BLE 已连接 | 已连接，发现 OTA 服务与特征后可开始 OTA |
| `ota: New Command: 0` | 设备收到命令 0（idle/abort） | 可选：开始前不写 0；或设备初始即为 0 |
| `ota: New Command: 1` | 设备收到命令 1（start），进入 OTA、准备收包 | **写 OTA Status = 1（start）**；可选：读回 Status 确认为 1 再发块，或超时后直接发块 |
| （无 “New Command” 的长时间段） | 设备在接收固件块并写 flash | **按序写 OTA Data 特征**（每包 ≤200 字节），等每包 write 成功后再发下一包；可选：每包后读 Status，仅当为 1 再发下一包 |
| `ota: New Command: 2` | 设备收到命令 2（finished），开始写分区并校验 | **全部块发完后写 OTA Status = 2（finished）** |
| `esp_image: segment 0: ...` 等 | 设备将镜像写入 ota_1 分区 | App 无需动作，等待设备校验 |
| `ota: New Command: 3` | 设备收到命令 3（reboot） | **轮询读 OTA Status 直到读到 3（image valid）后，写 OTA Status = 3（reboot）** |
| `rst:0xc (RTC_SW_CPU_RST)` | 设备软件重启 | 连接会断开，用户可重连以确认新版本 |

据此得到 **App 端必须执行的顺序**（与 `BLEManager` 实现一致）：

1. **连接** → 发现 OTA 服务与 OTA Status、OTA Data 特征。
2. **写 Status = 1（start）** → 读 OTA Status：若为 **1** 则发块；若为 **2**（working）则延时后再读，直到读到 1 或**超时（2.5s）**后直接发块；若为 0/4 等则写 0（abort）并结束。
3. **按序写 OTA Data** → 每包 ≤200 字节，等 write 成功再发下一包；每包后读 Status：若为 **1** 则发下一包，若为 **2** 则延时后再读，直到 1 或**超时（1.5s）**后直接发下一包；若为 0/4 等则 abort。
4. **全部块发完后写 Status = 2（finished）**。
5. **轮询读 OTA Status** → 读到 **3**（image valid）则写 **Status = 3（reboot）**；读到 **4**（image fail）则写 **Status = 0（abort）**；读到 2 等则间隔 0.4s 再读。
6. **设备重启并断开** → 提示用户 OTA 完成，可重连验证新固件版本。

---

## 1. GATT 定义摘要

| 项目 | UUID | 说明 |
|------|------|------|
| **OTA 服务** | `00000000-D1D0-4B64-AFCD-2F977AB4A11D` | OTA 升级服务 |
| **OTA Status** | `00000001-D1D0-4B64-AFCD-2F977AB4A11D` | 读：状态 0–4；写：控制 0/1/2/3 |
| **OTA Data** | `00000002-D1D0-4B64-AFCD-2F977AB4A11D` | 写：固件数据，每包最多 200 字节 |

- **OTA Status**（与 GattServices.json 及设备日志一致）
  - **读**：`uint8_t`  
    - `0` = OTA not started  
    - `1` = waiting for data（可发下一包）  
    - `2` = working（设备处理中，暂不接收）  
    - `3` = image valid（校验通过，可发 reboot）  
    - `4` = image fail（校验失败，应 abort）
  - **写**：`uint8_t`（设备日志中的 “New Command: N”）  
    - `0` = abort（中止）  
    - `1` = start（开始 OTA，设备进入收包状态）  
    - `2` = finished（传输完成，设备写分区并校验）  
    - `3` = reboot（重启设备）
- **OTA Data**
  - **写**：每包最多 200 字节，按顺序写入固件数据（chunk by chunk）。  
  - 属性为 Wr Enc，需加密写（若链路已加密则按现有 BLE 加密写即可）。

---

## 2. 推荐 OTA 流程（App 端，与正常设备日志一致）

```text
1. 连接设备并发现 OTA 服务与 OTA Status、OTA Data 特征。

2. 写 OTA Status = 1（start）。
   - 可选：读 OTA Status，若为 1 再发块；若超时（如 2.5s）未读到 1，也直接发块，确保设备能进入 OTA 进度。

3. 将固件按块拆分（每块 ≤ 200 字节），依次写 OTA Data：
   - 使用 Write With Response，等每包写成功后再发下一包。
   - 可选：每包写成功后读 OTA Status，仅当为 1（waiting for data）再发下一包；若为 2（working）则轮询直到 1 或超时；超时（如 1.5s）则直接发下一包。

4. 全部块写完后，写 OTA Status = 2（finished）。

5. 轮询读 OTA Status：
   - 读到 3（image valid）→ 写 OTA Status = 3（reboot），设备将重启并断开。
   - 读到 4（image fail）→ 写 OTA Status = 0（abort），提示失败。
   - 读到 2 等 → 继续轮询（如间隔 0.4s）。

6. 设备重启后连接断开，OTA 结束；用户可重连以确认新固件版本。
```

---

## 3. 状态与错误处理（与 GATT 及设备日志一致）

- **读到的 OTA Status**：0=idle，1=waiting for data，2=working，3=image valid，4=image fail（见 §1）。
- **写 OTA Data 失败**：可重试当前块若干次，仍失败则写 Status=0（abort），提示用户。
- **连接断开**：未写完或未发 finished/reboot 前断开，打日志「OTA 已中断」；固件端可通过下次 start/abort 恢复。

---

## 4. 实现要点（与本工程一致）

- **分块大小**：每包 ≤ 200 字节（与 JSON 中 “max 200 bytes” 一致）。
- **写入方式**：`CBCharacteristicWriteType.withResponse`，等设备响应后再发下一包，便于重试与流控。
- **密钥/加密**：若 GATT 要求 “Wr Enc”，则使用已配对的加密连接即可；无需在应用层再实现加密。
- **进度**：可按「已写字节数 / 固件总长」更新 UI；完成所有块并写 Status=2 后，再根据读到的 Status 写 3（reboot）。

以上逻辑完全由当前 `GattServices.json` 中 OTA 服务与两个特征的描述推导得出；具体状态码与可选协议头（如长度、magic）需与 ESP32 固件侧约定一致。

---

## 5. OTA 速度分析与提速（基于设备日志 ota_from_0312_via_app.txt）

**设备日志时间线（ESP32 毫秒）：**

| 事件 | 时间 I(ms) | 含义 |
|------|------------|------|
| connection established, mtu=200 | ~6539 | 连接建立，MTU 200 |
| ota: New Command: 1 | 21119, 22119 | App 写 start(1)，设备进入 OTA |
| ota: New Command: 2 | 115929 | App 写 finished(2)，设备开始写分区 |
| ota: New Command: 3 | 117959 | App 写 reboot(3)，设备重启 |

**传输阶段时长**：115929 − 22119 ≈ **93.8 秒**（约 2978 包 × 200 字节 ≈ 582 KB）  
**实际吞吐**：约 **6.2 KB/s**。

**慢的主要原因（App 侧）：**

1. **每包两次 BLE 往返**：写 otaData（1 次 RTT）→ 读 OTA Status（1 次 RTT）→ 延时 20ms → 发下一包。每包至少：写 RTT + 读 RTT + 20ms，合计约 30–40ms/包。
2. **每包固定延时 20ms**：`otaChunkDelayNs = 20ms`，2978 包共约 60s 纯延时。
3. **包长 200 字节**：MTU=200 时已接近单包上限，无法靠增大包长提速。

**提速建议：**

| 措施 | 预期效果 | 风险/说明 |
|------|----------|-----------|
| 将每包延时 20ms 降为 10ms 或 5ms | 总时长可减少约 30–45s | 设备忙时可能触发 “Too many errors”，可先试 10ms |
| ~~取消「每包后读 Status=1 再发下一包」~~ | ~~少一次读 RTT/包，可再省约 15–30s~~ | **已实现**：每包仅写 otaData → 等 write 成功 → 延时 → 发下一包，不再读 OTA Status |
| 设备端：收到包后尽快把 Status 置回 1 | 减少 App 轮询 2 的等待 | 需固件配合（当前已无每包读） |
| **进度 UI 节流** | 每包更新 @Published otaProgress 会触发 SwiftUI 重绘，约 3000 次导致主线程阻塞、OTA 变慢 | **已实现**：仅当整数百分比变化时更新 otaProgress（约 100 次），日志仍按 5% 打约 20 条 |
| **每包延时 0ms** | 取消人为延时，靠 BLE 回调自然 pacing | 当前 `otaChunkDelayNs = 0`；若设备/栈报错可改回 5ms |
| **BLE 耗时统计** | 确认瓶颈在 BLE 往返而非 App | 每 200 包及结束时打「平均 BLE 响应 X ms」；若 ~60–80ms/包则瓶颈在连接间隔 |

当前工程：每包延时 **0ms**，**已取消每包读 Status**，**进度仅按百分比更新**，**OTA 进行中打「已发 N 包，平均 BLE 响应 X ms」**。若该值约 60–80ms/包，则主要耗时在 BLE 连接间隔（每包一次 write-with-response 约 2 个连接周期）；设备端可请求更小 connection interval 以提速。
