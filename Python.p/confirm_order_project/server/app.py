
import os, sys, asyncio, json
from flask import Flask, request, jsonify

BASE = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
DATA_DIR = os.path.join(BASE, "data_sources")
OUT_DIR = os.path.join(BASE, "outputs")
if BASE not in sys.path:
    sys.path.append(BASE)

from scripts.agents import run_schedule

app = Flask(__name__)

@app.route("/api/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "autogen": "connected"})

@app.route("/api/schedule", methods=["POST"])
def schedule():
    try:
        body = request.get_json(force=True)
        atp_payload = body.get("atp")
        prefs_payload = body.get("preferences")
        result = asyncio.run(run_schedule(atp_payload, prefs_payload, DATA_DIR))

        os.makedirs(OUT_DIR, exist_ok=True)
        with open(os.path.join(OUT_DIR, "delivery_schedule_output.json"), "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2)
        if isinstance(result, dict) and "trace" in result:
            with open(os.path.join(OUT_DIR, "logic_trace_Delivery_Scheduler_Agent.txt"), "w", encoding="utf-8") as f:
                f.write(result["trace"])

        return jsonify({"status": "success", "data": result}), 200
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 400

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
