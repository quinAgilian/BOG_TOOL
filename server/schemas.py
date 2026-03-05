"""
API 请求/响应模型，与 BOG_TOOL 客户端保持一致。
"""
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


class StepSummaryItem(BaseModel):
    stepId: str
    status: str  # passed | failed | skipped


class ProductionTestPayload(BaseModel):
    """BOG_TOOL 产测结束时 POST 的 JSON 结构"""
    startTime: Optional[str] = None
    endTime: Optional[str] = None
    durationSeconds: Optional[float] = None
    deviceSerialNumber: str = Field(..., min_length=1)
    deviceName: Optional[str] = None
    deviceFirmwareVersion: Optional[str] = None
    deviceBootloaderVersion: Optional[str] = None
    deviceHardwareRevision: Optional[str] = None
    overallPassed: bool
    needRetest: bool = False
    stepsSummary: List[StepSummaryItem] = Field(default_factory=list)
    stepResults: Optional[Dict[str, str]] = None
    """结构化测试详情：RTC 时间/时间差、压力(mbar)、Gas 状态、阀门状态等"""
    testDetails: Optional[Dict[str, Any]] = None


class BurnRecordPayload(BaseModel):
    """烧录程序上报的烧录记录"""
    deviceSerialNumber: str = Field(..., min_length=1)
    macAddress: Optional[str] = None
    burnStartTime: Optional[str] = None
    burnDurationSeconds: Optional[float] = None
    computerIdentity: Optional[str] = None
    deviceWrittenTimestamp: Optional[str] = None  # 设备被写入的时间戳
    binFileName: Optional[str] = None  # 烧录的 bin 文件名称
    deviceWrittenSerialNumber: Optional[str] = None  # 设备被写入的序列号
    burnTestResult: Optional[str] = None  # 烧录前测试结果: passed | failed | self_check_failed | key_abnormal
    failureReason: Optional[str] = None  # 自检失败原因: rtc_error | pressure_sensor_error | button_timeout | button_user_exit | factory_config_incomplete | other
    flowType: Optional[str] = None  # 流程类型: P=仅烧录, T=仅自检, P+T=烧录+自检
    fromVersion: Optional[str] = None  # 烧录前固件版本，如 N.A
    toVersion: Optional[str] = None  # 烧录后固件版本，如 1.1.1
    targetFileSizeBytes: Optional[int] = None  # 烧录目标文件大小（字节）
    buttonWaitSeconds: Optional[float] = None  # 按键等待时间（秒），自检流程中从出现按键提示到用户按键/ESC/空格的耗时


class FirmwareUpgradePayload(BaseModel):
    """设备 OTA 升级结果上报"""
    deviceSerialNumber: Optional[str] = None
    macAddress: Optional[str] = None
    currentVersion: str = Field(..., min_length=1, description="升级前固件版本")
    upgradeSuccess: bool
    newVersion: Optional[str] = None  # 升级成功后固件版本
    finalVersion: Optional[str] = None  # 升级后设备实际版本（成功=新版本，失败=当前版本，建议必填）
    failureReason: Optional[str] = None  # 失败原因: user_cancelled|connection_lost|timeout|checksum_failed|flash_failed|other
    computerIdentity: Optional[str] = None
    targetFileSizeBytes: Optional[int] = None  # OTA 目标文件大小（字节）
    durationSeconds: Optional[float] = None  # OTA 执行耗时（秒）


class ProductionTestBatchPayload(BaseModel):
    """批量产测结果"""
    records: List[ProductionTestPayload] = Field(..., min_items=1, max_items=500)


class BurnRecordBatchPayload(BaseModel):
    """批量烧录记录"""
    records: List[BurnRecordPayload] = Field(..., min_items=1, max_items=500)


class PcbaTestRecordPayload(BaseModel):
    """PCBA 测试记录，MAC 地址优先"""
    macAddress: str = Field(..., min_length=1, description="MAC 地址，主键标识")
    deviceSerialNumber: Optional[str] = None
    testResult: Optional[str] = None  # passed | failed
    testTime: Optional[str] = None  # ISO 8601
    durationSeconds: Optional[float] = None
    computerIdentity: Optional[str] = None
    testDetails: Optional[Dict[str, Any]] = None


class PcbaTestRecordBatchPayload(BaseModel):
    """批量 PCBA 测试记录"""
    records: List[PcbaTestRecordPayload] = Field(..., min_items=1, max_items=500)
