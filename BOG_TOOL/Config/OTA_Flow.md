# OTA 升级完整逻辑（基于 GattServices.json）

根据 `GattServices.json` 中 OTA 服务与特征的描述，可推断出的完整 OTA 流程如下。

---

## 1. GATT 定义摘要

| 项目 | UUID | 说明 |
|------|------|------|
| **OTA 服务** | `00000000-D1D0-4B64-AFCD-2F977AB4A11D` | OTA 升级服务 |
| **OTA Status** | `00000001-D1D0-4B64-AFCD-2F977AB4A11D` | 读：状态 0–4；写：控制 0/1/2/3 |
| **OTA Data** | `00000002-D1D0-4B64-AFCD-2F977AB4A11D` | 写：固件数据，每包最多 200 字节 |

- **OTA Status**
  - **读**：`uint8_t`，取值 0–4，表示当前 OTA 状态（具体含义需与固件约定，常见如：0=idle, 1=receiving, 2=verifying, 3=ready_reboot, 4=error）。
  - **写**：`uint8_t`  
    - `0` = abort（中止）  
    - `1` = start（开始）  
    - `2` = finished（传输完成）  
    - `3` = reboot（重启设备）
- **OTA Data**
  - **写**：每包最多 200 字节，按顺序写入固件数据（chunk by chunk）。  
  - 属性为 Wr Enc，需加密写（若链路已加密则按现有 BLE 加密写即可）。

---

## 2. 推荐 OTA 流程（App 端）

```text
1. 连接设备并发现 OTA 服务与 OTA Status、OTA Data 特征。

2. 【可选】读 OTA Status，确认为 0（idle）再开始；否则可先写 0（abort）再重试。

3. 写 OTA Status = 1（start），表示开始本次 OTA。

4. 将固件二进制按块拆分（每块 ≤ 200 字节），依次写入 OTA Data 特征：
   - 使用 Write With Response（与 GATT 描述一致）。
   - 可每写若干包后读一次 OTA Status，根据状态决定继续/重试/中止。
   - 若固件有校验/长度头，需与固件协议一致（例如前几字节为长度或 magic）。

5. 全部数据写完后，写 OTA Status = 2（finished），通知设备传输结束。

6. 轮询读 OTA Status：
   - 若设备表示成功（例如状态变为 3 或固件约定的“就绪”），再写 OTA Status = 3（reboot）让设备重启进入新固件。
   - 若状态表示失败（例如 4=error），则提示用户并可选写 0（abort）清理。

7. 设备重启后断开连接，OTA 结束。
```

---

## 3. 状态与错误处理（需与固件对齐）

- **读到的 OTA Status 0–4**：具体枚举建议与固件文档一致，例如：
  - 0：idle，可开始
  - 1：receiving，正在接收
  - 2：verifying，校验中
  - 3：ready_reboot，可发 reboot
  - 4：error，可 abort 后重试
- **写 OTA Data 失败**：可重试当前块若干次，仍失败则写 Status=0（abort），提示用户。
- **连接断开**：未写完或未发 finished/reboot 前断开，固件端应能超时或通过下次 start/abort 恢复。

---

## 4. 实现要点（与本工程一致）

- **分块大小**：每包 ≤ 200 字节（与 JSON 中 “max 200 bytes” 一致）。
- **写入方式**：`CBCharacteristicWriteType.withResponse`，等设备响应后再发下一包，便于重试与流控。
- **密钥/加密**：若 GATT 要求 “Wr Enc”，则使用已配对的加密连接即可；无需在应用层再实现加密。
- **进度**：可按「已写字节数 / 固件总长」更新 UI；完成所有块并写 Status=2 后，再根据读到的 Status 写 3（reboot）。

以上逻辑完全由当前 `GattServices.json` 中 OTA 服务与两个特征的描述推导得出；具体状态码与可选协议头（如长度、magic）需与 ESP32 固件侧约定一致。
