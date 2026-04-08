
# -*- coding: utf-8 -*-
"""
Delivery Scheduler Agent — Reference Implementation (copy-paste friendly)

Folder layout (relative to this file):
  ../inputs/atp_results_input_01.json
  ../inputs/delivery_preferences_input_01.json
  ../data_sources/carrier_calendar_sample_01.csv
  ../data_sources/transit_time_matrix_sample_01.csv
  ../data_sources/warehouse_sla_sample_01.json
  ../outputs/delivery_schedule_output.json
  ../outputs/logic_trace_Delivery_Scheduler_Agent.txt

What this script does:
1) Loads ATP earliest-available dates per line and customer delivery window.
2) Loads carrier calendar, transit-time matrix, and warehouse SLA.
3) Computes ship & delivery dates per line (respecting holidays, cut-offs, SLA, and window).
4) Writes a schedule JSON and a human-readable logic trace.

It tolerates your "freeform" input files (not strict JSON) by using regex parsing as fallback.
"""

import os
import re
import json
import datetime
from typing import Dict, List, Any

import pandas as pd

# ---------- Paths (robust to any current working directory) ----------
import os  # keep this import; others can be above this block too

def _project_root() -> str:
    # scripts/ is where THIS file lives; project root is its parent
    scripts_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(scripts_dir, os.pardir))

def path_inputs(*names) -> str:
    return os.path.join(_project_root(), "inputs", *names)

def path_data(*names) -> str:
    return os.path.join(_project_root(), "data_sources", *names)

def path_outputs(*names) -> str:
    return os.path.join(_project_root(), "outputs", *names)


# ---------- Paths ----------
def base_dir_from_scripts() -> str:
    """Return project root based on expected layout (scripts/ is current)."""
    return os.path.abspath(os.path.join(os.getcwd(), os.pardir))


def path_inputs(*names) -> str:
    return os.path.join(base_dir_from_scripts(), "inputs", *names)


def path_data(*names) -> str:
    return os.path.join(base_dir_from_scripts(), "data_sources", *names)


def path_outputs(*names) -> str:
    return os.path.join(base_dir_from_scripts(), "outputs", *names)


# ---------- Safe file readers ----------
def read_text(path: str) -> str:
    if not os.path.isfile(path):
        raise FileNotFoundError(f"Missing file: {path}")
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read()


def read_json_or_freeform(path: str) -> Any:
    """
    Try to load as JSON. If it fails, return raw text (caller will parse).
    """
    txt = read_text(path)
    try:
        return json.loads(txt)
    except Exception:
        return txt


# ---------- Freeform parsers ----------
def parse_preferences_freeform(txt: str) -> Dict[str, Any]:
    """
    Parse delivery_preferences_input_01.json freeform text like:
      order_id SO-2025-0004 customer_id CUST-400099 preferred_delivery_window start 2025-12-09 end 2025-12-11
      delivery_address ship_to_party CUST-400099 city New Delhi region DL country IN postal_code 110001 incoterms DAP
    """
    def rex(pattern, default=None, flags=re.S):
        m = re.search(pattern, txt, flags)
        return m.group(1).strip() if m else default

    # order/customer
    order_id = rex(r"order_id\s+([^\s]+)")
    customer_id = rex(r"customer_id\s+([^\s]+)")

    # delivery window
    window_start = rex(r"\bstart\s+(\d{4}-\d{2}-\d{2})")
    window_end = rex(r"\bend\s+(\d{4}-\d{2}-\d{2})")

    # address fields
    # city could be multi-word, capture until 'region'
    city = rex(r"\bcity\s+(.*?)\s+region\b")
    region = rex(r"\bregion\s+([A-Za-z0-9-]+)")
    country = rex(r"\bcountry\s+([A-Za-z]{2,3})")
    postal_code = rex(r"\bpostal_code\s+([A-Za-z0-9-]+)")
    incoterms = rex(r"\bincoterms\s+([A-Za-z0-9-]+)")

    return {
        "order_id": order_id,
        "customer_id": customer_id,
        "preferred_delivery_window": {"start": window_start, "end": window_end},
        "address": {
            "city": city,
            "region": region,
            "country": country,
            "postal_code": postal_code,
        },
        "incoterms": incoterms,
    }


