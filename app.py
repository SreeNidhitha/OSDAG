import os
import logging
from flask import Flask, request
from dotenv import load_dotenv
from api.routes import api_bp

def configure_logging() -> None:
    os.makedirs("logs", exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        handlers=[logging.FileHandler("logs/agent2_scheduler.log"), logging.StreamHandler()],
    )

def create_app() -> Flask:
    load_dotenv()
    configure_logging()
    app = Flask(__name__)
    app.register_blueprint(api_bp)

    @app.before_request
    def inject_correlation():
        corr = request.headers.get("X-Request-ID")
        if not corr:
            import uuid
            corr = f"corr-{uuid.uuid4()}"
        request.correlation_id = corr  # attach for logs

    @app.route("/", methods=["GET"])
    def root():
        return {
            "message": "Delivery Scheduler Agent (Agent #2) — Confirm Order",
            "health": "/v1/health",
            "schedule": "POST /v1/scheduler/schedule"
        }, 200

    return app

if __name__ == "__main__":
    app = create_app()
    port = int(os.getenv("PORT", "8081"))
    debug = os.getenv("FLASK_ENV", "development") == "development"
    app.run(host="0.0.0.0", port=port, debug=debug)