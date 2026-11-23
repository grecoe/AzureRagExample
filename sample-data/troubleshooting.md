# Troubleshooting Fleet Telemetry

## Events are delayed by more than five minutes

1. Check the stream processor lag metric. Lag above 50,000 events per partition means
   the processor needs more instances.
2. Check whether one vehicle is flooding a single partition. A stuck edge agent can
   resend the same buffered batch repeatedly.
3. Check the analytics store write latency. Throttling there delays all partitions.

## Batches are rejected with HTTP 401

- The device certificate has expired or was revoked. Renew it through the platform
  security team's certificate portal.
- The device clock is more than five minutes off. The gateway rejects signatures from
  devices with large clock skew.

## Duplicate events appear in reports

The stream processor deduplicates on the batch ID within a 10-minute window. Duplicates
older than 10 minutes usually mean an edge agent restored a buffer after a long outage.
Reports should group by event ID to remove them.
