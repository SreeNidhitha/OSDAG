import os
import logging
from typing import Any, Dict, List, Optional, Tuple
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

logger = logging.getLogger("scheduler_agent")

class SchedulerAgent:
    """
    Delivery Scheduler Agent (Agent #2)
    - Inputs: ATP results, address, preferences/constraints
    - Outputs: per-line ship/delivery dates + consolidation suggestions
    - No split decisions (Agent #3 handles that)
    """

    def __init__(self) -> None:
        self.tz = ZoneInfo(os.getenv("TZ", "UTC"))
        self.default_carrier = os.getenv("DEFAULT_CARRIER", "CARRIER_DEFAULT")
        self.cutoff_hour = int(os.getenv("WAREHOUSE_CUTOFF_HOUR", "15"))
        self.allow_weekends = os.getenv("ALLOW_WEEKEND_DELIVERY", "false").lower() == "true"
        self.max_lines_per_shipment = int(os.getenv("MAX_LINES_PER_SHIPMENT", "999"))
        self.default_transit_days = int(os.getenv("DEFAULT_TRANSIT_DAYS", "3"))

    # -------- Public API --------
    def plan_delivery(self, req: Dict[str, Any], correlation_id: Optional[str] = None) -> Dict[str, Any]:
        customer_id = req["customer_id"]
        atp_lines = req["atp_results"]
        address = req["shipping_address"]
        prefs = (req.get("preferences") or {}) or {}
        constraints = req.get("constraints") or {}

        logger.info({"event": "schedule_received", "correlation_id": correlation_id,
                     "customer_id": customer_id, "line_count": len(atp_lines)})

        # Calendars & transit (stubs)
        wh_calendar = self._warehouse_calendar()
        carrier_cal = self._carrier_calendar()
        transit_matrix = self._transit_matrix()

        scheduled_lines: List[Dict[str, Any]] = []
        violations: List[Dict[str, Any]] = []

        for line in atp_lines:
            lp = self._compute_line_plan(line, wh_calendar, carrier_cal, transit_matrix, address, prefs)
            # Track window violations explicitly
            win_end = self._window_end(prefs.get("delivery_window"))
            warn_list: List[str] = []
            if win_end and lp["scheduled_delivery_date"] > win_end:
                warn_list.append(f"Delivery exceeds requested window end {win_end}")
                violations.append({
                    "type": "delivery_window_exceeded",
                    "line_id": line["line_id"],
                    "suggested_earliest": lp["scheduled_delivery_date"],
                    "requested_window_end": win_end
                })
            lp["warnings"] = warn_list
            scheduled_lines.append(lp)

        consolidation_suggestions = self._consolidation_hints(scheduled_lines)

        status = "success"
        next_hint = "proceed_to_split"
        if violations:
            status = "window_violation"
            next_hint = "needs_clarification"

        result = {
            "status": status,
            "correlation_id": correlation_id,
            "customer_id": customer_id,
            "scheduled_lines": scheduled_lines,
            "consolidation_suggestions": consolidation_suggestions,
            "violations": violations,
            "assumptions": self._assumptions_summary(),
            "next_hint": next_hint
        }

        logger.info({"event": "schedule_planned", "correlation_id": correlation_id,
                     "summary": {"lines": len(scheduled_lines), "status": status}})
        return result

    # -------- Core logic --------
    def _compute_line_plan(
        self, line: Dict[str, Any], wh_calendar: Dict[str, Any], carrier_cal: Dict[str, Any],
        transit_matrix: Dict[Tuple[str, str, str], int], address: Dict[str, Any], prefs: Dict[str, Any]
    ) -> Dict[str, Any]:
        line_id = line["line_id"]
        sku = line["sku"]
        qty = int(line["qty"])
        origin_site = line.get("origin_site") or "DEFAULT_SITE"
        preferred_carriers = prefs.get("preferred_carriers") or [self.default_carrier]

        # 1) Start from ATP earliest_ship_date or today
        candidate_ship = self._parse_date(line.get("earliest_ship_date")) if line.get("earliest_ship_date") else self._today_local()

        # 2) Apply warehouse cut-off & working day logic
        ship_dt = self._apply_cutoff_and_calendar(candidate_ship, wh_calendar)

        # 3) Carrier selection (first available, else default)
        carrier = self._choose_carrier(preferred_carriers, ship_dt, carrier_cal)

        # 4) Transit days lookup
        dest_key = f"{address.get('country')}-{address.get('postal_code')}"
        transit_days = transit_matrix.get((origin_site, dest_key, carrier), self.default_transit_days)

        # 5) Delivery date (respect weekend best-effort)
        delivery_dt = ship_dt + timedelta(days=transit_days)
        delivery_dt = self._avoid_weekend_if_needed(delivery_dt, prefs)

        return {
            "line_id": line_id,
            "sku": sku,
            "qty": qty,
            "origin_site": origin_site,
            "carrier": carrier,
            "scheduled_ship_date": ship_dt.date().isoformat(),
            "scheduled_delivery_date": delivery_dt.date().isoformat(),
            "transit_days": transit_days
        }

    def _consolidation_hints(self, scheduled_lines: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        if not scheduled_lines:
            return []
        # Group by (carrier, ship_date)
        groups: Dict[Tuple[str, str], List[str]] = {}
        for lp in scheduled_lines:
            key = (lp["carrier"], lp["scheduled_ship_date"])
            groups.setdefault(key, []).append(lp["line_id"])

        hints: List[Dict[str, Any]] = []
        idx = 1
        for (carrier, ship_date), line_ids in groups.items():
            if len(line_ids) > 1:
                hints.append({
                    "group_id": f"G{idx}",
                    "line_ids": line_ids,
                    "reason": f"Same carrier and ship date {ship_date}"
                })
                idx += 1
        return hints

    # -------- Helpers / Calendars / Transit --------
    def _today_local(self) -> datetime:
        return datetime.now(tz=self.tz).replace(hour=9, minute=0, second=0, microsecond=0)

    def _parse_date(self, iso_date: Optional[str]) -> datetime:
        return datetime.fromisoformat(iso_date).replace(tzinfo=self.tz)

    def _apply_cutoff_and_calendar(self, candidate: datetime, wh_calendar: Dict[str, Any]) -> datetime:
        # Move to next working day if today is non-working
        while not self._is_working_day(candidate, wh_calendar):
            candidate += timedelta(days=1)
        # If past cut-off, move to next working day 09:00
        if candidate.hour >= self.cutoff_hour:
            nxt = candidate + timedelta(days=1)
            while not self._is_working_day(nxt, wh_calendar):
                nxt += timedelta(days=1)
            return nxt.replace(hour=9, minute=0, second=0, microsecond=0)
        # Else 09:00 same day
        return candidate.replace(hour=9, minute=0, second=0, microsecond=0)

    def _is_working_day(self, dt: datetime, calendar: Dict[str, Any]) -> bool:
        # Mon-Fri working; Sat/Sun off unless calendar says otherwise
        if dt.weekday() >= 5:
            return calendar.get("weekend_working", False)
        holidays = calendar.get("holidays", set())
        return dt.date().isoformat() not in holidays

    def _choose_carrier(self, preferred: List[str], ship_dt: datetime, carrier_cal: Dict[str, Any]) -> str:
        for c in preferred:
            if self._carrier_operational(c, ship_dt, carrier_cal):
                return c
        return self.default_carrier

    def _carrier_operational(self, carrier: str, dt: datetime, carrier_cal: Dict[str, Any]) -> bool:
        blackout = carrier_cal.get(carrier, {}).get("non_operational_days", set())
        return dt.date().isoformat() not in blackout

    def _avoid_weekend_if_needed(self, dt: datetime, prefs: Dict[str, Any]) -> datetime:
        no_weekends = prefs.get("no_weekends")
        if no_weekends is True or not self.allow_weekends:
            while dt.weekday() >= 5:
                dt += timedelta(days=1)
        return dt.replace(hour=18, minute=0, second=0, microsecond=0)

    def _window_end(self, window: Optional[str]) -> Optional[str]:
        if not window or ".." not in window:
            return None
        try:
            _, end = window.split("..", 1)
            return end.strip()
        except Exception:
            return None

    def _warehouse_calendar(self) -> Dict[str, Any]:
        return {
            "weekend_working": False,
            "holidays": set()  # Fill from ERP/WMS later
        }

    def _carrier_calendar(self) -> Dict[str, Any]:
        return {
            self.default_carrier: {
                "non_operational_days": set()  # Fill from TMS later
            }
        }

    def _transit_matrix(self) -> Dict[Tuple[str, str, str], int]:
        # Key: (origin_site, dest_key 'CC-POSTAL', carrier)
        return {}

    def _assumptions_summary(self) -> Dict[str, Any]:
        return {
            "cutoff_hour_local": self.cutoff_hour,
            "weekend_delivery_allowed": self.allow_weekends,
            "default_transit_days": self.default_transit_days,
            "default_carrier": self.default_carrier
        }