def parse_atp_freeform(txt: str) -> List[Dict[str, Any]]:
    """
    Parse atp_results_input_01.json freeform text that repeats blocks per line:
      ... order_id ... line_id 001 MATNR MAT-3001 requested_ship_date 2025-12-08 customer_expected_delivery_date 2025-12-11 earliest_available_date 2025-12-08 ...
    Returns: list of dicts with keys: line_id, MATNR, requested_ship_date, earliest_available_date
    """
    # Build a regex to capture multiple blocks for line entries
    pattern = (
        r"line_id\s+([0-9]+).*?"
        r"MATNR\s+([A-Za-z0-9-]+).*?"
        r"requested_ship_date\s+(\d{4}-\d{2}-\d{2}).*?"
        r"earliest_available_date\s+(\d{4}-\d{2}-\d{2})"
    )
    lines = []
    for m in re.finditer(pattern, txt, flags=re.S):
        line_id, matnr, req_ship, atp_date = m.groups()
        lines.append({
            "line_id": line_id,
            "MATNR": matnr,
            "requested_ship_date": req_ship,
            "earliest_available_date": atp_date,
        })
    if not lines:
        raise ValueError("Could not parse ATP lines from freeform text.")
    return lines


def parse_sla_freeform(txt: str) -> Dict[str, Any]:
    """
    Parse warehouse_sla_sample_01.json freeform text like:
      plant 1000 pick_pack_sla_hours 8 dock_capacity_per_day 1800 policy ...
    """
    def rex(pattern, default=None):
        m = re.search(pattern, txt)
        return m.group(1) if m else default

    return {
        "plant": rex(r"\bplant\s+([A-Za-z0-9-]+)", "1000"),
        "pick_pack_sla_hours": int(rex(r"\bpick[_-]?pack[_-]?sla[_-]?hours\s+([0-9]+)", "8")),
        "dock_capacity_per_day": int(rex(r"\bdock[_-]?capacity[_-]?per[_-]?day\s+([0-9]+)", "1800")),
        "policy": rex(r"\bpolicy\s+(.*)", "Schedule on/after earliest_available_date; avoid carrier holidays; respect daily cutoff; ensure delivery <= customer end date"),
    }


# ---------- Route helpers ----------
def map_city_region_to_code(city: str, region: str, country: str) -> str:
    """
    Map destination to standardized code used in transit matrix.
    Known examples:
      New Delhi (DL) -> IN-DEL
      Hyderabad (TS) -> IN-HYD
      Chennai (TN) -> IN-MAA
      Bengaluru (KA) -> IN-BLR
    """
    city = (city or "").strip().lower()
    region = (region or "").strip().upper()
    country = (country or "").strip().upper()

    if country not in ("IN", "IND"):
        raise ValueError(f"Unsupported country '{country}' for routing.")

    if "delhi" in city or region == "DL":
        return "IN-DEL"
    if "hyderabad" in city or region in ("TS", "TG"):
        return "IN-HYD"
    if "chennai" in city or "madras" in city or region == "TN":
        return "IN-MAA"
    if "bengaluru" in city or "bangalore" in city or region == "KA":
        return "IN-BLR"

    # Default to region-based or raise
    if region:
        return f"IN-{region}"
    raise ValueError("Unable to map city/region to route code.")


# ---------- Loading structured data sources ----------
def load_carrier_calendar(path_csv: str) -> pd.DataFrame:
    df = pd.read_csv(path_csv)
    df["DATE"] = pd.to_datetime(df["DATE"])
    # Normalize Y/N to booleans
    for col in df.columns:
        if col.endswith("_available") or col.endswith("_holiday"):
            df[col] = (df[col].astype(str).str.upper().str.strip()
                       .map({"Y": True, "N": False}))
    return df


def load_transit_matrix(path_csv: str) -> pd.DataFrame:
    df = pd.read_csv(path_csv)
    df["TRANSIT_DAYS"] = pd.to_numeric(df["TRANSIT_DAYS"])
    df["DAILY_CUTOFF_LOCAL_HOUR"] = pd.to_numeric(df["DAILY_CUTOFF_LOCAL_HOUR"])
    df["ROUTE"] = df["ROUTE"].str.strip()
    df["CARRIER"] = df["CARRIER"].str.strip()
    df["SERVICE_LEVEL"] = df["SERVICE_LEVEL"].str.strip()
    # Deduplicate to fastest per (carrier, route), tie-breaker lower cutoff first
    fastest = (df.sort_values(["TRANSIT_DAYS", "DAILY_CUTOFF_LOCAL_HOUR"])
               .groupby(["CARRIER", "ROUTE"], as_index=False)
               .first())
    return fastest


