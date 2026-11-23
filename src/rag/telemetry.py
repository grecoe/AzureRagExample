"""Logging, Azure Monitor export, and custom events.

Logs and events carry identifiers, counts, statuses, and latency only. Questions,
answers, retrieved text, tokens, and user or principal identifiers are never logged.
Errors are recorded by exception type name only. Semantic Kernel's sensitive GenAI
diagnostics stay off (SEMANTICKERNEL_EXPERIMENTAL_GENAI_ENABLE_OTEL_DIAGNOSTICS_SENSITIVE
is never set).

Every container identifies itself in Application Insights:
- cloud_RoleName = rag-api or rag-ingest (OpenTelemetry service.name, from RAG_ROLE).
- cloud_RoleInstance = the replica or job execution name (service.instance.id).
- customDimensions.container = rag-api or rag-ingest on each custom event.
"""

from __future__ import annotations

import json
import logging
import os
import socket
from collections.abc import Mapping

from .clients import sync_credential
from .config import Settings

EVENT_NAME_ATTRIBUTE = "microsoft.custom_event.name"
MEASUREMENTS_ATTRIBUTE = "microsoft.custom_measurements"
# Container Apps sets the first for app replicas and the second for job executions.
INSTANCE_VARIABLES = ("CONTAINER_APP_REPLICA_NAME", "CONTAINER_APP_JOB_EXECUTION_NAME")

events = logging.getLogger("rag.events")
_state = {"container": "rag", "exporting": False}


def container_name(role: str) -> str:
    return f"rag-{role}"


def instance_name() -> str:
    for variable in INSTANCE_VARIABLES:
        value = os.environ.get(variable, "").strip()
        if value:
            return value
    return socket.gethostname()


def configure_telemetry(settings: Settings) -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    # Azure SDK HTTP logging is noisy and can include URLs; keep it at WARNING.
    logging.getLogger("azure").setLevel(logging.WARNING)
    logging.getLogger("httpx").setLevel(logging.WARNING)
    _state["container"] = container_name(settings.role)
    if not (settings.appinsights_connection_string and settings.managed_identity_client_id):
        logging.getLogger("rag").info("Azure Monitor export disabled (local run)")
        return
    from azure.monitor.opentelemetry import configure_azure_monitor
    from opentelemetry.sdk.resources import Resource

    # Application Insights has local (key) auth disabled, so export uses Entra ID.
    configure_azure_monitor(
        connection_string=settings.appinsights_connection_string,
        credential=sync_credential(settings),
        logger_name="rag",
        resource=Resource.create(
            {"service.name": _state["container"], "service.instance.id": instance_name()}
        ),
    )
    _state["exporting"] = True


def track_event(
    name: str,
    status: str,
    measurements: Mapping[str, float] | None = None,
    **dimensions: str | int | bool,
) -> None:
    """Send an Application Insights custom event (customEvents table).

    Dimensions become customDimensions and must never hold user content or identities.
    Locally, the same event is written to the console log.
    """
    attributes: dict[str, str] = {
        EVENT_NAME_ATTRIBUTE: name,
        "container": _state["container"],
        "status": status,
    }
    for key, value in dimensions.items():
        attributes[key] = str(value).lower() if isinstance(value, bool) else str(value)
    if measurements:
        attributes[MEASUREMENTS_ATTRIBUTE] = json.dumps(
            {key: float(value) for key, value in measurements.items()}
        )
    summary = " ".join(f"{key}={value}" for key, value in attributes.items() if "." not in key)
    events.info("event %s %s", name, summary, extra=attributes)


def flush_telemetry(timeout_millis: int = 10_000) -> None:
    """Export buffered telemetry now. Short-lived jobs call this before exiting."""
    if not _state["exporting"]:
        return
    from opentelemetry import _logs, metrics, trace

    for provider in (_logs.get_logger_provider(), trace.get_tracer_provider(), metrics.get_meter_provider()):
        flush = getattr(provider, "force_flush", None)
        if flush is None:
            continue
        try:
            flush(timeout_millis=timeout_millis)
        except Exception as error:  # noqa: BLE001 - telemetry must never fail the workload
            logging.getLogger("rag").warning("telemetry flush failed: %s", type(error).__name__)