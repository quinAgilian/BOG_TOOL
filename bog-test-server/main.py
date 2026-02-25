"""
产测数据接收服务：接收 BOG_TOOL 产测结果 POST，落库，提供 Summary 与记录查询。
推荐部署到远程服务器，BOG_TOOL APP 作为 HTTP 客户端连接。
"""
import json
import os
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from fastapi import FastAPI, Query, HTTPException, Request
from fastapi.responses import HTMLResponse, PlainTextResponse

from schemas import ProductionTestPayload

# ---------------------------------------------------------------------------
# 配置与数据库
# ---------------------------------------------------------------------------

BASE_DIR = Path(__file__).resolve().parent
_db_path = os.environ.get("BOG_DB_PATH", "")
DB_PATH = Path(_db_path) if _db_path.startswith("/") else (BASE_DIR / (_db_path or "bog_test.db"))


def get_db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
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
        conn.commit()


# ---------------------------------------------------------------------------
# FastAPI 应用
# ---------------------------------------------------------------------------

app = FastAPI(title="BOG 产测数据服务", version="0.1.0")


@app.on_event("startup")
def startup() -> None:
    init_db()


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@app.post("/api/production-test")
def post_production_test(payload: ProductionTestPayload) -> dict[str, Any]:
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
    return {"ok": True, "id": test_id, "createdAt": created_at}


@app.get("/api/summary")
def get_summary(
    sn: Optional[str] = Query(None),
    date_from: Optional[str] = Query(None, description="YYYY-MM-DD"),
    date_to: Optional[str] = Query(None, description="YYYY-MM-DD"),
) -> dict[str, Any]:
    """汇总：按设备号统计，随当前查询条件（SN、日期范围）变化；每设备只计其最新一次测试结果。使用 JOIN+MAX 兼容旧版 SQLite。"""
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    conditions: list[str] = ["device_serial_number IS NOT NULL", "device_serial_number != ''"]
    params: list[Any] = []
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
) -> dict[str, Any]:
    """分页查询产测记录，可按 SN、日期范围筛选。"""
    conditions: list[str] = []
    params: list[Any] = []
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

    def row_to_item(r: sqlite3.Row) -> dict[str, Any]:
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
def get_sn_list() -> list[str]:
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
    conditions: list[str] = []
    params: list[Any] = []
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

_viewers: dict[str, float] = {}
_viewers_lock = threading.Lock()
VIEWER_TIMEOUT_SEC = 60


def _get_client_ip(request: Request) -> str:
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()
    return request.client.host if request.client else ""


@app.get("/api/viewers")
def api_viewers(request: Request) -> dict[str, Any]:
    """登记当前请求 IP 为观众，清理超时，返回当前观众数和前 10 个 IP（供底部展示与悬停）。"""
    ip = _get_client_ip(request)
    now = time.time()
    with _viewers_lock:
        _viewers[ip] = now
        to_del = [k for k, v in _viewers.items() if now - v > VIEWER_TIMEOUT_SEC]
        for k in to_del:
            del _viewers[k]
        ips = sorted(_viewers.keys(), key=lambda k: -_viewers[k])[:10]
    return {"count": len(_viewers), "ips": ips}


# ---------------------------------------------------------------------------
# Dashboard 静态页（内联 HTML + JS，无需静态文件）
# ---------------------------------------------------------------------------

DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Production Test Overview</title>
  <style>
    * { box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }
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
    table { width: 100%; min-width: 960px; border-collapse: collapse; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); table-layout: fixed; }
    th, td { padding: 8px 10px; text-align: left; border-bottom: 1px solid #eee; font-size: 13px; }
    th, td { overflow: hidden; text-overflow: ellipsis; }
    td.test-details-cell { overflow: visible; text-overflow: clip; }
    th { background: #fafafa; font-size: 12px; color: #666; }
    .col-time { width: 152px; }
    .col-sn { width: 110px; }
    .col-device { width: 100px; }
    .col-result { width: 56px; }
    .col-fw { width: 64px; }
    .col-bl { width: 44px; }
    .col-hw { width: 82px; }
    .col-duration { width: 56px; }
    .col-details { width: 90px; }
    .col-retest { width: 52px; }
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
    .viewer-footer { margin-top: 16px; padding: 8px 0; font-size: 12px; color: #666; display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
    .viewer-footer span { cursor: default; }
    .viewer-footer a { font-size: 12px; }
  </style>
</head>
<body>
  <div style="display:flex; align-items: center; flex-wrap: wrap; gap: 12px; margin-bottom: 8px;">
    <h1 style="margin: 0;" id="page-title">Production Test Overview</h1>
    <span class="lang-switch" id="lang-switch"><a id="lang-en" href="javascript:void(0)">EN</a> | <a id="lang-zh" href="javascript:void(0)">中文</a></span>
  </div>
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
  <div class="viewer-footer" id="viewer-footer">
    <span id="viewer-count-text" title=""> </span>
    <a id="open-page-link" href="/" target="_blank"></a>
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
        openPageLink: 'Open this page'
      },
      zh: {
        title: '产测数据概览',
        loading: '加载中…',
        snPlaceholder: '可选',
        snAll: '全部',
        from: '从',
        to: '到',
        query: '查询',
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
        openPageLink: '打开网页'
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
      var d = new Date(isoStr);
      if (isNaN(d.getTime())) return isoStr;
      var y = d.getFullYear();
      var m = String(d.getMonth() + 1).padStart(2, '0');
      var day = String(d.getDate()).padStart(2, '0');
      var h = String(d.getHours()).padStart(2, '0');
      var min = String(d.getMinutes()).padStart(2, '0');
      var s = String(d.getSeconds()).padStart(2, '0');
      return y + '-' + m + '-' + day + ' ' + h + ':' + min + ':' + s;
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
    function applyDedupFilter() {
      if (!lastFetchedData || !lastFetchedData.items) {
        renderSummary(defaultSummary);
        return;
      }
      const dedupEl = document.getElementById('filter-dedup');
      const dedupChecked = dedupEl && dedupEl.checked === true;
      let payload = lastFetchedData;
      if (dedupChecked && lastFetchedData.items.length > 0) {
        payload = { total: lastFetchedData.total, limit: lastFetchedData.limit, offset: lastFetchedData.offset, items: dedupByDevice(lastFetchedData.items) };
      }
      renderRecords(payload, expandedId);
      const summary = computeSummaryFromPayload(payload);
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
        const data = await getRecords();
        lastFetchedData = data;
        applyDedupFilter();
      } catch (e) {
        var msg = (e && e.message) ? e.message : String(e);
        if (msg.indexOf('fetch') !== -1 || msg === 'Failed to fetch') msg = t('loadFailed');
        else if (msg.indexOf('abort') !== -1) msg = t('loadTimeout');
        showLoadError(msg);
        return;
      }
      const link = document.getElementById('export-link');
      let href = '/api/export';
      const fromVal = document.getElementById('filter-from').value;
      const toVal = document.getElementById('filter-to').value;
      const params = new URLSearchParams();
      if (sn) params.set('sn', sn);
      if (fromVal) params.set('date_from', fromVal);
      if (toVal) params.set('date_to', toVal);
      if (params.toString()) href += '?' + params.toString();
      link.href = href;
    }
    document.getElementById('filter-dedup').addEventListener('change', function() {
      loadRecords();
    });
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
      }).catch(function() {});
    }
    updateViewerCount();
    setInterval(function() {
      if (document.visibilityState === 'visible') {
        loadRecords();
        updateViewerCount();
      }
    }, 10000);
  </script>
</body>
</html>
"""


@app.get("/", response_class=HTMLResponse)
def dashboard() -> str:
    """数据概览页：Summary 卡片 + 最近记录表。"""
    return DASHBOARD_HTML


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