# ---------- Scheduling logic ----------
def carrier_available(calendar: pd.DataFrame, carrier: str, ship_date: pd.Timestamp) -> bool:
    row = calendar[calendar["DATE"] == ship_date]
    if row.empty:
        return False
    avail = bool(row.iloc[0].get(f"{carrier}_available", False))
    holiday = bool(row.iloc[0].get(f"{carrier}_holiday", False))
    return avail and (not holiday)


def select_route_options(fastest: pd.DataFrame, route_code: str,
                         preferred_carriers: List[str] = None,
                         banned_carriers: List[str] = None) -> pd.DataFrame:
    df = fastest[fastest["ROUTE"] == route_code].copy()
    if preferred_carriers:
        df = df[df["CARRIER"].isin(preferred_carriers)]
    if banned_carriers:
        df = df[~df["CARRIER"].isin(banned_carriers)]
    # Prefer shorter transit days, then later cutoff (descending)
    df = df.sort_values(["TRANSIT_DAYS", "DAILY_CUTOFF_LOCAL_HOUR"], ascending=[True, False])
    return df


def schedule_line(atp_date: pd.Timestamp,
                  window_start: pd.Timestamp,
                  window_end: pd.Timestamp,
                  route_code: str,
                  calendar: pd.DataFrame,
                  fastest: pd.DataFrame,
                  sla_hours: int,
                  allow_same_day_ship: bool = True) -> Dict[str, Any]:
    """
    Try to find the earliest ship_date and carrier s.t. delivery in window and no holiday,
    respecting cutoff vs SLA for same-day ship.
    """
    options = select_route_options(fastest, route_code)
    if options.empty:
        return {"status": "EXCEPTION", "reason": "No carrier options for route", "route": route_code}

    # Search from ATP date up to window_end (practical limit)
    horizon_days = (window_end - atp_date).days
    if horizon_days < 0:
        return {"status": "EXCEPTION", "reason": "ATP after window_end", "route": route_code}

    for d in range(horizon_days + 1):
        ship_date = atp_date + pd.Timedelta(days=d)

        for _, opt in options.iterrows():
            carrier = str(opt["CARRIER"])
            transit_days = int(opt["TRANSIT_DAYS"])
            cutoff_hour = int(opt["DAILY_CUTOFF_LOCAL_HOUR"])
            service_level = str(opt.get("SERVICE_LEVEL", ""))

            # Check carrier availability & holidays
            if not carrier_available(calendar, carrier, ship_date):
                continue

            # Same-day ship feasibility (simple rule: SLA hours must be <= cutoff hour)
            if allow_same_day_ship and d == 0:
                if sla_hours > cutoff_hour:
                    # can't meet cutoff for same-day
                    continue

            delivery_date = ship_date + pd.Timedelta(days=transit_days)

            # Delivery must be within window
            if delivery_date < window_start or delivery_date > window_end:
                continue

            return {
                "status": "SCHEDULED",
                "carrier": carrier,
                "service_level": service_level,
                "ship_date": ship_date.strftime("%Y-%m-%d"),
                "delivery_date": delivery_date.strftime("%Y-%m-%d"),
                "constraints_checked": {
                    "cutoff_hour": cutoff_hour,
                    "transit_days": transit_days,
                    "warehouse_sla_hours": sla_hours,
                }
            }

    return {"status": "EXCEPTION", "reason": "No feasible schedule within window", "route": route_code}


