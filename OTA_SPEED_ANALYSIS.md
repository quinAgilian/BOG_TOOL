# OTA 速度下降系统性分析

现象：此前可达约 24 kbps，现在仅约 1 kbps；设备端无变化，从 App / 系统侧排查。

---

## 一、App 侧可能原因

### 1. OTA 延时线程优先级不足（已修复）

**原因**：`performOtaDelayThenContinue` 使用 `otaQueue.asyncAfter(deadline:)` 做 10ms 包间延时。队列创建时只在**首次** `queue.async { }` 里对**当时执行的那条线程**调用了 `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE)`。  
之后 `asyncAfter` 触发的任务可能被调度到**其他**工作线程上执行，这些线程并未被设过高 QoS，若系统负载高会被延后调度，导致 10ms 实际变成几十～几百 ms，整体速率从 ~24 kbps 掉到 ~1 kbps。

**修复**：在**每次**执行延时的代码路径里，在**当前线程**上先设 QoS 再 `Thread.sleep`，保证“谁在等 10ms，谁就是高优先级”，然后再回主线程执行 continuation。见 `BLEManager.performOtaDelayThenContinue` 的修改。

### 2. 包间延时与包大小未改

- `otaChunkDelayNs = 10_000_000`（10 ms）、`otaChunkSize = 200` 未在近期改动。
- 若怀疑可临时把延时改为 5ms 做对比测试（注释里曾记录 5ms 在旧环境下反而更慢，可能与当时设备/BLE 栈有关）。

### 3. 主线程负担

- OTA 进行中每包会更新 `otaProgress`、`otaProgressLogLine` 等 @Published，以及 `appendLog`（若日志等级为 debug 会较频繁）。
- 理论上主线程若被其他 UI/逻辑占满，`continueOtaAfterChunkWrite` 被调起的时机可能推迟，但通常不会单独造成 20 倍减速，除非有额外重逻辑。
- 建议：OTA 时关闭或降低日志等级，减少主线程写日志；若仍慢可考虑进度条按每 N 包更新一次。

### 4. 近期代码变更与 OTA 路径的关系

- 已确认：删除 OTA 弹窗、ContentView overlay、产测 OTA 区域与取消按钮、RTC 的 `readRTCWithUnlock`/`clearRTCReadState`、`didConnect` 里 `clearOTAStatus()` 等均不参与 OTA 数据发送循环，不会直接改变包间延时或发送线程。
- 结论：近期功能改动未改动 OTA 核心参数；速度问题主要与“延时所在线程的调度优先级”相关。

---

## 二、系统 / 环境侧可能原因

### 1. 进程/线程优先级被系统压低

- macOS 会根据前台/后台、能耗、其他高优先级进程等调整调度。
- 若 App 在后台或其它应用占满 CPU，OTA 所用线程可能被延后执行，表现为每包间隔远大于 10ms。
- **建议**：OTA 时保持 App 在前台；关闭或减少其它高 CPU 应用；可用“活动监视器”看 BOG_TOOL 的 CPU 与线程数。

### 2. 蓝牙/系统服务负载

- 同一机器上其它 BLE 或蓝牙设备、系统蓝牙服务异常，可能导致 CoreBluetooth 回调或写入完成回调延迟。
- **建议**：OTA 时尽量只连接当前待升级设备；必要时重启蓝牙或重启系统后再测。

### 3. 机器负载与能耗管理

- 低电量、节能模式、或 CPU 降频可能导致所有线程变慢，包括 OTA 延时与 BLE 回调。
- **建议**：插电、关闭节能模式后再测 OTA 速率。

---

## 三、已做修改摘要

- **BLEManager.performOtaDelayThenContinue**：
  1. 每次在 otaQueue 任务中：当前线程设 QoS → `Thread.sleep(10ms)` → 回主线程执行 continuation。
  2. 回主线程改为 **`DispatchQueue.main.async { continuation() }`**，不再用 `Task { @MainActor in continuation() }`，避免与主线程上大量 Swift 并发任务争抢，导致 continuation 被推迟数秒、出现“约 2 秒/包、1 kbps”的现象。

- **进度更新节流**：`continueOtaAfterChunkWrite` 中不再每包都更新 `otaProgress` / `otaProgressLogLine`，改为每 10 包（及首包、最后一包）更新一次，减轻主线程与 @Published 负载，避免拖慢包间调度。

---

## 四、若仍慢可进一步排查

1. **看日志**：OTA 结束时打印的“平均 BLE 响应 X ms”。若平均响应时间从 ~40ms 升到数百 ms，多半是系统/BLE 延迟；若仍 ~40ms 但总速率低，则更可能是包间延时被拉长（已用上述修复）。
2. **临时缩短延时**：把 `otaChunkDelayNs` 改为 5_000_000（5ms）试跑一次，看速率是否明显上升（若设备能承受）。
3. **活动监视器**：观察 BOG_TOOL 的 CPU 使用率与线程数，确认没有异常占用或大量线程竞争。
