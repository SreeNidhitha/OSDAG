
import os
import re
import csv
from datetime import datetime, timedelta

def _read_text(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read()

def _map_dest_code(city: str, region: str, country: str) -> str:
    city_l = (city or "").strip().lower()
    reg_u = (region or "").strip().upper()
    ctry_u = (country or "").strip().upper()
    if ctry_u not in ("IN", "IND"):
        raise ValueError(f"Unsupported country '{country}' for routing.")
    if "delhi" in city_l or reg_u == "DL": return "IN-DEL"
    if "hyderabad" in city_l or reg_u in ("TS", "TG"): return "IN-HYD"
    if "chennai" in city_l or "madras" in city_l or reg_u == "TN": return "IN-MAA"
    if "bengaluru" in city_l or "bangalore" in city_l or reg_u == "KA": return "IN-BLR"
    return f"IN-{reg_u}" if reg_u else "IN-UNK"

def _load_carrier_calendar(path_csv):
    rows = []
    with open(path_csv, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            r2 = {k: v for k, v in r.items()}
            r2["DATE"] = datetime.strptime(r2["DATE"], "%Y-%m-%d").date()
            for k, v in list(r2.items()):
                if k.endswith("_available") or k.endswith("_holiday"):
                    r2[k] = (str(v).strip().upper() == "Y")
            rows.append(r2)
    return rows

def _load_transit_fastest(path_csv):
    raw = []
    with open(path_csv, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            raw.append({
                "CARRIER": r["CARRIER"].strip(),
                "ROUTE": r["ROUTE"].strip(),
                "TRANSIT_DAYS": int(float(r["TRANSIT_DAYS"])),
                "DAILY_CUTOFF_LOCAL_HOUR": int(float(r["DAILY_CUTOFF_LOCAL_HOUR"])),
                "SERVICE_LEVEL": r.get("SERVICE_LEVEL", "").strip()
            })
    fastest_map = {}
    for r in raw:
        key = (r["CARRIER"], r["ROUTE"])
        cur = fastest_map.get(key)
        if (cur is None or
            r["TRANSIT_DAYS"] < cur["TRANSIT_DAYS"] or
            (r["TRANSIT_DAYS"] == cur["TRANSIT_DAYS"] and r["DAILY_CUTOFF_LOCAL_HOUR"] > cur["DAILY_CUTOFF_LOCAL_HOUR"])
        ):
            fastest_map[key] = r
    return list(fastest_map.values())

def _carrier_available(calendar_rows, carrier, ship_date):
    row = next((r for r in calendar_rows if r["DATE"] == ship_date), None)
    if not row:
        return False
    return bool(row.get(f"{carrier}_available", False)) and not bool(row.get(f"{carrier}_holiday", False))

def _select_route_options(fastest_rows, route_code, preferred=None, banned=None):
    opts = [r for r in fastest_rows if r["ROUTE"] == route_code]
    if preferred: opts = [r for r in opts if r["CARRIER"] in preferred]
    if banned: opts = [r for r in opts if r["CARRIER"] not in banned]
    opts.sort(key=lambda r: (r["TRANSIT_DAYS"], -r["DAILY_CUTOFF_LOCAL_HOUR"]))
    return opts

def _parse_prefs_dict_or_text(prefs):
    if isinstance(prefs, dict): return prefs
    txt = str(prefs)
    return {
        "order_id": re.search(r"order_id\s+([^\s]+)", txt).group(1),
        "customer_id": re.search(r"customer_id\s+([^\s]+)", txt).group(1),
        "preferred_delivery_window": {
            "start": re.search(r"\bstart\s+(\d{4}-\d{2}-\d{2})", txt).group(1),
            "end": re.search(r"\bend\s+(\d{4}-\d{2}-\d{2})", txt).group(1),
        },
        "address": {
            "city": re.search(r"\bcity\s+(.*?)\s+region\b", txt).group(1),
            "region": re.search(r"\bregion\s+([A-Za-z0-9-]+)", txt).group(1),
            "country": re.search(r"\bcountry\s+([A-Za-z]{2,3})", txt).group(1),
            "postal_code": re.search(r"\bpostal_code\s+([A-Za-z0-9-]+)", txt).group(1),
        },
        "incoterms": re.search(r"\bincoterms\s+([A-Za-z0-9-]+)", txt).group(1)
    }

def _parse_atp_dict_or_text(atp):
    if isinstance(atp, dict):
        lines = atp.get("lines") or atp.get("atp_lines") or []
        return [{
            "line_id": str(ln.get("line_id")),
            "MATNR": ln.get("MATNR"),
            "requested_ship_date": ln.get("requested_ship_date"),
            "earliest_available_date": ln.get("earliest_available_date"),
        } for ln in lines]
    txt = str(atp)
    pattern = (r"line_id\s+([0-9]+).*?MATNR\s+([A-Za-z0-9-]+).*?"
               r"requested_ship_date\s+(\d{4}-\d{2}-\d{2}).*?"
               r"earliest_available_date\s+(\d{4}-\d{2}-\d{2})")
    out = []
    for m in re.finditer(pattern, txt, flags=re.S):
        line_id, matnr, req_ship, atp_date = m.groups()
        out.append({"line_id": line_id, "MATNR": matnr,
                    "requested_ship_date": req_ship, "earliest_available_date": atp_date})
    if not out: raise ValueError("Could not parse ATP lines.")
    return out

def schedule_order(atp_input, prefs_input, data_dir):
    prefs = _parse_prefs_dict_or_text(prefs_input)
    atp_lines = _parse_atp_dict_or_text(atp_input)

    calendar_rows = _load_carrier_calendar(os.path.join(data_dir, "carrier_calendar_sample_01.csv"))
    fastest_rows = _load_transit_fastest(os.path.join(data_dir, "transit_time_matrix_sample_01.csv"))
    sla_text = _read_text(os.path.join(data_dir, "warehouse_sla_sample_01.json"))
    m = re.search(r"pick[_-]?pack[_-]?sla[_-]?hours\s+([0-9]+)", sla_text)
    sla_hours = int(m.group(1)) if m else 8

    origin_code = "IN-BLR"
    dest_code = _map_dest_code(prefs["address"]["city"], prefs["address"]["region"], prefs["address"]["country"])
    route_code = f"{origin_code}>{dest_code}"

    window_start = datetime.strptime(prefs["preferred_delivery_window"]["start"], "%Y-%m-%d").date()
    window_end = datetime.strptime(prefs["preferred_delivery_window"]["end"], "%Y-%m-%d").date()

    trace_lines = [
        "Logic Applied:",
        f"- End of preferred delivery window is set to {window_end:%Y-%m-%d}.",
        f"- Route fixed as {route_code} to match destination.",
        "- Transit days read from transit_time_matrix_sample_01.csv.",
        "- Select ship date such that (ship + transit_days) <= end and skip carrier holidays.",
        ""
    ]

    def schedule_line(atp_date):
        options = _select_route_options(fastest_rows, route_code)
        if not options: return {"status": "EXCEPTION", "reason": "No carrier options for route", "route": route_code}
        horizon_days = (window_end - atp_date).days
        if horizon_days < 0: return {"status": "EXCEPTION", "reason": "ATP after window_end", "route": route_code}
        for d in range(horizon_days + 1):
            ship_date = atp_date + timedelta(days=d)
            for opt in options:
                carrier = opt["CARRIER"]
                transit_days = opt["TRANSIT_DAYS"]
                cutoff = opt["DAILY_CUTOFF_LOCAL_HOUR"]
                if not _carrier_available(calendar_rows, carrier, ship_date): continue
                if d == 0 and sla_hours > cutoff: continue
                delivery_date = ship_date + timedelta(days=transit_days)
                if delivery_date < window_start or delivery_date > window_end: continue
                return {
                    "status": "SCHEDULED",
                    "carrier": carrier,
                    "service_level": opt.get("SERVICE_LEVEL", ""),
                    "ship_date": f"{ship_date:%Y-%m-%d}",
                    "delivery_date": f"{delivery_date:%Y-%m-%d}",
                    "constraints_checked": {
                        "cutoff_hour": cutoff,
                        "transit_days": transit_days,
                        "warehouse_sla_hours": sla_hours
                    }
                }
        return {"status": "EXCEPTION", "reason": "No feasible schedule within window", "route": route_code}

    schedules = []
    for ln in atp_lines:
        atp_date = datetime.strptime(ln["earliest_available_date"], "%Y-%m-%d").date()
        res = schedule_line(atp_date)
        entry = {
            "order_id": prefs["order_id"],
            "customer_id": prefs["customer_id"],
            "line_id": ln["line_id"],
            "MATNR": ln["MATNR"],
            "route": route_code
        }
        if res["status"] == "SCHEDULED":
            entry.update({
                "scheduled_ship_date": res["ship_date"],
                "estimated_delivery_date": res["delivery_date"],
                "carrier": res["carrier"],
                "service_level": res.get("service_level", ""),
                "validation_status": "pass",
                "constraints_checked": res["constraints_checked"]
            })
            trace_lines.append(
                f"order_id {entry['order_id']} customer_id {entry['customer_id']} line_id {entry['line_id']} MATNR {entry['MATNR']} "
                f"route {route_code} scheduled_ship_date {res['ship_date']} estimated_delivery_date {res['delivery_date']} "
                f"carrier {res['carrier']} validation_status pass compliance_flags window_end_respected pass holiday_considered pass "
                f"calculation_logic Choose ship date so that (ship + transit_days) <= customer_end_date and avoid carrier holidays"
            )
        else:
            entry.update({"status": "EXCEPTION", "reason": res["reason"]})
            trace_lines.append(
                f"line_id {ln['line_id']} MATNR {ln['MATNR']} route {route_code} status EXCEPTION reason {entry['reason']}"
            )
        schedules.append(entry)

    return {
        "business_rule": "Delivery must be <= customer provided end date; avoid holidays; match destination route data",
        "order_id": prefs["order_id"],
        "customer_id": prefs["customer_id"],
        "schedules": schedules,
        "trace": "\n".join(trace_lines)
    }