# ---------- Main orchestration ----------
def main():
    # Paths
    p_atp = path_inputs("atp_results_input_01.json")
    p_prefs = path_inputs("delivery_preferences_input_01.json")
    p_calendar = path_data("carrier_calendar_sample_01.csv")
    p_matrix = path_data("transit_time_matrix_sample_01.csv")
    p_sla = path_data("warehouse_sla_sample_01.json")
    p_out_json = path_outputs("delivery_schedule_output.json")
    p_out_trace = path_outputs("logic_trace_Delivery_Scheduler_Agent.txt")

    # Load inputs
    atp_raw = read_json_or_freeform(p_atp)
    prefs_raw = read_json_or_freeform(p_prefs)

    if isinstance(prefs_raw, dict):
        prefs = prefs_raw
    else:
        prefs = parse_preferences_freeform(prefs_raw)

    if isinstance(atp_raw, dict):
        # If strict JSON list is under some key, normalize
        lines = atp_raw.get("lines") or atp_raw.get("atp_lines") or []
        atp_lines = []
        for ln in lines:
            atp_lines.append({
                "line_id": str(ln.get("line_id")),
                "MATNR": ln.get("MATNR"),
                "requested_ship_date": ln.get("requested_ship_date"),
                "earliest_available_date": ln.get("earliest_available_date"),
            })
        if not atp_lines:
            raise ValueError("ATP JSON found but no recognized line entries.")
    else:
        atp_lines = parse_atp_freeform(atp_raw)

    # Load data sources
    calendar = load_carrier_calendar(p_calendar)
    fastest = load_transit_matrix(p_matrix)
    sla_raw = read_json_or_freeform(p_sla)
    if isinstance(sla_raw, dict):
        sla = sla_raw
    else:
        sla = parse_sla_freeform(sla_raw)
    sla_hours = int(sla.get("pick_pack_sla_hours", 8))

    # Routing: origin default IN-BLR; destination from preferences
    origin_code = "IN-BLR"
    dest_code = map_city_region_to_code(
        prefs["address"].get("city"),
        prefs["address"].get("region"),
        prefs["address"].get("country")
    )
    route_code = f"{origin_code}>{dest_code}"

    # Delivery window
    window_start = pd.to_datetime(prefs["preferred_delivery_window"]["start"])
    window_end = pd.to_datetime(prefs["preferred_delivery_window"]["end"])

    # Compute schedules per line
    schedules = []
    trace_lines = []

    # Logic header for trace
    trace_lines.append("Logic Applied:")
    trace_lines.append(f"- End of preferred delivery window is set to {window_end.strftime('%Y-%m-%d')}.")
    trace_lines.append(f"- Route fixed as {route_code} to match destination.")
    trace_lines.append("- Transit days read from transit_time_matrix_sample_01.csv.")
    trace_lines.append("- Select ship date such that (ship + transit_days) <= end and skip carrier holidays.")
    trace_lines.append("")

    for ln in atp_lines:
        atp_date = pd.to_datetime(ln["earliest_available_date"])
        result = schedule_line(
            atp_date=atp_date,
            window_start=window_start,
            window_end=window_end,
            route_code=route_code,
            calendar=calendar,
            fastest=fastest,
            sla_hours=sla_hours,
        )

        out_entry = {
            "order_id": prefs.get("order_id"),
            "customer_id": prefs.get("customer_id"),
            "line_id": ln["line_id"],
            "MATNR": ln["MATNR"],
            "route": route_code,
        }

        if result["status"] == "SCHEDULED":
            out_entry.update({
                "scheduled_ship_date": result["ship_date"],
                "estimated_delivery_date": result["delivery_date"],
                "carrier": result["carrier"],
                "service_level": result.get("service_level", ""),
                "validation_status": "pass",
                "constraints_checked": result["constraints_checked"],
            })

            # Trace per line (similar style to your sample)
            trace_lines.append(
                f"order_id {out_entry['order_id']} customer_id {out_entry['customer_id']} "
                f"line_id {out_entry['line_id']} MATNR {out_entry['MATNR']} route {route_code} "
                f"scheduled_ship_date {result['ship_date']} estimated_delivery_date {result['delivery_date']} "
                f"carrier {result['carrier']} validation_status pass "
                f"compliance_flags window_end_respected pass holiday_considered pass "
                f"calculation_logic Choose ship date so that (ship + transit_days) <= customer_end_date and avoid carrier holidays"
            )
        else:
            out_entry.update({
                "status": "EXCEPTION",
                "reason": result.get("reason", "Unknown"),
            })
            trace_lines.append(
                f"line_id {ln['line_id']} MATNR {ln['MATNR']} route {route_code} "
                f"status EXCEPTION reason {out_entry['reason']}"
            )

        schedules.append(out_entry)

    # Compose final output JSON similar to your structure, but valid JSON
    output_payload = {
        "business_rule": "Delivery must be <= customer provided end date; avoid holidays; match destination route data",
        "order_id": prefs.get("order_id"),
        "customer_id": prefs.get("customer_id"),
        "schedules": schedules
    }

    # Ensure outputs folder exists
    os.makedirs(os.path.dirname(p_out_json), exist_ok=True)

    # Write JSON
    with open(p_out_json, "w", encoding="utf-8") as f:
        json.dump(output_payload, f, indent=2)

    # Write trace
    with open(p_out_trace, "w", encoding="utf-8") as f:
        f.write("\n".join(trace_lines))

    # Console summary
    print("Delivery Scheduler Agent completed.")
    print(f"Route: {route_code}")
    print(f"Output JSON: {p_out_json}")
    print(f"Trace file: {p_out_trace}")


if __name__ == "__main__":
    # Lazy import of pandas where needed above
    import pandas as pd  # noqa
    main()
