from flask import Blueprint, jsonify, request
from pydantic import BaseModel, Field, ValidationError
from typing import Any, Dict, List, Optional
from agent_core.scheduler_agent import SchedulerAgent

api_bp = Blueprint("api", __name__, url_prefix="/v1")
scheduler = SchedulerAgent()

# ---------- Schemas ----------
class Address(BaseModel):
    line1: str
    city: str
    state: str
    postal_code: str
    country: str
    line2: Optional[str] = None

class ATPLine(BaseModel):
    line_id: str
    sku: str
    qty: int
    origin_site: Optional[str] = None
    earliest_ship_date: Optional[str] = None  # ISO yyyy-mm-dd
    promised_date: Optional[str] = None

class Preferences(BaseModel):
    delivery_window: Optional[str] = None     # "YYYY-MM-DD..YYYY-MM-DD"
    preferred_carriers: List[str] = Field(default_factory=list)
    no_weekends: Optional[bool] = None
    priority: Optional[str] = None            # "urgent" | "normal" | "defer"

class ScheduleRequest(BaseModel):
    customer_id: str
    atp_results: List[ATPLine]
    shipping_address: Address
    preferences: Optional[Preferences] = None
    constraints: Dict[str, Any] = Field(default_factory=dict)
    notes: Optional[str] = None

@api_bp.route("/health", methods=["GET"])
def health() -> Any:
    return jsonify({"status": "ok"}), 200

@api_bp.route("/scheduler/schedule", methods=["POST"])
def schedule() -> Any:
    try:
        payload = request.get_json(silent=True) or {}
        req = ScheduleRequest(**payload)
    except ValidationError as ve:
        return jsonify({"status": "error", "error": ve.errors()}), 400
    except Exception as e:
        return jsonify({"status": "error", "error": str(e)}), 400

    try:
        result = scheduler.plan_delivery(
            req.model_dump(mode="python"),
            correlation_id=getattr(request, "correlation_id", None),
        )
        return jsonify(result), 200
    except Exception as e:
        return jsonify({"status": "error", "error": "Scheduling failed", "details": str(e)}), 500