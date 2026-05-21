# 产测步骤显示名称（统一风格）

仅 `production_test_rules.*_title` 与 `production_test.result_criteria_fw`；`stepId`、逻辑、规则 JSON 不变。

## 命名原则（信达雅）

| 动词 | 英文 | 中文 | 用于 |
|------|------|------|------|
| 连接/读取 | Connect / Read | 连接 / 读取 | 建立链路、读 SN |
| Check | Check | 核对 | 读回并与 SOP 阈值比对（固件、HW、RTC、压力） |
| Confirm | Confirm | 确认 | 状态须在允许集合内（气体状态、电磁阀、Overlay 固件结论） |
| Test | Test | 检测 | 多阶段主动测试（关阀漏气） |
| Set | Set | 设置 | 向设备写入配置（出货区域 HW） |
| Disable | Disable | 禁用 | 关闭设备侧功能（气体自检） |
| Run | Run | 执行 | 较长流程（固件升级） |
| Reboot / Reset / Disconnect | 同左 | 重启 / 恢复出厂设置 / 断开设备 | 单次明确动作 |

## 当前标题对照

| step.id | 中文 | English |
|---------|------|---------|
| `step_connect` | 连接设备 | Connect device |
| `step_read_serial_number` | 读取序列号 | Read serial number |
| `step_verify_firmware` | 核对固件版本 | Check firmware revision |
| `step_verify_hw_rev` | 核对硬件修订 | Check hardware revision |
| `step_hw_rev_shipping_region` | 设置出货区域 | Set shipping region HW |
| `step_read_rtc` | 核对设备时钟 | Check RTC |
| `step_read_pressure` | 核对气路压力 | Check pressure readings |
| `step_disable_diag` | 禁用气体自检 | Disable gas self-check |
| `step_gas_system_status` | 确认气体系统状态 | Confirm gas system status |
| `step_gas_leak_closed` | 检测关阀漏气 | Test closed-valve leakage |
| `step_valve` | 确认电磁阀开启 | Confirm solenoid valve open |
| `step_reset` | 重启设备 | Reboot device |
| `step_factory_reset` | 恢复出厂设置 | Reset to factory defaults |
| `step_ota` | 执行固件升级 | Run firmware update |
| `step_disconnect` | 断开设备 | Disconnect device |
| Overlay | 确认固件（匹配或升级） | Confirm firmware (match or OTA) |

未改：`*_desc`、`*_criteria`、过程弹窗、`stepResults` 结果句。
