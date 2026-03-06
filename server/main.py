"""
产测数据接收服务：接收 BOG_TOOL 产测结果 POST，落库，提供 Summary 与记录查询。
推荐部署到远程服务器，BOG_TOOL APP 作为 HTTP 客户端连接。
"""
import asyncio
import json
import os
import re
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import hashlib
from fastapi import (
    Cookie,
    Depends,
    FastAPI,
    File,
    Form,
    HTTPException,
    Query,
    Request,
    Response,
    UploadFile,
)
from fastapi.responses import FileResponse, HTMLResponse, PlainTextResponse, RedirectResponse, StreamingResponse

from schemas import (
    ProductionTestPayload,
    BurnRecordPayload,
    ProductionTestBatchPayload,
    BurnRecordBatchPayload,
    PcbaTestRecordPayload,
    PcbaTestRecordBatchPayload,
    FirmwareUpgradePayload,
)

# ---------------------------------------------------------------------------
# 配置与数据库
# ---------------------------------------------------------------------------

BASE_DIR = Path(__file__).resolve().parent
_db_path = os.environ.get("BOG_DB_PATH", "")
DB_PATH = Path(_db_path) if _db_path.startswith("/") else (BASE_DIR / (_db_path or "bog_test.db"))
FIRMWARE_ROOT = Path(os.environ.get("BOG_FIRMWARE_ROOT") or (BASE_DIR / "firmware_files"))

ADMIN_USERNAME = os.environ.get("BOG_ADMIN_USERNAME")
ADMIN_PASSWORD_SHA256 = os.environ.get("BOG_ADMIN_PASSWORD_SHA256")
ADMIN_SESSION_COOKIE_NAME = "bog_admin_session"
ADMIN_SESSION_TTL_SECONDS = int(os.environ.get("BOG_ADMIN_SESSION_TTL", "604800"))


def _ensure_firmware_dir(usage_type: str, channel: str) -> Path:
    if usage_type not in ("factory_merged", "ota_app"):
        raise HTTPException(status_code=400, detail="Invalid usage_type")
    if channel not in ("production", "debugging"):
        raise HTTPException(status_code=400, detail="Invalid channel")
    subdir = "factory" if usage_type == "factory_merged" else "ota"
    target_dir = FIRMWARE_ROOT / subdir / channel
    target_dir.mkdir(parents=True, exist_ok=True)
    return target_dir


def _firmware_public_path(file_path: str) -> str:
    try:
        rel = Path(file_path).relative_to(FIRMWARE_ROOT)
    except ValueError:
        return ""
    return f"/bog/firmware/{rel.as_posix()}"


def get_db() -> sqlite3.Connection:
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    with get_db() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS production_tests (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                start_time TEXT,
                end_time TEXT,
                duration_seconds REAL,
                device_serial_number TEXT NOT NULL,
                device_name TEXT,
                device_firmware_version TEXT,
                device_bootloader_version TEXT,
                device_hardware_revision TEXT,
                overall_passed INTEGER NOT NULL,
                need_retest INTEGER NOT NULL,
                steps_summary TEXT,
                step_results TEXT,
                test_details TEXT
            )
        """)
        cols = [r[1] for r in conn.execute("PRAGMA table_info(production_tests)").fetchall()]
        if cols and "test_details" not in cols:
            try:
                conn.execute("ALTER TABLE production_tests ADD COLUMN test_details TEXT")
            except sqlite3.OperationalError:
                pass
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_pt_created ON production_tests(created_at)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_pt_sn ON production_tests(device_serial_number)"
        )
        conn.execute("""
            CREATE TABLE IF NOT EXISTS burn_records (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                device_serial_number TEXT NOT NULL,
                mac_address TEXT,
                burn_start_time TEXT,
                burn_duration_seconds REAL,
                computer_identity TEXT
            )
        """)
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_br_created ON burn_records(created_at)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_br_sn ON burn_records(device_serial_number)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_br_mac ON burn_records(mac_address)"
        )
        conn.execute("""
            CREATE TABLE IF NOT EXISTS pcba_test_records (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                mac_address TEXT NOT NULL,
                device_serial_number TEXT,
                test_result TEXT,
                test_time TEXT,
                duration_seconds REAL,
                computer_identity TEXT,
                test_details TEXT
            )
        """)
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_pcba_created ON pcba_test_records(created_at)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_pcba_mac ON pcba_test_records(mac_address)"
        )
        br_cols = [r[1] for r in conn.execute("PRAGMA table_info(burn_records)").fetchall()]
        for col, _ in [
            ("device_written_timestamp", "TEXT"),
            ("bin_file_name", "TEXT"),
            ("device_written_serial_number", "TEXT"),
            ("burn_test_result", "TEXT"),
            ("failure_reason", "TEXT"),
            ("flow_type", "TEXT"),
            ("button_wait_seconds", "REAL"),
        ]:
            if col not in br_cols:
                try:
                    conn.execute(f"ALTER TABLE burn_records ADD COLUMN {col} {_}")
                except sqlite3.OperationalError:
                    pass
        conn.execute("""
            CREATE TABLE IF NOT EXISTS firmware_history (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                record_type TEXT NOT NULL,
                device_serial_number TEXT,
                mac_address TEXT,
                from_version TEXT,
                to_version TEXT,
                upgrade_success INTEGER,
                burn_record_id TEXT,
                computer_identity TEXT
            )
        """)
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_fw_created ON firmware_history(created_at)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_fw_sn ON firmware_history(device_serial_number)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_fw_mac ON firmware_history(mac_address)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_fw_type ON firmware_history(record_type)"
        )
        fw_cols = [r[1] for r in conn.execute("PRAGMA table_info(firmware_history)").fetchall()]
        for col, _ in [
            ("target_file_size_bytes", "INTEGER"),
            ("duration_seconds", "REAL"),
            ("failure_reason", "TEXT"),
            ("final_version", "TEXT"),
        ]:
            if col not in fw_cols:
                try:
                    conn.execute(f"ALTER TABLE firmware_history ADD COLUMN {col} {_}")
                except sqlite3.OperationalError:
                    pass
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS firmware_files (
                id TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                usage_type TEXT NOT NULL,
                channel TEXT NOT NULL,
                version TEXT,
                file_name TEXT NOT NULL,
                file_path TEXT NOT NULL,
                file_size_bytes INTEGER,
                checksum TEXT,
                description TEXT,
                is_active INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        fwf_cols = [r[1] for r in conn.execute("PRAGMA table_info(firmware_files)").fetchall()]
        if "original_file_name" not in fwf_cols:
            try:
                conn.execute("ALTER TABLE firmware_files ADD COLUMN original_file_name TEXT")
            except sqlite3.OperationalError:
                pass
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_fw_files_created ON firmware_files(created_at)"
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_fw_files_usage_channel ON firmware_files(usage_type, channel)"
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS admin_sessions (
                token TEXT PRIMARY KEY,
                created_at TEXT NOT NULL,
                expires_at TEXT NOT NULL
            )
            """
        )
        conn.commit()


# ---------------------------------------------------------------------------
# FastAPI 应用
# ---------------------------------------------------------------------------

app = FastAPI(title="BOG 产测数据服务", version="0.1.0")

_sse_queues: List[asyncio.Queue] = []
_sse_lock = threading.Lock()
_app_loop: Optional[asyncio.AbstractEventLoop] = None


def _broadcast_sse(event_type: str) -> None:
    """有新数据时通知所有 SSE 客户端刷新。event_type: production|burn|firmware"""
    global _app_loop
    loop = _app_loop
    if not loop:
        return
    with _sse_lock:
        queues = list(_sse_queues)
    for q in queues:
        try:
            loop.call_soon_threadsafe(q.put_nowait, event_type)
        except Exception:
            pass


@app.on_event("startup")
async def startup() -> None:
    global _app_loop
    init_db()
    try:
        _app_loop = asyncio.get_running_loop()
    except AttributeError:
        _app_loop = asyncio.get_event_loop()


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _require_admin_session(token: Optional[str]) -> None:
    if not ADMIN_USERNAME or not ADMIN_PASSWORD_SHA256:
        raise HTTPException(status_code=500, detail="Admin login not configured")
    if not token:
        raise HTTPException(status_code=401, detail="Not authenticated")
    now_iso = _now_iso()
    with get_db() as conn:
        row = conn.execute(
            "SELECT expires_at FROM admin_sessions WHERE token = ?",
            (token,),
        ).fetchone()
        if not row:
            raise HTTPException(status_code=401, detail="Invalid session")
        if row["expires_at"] <= now_iso:
            conn.execute("DELETE FROM admin_sessions WHERE token = ?", (token,))
            conn.commit()
            raise HTTPException(status_code=401, detail="Session expired")


def _is_admin_authenticated(token: Optional[str]) -> bool:
    """仅判断是否已登录，不抛异常。"""
    if not ADMIN_USERNAME or not ADMIN_PASSWORD_SHA256 or not token:
        return False
    now_iso = _now_iso()
    with get_db() as conn:
        row = conn.execute(
            "SELECT expires_at FROM admin_sessions WHERE token = ?",
            (token,),
        ).fetchone()
        if not row or row["expires_at"] <= now_iso:
            return False
    return True


def require_admin(
    session_token: Optional[str] = Cookie(default=None, alias=ADMIN_SESSION_COOKIE_NAME),
) -> None:
    _require_admin_session(session_token)


def require_admin_or_redirect(
    request: Request,
    session_token: Optional[str] = Cookie(default=None, alias=ADMIN_SESSION_COOKIE_NAME),
) -> Optional[RedirectResponse]:
    """未登录时：浏览器请求重定向到登录页，API 请求返回 401。"""
    if not ADMIN_USERNAME or not ADMIN_PASSWORD_SHA256:
        raise HTTPException(status_code=500, detail="Admin login not configured")
    if _is_admin_authenticated(session_token):
        return None
    accept = (request.headers.get("accept") or "").lower()
    if request.method == "GET" and "text/html" in accept:
        return RedirectResponse(url="/admin/login", status_code=302)
    raise HTTPException(status_code=401, detail="Not authenticated")


@app.post("/api/admin/login")
def admin_login(
    response: Response,
    username: str = Form(...),
    password: str = Form(...),
) -> Dict[str, Any]:
    if not ADMIN_USERNAME or not ADMIN_PASSWORD_SHA256:
        raise HTTPException(status_code=500, detail="Admin login not configured")
    if username != ADMIN_USERNAME or _sha256(password) != ADMIN_PASSWORD_SHA256:
        raise HTTPException(status_code=401, detail="Invalid username or password")
    token = str(uuid.uuid4())
    created_at = _now_iso()
    expires_at = datetime.fromtimestamp(
        time.time() + ADMIN_SESSION_TTL_SECONDS, tz=timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    with get_db() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO admin_sessions(token, created_at, expires_at) VALUES (?, ?, ?)",
            (token, created_at, expires_at),
        )
        conn.commit()
    response.set_cookie(
        key=ADMIN_SESSION_COOKIE_NAME,
        value=token,
        httponly=True,
        max_age=ADMIN_SESSION_TTL_SECONDS,
        samesite="lax",
    )
    return {"ok": True}


@app.post("/api/admin/logout")
def admin_logout(
    response: Response,
    session_token: Optional[str] = Cookie(default=None, alias=ADMIN_SESSION_COOKIE_NAME),
) -> Dict[str, Any]:
    if session_token:
        with get_db() as conn:
            conn.execute("DELETE FROM admin_sessions WHERE token = ?", (session_token,))
            conn.commit()
    response.delete_cookie(ADMIN_SESSION_COOKIE_NAME)
    return {"ok": True}


@app.post("/api/production-test")
def post_production_test(payload: ProductionTestPayload) -> Dict[str, Any]:
    """接收一次产测结果并写入数据库。"""
    test_id = str(uuid.uuid4())
    created_at = _now_iso()
    steps_json = json.dumps(
        [{"stepId": s.stepId, "status": s.status} for s in payload.stepsSummary],
        ensure_ascii=False,
    )
    step_results_json = (
        json.dumps(payload.stepResults, ensure_ascii=False)
        if payload.stepResults is not None
        else None
    )
    test_details_json = (
        json.dumps(payload.testDetails, ensure_ascii=False)
        if payload.testDetails is not None
        else None
    )
    try:
        with get_db() as conn:
            conn.execute(
                """
                INSERT INTO production_tests (
                    id, created_at, start_time, end_time, duration_seconds,
                    device_serial_number, device_name,
                    device_firmware_version, device_bootloader_version, device_hardware_revision,
                    overall_passed, need_retest, steps_summary, step_results, test_details
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    test_id,
                    created_at,
                    payload.startTime,
                    payload.endTime,
                    payload.durationSeconds,
                    payload.deviceSerialNumber.strip(),
                    payload.deviceName,
                    payload.deviceFirmwareVersion,
                    payload.deviceBootloaderVersion,
                    payload.deviceHardwareRevision,
                    1 if payload.overallPassed else 0,
                    1 if payload.needRetest else 0,
                    steps_json,
                    step_results_json,
                    test_details_json,
                ),
            )
            conn.commit()
    except sqlite3.IntegrityError as e:
        raise HTTPException(status_code=400, detail=str(e))
    _broadcast_sse("production")
    return {"ok": True, "id": test_id, "createdAt": created_at}


@app.post("/api/production-test/batch")
def post_production_test_batch(payload: ProductionTestBatchPayload) -> Dict[str, Any]:
    """批量接收产测结果，单次最多 500 条。"""
    results: List[Dict[str, Any]] = []
    for p in payload.records:
        try:
            r = post_production_test(p)
            results.append({"ok": True, "id": r["id"], "createdAt": r["createdAt"]})
        except HTTPException as e:
            results.append({"ok": False, "error": str(e.detail)})
    return {"ok": True, "count": len(results), "results": results}


def _insert_firmware_history(
    conn: sqlite3.Connection,
    record_type: str,
    device_sn: Optional[str],
    mac: Optional[str],
    from_version: Optional[str],
    to_version: Optional[str],
    upgrade_success: Optional[bool],
    burn_record_id: Optional[str],
    computer_identity: Optional[str],
    target_file_size_bytes: Optional[int] = None,
    duration_seconds: Optional[float] = None,
    failure_reason: Optional[str] = None,
    final_version: Optional[str] = None,
) -> None:
    fw_id = str(uuid.uuid4())
    created_at = _now_iso()
    conn.execute(
        """INSERT INTO firmware_history (
            id, created_at, record_type, device_serial_number, mac_address,
            from_version, to_version, upgrade_success, burn_record_id, computer_identity,
            target_file_size_bytes, duration_seconds, failure_reason, final_version
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            fw_id,
            created_at,
            record_type,
            device_sn,
            mac,
            from_version,
            to_version,
            1 if upgrade_success is True else (0 if upgrade_success is False else None),
            burn_record_id,
            computer_identity,
            target_file_size_bytes,
            duration_seconds,
            failure_reason,
            final_version,
        ),
    )


