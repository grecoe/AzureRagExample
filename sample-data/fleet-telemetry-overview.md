# Contoso Fleet Telemetry Overview

Contoso Fleet Telemetry collects health and location events from delivery vehicles and
makes them available to dispatch, maintenance, and billing teams.

## Components

- **Edge agent** runs on each vehicle and batches events every 30 seconds.
- **Ingestion gateway** receives batches over HTTPS and validates the device certificate.
- **Event hub** buffers validated events for downstream processing.
- **Stream processor** enriches events with route and driver metadata.
- **Raw event store** keeps unmodified events for 90 days in an append-only data lake.
- **Analytics store** keeps aggregated hourly metrics for 2 years.

## Data flow

1. The edge agent signs each batch and sends it to the ingestion gateway.
2. The gateway rejects batches with expired certificates and returns HTTP 401.
3. Accepted batches are written to the event hub partition chosen by vehicle ID.
4. The stream processor reads each partition in order and writes to both stores.

## Service levels

- 99.9% of events are queryable in the analytics store within 5 minutes.
- The raw event store is the system of record for billing disputes.
