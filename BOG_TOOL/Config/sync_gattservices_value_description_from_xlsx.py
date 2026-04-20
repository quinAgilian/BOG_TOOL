#!/usr/bin/env python3
"""
Merge template for GattServices.json valueDescription from Excel Overview.

Rule (literal correspondence to spreadsheet cells):
  - Take Excel columns "Value" and "Value Description" as two parts.
  - Each part is stripped of leading/trailing whitespace only; inner newlines preserved.
  - If both parts are empty/missing, omit valueDescription in JSON.
  - Otherwise join non-empty parts with "\\n\\n" (Value first, then Value Description).

Does not change uuid, description, properties, service names, appServiceUuids, or appCharacteristicKeys.

Usage (from repo root):
  python3 BOG_TOOL/Config/sync_gattservices_value_description_from_xlsx.py \\
    [--xlsx path/to/GattServices\\ 2026-03-26_111538.xlsx] \\
    [--json path/to/GattServices.json]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import openpyxl
except ImportError:
    print("Requires openpyxl: pip install openpyxl", file=sys.stderr)
    sys.exit(1)


def norm_uuid_cell(cell) -> str | None:
    if cell is None or str(cell).strip() == "":
        return None
    s = str(cell).strip()
    if s.lower().startswith("0x") and "-" in s:
        return s[2:].upper()
    if s.lower().startswith("0x"):
        h = s[2:].upper()
        if len(h) == 4:
            return f"0000{h}-0000-1000-8000-00805F9B34FB"
        if len(h) == 8:
            return f"{h}-0000-1000-8000-00805F9B34FB"
    return s.upper()


def merge_value_description(value_cell, value_desc_cell) -> str | None:
    """Literal merge: Value block + '\\n\\n' + Value Description block; omit if both empty."""
    parts: list[str] = []
    if value_cell is not None:
        if isinstance(value_cell, float) and value_cell.is_integer():
            t = str(int(value_cell))
        else:
            t = str(value_cell).strip()
        if t:
            parts.append(t)
    if value_desc_cell is not None:
        t = str(value_desc_cell).strip()
        if t:
            parts.append(t)
    if not parts:
        return None
    return "\n\n".join(parts)


def parse_overview(path: Path) -> dict[tuple[str, str], tuple[str | None, str | None]]:
    """Map (service_uuid, char_uuid) -> (raw Value cell, raw Value Description cell)."""
    wb = openpyxl.load_workbook(path, data_only=True, read_only=True)
    ws = wb["Overview"]
    cur_svc: str | None = None
    out: dict[tuple[str, str], tuple[str | None, str | None]] = {}
    for i, row in enumerate(ws.iter_rows(values_only=True)):
        if i < 3:
            continue
        svc_c, ch_c, _desc, val, valdesc, _props = row[:6]
        if svc_c is not None and str(svc_c).strip():
            cur_svc = norm_uuid_cell(svc_c)
        ch = norm_uuid_cell(ch_c)
        if not ch or not cur_svc:
            continue
        out[(cur_svc, ch)] = (val, valdesc)
    wb.close()
    return out


def apply_merges(
    gatt: dict, excel_map: dict[tuple[str, str], tuple[str | None, str | None]]
) -> None:
    for svc in gatt["services"]:
        su = svc["uuid"].upper()
        for ch in svc["characteristics"]:
            cu = ch["uuid"].upper()
            key = (su, cu)
            if key not in excel_map:
                continue
            merged = merge_value_description(*excel_map[key])
            if merged is None:
                ch.pop("valueDescription", None)
            else:
                ch["valueDescription"] = merged


def dump_gatt_compact(data: dict, path: Path) -> None:
    """Write JSON matching repo style: indent=2, one line per characteristic object."""

    def esc(s: str) -> str:
        return json.dumps(s, ensure_ascii=False)

    lines: list[str] = []
    lines.append("{")
    lines.append(f'  "deviceNamePrefix": {esc(data["deviceNamePrefix"])},')
    lines.append(f'  "specVersion": {esc(data["specVersion"])},')
    lines.append(f'  "byteOrder": {esc(data["byteOrder"])},')
    lines.append('  "services": [')
    for si, svc in enumerate(data["services"]):
        lines.append("    {")
        lines.append(f'      "uuid": {esc(svc["uuid"])},')
        lines.append(f'      "name": {esc(svc["name"])},')
        lines.append('      "characteristics": [')
        chars = svc["characteristics"]
        for ci, c in enumerate(chars):
            u, d, p = c["uuid"], c["description"], c["properties"]
            p_json = json.dumps(p, ensure_ascii=False)
            if "valueDescription" in c and c["valueDescription"] is not None:
                vd = esc(c["valueDescription"])
                inner = f'"uuid": {esc(u)}, "description": {esc(d)}, "valueDescription": {vd}, "properties": {p_json}'
            else:
                inner = f'"uuid": {esc(u)}, "description": {esc(d)}, "properties": {p_json}'
            comma = "," if ci < len(chars) - 1 else ""
            lines.append(f"        {{ {inner} }}{comma}")
        lines.append("      ]")
        comma = "," if si < len(data["services"]) - 1 else ""
        lines.append(f"    }}{comma}")
    lines.append("  ],")
    lines.append('  "appServiceUuids": [')
    uuids = data["appServiceUuids"]
    for i, u in enumerate(uuids):
        comma = "," if i < len(uuids) - 1 else ""
        lines.append(f'    {esc(u)}{comma}')
    lines.append("  ],")
    lines.append('  "appCharacteristicKeys": {')
    keys = list(data["appCharacteristicKeys"].items())
    for i, (k, v) in enumerate(keys):
        comma = "," if i < len(keys) - 1 else ""
        lines.append(f'    {esc(k)}: {esc(v)}{comma}')
    lines.append("  }")
    lines.append("}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent.parent
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--xlsx",
        type=Path,
        default=repo_root
        / "BOG_TOOL/Config/GattServicesSources/GattServices 2026-03-26_111538.xlsx",
        help="GattServices Excel path",
    )
    ap.add_argument(
        "--json",
        type=Path,
        default=Path(__file__).resolve().parent / "GattServices.json",
        help="GattServices.json to update",
    )
    args = ap.parse_args()
    if not args.xlsx.is_file():
        print(f"Excel not found: {args.xlsx}", file=sys.stderr)
        sys.exit(1)
    excel_map = parse_overview(args.xlsx)
    with open(args.json, encoding="utf-8") as f:
        gatt = json.load(f)
    apply_merges(gatt, excel_map)
    dump_gatt_compact(gatt, args.json)
    print(f"Updated {args.json} valueDescription fields from {args.xlsx} ({len(excel_map)} rows).")


if __name__ == "__main__":
    main()