@app.post("/api/burn-record")
def post_burn_record(payload: BurnRecordPayload) -> Dict[str, Any]:
    """烧录程序上报烧录记录"""
    record_id = str(uuid.uuid4())
    created_at = _now_iso()
    with get_db() as conn:
        conn.execute(
            """INSERT INTO burn_records (
                id, created_at, device_serial_number, mac_address,
                burn_start_time, burn_duration_seconds, computer_identity,
                device_written_timestamp, bin_file_name, device_written_serial_number, burn_test_result, failure_reason, flow_type, button_wait_seconds
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                record_id,
                created_at,
                payload.deviceSerialNumber.strip(),
                payload.macAddress,
                payload.burnStartTime,
                payload.burnDurationSeconds,
                payload.computerIdentity,
                payload.deviceWrittenTimestamp,
                payload.binFileName,
                payload.deviceWrittenSerialNumber,
                payload.burnTestResult,
                payload.failureReason,
                payload.flowType,
                payload.buttonWaitSeconds,
            ),
        )
        if payload.fromVersion is not None or payload.toVersion is not None:
            _insert_firmware_history(
                conn,
                "burn",
                payload.deviceSerialNumber.strip() or None,
                payload.macAddress,
                payload.fromVersion,
                payload.toVersion,
                None,
                record_id,
                payload.computerIdentity,
                payload.targetFileSizeBytes,
                payload.burnDurationSeconds,
                None,
                payload.toVersion,  # Final 列：烧录时用 toVersion
            )
        conn.commit()
    _broadcast_sse("burn")
    if payload.fromVersion is not None or payload.toVersion is not None:
        _broadcast_sse("firmware")
    return {"ok": True, "id": record_id, "createdAt": created_at}


@app.post("/api/burn-record/batch")
def post_burn_record_batch(payload: BurnRecordBatchPayload) -> Dict[str, Any]:
    """批量上报烧录记录，单次最多 500 条。"""
    results: List[Dict[str, Any]] = []
    for p in payload.records:
        try:
            r = post_burn_record(p)
            results.append({"ok": True, "id": r["id"], "createdAt": r["createdAt"]})
        except HTTPException as e:
            results.append({"ok": False, "error": str(e.detail)})
    return {"ok": True, "count": len(results), "results": results}


@app.get("/api/burn-records")
def get_burn_records(
    sn: Optional[str] = Query(None),
    mac: Optional[str] = Query(None, description="MAC 地址，支持模糊"),
    date_from: Optional[str] = Query(None, description="YYYY-MM-DD"),
    date_to: Optional[str] = Query(None, description="YYYY-MM-DD"),
    burn_test_result: Optional[str] = Query(None, description="passed|failed|self_check_failed|key_abnormal"),
    flow_type: Optional[str] = Query(None, description="P|T|P+T"),
    bin_file: Optional[str] = Query(None, description="bin 文件名，精确匹配"),
    limit: int = Query(200, ge=1, le=1000),
) -> Dict[str, Any]:
    """查询烧录记录。SN/MAC 支持模糊匹配，按 MAC 优先排序。"""
    conditions: List[str] = ["1=1"]
    params: List[Any] = []
    if sn:
        sn_val = sn.strip().replace("*", "%")
        if "%" not in sn_val:
            sn_val = "%" + sn_val + "%"
        conditions.append(
            "(device_serial_number LIKE ? OR COALESCE(device_written_serial_number, '') LIKE ?)"
        )
        params.extend([sn_val, sn_val])
    if date_from:
        conditions.append("date(created_at) >= ?")
        params.append(date_from)
    if date_to:
        conditions.append("date(created_at) <= ?")
        params.append(date_to)
    if burn_test_result and burn_test_result in ("passed", "failed", "self_check_failed", "key_abnormal"):
        conditions.append("burn_test_result = ?")
        params.append(burn_test_result)
    if flow_type and flow_type in ("P", "T", "P+T"):
        conditions.append("flow_type = ?")
        params.append(flow_type)
    if bin_file and bin_file.strip():
        conditions.append("bin_file_name = ?")
        params.append(bin_file.strip())
    if mac:
        mac_val = mac.strip().replace("*", "%")
        if "%" not in mac_val:
            mac_val = "%" + mac_val + "%"
        conditions.append("mac_address LIKE ?")
        params.append(mac_val)
    where = " AND ".join(conditions)
    with get_db() as conn:
        count_row = conn.execute(
            f"SELECT COUNT(*) FROM burn_records WHERE {where}", tuple(params)
        ).fetchone()
        total_count = count_row[0] if count_row else 0
        params_ext = params + [limit]
        rows = conn.execute(
            f"""SELECT id, created_at, device_serial_number, mac_address,
                       burn_start_time, burn_duration_seconds, computer_identity,
                       device_written_timestamp, bin_file_name, device_written_serial_number, burn_test_result, failure_reason, flow_type, button_wait_seconds
                FROM burn_records WHERE {where}
                ORDER BY created_at DESC LIMIT ?""",
            tuple(params_ext),
        ).fetchall()
    records = [
        {
            "id": r["id"],
            "createdAt": r["created_at"],
            "deviceSerialNumber": r["device_serial_number"],
            "macAddress": r["mac_address"],
            "burnStartTime": r["burn_start_time"],
            "burnDurationSeconds": r["burn_duration_seconds"],
            "computerIdentity": r["computer_identity"],
            "deviceWrittenTimestamp": r["device_written_timestamp"],
            "binFileName": r["bin_file_name"],
            "deviceWrittenSerialNumber": r["device_written_serial_number"],
            "burnTestResult": r["burn_test_result"],
            "failureReason": r["failure_reason"],
            "flowType": r["flow_type"],
            "buttonWaitSeconds": r["button_wait_seconds"],
        }
        for r in rows
    ]
    return {"records": records, "totalCount": total_count}


@app.post("/api/firmware-upgrade-record")
def post_firmware_upgrade_record(payload: FirmwareUpgradePayload) -> Dict[str, Any]:
    """设备 OTA 升级结果上报。deviceSerialNumber 与 macAddress 至少填一个。"""
    sn = payload.deviceSerialNumber.strip() if payload.deviceSerialNumber else None
    mac = payload.macAddress.strip() if payload.macAddress else None
    if not sn and not mac:
        raise HTTPException(
            status_code=400,
            detail="At least one of deviceSerialNumber or macAddress is required",
        )
    to_ver = payload.newVersion if payload.upgradeSuccess else None
    final_ver = payload.finalVersion or (payload.newVersion if payload.upgradeSuccess else payload.currentVersion)
    with get_db() as conn:
        _insert_firmware_history(
            conn,
            "upgrade",
            sn,
            mac,
            payload.currentVersion,
            to_ver,
            payload.upgradeSuccess,
            None,
            payload.computerIdentity,
            payload.targetFileSizeBytes,
            payload.durationSeconds,
            payload.failureReason,
            final_ver,
        )
        conn.commit()
    _broadcast_sse("firmware")
    return {"ok": True}


@app.get("/api/events")
async def sse_events():
    """SSE 推送：有新数据时推送 production|burn|firmware，客户端收到后刷新对应 tab。"""
    async def gen():
        queue: asyncio.Queue = asyncio.Queue()
        with _sse_lock:
            _sse_queues.append(queue)
        try:
            while True:
                try:
                    event_type = await asyncio.wait_for(queue.get(), timeout=30.0)
                    yield f"data: {json.dumps({'type': event_type})}\n\n"
                except asyncio.TimeoutError:
                    yield ": keepalive\n\n"
        finally:
            with _sse_lock:
                if queue in _sse_queues:
                    _sse_queues.remove(queue)

    return StreamingResponse(
        gen(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive", "X-Accel-Buffering": "no"},
    )


@app.get("/api/firmware-history")
def get_firmware_history(
    sn: Optional[str] = Query(None, description="设备 SN，支持模糊"),
    mac: Optional[str] = Query(None, description="MAC 地址，支持模糊"),
    date_from: Optional[str] = Query(None, description="YYYY-MM-DD"),
    date_to: Optional[str] = Query(None, description="YYYY-MM-DD"),
    record_type: Optional[str] = Query(None, description="burn|upgrade"),
    limit: int = Query(200, ge=1, le=1000),
) -> Dict[str, Any]:
    """查询设备固件版本历史。"""
    conditions: List[str] = ["1=1"]
    params: List[Any] = []
    if sn:
        sn_val = sn.strip().replace("*", "%")
        if "%" not in sn_val:
            sn_val = "%" + sn_val + "%"
        conditions.append("device_serial_number LIKE ?")
        params.append(sn_val)
    if mac:
        mac_val = mac.strip().replace("*", "%")
        if "%" not in mac_val:
            mac_val = "%" + mac_val + "%"
        conditions.append("mac_address LIKE ?")
        params.append(mac_val)
    if date_from:
        conditions.append("date(created_at) >= ?")
        params.append(date_from)
    if date_to:
        conditions.append("date(created_at) <= ?")
        params.append(date_to)
    if record_type and record_type in ("burn", "upgrade"):
        conditions.append("record_type = ?")
        params.append(record_type)
    where = " AND ".join(conditions)
    with get_db() as conn:
        count_row = conn.execute(
            f"SELECT COUNT(*) FROM firmware_history WHERE {where}", tuple(params)
        ).fetchone()
        total_count = count_row[0] if count_row else 0
        params_ext = params + [limit]
        rows = conn.execute(
            f"""SELECT id, created_at, record_type, device_serial_number, mac_address,
                       from_version, to_version, upgrade_success, burn_record_id, computer_identity,
                       target_file_size_bytes, duration_seconds, failure_reason, final_version
                FROM firmware_history WHERE {where}
                ORDER BY created_at DESC LIMIT ?""",
            tuple(params_ext),
        ).fetchall()
    records = [
        {
            "id": r["id"],
            "createdAt": r["created_at"],
            "recordType": r["record_type"],
            "deviceSerialNumber": r["device_serial_number"],
            "macAddress": r["mac_address"],
            "fromVersion": r["from_version"],
            "toVersion": r["to_version"],
            "upgradeSuccess": bool(r["upgrade_success"]) if r["upgrade_success"] is not None else None,
            "burnRecordId": r["burn_record_id"],
            "targetFileSizeBytes": r["target_file_size_bytes"],
            "durationSeconds": r["duration_seconds"],
            "failureReason": r["failure_reason"],
            "finalVersion": r["final_version"],
            "computerIdentity": r["computer_identity"],
        }
        for r in rows
    ]
    return {"records": records, "totalCount": total_count}


@app.get("/api/admin/firmware")
def admin_list_firmware(
    usage_type: Optional[str] = Query(None, description="factory_merged|ota_app"),
    channel: Optional[str] = Query(None, description="production|debugging"),
    _: None = Depends(require_admin),
) -> Dict[str, Any]:
    conditions: List[str] = []
    params: List[Any] = []
    if usage_type:
        conditions.append("usage_type = ?")
        params.append(usage_type)
    if channel:
        conditions.append("channel = ?")
        params.append(channel)
    where = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    with get_db() as conn:
        rows = conn.execute(
            f"""
            SELECT id, created_at, usage_type, channel, version,
                   file_name, file_path, file_size_bytes, checksum,
                   description, is_active, original_file_name
            FROM firmware_files
            {where}
            ORDER BY created_at DESC
            """,
            tuple(params),
        ).fetchall()
    items: List[Dict[str, Any]] = []
    for r in rows:
        public_path = _firmware_public_path(r["file_path"])
        download_url = f"/api/admin/firmware/{r['id']}/download"
        items.append(
            {
                "id": r["id"],
                "createdAt": r["created_at"],
                "usageType": r["usage_type"],
                "channel": r["channel"],
                "version": r["version"],
                "fileName": r["file_name"],
                "originalFileName": r["original_file_name"],
                "fileSizeBytes": r["file_size_bytes"],
                "checksum": r["checksum"],
                "description": r["description"],
                "isActive": bool(r["is_active"]),
                "downloadPath": public_path,
                "downloadUrl": download_url,
            }
        )
    return {"items": items}


@app.post("/api/admin/firmware")
def admin_upload_firmware(
    usage_type: str = Form(..., description="factory_merged or ota_app"),
    channel: str = Form(..., description="production or debugging"),
    version: str = Form(..., description="Firmware version string"),
    description: str = Form("", description="Optional description"),
    file: UploadFile = File(...),
    _: None = Depends(require_admin),
) -> Dict[str, Any]:
    target_dir = _ensure_firmware_dir(usage_type, channel)
    original_name = file.filename or "firmware.bin"
    # 文件名格式校验：
    # - 合并固件（产线烧录）：CO2ControllerFW_combined_1_1_3.bin
    # - OTA 应用固件：CO2ControllerFW_1_1_3.bin
    if usage_type == "factory_merged":
        m = re.fullmatch(r"CO2ControllerFW_combined_(\d+)_(\d+)_(\d+)\.bin", original_name)
        if not m:
            raise HTTPException(
                status_code=400,
                detail="合并固件文件名必须类似 CO2ControllerFW_combined_1_1_3.bin",
            )
    elif usage_type == "ota_app":
        m = re.fullmatch(r"CO2ControllerFW_(\d+)_(\d+)_(\d+)\.bin", original_name)
        if not m:
            raise HTTPException(
                status_code=400,
                detail="OTA 固件文件名必须类似 CO2ControllerFW_1_1_3.bin",
            )
    else:
        # 理论上不会走到这里，_ensure_firmware_dir 已经校验 usage_type
        raise HTTPException(status_code=400, detail="Invalid usage_type")

    major, minor, patch = m.group(1), m.group(2), m.group(3)
    version_from_name = f"{major}.{minor}.{patch}"
    if version and version.strip() and version.strip() != version_from_name:
        raise HTTPException(
            status_code=400,
            detail=f"版本号应与文件名中的 1_1_3 一致，即 {version_from_name}",
        )
    version_value = version_from_name

    ext = Path(original_name).suffix or ".bin"
    safe_stem = f"{usage_type}-{channel}-{version_value}".replace("/", "_").replace(" ", "_")
    filename = f"{safe_stem}-{int(time.time())}{ext}"
    path = target_dir / filename
    file_size = 0
    hasher = hashlib.sha256()
    with path.open("wb") as f:
        while True:
            chunk = file.file.read(8192)
            if not chunk:
                break
            file_size += len(chunk)
            hasher.update(chunk)
            f.write(chunk)
    checksum = hasher.hexdigest()
    fw_id = str(uuid.uuid4())
    created_at = _now_iso()
    with get_db() as conn:
        conn.execute(
            """
            INSERT INTO firmware_files (
                id, created_at, usage_type, channel, version,
                file_name, file_path, file_size_bytes, checksum, description, is_active, original_file_name
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            """,
            (
                fw_id,
                created_at,
                usage_type,
                channel,
                version_value,
                filename,
                str(path),
                file_size,
                checksum,
                description or None,
                original_name,
            ),
        )
        conn.commit()
    return {"ok": True, "id": fw_id, "createdAt": created_at}


@app.delete("/api/admin/firmware/{firmware_id}")
def admin_delete_firmware(
    firmware_id: str,
    _: None = Depends(require_admin),
) -> Dict[str, Any]:
    file_path: Optional[str] = None
    with get_db() as conn:
        row = conn.execute(
            "SELECT file_path FROM firmware_files WHERE id = ?",
            (firmware_id,),
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Firmware not found")
        file_path = row["file_path"]
        conn.execute("DELETE FROM firmware_files WHERE id = ?", (firmware_id,))
        conn.commit()
    if file_path:
        try:
            p = Path(file_path)
            if p.is_file():
                p.unlink()
        except Exception:
            # 文件删除失败不影响接口返回，记录保留已被删除
            pass
    return {"ok": True}


@app.get("/api/admin/firmware/{firmware_id}/download")
def admin_download_firmware(
    firmware_id: str,
    _: None = Depends(require_admin),
):
    with get_db() as conn:
        row = conn.execute(
            """
            SELECT file_path, COALESCE(original_file_name, file_name) AS download_name
            FROM firmware_files WHERE id = ?
            """,
            (firmware_id,),
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Firmware not found")
    path = Path(row["file_path"])
    if not path.is_file():
        raise HTTPException(status_code=404, detail="File not found on disk")
    return FileResponse(
        path,
        filename=row["download_name"],
        media_type="application/octet-stream",
    )


# ---------------------------------------------------------------------------
# 只读固件 API（供 BOG_TOOL App 拉取列表与下载，无需 admin 鉴权）
# ---------------------------------------------------------------------------

@app.get("/api/firmware")
def list_firmware(
    usage_type: Optional[str] = Query(None, description="factory_merged|ota_app"),
    channel: Optional[str] = Query(None, description="production|debugging"),
) -> Dict[str, Any]:
    """返回固件列表，结构与 GET /api/admin/firmware 一致，供 App 下拉选择。"""
    conditions: List[str] = []
    params: List[Any] = []
    if usage_type:
        conditions.append("usage_type = ?")
        params.append(usage_type)
    if channel:
        conditions.append("channel = ?")
        params.append(channel)
    where = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    with get_db() as conn:
        rows = conn.execute(
            f"""
            SELECT id, created_at, usage_type, channel, version,
                   file_name, file_path, file_size_bytes, checksum,
                   description, is_active, original_file_name
            FROM firmware_files
            {where}
            ORDER BY created_at DESC
            """,
            tuple(params),
        ).fetchall()
    items: List[Dict[str, Any]] = []
    for r in rows:
        download_url = f"/api/firmware/{r['id']}/download"
        items.append(
            {
                "id": r["id"],
                "createdAt": r["created_at"],
                "usageType": r["usage_type"],
                "channel": r["channel"],
                "version": r["version"],
                "fileName": r["file_name"],
                "originalFileName": r["original_file_name"],
                "fileSizeBytes": r["file_size_bytes"],
                "checksum": r["checksum"],
                "description": r["description"],
                "isActive": bool(r["is_active"]),
                "downloadUrl": download_url,
            }
        )
    return {"items": items}


@app.get("/api/firmware/{firmware_id}/download")
def download_firmware(firmware_id: str):
    """下载固件文件，供 App OTA 使用。无需鉴权。"""
    with get_db() as conn:
        row = conn.execute(
            """
            SELECT file_path, COALESCE(original_file_name, file_name) AS download_name
            FROM firmware_files WHERE id = ?
            """,
            (firmware_id,),
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Firmware not found")
    path = Path(row["file_path"])
    if not path.is_file():
        raise HTTPException(status_code=404, detail="File not found on disk")
    return FileResponse(
        path,
        filename=row["download_name"],
        media_type="application/octet-stream",
    )


@app.get("/api/debug/burn-timestamps")
def debug_burn_timestamps(limit: int = Query(20, ge=1, le=100)) -> Dict[str, Any]:
    """调试：检查 device_written_timestamp 在 DB 中的存储情况。"""
    with get_db() as conn:
        total = conn.execute("SELECT COUNT(*) FROM burn_records").fetchone()[0]
        has_ts = conn.execute(
            "SELECT COUNT(*) FROM burn_records WHERE device_written_timestamp IS NOT NULL AND device_written_timestamp != ''"
        ).fetchone()[0]
        rows = conn.execute(
            """SELECT id, device_serial_number, burn_start_time, device_written_timestamp, created_at
               FROM burn_records ORDER BY created_at DESC LIMIT ?""",
            (limit,),
        ).fetchall()
    samples = [
        {
            "deviceSerialNumber": r["device_serial_number"],
            "burnStartTime": r["burn_start_time"],
            "deviceWrittenTimestamp": r["device_written_timestamp"],
            "createdAt": r["created_at"],
        }
        for r in rows
    ]
    return {
        "totalRecords": total,
        "recordsWithDeviceWrittenTimestamp": has_ts,
        "recordsWithout": total - has_ts,
        "samples": samples,
        "hint": "若 recordsWithout>0，说明烧录端未上传 deviceWrittenTimestamp 字段",
    }


@app.post("/api/pcba-test-record")
def post_pcba_test_record(payload: PcbaTestRecordPayload) -> Dict[str, Any]:
    """PCBA 测试记录上报，MAC 地址为主标识。"""
    record_id = str(uuid.uuid4())
    created_at = _now_iso()
    test_details_json = (
        json.dumps(payload.testDetails, ensure_ascii=False)
        if payload.testDetails is not None
        else None
    )
    with get_db() as conn:
        conn.execute(
            """INSERT INTO pcba_test_records (
                id, created_at, mac_address, device_serial_number,
                test_result, test_time, duration_seconds, computer_identity, test_details
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                record_id,
                created_at,
                payload.macAddress.strip(),
                payload.deviceSerialNumber.strip() if payload.deviceSerialNumber else None,
                payload.testResult,
                payload.testTime,
                payload.durationSeconds,
                payload.computerIdentity,
                test_details_json,
            ),
        )
        conn.commit()
    return {"ok": True, "id": record_id, "createdAt": created_at}


@app.post("/api/pcba-test-record/batch")
def post_pcba_test_record_batch(payload: PcbaTestRecordBatchPayload) -> Dict[str, Any]:
    """批量上报 PCBA 测试记录，单次最多 500 条。"""
    results: List[Dict[str, Any]] = []
    for p in payload.records:
        try:
            r = post_pcba_test_record(p)
            results.append({"ok": True, "id": r["id"], "createdAt": r["createdAt"]})
        except HTTPException as e:
            results.append({"ok": False, "error": str(e.detail)})
    return {"ok": True, "count": len(results), "results": results}


@app.get("/api/pcba-test-records")
def get_pcba_test_records(
    mac: Optional[str] = Query(None, description="MAC 地址，支持模糊"),
    date_from: Optional[str] = Query(None, description="YYYY-MM-DD"),
    date_to: Optional[str] = Query(None, description="YYYY-MM-DD"),
    test_result: Optional[str] = Query(None, description="passed|failed"),
    limit: int = Query(200, ge=1, le=1000),
) -> Dict[str, Any]:
    """查询 PCBA 测试记录，按 MAC 优先排序。"""
    conditions: List[str] = ["1=1"]
    params: List[Any] = []
    if mac:
        mac_val = mac.strip().replace("*", "%")
        if "%" not in mac_val:
            mac_val = "%" + mac_val + "%"
        conditions.append("mac_address LIKE ?")
        params.append(mac_val)
    if date_from:
        conditions.append("date(created_at) >= ?")
        params.append(date_from)
    if date_to:
        conditions.append("date(created_at) <= ?")
        params.append(date_to)
    if test_result and test_result in ("passed", "failed"):
        conditions.append("test_result = ?")
        params.append(test_result)
    where = " AND ".join(conditions)
    with get_db() as conn:
        count_row = conn.execute(
            f"SELECT COUNT(*) FROM pcba_test_records WHERE {where}", tuple(params)
        ).fetchone()
        total_count = count_row[0] if count_row else 0
        params_ext = params + [limit]
        rows = conn.execute(
            f"""SELECT id, created_at, mac_address, device_serial_number,
                       test_result, test_time, duration_seconds, computer_identity, test_details
                FROM pcba_test_records WHERE {where}
                ORDER BY mac_address, created_at DESC LIMIT ?""",
            tuple(params_ext),
        ).fetchall()
    records = [
        {
            "id": r["id"],
            "createdAt": r["created_at"],
            "macAddress": r["mac_address"],
            "deviceSerialNumber": r["device_serial_number"],
            "testResult": r["test_result"],
            "testTime": r["test_time"],
            "durationSeconds": r["duration_seconds"],
            "computerIdentity": r["computer_identity"],
            "testDetails": r["test_details"],
        }
        for r in rows
    ]
    return {"records": records, "totalCount": total_count}


@app.get("/api/pcba-mac-list")
def get_pcba_mac_list() -> List[str]:
    """返回 PCBA 记录中不重复的 MAC 地址，供下拉选择。"""
    with get_db() as conn:
        rows = conn.execute(
            """SELECT DISTINCT mac_address FROM pcba_test_records
               WHERE mac_address IS NOT NULL AND mac_address != ''
               ORDER BY mac_address"""
        ).fetchall()
    return [r["mac_address"] for r in rows]


@app.get("/api/burn-bin-list")
def get_burn_bin_list() -> List[str]:
    """返回烧录记录中所有不重复的 bin 文件名，供下拉选择。"""
    with get_db() as conn:
        rows = conn.execute(
            """SELECT DISTINCT bin_file_name FROM burn_records
               WHERE bin_file_name IS NOT NULL AND bin_file_name != ''
               ORDER BY bin_file_name"""
        ).fetchall()
    return [r["bin_file_name"] for r in rows]


@app.get("/api/summary")
def get_summary(
    sn: Optional[str] = Query(None),
    date_from: Optional[str] = Query(None, description="YYYY-MM-DD"),
    date_to: Optional[str] = Query(None, description="YYYY-MM-DD"),
) -> Dict[str, Any]:
    """汇总：按设备号统计，随当前查询条件（SN、日期范围）变化；每设备只计其最新一次测试结果。使用 JOIN+MAX 兼容旧版 SQLite。"""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    conditions: List[str] = ["device_serial_number IS NOT NULL", "device_serial_number != ''"]
    params: List[Any] = []
    if sn:
        conditions.append("device_serial_number = ?")
        params.append(sn.strip())
    if date_from:
        conditions.append("date(created_at) >= ?")
        params.append(date_from)
    if date_to:
        conditions.append("date(created_at) <= ?")
        params.append(date_to)
    where = " AND ".join(conditions)

    with get_db() as conn:
        # 总测试记录数（当前筛选条件下的记录条数）
        where_clause = (" WHERE " + where) if where else ""
        total_records_row = conn.execute(
            f"SELECT COUNT(*) FROM production_tests{where_clause}",
            tuple(params),
        ).fetchone()
        total_records = total_records_row[0] if total_records_row else 0

        # 每设备取最新一条：JOIN (device_serial_number, MAX(created_at))，兼容无 ROW_NUMBER 的 SQLite
        latest_subq = f"""
            SELECT device_serial_number, MAX(created_at) AS created_at
            FROM production_tests WHERE {where}
            GROUP BY device_serial_number
        """
        join_subq = f"""
            SELECT t.device_serial_number, t.overall_passed
            FROM production_tests t
            INNER JOIN ({latest_subq}) lat
              ON t.device_serial_number = lat.device_serial_number AND t.created_at = lat.created_at
        """
        total_row = conn.execute(
            "SELECT COUNT(*) FROM (" + join_subq + ")",
            tuple(params),
        ).fetchone()
        passed_row = conn.execute(
            "SELECT COUNT(*) FROM (" + join_subq + ") WHERE overall_passed = 1",
            tuple(params),
        ).fetchone()
        total = total_row[0] if total_row else 0
        passed = passed_row[0] if passed_row else 0
        failed = total - passed
        pass_rate = round(100.0 * passed / total, 1) if total else 0.0

        # 今日：在当前筛选下仅今日记录，每设备取今日内最新一条
        where_today = where + " AND date(created_at) = ?"
        params_today = list(params) + [today]
        latest_today_subq = f"""
            SELECT device_serial_number, MAX(created_at) AS created_at
            FROM production_tests WHERE {where_today}
            GROUP BY device_serial_number
        """
        join_today_subq = f"""
            SELECT t.device_serial_number, t.overall_passed
            FROM production_tests t
            INNER JOIN ({latest_today_subq}) lat
              ON t.device_serial_number = lat.device_serial_number AND t.created_at = lat.created_at
        """
        today_total_row = conn.execute(
            "SELECT COUNT(*) FROM (" + join_today_subq + ")",
            tuple(params_today),
        ).fetchone()
        today_passed_row = conn.execute(
            "SELECT COUNT(*) FROM (" + join_today_subq + ") WHERE overall_passed = 1",
            tuple(params_today),
        ).fetchone()
        today_count = today_total_row[0] if today_total_row else 0
        today_passed = today_passed_row[0] if today_passed_row else 0
        today_failed = today_count - today_passed
        today_pass_rate = round(100.0 * today_passed / today_count, 1) if today_count else 0.0
    return {
        "totalRecords": total_records,
        "total": total,
        "passed": passed,
        "failed": failed,
        "passRatePercent": pass_rate,
        "today": {
            "total": today_count,
            "passed": today_passed,
            "failed": today_failed,
            "passRatePercent": today_pass_rate,
        },
    }


@app.get("/api/records")
def get_records(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    sn: Optional[str] = Query(None),
    date_from: Optional[str] = Query(None, description="YYYY-MM-DD"),
    date_to: Optional[str] = Query(None, description="YYYY-MM-DD"),
) -> Dict[str, Any]:
    """分页查询产测记录，可按 SN、日期范围筛选。"""
    conditions: List[str] = []
    params: List[Any] = []
    if sn:
        conditions.append("device_serial_number = ?")
        params.append(sn.strip())
    if date_from:
        conditions.append("date(created_at) >= ?")
        params.append(date_from)
    if date_to:
        conditions.append("date(created_at) <= ?")
        params.append(date_to)
    where = (" WHERE " + " AND ".join(conditions)) if conditions else ""

    with get_db() as conn:
        count_row = conn.execute(
            f"SELECT COUNT(*) FROM production_tests{where}", params
        ).fetchone()
        total_count = count_row[0] if count_row else 0
        params_ext = params + [limit, offset]
        rows = conn.execute(
            f"""
            SELECT id, created_at, start_time, end_time, duration_seconds,
                   device_serial_number, device_name,
                   device_firmware_version, device_bootloader_version, device_hardware_revision,
                   overall_passed, need_retest, steps_summary, step_results, test_details
            FROM production_tests
            {where}
            ORDER BY created_at DESC
            LIMIT ? OFFSET ?
            """,
            params_ext,
        ).fetchall()

    def row_to_item(r: sqlite3.Row) -> Dict[str, Any]:
        steps = []
        if r["steps_summary"]:
            try:
                steps = json.loads(r["steps_summary"])
            except json.JSONDecodeError:
                pass
        test_details = None
        try:
            td = r["test_details"]
            if td:
                test_details = json.loads(td)
        except (KeyError, json.JSONDecodeError, TypeError):
            pass
        return {
            "id": r["id"],
            "createdAt": r["created_at"],
            "startTime": r["start_time"],
            "endTime": r["end_time"],
            "durationSeconds": r["duration_seconds"],
            "deviceSerialNumber": r["device_serial_number"],
            "deviceName": r["device_name"],
            "deviceFirmwareVersion": r["device_firmware_version"],
            "deviceBootloaderVersion": r["device_bootloader_version"],
            "deviceHardwareRevision": r["device_hardware_revision"],
            "overallPassed": bool(r["overall_passed"]),
            "needRetest": bool(r["need_retest"]),
            "stepsSummary": steps,
            "stepResults": json.loads(r["step_results"]) if r["step_results"] else None,
            "testDetails": test_details,
        }

    return {
        "total": total_count,
        "limit": limit,
        "offset": offset,
        "items": [row_to_item(r) for r in rows],
    }


@app.get("/api/sn-list")
def get_sn_list() -> List[str]:
    """返回所有出现过的设备号（去重、排序），供前端 SN 下拉建议。"""
    with get_db() as conn:
        rows = conn.execute(
            "SELECT DISTINCT device_serial_number FROM production_tests WHERE device_serial_number IS NOT NULL AND device_serial_number != '' ORDER BY device_serial_number"
        ).fetchall()
    return [r[0] for r in rows]


@app.get("/api/export", response_class=PlainTextResponse)
def export_csv(
    date_from: Optional[str] = Query(None),
    date_to: Optional[str] = Query(None),
    sn: Optional[str] = Query(None),
) -> str:
    """导出为 CSV（UTF-8）。"""
    conditions: List[str] = []
    params: List[Any] = []
    if sn:
        conditions.append("device_serial_number = ?")
        params.append(sn.strip())
    if date_from:
        conditions.append("date(created_at) >= ?")
        params.append(date_from)
    if date_to:
        conditions.append("date(created_at) <= ?")
        params.append(date_to)
    where = (" AND " + " AND ".join(conditions)) if conditions else ""

    with get_db() as conn:
        rows = conn.execute(
            f"""
            SELECT id, created_at, start_time, end_time, duration_seconds,
                   device_serial_number, device_name,
                   device_firmware_version, device_bootloader_version, device_hardware_revision,
                   overall_passed, need_retest, steps_summary, step_results, test_details
            FROM production_tests
            {where}
            ORDER BY created_at DESC
            """,
            params,
        ).fetchall()

    import csv
    import io
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow([
        "id", "created_at", "start_time", "end_time", "duration_seconds",
        "device_serial_number", "device_name",
        "device_firmware_version", "device_bootloader_version", "device_hardware_revision",
        "overall_passed", "need_retest", "steps_summary", "step_results", "test_details",
    ])
    for r in rows:
        writer.writerow([
            r["id"], r["created_at"], r["start_time"], r["end_time"], r["duration_seconds"],
            r["device_serial_number"], r["device_name"] or "",
            r["device_firmware_version"] or "", r["device_bootloader_version"] or "",
            r["device_hardware_revision"] or "",
            1 if r["overall_passed"] else 0, 1 if r["need_retest"] else 0,
            (r["steps_summary"] or "").replace("\n", " "),
            (r["step_results"] or "").replace("\n", " "),
            (r["test_details"] or "").replace("\n", " "),
        ])
    buf.seek(0)
    return buf.getvalue()


# ---------------------------------------------------------------------------
# 当前预览观众（按心跳，超时视为离开）
# ---------------------------------------------------------------------------

_viewers: Dict[str, float] = {}
_viewers_lock = threading.Lock()
VIEWER_TIMEOUT_SEC = 60


def _get_client_ip(request: Request) -> str:
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()
    return request.client.host if request.client else ""


def _is_dev_env() -> bool:
    """是否为测试环境（仅测试环境允许清空数据）。"""
    return os.environ.get("BOG_ENV") == "dev"


@app.get("/api/deploy-info")
def api_deploy_info() -> Dict[str, Any]:
    """返回最近一次部署时间（由 deploy 脚本写入）。"""
    ts_path = BASE_DIR / "deploy_timestamp.txt"
    result: Dict[str, Any] = {"deployTime": None, "isDev": _is_dev_env()}
    try:
        if ts_path.exists():
            t = ts_path.read_text().strip()
            if t:
                result["deployTime"] = t
    except Exception:
        pass
    return result


@app.delete("/api/clear-test-data")
def api_clear_test_data() -> Dict[str, Any]:
    """清空测试环境数据（产测+烧录+固件历史），仅 BOG_ENV=dev 时可用。"""
    if not _is_dev_env():
        raise HTTPException(status_code=403, detail="Only available in dev environment")
    with get_db() as conn:
        conn.execute("DELETE FROM production_tests")
        conn.execute("DELETE FROM burn_records")
        conn.execute("DELETE FROM pcba_test_records")
        conn.execute("DELETE FROM firmware_history")
        conn.commit()
    return {"ok": True, "message": "Test data cleared"}


@app.get("/api/viewers")
def api_viewers(request: Request) -> Dict[str, Any]:
    """登记当前请求 IP 为观众，清理超时，返回观众列表（IP + 最后访问时间）。"""
    ip = _get_client_ip(request)
    now = time.time()
    with _viewers_lock:
        _viewers[ip] = now
        to_del = [k for k, v in _viewers.items() if now - v > VIEWER_TIMEOUT_SEC]
        for k in to_del:
            del _viewers[k]
        items = [
            {"ip": k, "lastSeen": datetime.fromtimestamp(v, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
            for k, v in sorted(_viewers.items(), key=lambda x: -x[1])
        ]
        ips = [x["ip"] for x in items[:10]]
    return {"count": len(_viewers), "ips": ips, "items": items}


# ---------------------------------------------------------------------------
# Admin 页面（固件管理）
# ---------------------------------------------------------------------------

ADMIN_LOGIN_HTML = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>BOG 固件管理登录</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 0; background: #f5f5f5; }
    .wrap { min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 24px; }
    .card { background: #fff; padding: 24px 28px 28px; border-radius: 10px; box-shadow: 0 12px 30px rgba(15,23,42,0.15); max-width: 360px; width: 100%; }
    h1 { margin: 0 0 16px; font-size: 20px; color: #111827; text-align: center; }
    p.desc { margin: 0 0 20px; font-size: 13px; color: #6b7280; text-align: center; }
    label { display: block; margin-bottom: 12px; font-size: 13px; color: #374151; }
    input[type="text"], input[type="password"] { width: 100%; padding: 8px 10px; border-radius: 8px; border: 1px solid #d1d5db; font-size: 14px; }
    input:focus { outline: none; border-color: #2563eb; box-shadow: 0 0 0 1px rgba(37,99,235,0.15); }
    button { width: 100%; padding: 9px 12px; border-radius: 999px; border: none; background: linear-gradient(135deg,#2563eb,#4f46e5); color: #fff; font-size: 14px; font-weight: 500; cursor: pointer; margin-top: 4px; }
    button:disabled { opacity: 0.6; cursor: default; }
    .error { margin-top: 10px; font-size: 13px; color: #b91c1c; min-height: 18px; }
    .footer { margin-top: 16px; font-size: 12px; color: #9ca3af; text-align: center; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>BOG 固件管理后台</h1>
      <p class="desc">仅限管理员使用，用于管理烧录 / OTA 固件。</p>
      <form id="login-form">
        <label>
          用户名
          <input type="text" name="username" autocomplete="username" required />
        </label>
        <label>
          密码
          <input type="password" name="password" autocomplete="current-password" required />
        </label>
        <button type="submit" id="btn-login">登录</button>
        <div class="error" id="error-text"></div>
      </form>
      <div class="footer">登录成功后将进入固件管理页面。</div>
    </div>
  </div>
  <script>
    (function () {
      var form = document.getElementById('login-form');
      var btn = document.getElementById('btn-login');
      var err = document.getElementById('error-text');
      form.addEventListener('submit', function (e) {
        e.preventDefault();
        err.textContent = '';
        btn.disabled = true;
        var fd = new FormData(form);
        fetch('/api/admin/login', { method: 'POST', body: fd })
          .then(function (res) {
            if (!res.ok) throw new Error('登录失败: ' + res.status);
            return res.json();
          })
          .then(function () {
            window.location.href = '/admin/firmware';
          })
          .catch(function (e) {
            err.textContent = e.message || '登录失败，请重试';
          })
          .finally(function () { btn.disabled = false; });
      });
    })();
  </script>
</body>
</html>
"""


ADMIN_FIRMWARE_HTML = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>BOG 固件管理</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 20px; background: #f3f4f6; }
    h1 { margin: 0 0 12px; color: #111827; }
    .topbar { display: flex; flex-wrap: wrap; gap: 12px; align-items: center; margin-bottom: 12px; }
    .tag { font-size: 12px; padding: 3px 8px; border-radius: 999px; background: #e5e7eb; color: #374151; }
    .controls { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 14px; }
    select, input[type="text"], input[type="file"] { padding: 7px 9px; border-radius: 8px; border: 1px solid #d1d5db; font-size: 13px; }
    select:focus, input:focus { outline: none; border-color: #2563eb; box-shadow: 0 0 0 1px rgba(37,99,235,0.15); }
    button { padding: 7px 12px; border-radius: 999px; border: none; font-size: 13px; cursor: pointer; }
    .btn-primary { background: linear-gradient(135deg,#2563eb,#4f46e5); color: #fff; }
    .btn-secondary { background: #e5e7eb; color: #111827; }
    .btn-danger { background: #ef4444; color: #fff; }
    table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
    th, td { padding: 8px 10px; border-bottom: 1px solid #e5e7eb; font-size: 12px; text-align: left; }
    th { background: #f9fafb; color: #6b7280; font-weight: 500; }
    tr:hover td { background: #f9fafb; }
    .empty-row td { text-align: center; color: #9ca3af; }
    .badge { display: inline-block; padding: 2px 6px; border-radius: 999px; font-size: 11px; }
    .badge-factory { background: #dbeafe; color: #1d4ed8; }
    .badge-ota { background: #dcfce7; color: #15803d; }
    .badge-prod { background: #fee2e2; color: #b91c1c; }
    .badge-debug { background: #e5e7eb; color: #374151; }
    .layout { display: grid; grid-template-columns: minmax(0, 2fr) minmax(0, 1fr); gap: 16px; align-items: flex-start; }
    @media (max-width: 960px) { .layout { grid-template-columns: minmax(0, 1fr); } }
    .panel { background: #fff; border-radius: 10px; padding: 14px 16px 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }
    .panel h2 { margin: 0 0 10px; font-size: 15px; color: #111827; }
    .panel p { margin: 0 0 8px; font-size: 12px; color: #6b7280; }
    .help { font-size: 12px; color: #6b7280; margin-top: 6px; }
    .muted { color: #9ca3af; }
    .link { color: #2563eb; text-decoration: none; }
    .link:hover { text-decoration: underline; }
    #fw-table { table-layout: fixed; min-width: 900px; }
    #fw-table th { position: relative; white-space: nowrap; }
    #fw-table th .resize-handle { position: absolute; right: 0; top: 0; bottom: 0; width: 6px; cursor: col-resize; }
    #fw-table th .resize-handle:hover { background: rgba(37,99,235,0.2); }
    #fw-table .col-time { width: 160px; min-width: 100px; }
    #fw-table .col-usage { width: 120px; min-width: 80px; }
    #fw-table .col-env { width: 90px; min-width: 70px; }
    #fw-table .col-version { width: 85px; min-width: 65px; }
    #fw-table .col-fname { width: 200px; min-width: 120px; }
    #fw-table .col-size { width: 85px; min-width: 65px; }
    #fw-table .col-summary { width: 140px; min-width: 90px; }
    #fw-table .col-dl { width: 65px; min-width: 50px; }
    #fw-table .col-action { width: 75px; min-width: 60px; }
    #fw-table td { overflow: hidden; text-overflow: ellipsis; }
  </style>
</head>
<body>
  <div class="topbar">
    <h1>BOG 固件管理</h1>
    <span class="tag">私有后台 · 仅管理员</span>
    <button class="btn-secondary" id="btn-logout">退出登录</button>
  </div>

  <div class="controls">
    <label>用途：
      <select id="usage-select">
        <option value="">全部</option>
        <option value="factory_merged">产线合并固件（烧录）</option>
        <option value="ota_app">应用固件（OTA）</option>
      </select>
    </label>
    <label>环境：
      <select id="channel-select">
        <option value="production">生产环境</option>
        <option value="debugging">调试 / 内测</option>
      </select>
    </label>
    <button class="btn-secondary" id="btn-refresh">刷新列表</button>
  </div>

  <div class="layout">
    <div class="panel">
      <h2>固件列表</h2>
      <p>按上传时间倒序排列，仅当前用途 / 环境。</p>
      <div style="overflow-x:auto;">
        <table id="fw-table">
          <colgroup>
            <col class="col-time" /><col class="col-usage" /><col class="col-env" /><col class="col-version" /><col class="col-fname" /><col class="col-size" /><col class="col-summary" /><col class="col-dl" /><col class="col-action" />
          </colgroup>
          <thead>
            <tr>
              <th>时间<span class="resize-handle"></span></th>
              <th>用途<span class="resize-handle"></span></th>
              <th>环境<span class="resize-handle"></span></th>
              <th>版本<span class="resize-handle"></span></th>
              <th>文件名<span class="resize-handle"></span></th>
              <th>大小<span class="resize-handle"></span></th>
              <th>摘要<span class="resize-handle"></span></th>
              <th>下载<span class="resize-handle"></span></th>
              <th>操作<span class="resize-handle"></span></th>
            </tr>
          </thead>
          <tbody id="fw-tbody">
            <tr class="empty-row"><td colspan="9">正在加载…</td></tr>
          </tbody>
        </table>
      </div>
    </div>

    <div class="panel">
      <h2>上传新固件</h2>
      <p>上传合并固件（用于产线烧录）或仅应用固件（用于 OTA 拉取）。</p>
      <form id="upload-form">
        <div style="display:flex;flex-direction:column;gap:8px;">
          <label>固件用途
            <select name="usage_type" id="form-usage">
              <option value="factory_merged">产线合并固件（烧录）</option>
              <option value="ota_app">应用固件（OTA）</option>
            </select>
          </label>
          <label>发布环境
            <select name="channel" id="form-channel">
              <option value="production">生产环境</option>
              <option value="debugging">调试 / 内测</option>
            </select>
          </label>
          <label>版本号
            <input type="text" name="version" placeholder="例如 1.2.3" required />
          </label>
          <label>备注说明
            <input type="text" name="description" placeholder="可选：适用硬件、变更摘要等" />
          </label>
          <label>固件文件
            <input type="file" name="file" accept=".bin,.hex,.img,.fw,*/*" required />
          </label>
          <button type="submit" class="btn-primary" id="btn-upload">上传固件</button>
          <div class="help" id="upload-help"></div>
        </div>
      </form>
      <p class="help">
        建议：<br />
        - 合并固件（烧录）：通常包含 bootloader + app + 配置；<br />
        - 应用固件（OTA）：仅应用区 bin，由客户端按版本号拉取。
      </p>
    </div>
  </div>

  <script>
    function fmtBytes(bytes) {
      if (bytes == null) return '-';
      var b = Number(bytes);
      if (!isFinite(b) || b <= 0) return '-';
      var units = ['B','KB','MB','GB'];
      var i = 0;
      while (b >= 1024 && i < units.length - 1) { b /= 1024; i++; }
      return b.toFixed(1) + ' ' + units[i];
    }

    function shorten(str, len) {
      if (!str) return '';
      if (str.length <= len) return str;
      return str.slice(0, len - 3) + '...';
    }

    function currentSelection() {
      var usage = document.getElementById('usage-select').value;
      var channel = document.getElementById('channel-select').value;
      return { usage: usage, channel: channel };
    }

    function usageLabel(u) {
      if (u === 'factory_merged') return '合并固件';
      if (u === 'ota_app') return '应用固件';
      return u || '';
    }

    function channelLabel(c) {
      if (c === 'production') return '生产';
      if (c === 'debugging') return '调试';
      return c || '';
    }

    function loadFirmware() {
      var sel = currentSelection();
      var tbody = document.getElementById('fw-tbody');
      tbody.innerHTML = '<tr class="empty-row"><td colspan="9">正在加载…</td></tr>';
      var url = '/api/admin/firmware?usage_type=' + encodeURIComponent(sel.usage) + '&channel=' + encodeURIComponent(sel.channel);
      fetch(url, { credentials: 'same-origin' })
        .then(function (res) {
          if (res.status === 401) {
            window.location.href = '/admin/login';
            return Promise.reject(new Error('未登录'));
          }
          if (!res.ok) throw new Error('加载失败: ' + res.status);
          return res.json();
        })
        .then(function (data) {
          var items = (data && data.items) || [];
          if (!items.length) {
            tbody.innerHTML = '<tr class="empty-row"><td colspan="9">暂无记录</td></tr>';
            return;
          }
          tbody.innerHTML = '';
          items.forEach(function (it) {
            var tr = document.createElement('tr');
            var badgeUsage = it.usageType === 'factory_merged'
              ? '<span class="badge badge-factory">' + usageLabel(it.usageType) + '</span>'
              : '<span class="badge badge-ota">' + usageLabel(it.usageType) + '</span>';
            var badgeChannel = it.channel === 'production'
              ? '<span class="badge badge-prod">' + channelLabel(it.channel) + '</span>'
              : '<span class="badge badge-debug">' + channelLabel(it.channel) + '</span>';
            var dl = it.downloadUrl
              ? '<a class="link" href="' + it.downloadUrl + '" target="_blank">下载</a>'
              : '<span class="muted">-</span>';
            tr.innerHTML =
              '<td>' + (it.createdAt || '') + '</td>' +
              '<td>' + badgeUsage + '</td>' +
              '<td>' + badgeChannel + '</td>' +
              '<td>' + (it.version || '') + '</td>' +
              '<td title="' + (it.originalFileName || it.fileName || '') + '">' + shorten(it.originalFileName || it.fileName || '', 40) + '</td>' +
              '<td>' + fmtBytes(it.fileSizeBytes) + '</td>' +
              '<td title="' + (it.checksum || '') + '">' + shorten(it.checksum || '', 18) + '</td>' +
              '<td>' + dl + '</td>' +
              '<td><button class="btn-danger" data-id="' + it.id + '">删除</button></td>';
            tbody.appendChild(tr);
          });
        })
        .catch(function (e) {
          tbody.innerHTML = '<tr class="empty-row"><td colspan="9">加载失败：' + (e && e.message ? e.message : '未知错误') + '</td></tr>';
        });
    }

    function bindUpload() {
      var form = document.getElementById('upload-form');
      var help = document.getElementById('upload-help');
      var btn = document.getElementById('btn-upload');
      var fileInput = form.querySelector('input[name="file"]');
      var verInput = form.querySelector('input[name="version"]');
      var usageSelect = document.getElementById('form-usage');

      if (fileInput && verInput) {
        fileInput.addEventListener('change', function () {
          if (!fileInput.files || !fileInput.files[0]) return;
          var name = fileInput.files[0].name || '';
          var m = name.match(/^CO2ControllerFW_combined_(\d+)_(\d+)_(\d+)\.bin$/);
          if (m) {
            verInput.value = m[1] + '.' + m[2] + '.' + m[3];
            if (usageSelect) usageSelect.value = 'factory_merged';
            return;
          }
          m = name.match(/^CO2ControllerFW_(\d+)_(\d+)_(\d+)\.bin$/);
          if (m) {
            verInput.value = m[1] + '.' + m[2] + '.' + m[3];
            if (usageSelect) usageSelect.value = 'ota_app';
          }
        });
      }

      form.addEventListener('submit', function (e) {
        e.preventDefault();
        help.textContent = '';
        btn.disabled = true;
        var fd = new FormData(form);
        var sel = currentSelection();
        fd.set('usage_type', document.getElementById('form-usage').value || sel.usage);
        fd.set('channel', document.getElementById('form-channel').value || sel.channel);
        fetch('/api/admin/firmware', { method: 'POST', body: fd })
          .then(function (res) {
            if (res.status === 401) {
              window.location.href = '/admin/login';
              return Promise.reject(new Error('未登录'));
            }
            if (!res.ok) throw new Error('上传失败: ' + res.status);
            return res.json();
          })
          .then(function () {
            help.textContent = '上传成功';
            form.reset();
            loadFirmware();
          })
          .catch(function (e) {
            help.textContent = e.message || '上传失败，请重试';
          })
          .finally(function () { btn.disabled = false; });
      });
    }

    function bindTableDelete() {
      var tbody = document.getElementById('fw-tbody');
      tbody.addEventListener('click', function (e) {
        var t = e.target;
        if (t.tagName === 'BUTTON' && t.dataset.id) {
          var id = t.dataset.id;
          if (!confirm('确定要删除该固件吗？仅影响服务器存储。')) return;
          t.disabled = true;
          fetch('/api/admin/firmware/' + encodeURIComponent(id), { method: 'DELETE' })
            .then(function (res) {
              if (res.status === 401) {
                window.location.href = '/admin/login';
                return Promise.reject(new Error('未登录'));
              }
              if (!res.ok) throw new Error('删除失败: ' + res.status);
              return res.json();
            })
            .then(function () { loadFirmware(); })
            .catch(function (e) { alert(e.message || '删除失败'); })
            .finally(function () { t.disabled = false; });
        }
      });
    }

    function bindControls() {
      document.getElementById('btn-refresh').addEventListener('click', loadFirmware);
      document.getElementById('usage-select').addEventListener('change', loadFirmware);
      document.getElementById('channel-select').addEventListener('change', loadFirmware);
      document.getElementById('btn-logout').addEventListener('click', function () {
        fetch('/api/admin/logout', { method: 'POST' }).finally(function () {
          window.location.href = '/admin/login';
        });
      });
    }

    var admResizeState = null;
    function initAdmResize(handle) {
      if (handle._admResizeInit) return;
      handle._admResizeInit = true;
      handle.addEventListener('mousedown', function (e) {
        e.preventDefault();
        e.stopPropagation();
        var th = handle.closest('th');
        var table = th.closest('table');
        var colIndex = Array.prototype.indexOf.call(th.parentElement.children, th);
        var cols = table.querySelectorAll('colgroup col');
        var col = cols[colIndex];
        if (!col) return;
        var startX = e.clientX, startW = th.offsetWidth;
        admResizeState = { col: col, startX: startX, startW: startW };
        document.body.style.cursor = 'col-resize';
        document.body.style.userSelect = 'none';
      });
    }
    document.addEventListener('mousemove', function (e) {
      if (!admResizeState) return;
      var dw = e.clientX - admResizeState.startX;
      var newW = Math.max(40, admResizeState.startW + dw);
      admResizeState.col.style.width = newW + 'px';
      admResizeState.col.style.minWidth = newW + 'px';
    });
    document.addEventListener('mouseup', function () {
      if (admResizeState) {
        document.body.style.cursor = '';
        document.body.style.userSelect = '';
        admResizeState = null;
      }
    });

    (function init() {
      bindControls();
      bindUpload();
      bindTableDelete();
      loadFirmware();
      document.querySelectorAll('#fw-table th .resize-handle').forEach(initAdmResize);
    })();
  </script>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# Home / BOG 入口页
# ---------------------------------------------------------------------------

HOME_HTML = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Home</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 40px; background: #f5f5f5; }
    h1 { color: #333; margin-bottom: 24px; }
    ul { list-style: none; padding: 0; }
    li { margin: 12px 0; }
    a { color: #2563eb; text-decoration: none; font-size: 18px; }
    a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <h1>Home</h1>
  <ul>
    <li><a href="/bog">BOG</a> — 产测与固件管理项目</li>
  </ul>
</body>
</html>
"""

# BOG 页模板：产测/调试链接由环境变量决定，指向不同端口则数据分离（产测=生产库，调试=开发库）
# CSS 内 { } 已写成 {{ }} 避免 .format() 当作占位符
BOG_HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>BOG</title>
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 40px; background: #f5f5f5; }}
    h1 {{ color: #333; margin-bottom: 24px; }}
    p {{ color: #666; margin-bottom: 20px; }}
    ul {{ list-style: none; padding: 0; }}
    li {{ margin: 16px 0; }}
    a {{ color: #2563eb; text-decoration: none; font-size: 18px; }}
    a:hover {{ text-decoration: underline; }}
    .back {{ font-size: 14px; color: #666; margin-bottom: 24px; }}
  </style>
</head>
<body>
  <p class="back"><a href="/home">← Home</a></p>
  <h1>BOG</h1>
  <p>产测与固件管理项目。请选择：</p>
  <ul>
    <li><a href="{production_dashboard_url}">产测 Dashboard</a> — 产线/正式环境数据概览</li>
    <li><a href="{development_dashboard_url}">调试 Dashboard</a> — 开发/内测环境数据概览</li>
    <li><a href="/admin/firmware">固件管理后台</a> — 固件上传与管理</li>
  </ul>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# Dashboard 静态页（内联 HTML + JS，无需静态文件）
# ---------------------------------------------------------------------------

DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>BOG Dashboard</title>
  <style>
    * { box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 20px; padding-bottom: 70px; background: #f5f5f5; }
    h1 { color: #333; }
    .cards { display: flex; flex-wrap: wrap; gap: 16px; margin-bottom: 24px; }
    .card { background: #fff; padding: 20px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); min-width: 140px; }
    .card .label { font-size: 12px; color: #666; }
    .card .value { font-size: 24px; font-weight: 600; }
    .card.pass .value { color: #0a0; }
    .card.fail .value { color: #c00; }
    .filters { margin-bottom: 16px; display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
    .filters input, .filters button, .filters select { padding: 8px 12px; border-radius: 6px; border: 1px solid #ccc; }
    .filters select { min-width: 140px; }
    .filters button { background: #07c; color: #fff; border: none; cursor: pointer; }
    .table-wrap { overflow-x: auto; }
    table { width: 100%; min-width: 960px; border-collapse: collapse; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); table-layout: auto; }
    th, td { padding: 8px 10px; text-align: left; border-bottom: 1px solid #eee; font-size: 13px; }
    th, td { overflow: hidden; text-overflow: ellipsis; }
    td.test-details-cell { overflow: visible; text-overflow: clip; }
    th { background: #fafafa; font-size: 12px; color: #666; }
    .col-time { min-width: 140px; }
    .burn-table td:nth-child(1), .burn-table td:nth-child(2), .burn-table td:nth-child(4), .burn-table td:nth-child(7), .burn-table td:nth-child(8),
    .burn-table th:nth-child(1), .burn-table th:nth-child(2), .burn-table th:nth-child(4), .burn-table th:nth-child(7), .burn-table th:nth-child(8) { white-space: nowrap; }
    .col-sn { min-width: 90px; }
    .col-sn-device { min-width: 120px; }
    .col-device { min-width: 120px; }
    .col-result { min-width: 56px; }
    .col-fw { min-width: 64px; }
    .col-bl { min-width: 44px; }
    .col-hw { min-width: 82px; }
    .col-duration { min-width: 64px; }
    .col-details { min-width: 80px; }
    .col-retest { min-width: 52px; }
    .ok { color: #0a0; }
    .ng { color: #c00; }
    .loading { color: #666; }
    a { color: #07c; }
    .test-details-cell { font-size: 12px; line-height: 1.5; white-space: normal; vertical-align: top; }
    .test-details-cell b { display: block; margin-top: 6px; color: #333; }
    .test-details-cell b:first-child { margin-top: 0; }
    tr.record-row { cursor: pointer; }
    tr.record-row:hover { background: #f8f8f8; }
    tr.detail-row td { background: #f0f4f8; padding: 12px 10px; border-bottom: 1px solid #ddd; font-size: 12px; line-height: 1.6; }
    tr.detail-row td .expand-hint { color: #666; margin-bottom: 8px; }
    tr.detail-row td .detail-fail { color: #c00; font-weight: 500; }
    .lang-switch { margin-left: auto; font-size: 13px; }
    .lang-switch a { margin: 0 4px; cursor: pointer; }
    .lang-switch a.active { font-weight: 600; text-decoration: none; }
    .fixed-footer { position: fixed; bottom: 0; left: 0; right: 0; background: #f5f5f5; border-top: 1px solid #e8e8e8; z-index: 100; padding: 8px 20px 0; }
    .viewer-footer { padding: 0 0 4px; font-size: 12px; color: #666; display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
    .viewer-footer span { cursor: default; }
    .viewer-footer a { font-size: 12px; }
    .viewer-click-area { height: 12px; cursor: pointer; background: rgba(0,0,0,0.04); margin: 0 -20px; font-size: 10px; color: #999; display: flex; align-items: center; justify-content: center; }
    .viewer-click-area:hover { background: rgba(0,0,0,0.08); color: #666; }
    .visitor-modal-overlay { display: none; position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.4); z-index: 9999; align-items: center; justify-content: center; }
    .visitor-modal-overlay.show { display: flex; }
    .visitor-modal { background: #fff; border-radius: 8px; box-shadow: 0 4px 20px rgba(0,0,0,0.2); max-width: 480px; width: 90%; max-height: 70vh; display: flex; flex-direction: column; }
    .visitor-modal-header { padding: 16px; border-bottom: 1px solid #eee; font-weight: 600; display: flex; justify-content: space-between; align-items: center; }
    .visitor-modal-close { cursor: pointer; font-size: 20px; color: #666; }
    .visitor-modal-body { padding: 12px; overflow-y: auto; flex: 1; }
    .visitor-item { padding: 8px 12px; border-bottom: 1px solid #f0f0f0; font-size: 13px; font-family: monospace; }
    .visitor-item:last-child { border-bottom: none; }
    .visitor-item .ip { font-weight: 500; color: #333; }
    .visitor-item .time { color: #666; font-size: 12px; margin-left: 8px; }
    .tab-bar { display: flex; gap: 0; margin-bottom: 16px; border-bottom: 1px solid #ddd; }
    .tab-bar a { padding: 10px 16px; text-decoration: none; color: #666; border-bottom: 2px solid transparent; margin-bottom: -1px; }
    .tab-bar a:hover { color: #333; }
    .tab-bar a.active { color: #07c; font-weight: 600; border-bottom-color: #07c; }
    .sub-tab-bar a { padding: 8px 14px; text-decoration: none; color: #666; border-bottom: 2px solid transparent; margin-bottom: -1px; }
    .sub-tab-bar a:hover { color: #333; }
    .sub-tab-bar a.active { color: #07c; font-weight: 600; border-bottom-color: #07c; }
    .tab-panel { display: none; }
    .tab-panel.active { display: block; }
    .burn-table col.col-flow, .burn-table th.col-flow { min-width: 65px; }
    .burn-table th.col-mac, .burn-table col.col-mac { min-width: 120px; }
    .burn-table th.col-computer, .burn-table col.col-computer { min-width: 100px; }
    .burn-table col.col-bin, .burn-table th.col-bin { min-width: 160px; }
    .burn-table th.col-test, .burn-table col.col-test { min-width: 80px; }
    .col-fw-version { min-width: 80px; }
    .col-fw-size { min-width: 75px; }
    .col-fw-result { min-width: 90px; }
    .col-fail-reason { min-width: 100px; }
    th.sortable { cursor: pointer; user-select: none; position: relative; padding-right: 20px; }
    th.sortable:hover { background: #eee; }
    th.sortable .sort-icon { opacity: 0.4; font-size: 10px; margin-left: 4px; }
    th.sortable.asc .sort-icon::after { content: '▲'; }
    th.sortable.desc .sort-icon::after { content: '▼'; }
    .burn-table th { position: relative; }
    th .resize-handle { position: absolute; right: 0; top: 0; bottom: 0; width: 6px; cursor: col-resize; }
    th .resize-handle:hover { background: rgba(0,120,200,0.2); }
  </style>
</head>
<body>
  <div style="display:flex; align-items: center; flex-wrap: wrap; gap: 12px; margin-bottom: 8px;">
    <h1 style="margin: 0;" id="page-title">Production Test Overview</h1>
    <span class="lang-switch" id="lang-switch"><a id="lang-en" href="javascript:void(0)">EN</a> | <a id="lang-zh" href="javascript:void(0)">中文</a></span>
    <span id="clear-data-wrap" style="display:none;"><button type="button" id="btn-clear-data" onclick="clearTestData()" style="background:#c00;color:#fff;border:none;padding:8px 12px;border-radius:6px;cursor:pointer;font-size:13px;"><span id="label-clear-data">Clear Test Data</span></button></span>
  </div>
  <div class="tab-bar">
    <a href="javascript:void(0)" id="tab-production" class="active">产测记录</a>
    <a href="javascript:void(0)" id="tab-burn">烧录+PCBA测试</a>
    <a href="javascript:void(0)" id="tab-firmware">设备固件历史</a>
  </div>
  <div id="panel-production" class="tab-panel active">
  <div class="cards" id="summary-cards">
    <span class="loading" id="loading-label">Loading…</span>
  </div>
  <div class="filters">
    <label>SN <input type="text" id="filter-sn" list="sn-datalist" placeholder="" autocomplete="off" /></label>
    <select id="filter-sn-select" title="">
      <option value="">All</option>
    </select>
    <datalist id="sn-datalist"></datalist>
    <label><span id="label-from-text">From</span> <input type="date" id="filter-from" /></label>
    <label><span id="label-to-text">To</span> <input type="date" id="filter-to" /></label>
    <button onclick="loadRecords()" id="btn-query">Query</button>
    <button onclick="resetFilterProduction()" id="btn-reset" type="button"><span id="label-reset">Reset</span></button>
    <label><input type="checkbox" id="filter-dedup" /> <span id="label-dedup">Dedup by device</span></label>
    <a href="/api/export" id="export-link" target="_blank"><span id="label-export">Export CSV</span></a>
  </div>
  <div class="table-wrap">
  <table>
    <colgroup>
      <col class="col-time" /><col class="col-sn" /><col class="col-device" /><col class="col-result" /><col class="col-fw" /><col class="col-bl" /><col class="col-hw" /><col class="col-duration" /><col class="col-details" /><col class="col-retest" />
    </colgroup>
    <thead>
      <tr id="table-head-row">
        <th>Time</th><th>SN</th><th>Device</th><th>Result</th><th>FW</th><th>BL</th><th>HW</th><th>Duration</th><th>Details</th><th>Retest</th>
      </tr>
    </thead>
    <tbody id="records-body">
      <tr><td colspan="10" class="loading">Loading…</td></tr>
    </tbody>
  </table>
  </div>
  </div>
  <div id="panel-burn" class="tab-panel">
  <div class="cards" id="burn-summary-cards" style="margin-bottom:16px">
    <span class="loading" id="burn-loading-label">Loading…</span>
  </div>
  <div class="filters">
    <span id="burn-flow-filter-wrap"><label><span id="burn-label-flow">流程类型</span> <select id="burn-filter-flow"><option value="">全部</option><option value="P">P (仅烧录)</option><option value="T">T (仅自检)</option><option value="P+T">P+T (烧录+自检)</option></select></label></span>
    <label>MAC <input type="text" id="burn-filter-mac" placeholder="MAC优先" autocomplete="off" /></label>
    <label>SN <input type="text" id="burn-filter-sn" placeholder="" autocomplete="off" /></label>
    <label><span id="burn-label-from">From</span> <input type="date" id="burn-filter-from" /></label>
    <label><span id="burn-label-to">To</span> <input type="date" id="burn-filter-to" /></label>
    <label><span id="burn-label-test">测试结果</span> <select id="burn-filter-test"><option value="">全部</option><option value="passed">通过</option><option value="failed">失败</option><option value="self_check_failed">自检失败</option><option value="key_abnormal">按键异常</option></select></label>
    <label id="burn-bin-filter-wrap"><span id="burn-label-bin">bin文件</span> <select id="burn-filter-bin"><option value="">全部</option></select></label>
    <button onclick="loadBurnRecords()" id="burn-btn-query">Query</button>
    <button onclick="resetFilterBurn()" id="burn-btn-reset" type="button"><span id="burn-label-reset">Reset</span></button>
  </div>
  <div id="burn-table-wrap" class="table-wrap">
  <table class="burn-table">
    <colgroup>
      <col class="col-time" /><col class="col-flow" /><col class="col-sn-device" /><col class="col-mac" /><col class="col-time" /><col class="col-duration" /><col class="col-duration" /><col class="col-computer" /><col class="col-time" /><col class="col-sn-device" /><col class="col-bin" /><col class="col-test" /><col class="col-fail-reason" />
    </colgroup>
    <thead>
      <tr id="burn-thead-row">
        <th class="sortable" data-sort="createdAt">上报时间<span class="sort-icon"></span><span class="resize-handle"></span></th>
        <th class="sortable" data-sort="flowType">流程类型<span class="sort-icon"></span><span class="resize-handle"></span></th>
        <th class="sortable" data-sort="deviceSerialNumber">设备号<span class="sort-icon"></span><span class="resize-handle"></span></th>
        <th class="sortable" data-sort="macAddress">MAC<span class="sort-icon"></span><span class="resize-handle"></span></th>
        <th class="sortable" data-sort="burnStartTime">烧录开始<span class="sort-icon"></span><span class="resize-handle"></span></th>
        <th class="sortable" data-sort="burnDurationSeconds">耗时<span class="sort-icon"></span><span class="resize-handle"></span></th>
        <th class="sortable" data-sort="buttonWaitSeconds">按键等待<span class="sort-icon"></span><span class="resize-handle"></span></th>
        <th class="sortable" data-sort="computerIdentity">电脑身份<span class="sort-icon"></span><span class="resize-handle"></span></th>
        <th class="sortable" data-sort="deviceWrittenTimestamp">设备写入时间<span class="sort-icon"></span><span class="resize-handle"></span></th>
        <th class="sortable" data-sort="deviceWrittenSerialNumber">写入序列号<span class="sort-icon"></span><span class="resize-handle"></span></th>
        <th class="sortable" data-sort="binFileName">bin文件<span class="sort-icon"></span><span class="resize-handle"></span></th>
        <th class="sortable" data-sort="burnTestResult">测试结果<span class="sort-icon"></span><span class="resize-handle"></span></th>
        <th class="sortable" data-sort="failureReason">失败原因<span class="sort-icon"></span><span class="resize-handle"></span></th>
      </tr>
    </thead>
    <tbody id="burn-records-body">
      <tr><td colspan="13" class="loading">Loading…</td></tr>
    </tbody>
  </table>
  </div>
  </div>
  <div id="panel-firmware" class="tab-panel">
  <div class="cards" id="fw-summary-cards" style="margin-bottom:16px">
    <span class="loading" id="fw-loading-label">Loading…</span>
  </div>
  <div class="filters">
    <label>SN <input type="text" id="fw-filter-sn" placeholder="" autocomplete="off" /></label>
    <label>MAC <input type="text" id="fw-filter-mac" placeholder="" autocomplete="off" /></label>
    <label><span id="fw-label-from">From</span> <input type="date" id="fw-filter-from" /></label>
    <label><span id="fw-label-to">To</span> <input type="date" id="fw-filter-to" /></label>
    <label><span id="fw-label-type">类型</span> <select id="fw-filter-type"><option value="">全部</option><option value="burn">烧录</option><option value="upgrade">升级</option></select></label>
    <button onclick="loadFirmwareHistory()" id="fw-btn-query">Query</button>
    <button onclick="resetFilterFirmware()" id="fw-btn-reset" type="button"><span id="fw-label-reset">Reset</span></button>
  </div>
  <div class="table-wrap">
  <table class="burn-table">
    <colgroup>
      <col class="col-time" /><col class="col-sn-device" /><col class="col-mac" /><col class="col-fw-version" /><col class="col-fw-version" /><col class="col-fw-result" /><col class="col-fw-version" /><col class="col-fail-reason" /><col class="col-fw-size" /><col class="col-duration" /><col class="col-computer" />
    </colgroup>
    <thead>
      <tr id="fw-thead-row">
        <th>时间<span class="resize-handle"></span></th><th>SN<span class="resize-handle"></span></th><th>MAC<span class="resize-handle"></span></th><th>From<span class="resize-handle"></span></th><th>To<span class="resize-handle"></span></th><th>类型/结果<span class="resize-handle"></span></th><th>最终版本<span class="resize-handle"></span></th><th>失败原因<span class="resize-handle"></span></th><th>文件大小<span class="resize-handle"></span></th><th>耗时<span class="resize-handle"></span></th><th>电脑<span class="resize-handle"></span></th>
      </tr>
    </thead>
    <tbody id="fw-records-body">
      <tr><td colspan="11" class="loading">Loading…</td></tr>
    </tbody>
  </table>
  </div>
  </div>
  <div class="fixed-footer">
    <div class="viewer-footer" id="viewer-footer">
      <label style="display:inline-flex;align-items:center;gap:6px;cursor:pointer;user-select:none;margin:0;"><input type="checkbox" id="auto-refresh-cb" checked /> <span id="label-auto-refresh">Auto refresh</span></label>
      <span id="viewer-count-text" title=""> </span>
      <span id="deploy-time-text"></span>
      <a id="open-page-link" href="/" target="_blank"></a>
    </div>
    <div class="viewer-click-area" id="viewer-click-area" title="">⋯</div>
  </div>

  <div class="visitor-modal-overlay" id="visitor-modal-overlay">
    <div class="visitor-modal" onclick="event.stopPropagation()">
      <div class="visitor-modal-header">
        <span id="visitor-modal-title"></span>
        <span class="visitor-modal-close" id="visitor-modal-close">&times;</span>
      </div>
      <div class="visitor-modal-body" id="visitor-modal-body"></div>
    </div>
  </div>

  <script>
    const T = {
      en: {
        title: 'Production Test Overview',
        loading: 'Loading…',
        snPlaceholder: 'optional',
        snAll: 'All',
        from: 'From',
        to: 'To',
        query: 'Query',
        reset: 'Reset',
        dedup: 'Dedup by device',
        exportCsv: 'Export CSV',
        time: 'Time',
        sn: 'SN',
        device: 'Device',
        result: 'Result',
        fw: 'FW',
        bl: 'BL',
        hw: 'HW',
        steps: 'Steps',
        duration: 'Duration',
        details: 'Details',
        retest: 'Retest',
        totalRecords: 'Records',
        total: 'Devices',
        passed: 'Passed',
        failed: 'Failed',
        passRate: 'Pass rate',
        today: 'Today',
        todayPassRate: 'Today pass rate',
        noRecords: 'No records',
        pass: 'Pass',
        fail: 'Fail',
        yes: 'Yes',
        expand: 'Expand',
        collapse: 'Collapse',
        detailHint: 'Test details (this record)',
        none: 'None',
        summaryError: 'Summary load failed',
        loadFailed: 'Load failed. Open this page from the server (e.g. http://127.0.0.1:8000/)',
        loadTimeout: 'Request timed out. Try again or check the server.',
        startTimeLabel: 'Start time',
        endTimeLabel: 'End time',
        durationLabel: 'Duration',
        version: 'Version',
        pressureTest: 'Pressure test',
        rtc: 'RTC',
        other: 'Other',
        openPressure: 'Open pressure',
        closedPressure: 'Closed pressure',
        systemTimeAtRead: 'System time at read',
        deviceTimeAtRead: 'Device time at read',
        timeDiff: 'Time diff',
        gasStatus: 'Gas status',
        valveState: 'Valve state',
        stepResultsTitle: 'Step results',
        viewersCount: '{{n}} viewer(s) viewing',
        viewersIpsHint: 'Visitors (first 10): ',
        openPageLink: 'Open this page',
        lastDeploy: 'Last deploy',
        clickToViewVisitors: 'Click to view visitor list (IP + time)',
        visitorsTitle: 'Page visitors',
        visitorsEmpty: 'No visitors',
        tabProduction: 'Production Test',
        tabBurn: 'Burn + PCBA Testing',
        tabFirmware: 'Firmware History',
        subTabBurnRecords: 'Burn Records',
        subTabPcbaRecords: 'PCBA Records',
        burnReportTime: 'Report Time',
        burnFlowType: 'Flow Type',
        burnDevice: 'Device SN',
        burnMac: 'MAC',
        burnStart: 'Burn Start',
        burnDuration: 'Duration',
        burnButtonWait: 'Button Wait',
        burnComputer: 'Computer',
        burnWrittenTime: 'Written RTC Timestamp',
        burnWrittenSn: 'Written SN',
        burnBinFile: 'Bin File',
        burnTestResult: 'Test Result',
        burnTestPassed: 'Passed',
        burnTestFailed: 'Failed',
        burnTestSelfCheckFailed: 'Self Check Failed',
        burnTestKeyAbnormal: 'Key Abnormal',
        burnFailureReason: 'Failure Reason',
        failureReasonRtc: 'RTC Error',
        failureReasonPressure: 'Pressure Sensor Error',
        failureReasonButtonTimeout: 'Button Timeout',
        failureReasonButtonExit: 'Button User Exit',
        failureReasonFcc: 'Factory Config Incomplete',
        failureReasonOther: 'Other',
        clearTestData: 'Clear Test Data',
        clearTestDataConfirm: 'Delete all production test and burn records? This cannot be undone.',
        dataCleared: 'Data cleared',
        fwTypeBurn: 'Burn',
        fwTypeUpgrade: 'Upgrade',
        fwUpgradeSuccess: 'Success',
        fwUpgradeFailed: 'Failed',
        autoRefresh: 'Auto refresh'
      },
      zh: {
        title: '产测数据概览',
        loading: '加载中…',
        snPlaceholder: '可选',
        snAll: '全部',
        from: '从',
        to: '到',
        query: '查询',
        reset: '复位',
        dedup: '按设备号去重',
        exportCsv: '导出 CSV',
        time: '时间',
        sn: 'SN',
        device: '设备名',
        result: '结果',
        fw: 'FW',
        bl: 'BL',
        hw: 'HW',
        steps: '步骤',
        duration: '耗时',
        details: '测试详情',
        retest: '需重测',
        totalRecords: '总测试记录数',
        total: '设备数',
        passed: '通过',
        failed: '失败',
        passRate: '通过率',
        today: '今日',
        todayPassRate: '今日通过率',
        noRecords: '暂无记录',
        pass: '通过',
        fail: '失败',
        yes: '是',
        expand: '点击展开',
        collapse: '点击收起',
        detailHint: '测试详情（本条）',
        none: '无',
        summaryError: '汇总加载失败',
        loadFailed: '加载失败，请通过服务器地址打开本页（如 http://127.0.0.1:8000/）',
        loadTimeout: '请求超时，请重试或检查服务器。',
        startTimeLabel: '开始时间',
        endTimeLabel: '结束时间',
        durationLabel: '耗时',
        version: '版本号',
        pressureTest: '压力测试',
        rtc: 'RTC',
        other: '其它',
        openPressure: '开阀压力',
        closedPressure: '关阀压力',
        systemTimeAtRead: '读取时系统时间',
        deviceTimeAtRead: '读取的设备时间',
        timeDiff: '时间差',
        gasStatus: 'Gas 状态',
        valveState: '阀门状态',
        stepResultsTitle: '步骤结果',
        viewersCount: '当前 {{n}} 个终端在预览',
        viewersIpsHint: '访问者 IP（前 10 个）：',
        openPageLink: '打开网页',
        lastDeploy: '最近部署',
        clickToViewVisitors: '点击查看访问者列表（IP + 时间）',
        visitorsTitle: '页面访问者',
        visitorsEmpty: '暂无访问者',
        tabProduction: '产测记录',
        tabBurn: '烧录+PCBA测试',
        tabFirmware: '设备固件历史',
        subTabBurnRecords: '烧录记录',
        subTabPcbaRecords: 'PCBA记录',
        burnReportTime: '上报时间',
        burnFlowType: '流程类型',
        burnDevice: '设备号',
        burnMac: 'MAC',
        burnStart: '烧录开始',
        burnDuration: '耗时',
        burnButtonWait: '按键等待',
        burnComputer: '电脑身份',
        burnWrittenTime: '被写入的RTC时间戳',
        burnWrittenSn: '写入序列号',
        burnBinFile: 'bin文件',
        burnTestResult: '测试结果',
        burnTestPassed: '通过',
        burnTestFailed: '失败',
        clearTestData: '清空测试数据',
        clearTestDataConfirm: '确定删除所有产测和烧录记录？此操作不可恢复。',
        dataCleared: '已清空',
        burnTestSelfCheckFailed: '自检失败',
        burnTestKeyAbnormal: '按键异常',
        burnFailureReason: '失败原因',
        failureReasonRtc: 'RTC错误',
        failureReasonPressure: '压力传感器错误',
        failureReasonButtonTimeout: '按键超时',
        failureReasonButtonExit: '按键用户退出',
        failureReasonFcc: '工厂配置未完成',
        failureReasonOther: '其他',
        fwTypeBurn: '烧录',
        fwTypeUpgrade: '升级',
        fwUpgradeSuccess: '成功',
        fwUpgradeFailed: '失败',
        autoRefresh: '自动刷新'
      }
    };
    let lang = localStorage.getItem('bog-lang') || 'en';
    function t(k) { return (T[lang] && T[lang][k]) || T.en[k] || k; }
    function setLang(l) {
      lang = l;
      localStorage.setItem('bog-lang', lang);
      document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
      document.title = t('title');
      document.getElementById('page-title').textContent = t('title');
      var loadingEl = document.getElementById('loading-label');
      if (loadingEl) loadingEl.textContent = t('loading');
      document.getElementById('filter-sn').placeholder = t('snPlaceholder');
      var selAll = document.querySelector('#filter-sn-select option[value=""]');
      if (selAll) selAll.textContent = t('snAll');
      document.getElementById('label-from-text').textContent = t('from');
      document.getElementById('label-to-text').textContent = t('to');
      document.getElementById('btn-query').textContent = t('query');
      var resetBtn = document.getElementById('label-reset');
      if (resetBtn) resetBtn.textContent = t('reset');
      document.getElementById('label-dedup').textContent = t('dedup');
      document.getElementById('label-export').textContent = t('exportCsv');
      var openLink = document.getElementById('open-page-link');
      if (openLink) openLink.textContent = t('openPageLink');
      document.getElementById('lang-en').classList.toggle('active', lang === 'en');
      document.getElementById('lang-zh').classList.toggle('active', lang === 'zh');
      var th = document.getElementById('table-head-row');
      if (th) th.innerHTML = '<th>' + [t('time'),t('sn'),t('device'),t('result'),t('fw'),t('bl'),t('hw'),t('duration'),t('details'),t('retest')].join('</th><th>') + '</th>';
      if (recordsData) {
        renderSummary(lastSummary != null ? lastSummary : defaultSummary);
        renderRecords(recordsData, expandedId);
      } else {
        renderSummary(defaultSummary);
        var body = document.getElementById('records-body');
        if (body) body.innerHTML = '<tr><td colspan="11" class="loading">' + t('loading') + '</td></tr>';
      }
      if (typeof updateDeployTime === 'function') updateDeployTime();
      var clickArea = document.getElementById('viewer-click-area');
      if (clickArea) clickArea.title = t('clickToViewVisitors');
      document.getElementById('tab-production').textContent = t('tabProduction');
      document.getElementById('tab-burn').textContent = t('tabBurn');
      document.getElementById('tab-firmware').textContent = t('tabFirmware');
      document.getElementById('burn-label-from').textContent = t('from');
      document.getElementById('burn-label-to').textContent = t('to');
      var burnLabelFlow = document.getElementById('burn-label-flow');
      if (burnLabelFlow) burnLabelFlow.textContent = t('burnFlowType');
      var burnLabelTest = document.getElementById('burn-label-test');
      if (burnLabelTest) burnLabelTest.textContent = t('burnTestResult');
      var burnLabelBin = document.getElementById('burn-label-bin');
      if (burnLabelBin) burnLabelBin.textContent = t('burnBinFile');
      var burnBinSel = document.getElementById('burn-filter-bin');
      if (burnBinSel && burnBinSel.options.length > 0) burnBinSel.options[0].textContent = t('snAll');
      document.getElementById('burn-btn-query').textContent = t('query');
      var burnResetBtn = document.getElementById('burn-label-reset');
      if (burnResetBtn) burnResetBtn.textContent = t('reset');
      var burnSel = document.getElementById('burn-filter-test');
      if (burnSel) {
        var v = burnSel.value;
        burnSel.innerHTML = '<option value="">' + t('snAll') + '</option><option value="passed">' + t('burnTestPassed') + '</option><option value="failed">' + (t('burnTestFailed') || '失败') + '</option><option value="self_check_failed">' + t('burnTestSelfCheckFailed') + '</option><option value="key_abnormal">' + t('burnTestKeyAbnormal') + '</option>';
        burnSel.value = v;
      }
      var burnTh = document.querySelector('#burn-thead-row');
      if (burnTh) {
        var burnLabels = [t('burnReportTime'),t('burnFlowType'),t('burnDevice'),t('burnMac'),t('burnStart'),t('burnDuration'),t('burnButtonWait'),t('burnComputer'),t('burnWrittenTime'),t('burnWrittenSn'),t('burnBinFile'),t('burnTestResult'),t('burnFailureReason')];
        var burnSortKeys = ['createdAt','flowType','deviceSerialNumber','macAddress','burnStartTime','burnDurationSeconds','buttonWaitSeconds','computerIdentity','deviceWrittenTimestamp','deviceWrittenSerialNumber','binFileName','burnTestResult','failureReason'];
        burnTh.innerHTML = burnLabels.map(function(lbl,i){ return '<th class="sortable" data-sort="'+burnSortKeys[i]+'">'+lbl+'<span class="sort-icon"></span><span class="resize-handle"></span></th>'; }).join('');
        burnTh.querySelector('[data-sort="'+burnSortCol+'"]') && burnTh.querySelector('[data-sort="'+burnSortCol+'"]').classList.add(burnSortAsc ? 'asc' : 'desc');
      }
      var fwLabelFrom = document.getElementById('fw-label-from');
      if (fwLabelFrom) fwLabelFrom.textContent = t('from');
      var fwLabelTo = document.getElementById('fw-label-to');
      if (fwLabelTo) fwLabelTo.textContent = t('to');
      var fwLabelType = document.getElementById('fw-label-type');
      if (fwLabelType) fwLabelType.textContent = lang === 'zh' ? '类型' : 'Type';
      var fwTypeSel = document.getElementById('fw-filter-type');
      if (fwTypeSel) {
        var fwTypeVal = fwTypeSel.value;
        fwTypeSel.innerHTML = '<option value="">' + t('snAll') + '</option><option value="burn">' + t('fwTypeBurn') + '</option><option value="upgrade">' + t('fwTypeUpgrade') + '</option>';
        fwTypeSel.value = fwTypeVal;
      }
      var fwBtnQuery = document.getElementById('fw-btn-query');
      if (fwBtnQuery) fwBtnQuery.textContent = t('query');
      var fwLabelReset = document.getElementById('fw-label-reset');
      if (fwLabelReset) fwLabelReset.textContent = t('reset');
      var fwTh = document.querySelector('#fw-thead-row');
      if (fwTh) fwTh.innerHTML = '<th>'+t('time')+'<span class="resize-handle"></span></th><th>'+t('sn')+'<span class="resize-handle"></span></th><th>'+t('burnMac')+'<span class="resize-handle"></span></th><th>From<span class="resize-handle"></span></th><th>To<span class="resize-handle"></span></th><th>'+(lang==='zh'?'类型/结果':'Type/Result')+'<span class="resize-handle"></span></th><th>'+(lang==='zh'?'最终版本':'Final')+'<span class="resize-handle"></span></th><th>'+(lang==='zh'?'失败原因':'Fail Reason')+'<span class="resize-handle"></span></th><th>'+(lang==='zh'?'文件大小':'File Size')+'<span class="resize-handle"></span></th><th>'+t('burnDuration')+'<span class="resize-handle"></span></th><th>'+t('burnComputer')+'<span class="resize-handle"></span></th>';
      var autoRefreshLabel = document.getElementById('label-auto-refresh');
      if (autoRefreshLabel) autoRefreshLabel.textContent = t('autoRefresh');
      if (typeof initTableResize === 'function') initTableResize();
    }
    let lastSummary = null;
    async function loadSnList() {
      try {
        const list = await fetch('/api/sn-list').then(r => r.json());
        const dl = document.getElementById('sn-datalist');
        const sel = document.getElementById('filter-sn-select');
        if (dl) {
          dl.innerHTML = '';
          (list || []).forEach(sn => {
            if (sn && String(sn).trim()) {
              const opt = document.createElement('option');
              opt.value = String(sn).trim();
              dl.appendChild(opt);
            }
          });
        }
        if (sel) {
          sel.innerHTML = '<option value="">' + (t('snAll') || 'All') + '</option>';
          (list || []).forEach(sn => {
            if (sn && String(sn).trim()) {
              const opt = document.createElement('option');
              opt.value = String(sn).trim();
              opt.textContent = String(sn).trim();
              sel.appendChild(opt);
            }
          });
        }
      } catch (e) {}
    }
    var FETCH_TIMEOUT_MS = 15000;
    function fetchWithTimeout(url, opts, timeoutMs) {
      timeoutMs = timeoutMs || FETCH_TIMEOUT_MS;
      var c = new AbortController();
      var t = setTimeout(function() { c.abort(); }, timeoutMs);
      var opts2 = opts ? Object.assign({}, opts) : {};
      opts2.signal = c.signal;
      return fetch(url, opts2).finally(function() { clearTimeout(t); });
    }
    async function getSummary(sn, dateFrom, dateTo) {
      let url = '/api/summary';
      const params = [];
      if (sn) params.push('sn=' + encodeURIComponent(sn));
      if (dateFrom) params.push('date_from=' + encodeURIComponent(dateFrom));
      if (dateTo) params.push('date_to=' + encodeURIComponent(dateTo));
      if (params.length) url += '?' + params.join('&');
      const r = await fetchWithTimeout(url);
      if (!r.ok) { var t = await r.text(); throw new Error(r.status + ' ' + (t || r.statusText)); }
      return r.json();
    }
    async function getRecords() {
      const sn = document.getElementById('filter-sn').value.trim();
      const from = document.getElementById('filter-from').value || undefined;
      const to = document.getElementById('filter-to').value || undefined;
      let url = '/api/records?limit=50';
      if (sn) url += '&sn=' + encodeURIComponent(sn);
      if (from) url += '&date_from=' + encodeURIComponent(from);
      if (to) url += '&date_to=' + encodeURIComponent(to);
      const r = await fetchWithTimeout(url);
      if (!r.ok) { var t = await r.text(); throw new Error(r.status + ' ' + (t || r.statusText)); }
      return r.json();
    }
    var defaultSummary = { totalRecords: 0, total: 0, passed: 0, failed: 0, passRatePercent: 0, today: { total: 0, passed: 0, failed: 0, passRatePercent: 0 } };
    function renderSummary(s) {
      if (!s || typeof s !== 'object') s = defaultSummary;
      var today = (s.today && typeof s.today === 'object') ? s.today : defaultSummary.today;
      var totalRecords = (s.totalRecords != null ? s.totalRecords : 0);
      lastSummary = s;
      const el = document.getElementById('summary-cards');
      if (!el) return;
      el.innerHTML = '<div class="card"><div class="label">' + t('totalRecords') + '</div><div class="value">' + totalRecords + '</div></div>'
        + '<div class="card"><div class="label">' + t('total') + '</div><div class="value">' + (s.total != null ? s.total : 0) + '</div></div>'
        + '<div class="card pass"><div class="label">' + t('passed') + '</div><div class="value">' + (s.passed != null ? s.passed : 0) + '</div></div>'
        + '<div class="card fail"><div class="label">' + t('failed') + '</div><div class="value">' + (s.failed != null ? s.failed : 0) + '</div></div>'
        + '<div class="card"><div class="label">' + t('passRate') + '</div><div class="value">' + (s.passRatePercent != null ? s.passRatePercent : 0) + '%</div></div>'
        + '<div class="card"><div class="label">' + t('today') + '</div><div class="value">' + (today.total != null ? today.total : 0) + '</div></div>'
        + '<div class="card"><div class="label">' + t('todayPassRate') + '</div><div class="value">' + (today.passRatePercent != null ? today.passRatePercent : 0) + '%</div></div>';
    }
    function formatDateLocal(isoStr) {
      if (!isoStr) return '-';
      var s = String(isoStr).trim();
      if (/^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}$/.test(s)) return s;
      var d = new Date(s);
      if (isNaN(d.getTime())) return s;
      var y = d.getFullYear();
      var m = String(d.getMonth() + 1).padStart(2, '0');
      var day = String(d.getDate()).padStart(2, '0');
      var h = String(d.getHours()).padStart(2, '0');
      var min = String(d.getMinutes()).padStart(2, '0');
      var sec = String(d.getSeconds()).padStart(2, '0');
      return y + '-' + m + '-' + day + ' ' + h + ':' + min + ':' + sec;
    }
    function stepSummaryText(steps) {
      if (!steps || !steps.length) return '-';
      let p = 0, f = 0, s = 0;
      steps.forEach(x => {
        if (x.status === 'passed') p++;
        else if (x.status === 'failed') f++;
        else if (x.status === 'skipped') s++;
      });
      const parts = [];
      if (p) parts.push(p + '✓');
      if (f) parts.push(f + '✗');
      if (s) parts.push(s + '−');
      return parts.length ? parts.join(' ') : '-';
    }
    function durationText(item) {
      if (item.durationSeconds != null && item.durationSeconds >= 0) {
        const s = Math.round(item.durationSeconds);
        if (s < 60) return s + 's';
        return Math.floor(s/60) + 'm' + (s%60) + 's';
      }
      return '-';
    }
    function esc(s) {
      if (s == null || s === '') return '';
      return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }
    function formatTestDetailsFull(item) {
      const d = item.testDetails || {};
      const steps = item.stepsSummary || [];
      const stepRes = item.stepResults || {};
      const hasSteps = steps.length > 0;
      const hasTime = item.startTime || item.endTime || (item.durationSeconds != null && item.durationSeconds >= 0);
      const hasVer = item.deviceHardwareRevision || item.deviceFirmwareVersion || item.deviceBootloaderVersion;
      const hasPressure = d.pressureClosedMbar != null || d.pressureOpenMbar != null;
      const hasRtc = d.rtcSystemTime != null || d.rtcDeviceTime != null || d.rtcTimeDiffSeconds != null;
      const hasOther = d.gasSystemStatus != null || d.valveState != null;
      if (!hasSteps && !hasTime && !hasVer && !hasPressure && !hasRtc && !hasOther) return '-';
      const lines = [];
      if (hasSteps) {
        lines.push('<b>' + t('stepResultsTitle') + '</b>');
        steps.forEach(function(s) {
          var icon = s.status === 'passed' ? ' ✓' : (s.status === 'failed' ? ' ✗' : ' −');
          var detail = (s.status === 'failed' && stepRes[s.stepId]) ? ' ' + esc(stepRes[s.stepId].replace(/\\n/g, ' ')) : '';
          var text = esc(s.stepId) + icon + detail;
          if (s.status === 'failed') text = '<span class="detail-fail">' + text + '</span>';
          lines.push(text);
        });
      }
      if (hasTime) {
        lines.push('<b>' + t('time') + '</b>');
        lines.push(t('startTimeLabel') + '：' + formatDateLocal(item.startTime));
        lines.push(t('endTimeLabel') + '：' + formatDateLocal(item.endTime));
        lines.push(t('durationLabel') + '：' + durationText(item));
      }
      if (hasVer) {
        lines.push('<b>' + t('version') + '</b>');
        lines.push('HW：' + (item.deviceHardwareRevision ? esc(item.deviceHardwareRevision) : '-'));
        lines.push('FW：' + (item.deviceFirmwareVersion ? esc(item.deviceFirmwareVersion) : '-'));
        lines.push('Bootloader：' + (item.deviceBootloaderVersion ? esc(item.deviceBootloaderVersion) : '-'));
      }
      if (hasPressure) {
        lines.push('<b>' + t('pressureTest') + '</b>');
        lines.push(t('openPressure') + '：' + (d.pressureOpenMbar != null ? esc(d.pressureOpenMbar) + ' mbar' : '-'));
        lines.push(t('closedPressure') + '：' + (d.pressureClosedMbar != null ? esc(d.pressureClosedMbar) + ' mbar' : '-'));
      }
      if (hasRtc) {
        lines.push('<b>' + t('rtc') + '</b>');
        lines.push(t('systemTimeAtRead') + '：' + (d.rtcSystemTime != null ? esc(d.rtcSystemTime) : '-'));
        lines.push(t('deviceTimeAtRead') + '：' + (d.rtcDeviceTime != null ? esc(d.rtcDeviceTime) : '-'));
        const diffStr = d.rtcTimeDiffSeconds != null
          ? ((d.rtcTimeDiffSeconds >= 0 ? '+' : '') + Number(d.rtcTimeDiffSeconds).toFixed(1) + ' s')
          : '-';
        lines.push(t('timeDiff') + '：' + diffStr);
      }
      if (hasOther) {
        lines.push('<b>' + t('other') + '</b>');
        if (d.gasSystemStatus != null) lines.push(t('gasStatus') + '：' + esc(d.gasSystemStatus));
        if (d.valveState != null) lines.push(t('valveState') + '：' + esc(d.valveState));
      }
      return lines.join('<br/>');
    }
    let recordsData = null;
    let lastFetchedData = null;
    let expandedId = null;
    function renderRecords(data, expanded) {
      recordsData = data;
      expandedId = expanded !== undefined ? expanded : expandedId;
      const tbody = document.getElementById('records-body');
      if (!data.items || data.items.length === 0) {
        tbody.innerHTML = '<tr><td colspan="10">' + t('noRecords') + '</td></tr>';
        return;
      }
      const rows = [];
      data.items.forEach(item => {
        const isExpanded = item.id === expandedId;
        const detailLabel = isExpanded ? t('collapse') : t('expand');
        const safeId = (item.id || '').replace(/"/g, '&quot;');
        rows.push('<tr class="record-row" data-id="' + safeId + '" title="' + detailLabel + '">'
          + '<td>' + formatDateLocal(item.createdAt) + '</td>'
          + '<td>' + (item.deviceSerialNumber || '-') + '</td>'
          + '<td>' + (item.deviceName || '-') + '</td>'
          + '<td class="' + (item.overallPassed ? 'ok' : 'ng') + '">' + (item.overallPassed ? t('pass') : t('fail')) + '</td>'
          + '<td>' + (item.deviceFirmwareVersion || '-') + '</td>'
          + '<td>' + (item.deviceBootloaderVersion || '-') + '</td>'
          + '<td>' + (item.deviceHardwareRevision || '-') + '</td>'
          + '<td>' + durationText(item) + '</td>'
          + '<td class="test-details-cell">' + detailLabel + '</td>'
          + '<td>' + (item.needRetest ? t('yes') : '-') + '</td>'
          + '</tr>');
        if (isExpanded) {
          const detailHtml = formatTestDetailsFull(item);
          rows.push('<tr class="detail-row"><td colspan="10"><span class="expand-hint">' + t('detailHint') + '</span><br/>' + (detailHtml === '-' ? t('none') : detailHtml) + '</td></tr>');
        }
      });
      tbody.innerHTML = rows.join('');
      tbody.querySelectorAll('tr.record-row').forEach(tr => {
        tr.addEventListener('click', function() {
          const id = this.getAttribute('data-id');
          renderRecords(recordsData, id === expandedId ? null : id);
        });
      });
    }
    function getDeviceSn(item) {
      return (item.deviceSerialNumber != null ? item.deviceSerialNumber : (item.device_serial_number != null ? item.device_serial_number : '')).toString().trim();
    }
    function dedupByDevice(items) {
      if (!items || !items.length) return items;
      const seen = new Set();
      return items.filter(item => {
        const sn = getDeviceSn(item);
        if (!sn || seen.has(sn)) return false;
        seen.add(sn);
        return true;
      });
    }
    function computeSummaryFromPayload(payload) {
      if (!payload || !payload.items || !payload.items.length) return defaultSummary;
      const items = payload.items;
      const totalRecords = items.length;
      const deviceSet = new Set();
      let passed = 0;
      let failed = 0;
      const todayStr = new Date().toISOString().slice(0, 10);
      let todayTotal = 0;
      let todayPassed = 0;
      let todayFailed = 0;
      items.forEach(item => {
        const sn = getDeviceSn(item);
        if (sn) deviceSet.add(sn);
        if (item.overallPassed) passed += 1;
        else failed += 1;
        const created = (item.createdAt || '').slice(0, 10);
        if (created === todayStr) {
          todayTotal += 1;
          if (item.overallPassed) todayPassed += 1;
          else todayFailed += 1;
        }
      });
      const passRate = totalRecords ? Math.round((passed * 1000.0) / totalRecords) / 10.0 : 0.0;
      const todayPassRate = todayTotal ? Math.round((todayPassed * 1000.0) / todayTotal) / 10.0 : 0.0;
      return {
        totalRecords: totalRecords,
        total: deviceSet.size,
        passed: passed,
        failed: failed,
        passRatePercent: passRate,
        today: {
          total: todayTotal,
          passed: todayPassed,
          failed: todayFailed,
          passRatePercent: todayPassRate
        }
      };
    }
    function applyDedupFilter(apiSummary) {
      if (!lastFetchedData || !lastFetchedData.items) {
        renderSummary(apiSummary || defaultSummary);
        return;
      }
      const dedupEl = document.getElementById('filter-dedup');
      const dedupChecked = dedupEl && dedupEl.checked === true;
      let payload = lastFetchedData;
      if (dedupChecked && lastFetchedData.items.length > 0) {
        payload = { total: lastFetchedData.total, limit: lastFetchedData.limit, offset: lastFetchedData.offset, items: dedupByDevice(lastFetchedData.items) };
      }
      renderRecords(payload, expandedId);
      const summary = dedupChecked ? computeSummaryFromPayload(payload) : (apiSummary || defaultSummary);
      if (dedupChecked && apiSummary && apiSummary.totalRecords != null) {
        summary.totalRecords = apiSummary.totalRecords;
      }
      renderSummary(summary);
    }
    function showLoadError(msg) {
      var el = document.getElementById('summary-cards');
      if (el) el.innerHTML = '<span style="color:#c00">' + (msg || t('summaryError')) + '</span>';
      var tbody = document.getElementById('records-body');
      if (tbody) tbody.innerHTML = '<tr><td colspan="10" style="color:#c00">' + (msg || t('summaryError')) + '</td></tr>';
    }
    async function loadRecords() {
      try {
        const sn = document.getElementById('filter-sn').value.trim();
        const fromVal = document.getElementById('filter-from').value || undefined;
        const toVal = document.getElementById('filter-to').value || undefined;
        const [data, apiSummary] = await Promise.all([
          getRecords(),
          getSummary(sn, fromVal, toVal)
        ]);
        lastFetchedData = data;
        applyDedupFilter(apiSummary);
      } catch (e) {
        var msg = (e && e.message) ? e.message : String(e);
        if (msg.indexOf('fetch') !== -1 || msg === 'Failed to fetch') msg = t('loadFailed');
        else if (msg.indexOf('abort') !== -1) msg = t('loadTimeout');
        showLoadError(msg);
        return;
      }
      const link = document.getElementById('export-link');
      let href = '/api/export';
      const snVal = document.getElementById('filter-sn').value.trim();
      const fromVal = document.getElementById('filter-from').value;
      const toVal = document.getElementById('filter-to').value;
      const params = new URLSearchParams();
      if (snVal) params.set('sn', snVal);
      if (fromVal) params.set('date_from', fromVal);
      if (toVal) params.set('date_to', toVal);
      if (params.toString()) href += '?' + params.toString();
      link.href = href;
    }
    document.getElementById('filter-dedup').addEventListener('change', function() {
      loadRecords();
    });
    function resetFilterProduction() {
      document.getElementById('filter-sn').value = '';
      document.getElementById('filter-sn-select').value = '';
      document.getElementById('filter-from').value = '2000-01-01';
      var d = new Date();
      document.getElementById('filter-to').value = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
      document.getElementById('filter-dedup').checked = false;
      loadRecords();
    }
    var fromInput = document.getElementById('filter-from');
    if (fromInput) {
      fromInput.addEventListener('change', function() {
        loadRecords();
      });
    }
    var toInput = document.getElementById('filter-to');
    if (toInput) {
      toInput.addEventListener('change', function() {
        loadRecords();
      });
    }
    function syncSnSelectToInput() {
      var sel = document.getElementById('filter-sn-select');
      var v = document.getElementById('filter-sn').value.trim();
      if (!sel) return;
      var found = false;
      for (var i = 0; i < sel.options.length; i++) {
        if (sel.options[i].value === v) { found = true; break; }
      }
      sel.value = found ? v : '';
    }
    document.getElementById('filter-sn-select').addEventListener('change', function() {
      document.getElementById('filter-sn').value = this.value;
      loadRecords();
    });
    var snQueryTimer = null;
    document.getElementById('filter-sn').addEventListener('change', function() { syncSnSelectToInput(); loadRecords(); });
    document.getElementById('filter-sn').addEventListener('input', function() {
      clearTimeout(snQueryTimer);
      snQueryTimer = setTimeout(function() { syncSnSelectToInput(); loadRecords(); }, 400);
    });
    document.getElementById('lang-en').onclick = function() { setLang('en'); };
    document.getElementById('lang-zh').onclick = function() { setLang('zh'); };
    document.getElementById('tab-production').onclick = function() {
      document.getElementById('tab-production').classList.add('active');
      document.getElementById('tab-burn').classList.remove('active');
      document.getElementById('tab-firmware').classList.remove('active');
      document.getElementById('panel-production').classList.add('active');
      document.getElementById('panel-burn').classList.remove('active');
      document.getElementById('panel-firmware').classList.remove('active');
    };
    document.getElementById('tab-burn').onclick = function() {
      document.getElementById('tab-production').classList.remove('active');
      document.getElementById('tab-burn').classList.add('active');
      document.getElementById('tab-firmware').classList.remove('active');
      document.getElementById('panel-production').classList.remove('active');
      document.getElementById('panel-burn').classList.add('active');
      document.getElementById('panel-firmware').classList.remove('active');
      var bf = document.getElementById('burn-filter-from');
      var bt = document.getElementById('burn-filter-to');
      if (bf && !bf.value) bf.value = '2000-01-01';
      if (bt && !bt.value) {
        var d = new Date();
        bt.value = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
      }
      loadBurnBinList();
      loadBurnOrPcbaRecords();
    };
    document.getElementById('tab-firmware').onclick = function() {
      document.getElementById('tab-production').classList.remove('active');
      document.getElementById('tab-burn').classList.remove('active');
      document.getElementById('tab-firmware').classList.add('active');
      document.getElementById('panel-production').classList.remove('active');
      document.getElementById('panel-burn').classList.remove('active');
      document.getElementById('panel-firmware').classList.add('active');
      var ff = document.getElementById('fw-filter-from');
      var ft = document.getElementById('fw-filter-to');
      if (ff && !ff.value) ff.value = '2000-01-01';
      if (ft && !ft.value) {
        var d = new Date();
        ft.value = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
      }
      loadFirmwareHistory();
    };
    async function loadBurnBinList() {
      try {
        const list = await fetch('/api/burn-bin-list').then(r => r.json());
        const sel = document.getElementById('burn-filter-bin');
        if (!sel) return;
        var v = sel.value;
        sel.innerHTML = '<option value="">' + t('snAll') + '</option>';
        (list || []).forEach(function(name) {
          if (name && String(name).trim()) {
            var opt = document.createElement('option');
            opt.value = String(name).trim();
            opt.textContent = String(name).trim();
            sel.appendChild(opt);
          }
        });
        sel.value = v;
      } catch (e) {}
    }
    async function getBurnRecords() {
      const sn = document.getElementById('burn-filter-sn').value.trim();
      const mac = document.getElementById('burn-filter-mac').value.trim();
      const from = document.getElementById('burn-filter-from').value || undefined;
      const to = document.getElementById('burn-filter-to').value || undefined;
      const testResult = document.getElementById('burn-filter-test').value || undefined;
      const flowType = document.getElementById('burn-filter-flow') ? document.getElementById('burn-filter-flow').value : undefined;
      const binFile = document.getElementById('burn-filter-bin').value || undefined;
      let url = '/api/burn-records?limit=200';
      if (sn) url += '&sn=' + encodeURIComponent(sn);
      if (mac) url += '&mac=' + encodeURIComponent(mac);
      if (from) url += '&date_from=' + encodeURIComponent(from);
      if (to) url += '&date_to=' + encodeURIComponent(to);
      if (testResult) url += '&burn_test_result=' + encodeURIComponent(testResult);
      if (flowType) url += '&flow_type=' + encodeURIComponent(flowType);
      if (binFile) url += '&bin_file=' + encodeURIComponent(binFile);
      const r = await fetchWithTimeout(url);
      if (!r.ok) { var t = await r.text(); throw new Error(r.status + ' ' + (t || r.statusText)); }
      return r.json();
    }
    function burnTestResultText(v) {
      if (!v) return '-';
      if (v === 'passed') return t('burnTestPassed');
      if (v === 'failed') return t('burnTestFailed') || '失败';
      if (v === 'self_check_failed') return t('burnTestSelfCheckFailed');
      if (v === 'key_abnormal') return t('burnTestKeyAbnormal');
      return v;
    }
    function failureReasonText(v) {
      if (!v) return '-';
      var map = { rtc_error: t('failureReasonRtc'), pressure_sensor_error: t('failureReasonPressure'),
        button_timeout: t('failureReasonButtonTimeout'), button_user_exit: t('failureReasonButtonExit'),
        factory_config_incomplete: t('failureReasonFcc'), other: t('failureReasonOther') };
      return map[v] || v;
    }
    function flowTypeText(v) {
      if (!v) return '-';
      if (v === 'P') return 'P';
      if (v === 'T') return 'T';
      if (v === 'P+T') return 'P+T';
      return v;
    }
    function burnDurationText(sec) {
      if (sec == null || sec < 0) return '-';
      const s = Math.round(sec);
      if (s < 60) return s + 's';
      return Math.floor(s/60) + 'm' + (s%60) + 's';
    }
    function buttonWaitDurationText(sec) {
      if (sec == null || sec < 0) return '-';
      const n = Number(sec);
      if (n < 60) return (Math.round(n * 10) / 10) + 's';
      return Math.floor(n/60) + 'm' + (Math.round((n%60) * 10) / 10) + 's';
    }
    var lastBurnData = null;
    var burnSortCol = 'createdAt', burnSortAsc = false;
    function sortBurnRecords(records) {
      if (!records || records.length === 0) return records;
      var key = burnSortCol, asc = burnSortAsc;
      return records.slice().sort(function(a, b) {
        var va = a[key], vb = b[key];
        if (va == null || va === '') va = '';
        if (vb == null || vb === '') vb = '';
        if (key === 'burnDurationSeconds' || key === 'durationSeconds') { va = Number(va) || 0; vb = Number(vb) || 0; return asc ? va - vb : vb - va; }
        if (key === 'buttonWaitSeconds') { va = Number(va) || 0; vb = Number(vb) || 0; return asc ? va - vb : vb - va; }
        var cmp = String(va).localeCompare(String(vb));
        return asc ? cmp : -cmp;
      });
    }
    function renderBurnSummary(totalCount, loading, error) {
      var el = document.getElementById('burn-summary-cards');
      if (!el) return;
      if (loading) {
        el.innerHTML = '<span class="loading" id="burn-loading-label">' + t('loading') + '</span>';
        return;
      }
      if (error) {
        el.innerHTML = '<span style="color:#c00">' + (error || t('summaryError')) + '</span>';
        return;
      }
      var n = totalCount != null ? totalCount : 0;
      el.innerHTML = '<div class="card"><div class="label">' + t('totalRecords') + '</div><div class="value">' + n + '</div></div>';
    }
    function renderBurnRecords(data) {
      const tbody = document.getElementById('burn-records-body');
      if (!tbody) return;
      if (!data || !data.records || data.records.length === 0) {
        tbody.innerHTML = '<tr><td colspan="13">' + t('noRecords') + '</td></tr>';
        renderBurnSummary(data && data.totalCount != null ? data.totalCount : 0, false, null);
        return;
      }
      lastBurnData = data;
      renderBurnSummary(data.totalCount != null ? data.totalCount : data.records.length, false, null);
      var sorted = sortBurnRecords(data.records);
      tbody.innerHTML = sorted.map(function(r) {
        return '<tr><td>' + formatDateLocal(r.createdAt) + '</td><td>' + flowTypeText(r.flowType) + '</td><td>' + esc(r.deviceSerialNumber || '-') + '</td><td>' + esc(r.macAddress || '-') + '</td><td>' + formatDateLocal(r.burnStartTime) + '</td><td>' + burnDurationText(r.burnDurationSeconds) + '</td><td>' + (r.buttonWaitSeconds != null ? buttonWaitDurationText(r.buttonWaitSeconds) : '-') + '</td><td>' + esc(r.computerIdentity || '-') + '</td><td>' + formatDateLocal(r.deviceWrittenTimestamp) + '</td><td>' + esc(r.deviceWrittenSerialNumber || '-') + '</td><td>' + esc(r.binFileName || '-') + '</td><td>' + burnTestResultText(r.burnTestResult) + '</td><td>' + failureReasonText(r.failureReason) + '</td></tr>';
      }).join('');
    }
    async function loadBurnRecords() {
      const tbody = document.getElementById('burn-records-body');
      renderBurnSummary(null, true, null);
      if (tbody) tbody.innerHTML = '<tr><td colspan="13" class="loading">' + t('loading') + '</td></tr>';
      try {
        const data = await getBurnRecords();
        renderBurnRecords(data);
      } catch (e) {
        var msg = (e && e.message) ? e.message : String(e);
        if (msg.indexOf('fetch') !== -1 || msg === 'Failed to fetch') msg = t('loadFailed');
        else if (msg.indexOf('abort') !== -1) msg = t('loadTimeout');
        renderBurnSummary(null, false, msg);
        if (tbody) tbody.innerHTML = '<tr><td colspan="13" style="color:#c00">' + msg + '</td></tr>';
      }
    }
    // 兼容历史代码：统一入口，当前仅加载 Burn Records
    function loadBurnOrPcbaRecords() {
      return loadBurnRecords();
    }
    document.getElementById('burn-filter-sn').addEventListener('change', loadBurnRecords);
    document.getElementById('burn-filter-mac').addEventListener('change', loadBurnRecords);
    var burnSnTimer = null;
    document.getElementById('burn-filter-sn').addEventListener('input', function() {
      clearTimeout(burnSnTimer);
      burnSnTimer = setTimeout(loadBurnRecords, 400);
    });
    document.getElementById('burn-filter-mac').addEventListener('input', function() {
      clearTimeout(burnSnTimer);
      burnSnTimer = setTimeout(loadBurnRecords, 400);
    });
    var flowEl = document.getElementById('burn-filter-flow');
    if (flowEl) flowEl.addEventListener('change', loadBurnRecords);
    async function getFirmwareHistory() {
      const sn = document.getElementById('fw-filter-sn').value.trim();
      const mac = document.getElementById('fw-filter-mac').value.trim();
      const from = document.getElementById('fw-filter-from').value || undefined;
      const to = document.getElementById('fw-filter-to').value || undefined;
      const type = document.getElementById('fw-filter-type').value || undefined;
      let url = '/api/firmware-history?limit=200';
      if (sn) url += '&sn=' + encodeURIComponent(sn);
      if (mac) url += '&mac=' + encodeURIComponent(mac);
      if (from) url += '&date_from=' + encodeURIComponent(from);
      if (to) url += '&date_to=' + encodeURIComponent(to);
      if (type) url += '&record_type=' + encodeURIComponent(type);
      const r = await fetchWithTimeout(url);
      if (!r.ok) { var t = await r.text(); throw new Error(r.status + ' ' + (t || r.statusText)); }
      return r.json();
    }
    function fwTypeText(r) {
      if (r.recordType === 'burn') return t('fwTypeBurn');
      if (r.recordType === 'upgrade') {
        return t('fwTypeUpgrade') + ' ' + (r.upgradeSuccess ? t('fwUpgradeSuccess') : t('fwUpgradeFailed'));
      }
      return r.recordType || '-';
    }
    function fwFailureReasonText(v) {
      if (!v) return '-';
      var mapZh = { user_cancelled: '用户取消', connection_lost: '连接断开', timeout: '超时', checksum_failed: '校验失败', flash_failed: '写入失败', other: '其他' };
      var mapEn = { user_cancelled: 'User cancelled', connection_lost: 'Connection lost', timeout: 'Timeout', checksum_failed: 'Checksum failed', flash_failed: 'Flash failed', other: 'Other' };
      var map = lang === 'zh' ? mapZh : mapEn;
      return map[v] || v;
    }
    function fwFileSizeText(bytes) {
      if (bytes == null || bytes < 0) return '-';
      if (bytes < 1024) return bytes + ' B';
      if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
      return (bytes / (1024 * 1024)).toFixed(2) + ' MB';
    }
    function renderFirmwareRecords(data) {
      const tbody = document.getElementById('fw-records-body');
      const summaryEl = document.getElementById('fw-summary-cards');
      if (!tbody) return;
      if (!data || !data.records || data.records.length === 0) {
        tbody.innerHTML = '<tr><td colspan="11">' + t('noRecords') + '</td></tr>';
        if (summaryEl) summaryEl.innerHTML = '<div class="card"><div class="label">' + t('totalRecords') + '</div><div class="value">0</div></div>';
        return;
      }
      if (summaryEl) summaryEl.innerHTML = '<div class="card"><div class="label">' + t('totalRecords') + '</div><div class="value">' + (data.totalCount != null ? data.totalCount : data.records.length) + '</div></div>';
      tbody.innerHTML = data.records.map(function(r) {
        var fromV = r.fromVersion || '-';
        var toV = r.toVersion || '-';
        var finalV = r.finalVersion || '-';
        var failR = fwFailureReasonText(r.failureReason);
        var sizeStr = fwFileSizeText(r.targetFileSizeBytes);
        var durStr = burnDurationText(r.durationSeconds);
        return '<tr><td>' + formatDateLocal(r.createdAt) + '</td><td>' + esc(r.deviceSerialNumber || '-') + '</td><td>' + esc(r.macAddress || '-') + '</td><td>' + esc(fromV) + '</td><td>' + esc(toV) + '</td><td>' + fwTypeText(r) + '</td><td>' + esc(finalV) + '</td><td>' + failR + '</td><td>' + sizeStr + '</td><td>' + durStr + '</td><td>' + esc(r.computerIdentity || '-') + '</td></tr>';
      }).join('');
    }
    async function loadFirmwareHistory() {
      const tbody = document.getElementById('fw-records-body');
      const summaryEl = document.getElementById('fw-summary-cards');
      if (summaryEl) summaryEl.innerHTML = '<span class="loading" id="fw-loading-label">' + t('loading') + '</span>';
      if (tbody) tbody.innerHTML = '<tr><td colspan="11" class="loading">' + t('loading') + '</td></tr>';
      try {
        const data = await getFirmwareHistory();
        renderFirmwareRecords(data);
      } catch (e) {
        var msg = (e && e.message) ? e.message : String(e);
        if (msg.indexOf('fetch') !== -1 || msg === 'Failed to fetch') msg = t('loadFailed');
        else if (msg.indexOf('abort') !== -1) msg = t('loadTimeout');
        if (summaryEl) summaryEl.innerHTML = '<span style="color:#c00">' + (msg || t('summaryError')) + '</span>';
        if (tbody) tbody.innerHTML = '<tr><td colspan="11" style="color:#c00">' + msg + '</td></tr>';
      }
    }
    function resetFilterFirmware() {
      document.getElementById('fw-filter-sn').value = '';
      document.getElementById('fw-filter-mac').value = '';
      document.getElementById('fw-filter-from').value = '2000-01-01';
      var d = new Date();
      document.getElementById('fw-filter-to').value = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
      document.getElementById('fw-filter-type').value = '';
      loadFirmwareHistory();
    }
    document.getElementById('burn-table-wrap').addEventListener('click', function(e) {
      var th = e.target.closest('th.sortable');
      if (!th || e.target.closest('.resize-handle')) return;
      var sortKey = th.getAttribute('data-sort');
      burnSortAsc = (burnSortCol === sortKey) ? !burnSortAsc : true;
      burnSortCol = sortKey;
      th.parentElement.querySelectorAll('th.sortable').forEach(function(x){ x.classList.remove('asc','desc'); });
      th.classList.add(burnSortAsc ? 'asc' : 'desc');
      if (lastBurnData) renderBurnRecords(lastBurnData);
    });
    var resizeState = null;
    function initResize(handle) {
      if (handle._resizeInit) return;
      handle._resizeInit = true;
      handle.addEventListener('mousedown', function(e) {
        e.preventDefault();
        e.stopPropagation();
        var th = handle.closest('th');
        var table = th.closest('table');
        var colIndex = Array.prototype.indexOf.call(th.parentElement.children, th);
        var cols = table.querySelectorAll('colgroup col');
        var col = cols[colIndex];
        if (!col) return;
        var startX = e.clientX, startW = th.offsetWidth;
        resizeState = { col: col, startX: startX, startW: startW };
        document.body.style.cursor = 'col-resize';
        document.body.style.userSelect = 'none';
      });
    }
    document.addEventListener('mousemove', function(e) {
      if (!resizeState) return;
      var dw = e.clientX - resizeState.startX;
      var newW = Math.max(50, resizeState.startW + dw);
      resizeState.col.style.width = newW + 'px';
      resizeState.col.style.minWidth = newW + 'px';
    });
    document.addEventListener('mouseup', function() {
      if (resizeState) {
        document.body.style.cursor = '';
        document.body.style.userSelect = '';
        resizeState = null;
      }
    });
    function initTableResize() {
      document.querySelectorAll('.burn-table th .resize-handle').forEach(initResize);
    }
    initTableResize();
    if (flowEl) flowEl.addEventListener('change', function() { setTimeout(initTableResize, 0); });
    document.getElementById('burn-filter-from').addEventListener('change', loadBurnOrPcbaRecords);
    document.getElementById('burn-filter-to').addEventListener('change', loadBurnOrPcbaRecords);
    document.getElementById('burn-filter-test').addEventListener('change', loadBurnOrPcbaRecords);
    document.getElementById('burn-filter-bin').addEventListener('change', loadBurnOrPcbaRecords);
    var fwFrom = document.getElementById('fw-filter-from');
    if (fwFrom) fwFrom.addEventListener('change', loadFirmwareHistory);
    var fwTo = document.getElementById('fw-filter-to');
    if (fwTo) fwTo.addEventListener('change', loadFirmwareHistory);
    var fwType = document.getElementById('fw-filter-type');
    if (fwType) fwType.addEventListener('change', loadFirmwareHistory);
    function resetFilterBurn() {
      document.getElementById('burn-filter-sn').value = '';
      document.getElementById('burn-filter-mac').value = '';
      document.getElementById('burn-filter-from').value = '2000-01-01';
      var d = new Date();
      document.getElementById('burn-filter-to').value = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
      document.getElementById('burn-filter-test').value = '';
      var flowEl = document.getElementById('burn-filter-flow');
      if (flowEl) flowEl.value = '';
      document.getElementById('burn-filter-bin').value = '';
      loadBurnOrPcbaRecords();
    }
    try { setLang(lang); } catch (e) {}
    (async function init() {
      try {
        var fromEl = document.getElementById('filter-from');
        var toEl = document.getElementById('filter-to');
        if (fromEl && !fromEl.value) fromEl.value = '2000-01-01';
        if (toEl && !toEl.value) {
          var d = new Date();
          toEl.value = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
        }
        loadSnList();
        await loadRecords();
      } catch (err) {
        var msg = (err && err.message) ? err.message : String(err);
        if (msg.indexOf('fetch') !== -1 || msg === 'Failed to fetch') msg = t('loadFailed');
        else if (msg.indexOf('abort') !== -1) msg = t('loadTimeout');
        showLoadError(msg);
      }
    })();
    function updateViewerCount() {
      fetch('/api/viewers').then(function(r) { return r.json(); }).then(function(data) {
        var el = document.getElementById('viewer-count-text');
        var hint = t('viewersIpsHint');
        var ipsText = (data.ips && data.ips.length) ? hint + data.ips.join(', ') : '';
        el.textContent = (t('viewersCount').replace('{{n}}', data.count != null ? data.count : 0));
        el.title = ipsText;
        var clickArea = document.getElementById('viewer-click-area');
        if (clickArea) clickArea.title = t('clickToViewVisitors');
      }).catch(function() {});
    }
    function showVisitorModal() {
      fetch('/api/viewers').then(function(r) { return r.json(); }).then(function(data) {
        var overlay = document.getElementById('visitor-modal-overlay');
        var titleEl = document.getElementById('visitor-modal-title');
        var bodyEl = document.getElementById('visitor-modal-body');
        if (!overlay || !titleEl || !bodyEl) return;
        titleEl.textContent = t('visitorsTitle') + ' (' + (data.count || 0) + ')';
        var items = data.items || [];
        if (items.length === 0) {
          bodyEl.innerHTML = '<div class="visitor-item" style="color:#999">' + t('visitorsEmpty') + '</div>';
        } else {
          bodyEl.innerHTML = items.map(function(it) {
            var d = new Date(it.lastSeen);
            var timeStr = isNaN(d.getTime()) ? it.lastSeen : d.toLocaleString();
            return '<div class="visitor-item"><span class="ip">' + esc(it.ip || '-') + '</span><span class="time">' + esc(timeStr) + '</span></div>';
          }).join('');
        }
        overlay.classList.add('show');
      }).catch(function() {});
    }
    function hideVisitorModal() {
      var overlay = document.getElementById('visitor-modal-overlay');
      if (overlay) overlay.classList.remove('show');
    }
    document.getElementById('viewer-click-area').addEventListener('click', showVisitorModal);
    document.getElementById('visitor-modal-close').addEventListener('click', hideVisitorModal);
    document.getElementById('visitor-modal-overlay').addEventListener('click', function(e) { if (e.target === this) hideVisitorModal(); });
    function updateDeployTime() {
      fetch('/api/deploy-info').then(function(r) { return r.json(); }).then(function(data) {
        var el = document.getElementById('deploy-time-text');
        if (el) {
          if (data.deployTime) {
            var d = new Date(data.deployTime);
            var s = isNaN(d.getTime()) ? data.deployTime : d.toLocaleString();
            el.textContent = t('lastDeploy') + ': ' + s;
            el.title = data.deployTime;
          } else {
            el.textContent = '';
          }
        }
        var wrap = document.getElementById('clear-data-wrap');
        if (wrap && data.isDev) {
          wrap.style.display = 'inline';
          var lbl = document.getElementById('label-clear-data');
          if (lbl) lbl.textContent = t('clearTestData');
        }
      }).catch(function() {});
    }
    function clearTestData() {
      if (!confirm(t('clearTestDataConfirm'))) return;
      fetch('/api/clear-test-data', { method: 'DELETE' }).then(function(r) {
        if (r.ok) {
          loadRecords();
          loadBurnOrPcbaRecords();
          if (typeof loadFirmwareHistory === 'function') loadFirmwareHistory();
          alert(t('dataCleared'));
        } else {
          r.json().then(function(d) { alert(d.detail || 'Failed'); }).catch(function() { alert('Failed'); });
        }
      }).catch(function() { alert('Failed'); });
    }
    updateViewerCount();
    updateDeployTime();
    function isAutoRefreshEnabled() {
      var cb = document.getElementById('auto-refresh-cb');
      return cb ? cb.checked : true;
    }
    function connectSSE() {
      var es = new EventSource('/api/events');
      es.onmessage = function(e) {
        if (!isAutoRefreshEnabled() || document.visibilityState !== 'visible') return;
        try {
          var d = JSON.parse(e.data);
          var t = d && d.type;
          if (t === 'production') loadRecords();
          else if (t === 'burn') loadBurnOrPcbaRecords();
          else if (t === 'firmware') loadFirmwareHistory();
        } catch (err) {}
      };
      es.onerror = function() { es.close(); setTimeout(connectSSE, 3000); };
    }
    connectSSE();
    setInterval(function() {
      if (!isAutoRefreshEnabled() || document.visibilityState !== 'visible') return;
      loadRecords();
      var panelBurn = document.getElementById('panel-burn');
      var panelFw = document.getElementById('panel-firmware');
      if (panelBurn && panelBurn.classList.contains('active')) loadBurnOrPcbaRecords();
      if (panelFw && panelFw.classList.contains('active')) loadFirmwareHistory();
      updateViewerCount();
      updateDeployTime();
    }, 30000);
    (function initAutoRefreshCb() {
      var cb = document.getElementById('auto-refresh-cb');
      var stored = localStorage.getItem('bog-auto-refresh');
      if (cb && stored !== null) cb.checked = stored === '1';
      if (cb) cb.addEventListener('change', function() { localStorage.setItem('bog-auto-refresh', cb.checked ? '1' : '0'); });
    })();
  </script>
</body>
</html>
"""


@app.get("/")
def root() -> RedirectResponse:
    """根路径重定向到 Home。"""
    return RedirectResponse(url="/home", status_code=302)


@app.get("/home", response_class=HTMLResponse)
def home_page() -> str:
    """Home 页：链接到各项目（如 BOG）。"""
    return HOME_HTML


@app.get("/bog", response_class=HTMLResponse)
def bog_page() -> str:
    """BOG 项目入口：产测链到生产环境、调试链到开发环境，实现数据分离。"""
    prod_base = (os.environ.get("BOG_PRODUCTION_BASE_URL") or "").rstrip("/")
    dev_base = (os.environ.get("BOG_DEVELOPMENT_BASE_URL") or "").rstrip("/")
    if prod_base and dev_base:
        production_dashboard_url = f"{prod_base}/bog/dashboard"
        development_dashboard_url = f"{dev_base}/bog/dashboard"
    else:
        production_dashboard_url = "/bog/dashboard"
        development_dashboard_url = "/bog/dashboard"
    return BOG_HTML_TEMPLATE.format(
        production_dashboard_url=production_dashboard_url,
        development_dashboard_url=development_dashboard_url,
    )


@app.get("/bog/dashboard", response_class=HTMLResponse)
def bog_dashboard() -> str:
    """统一 Dashboard：数据由当前服务端口决定（8000=产测库，8001=调试库）。"""
    return DASHBOARD_HTML


@app.get("/bog/production_dashboard", include_in_schema=False)
@app.get("/bog/development_dashboard", include_in_schema=False)
def _redirect_legacy_dashboard():
    """旧路径重定向到统一 /bog/dashboard。"""
    return RedirectResponse(url="/bog/dashboard", status_code=302)


@app.get("/admin/login", response_class=HTMLResponse)
def admin_login_page() -> str:
    return ADMIN_LOGIN_HTML


@app.get("/admin/firmware", response_class=HTMLResponse)
def admin_firmware_page(
    redirect_or_none: Optional[RedirectResponse] = Depends(require_admin_or_redirect),
) -> Any:
    if redirect_or_none is not None:
        return redirect_or_none
    return ADMIN_FIRMWARE_HTML


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
