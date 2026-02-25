"""
API 请求/响应模型，与 BOG_TOOL 客户端保持一致。
"""
from typing import Any, Optional

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
    stepsSummary: list[StepSummaryItem] = Field(default_factory=list)
    stepResults: Optional[dict[str, str]] = None
    """结构化测试详情：RTC 时间/时间差、压力(mbar)、Gas 状态、阀门状态等"""
    testDetails: Optional[dict[str, Any]] = None
