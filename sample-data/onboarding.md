# Onboarding a New Device Type

Use this procedure when a new vehicle model or sensor package must send telemetry.

## Register the device type

1. Create a device-type record in the fleet registry with the manufacturer and model.
2. Choose a schema version. New device types start on schema version 4.
3. Request a certificate profile from the platform security team. Approval usually
   takes two business days.

## Configure the edge agent

1. Set the batch interval to 30 seconds unless the device has a cellular data cap.
2. Enable local buffering of at least 24 hours for areas without coverage.
3. Install the issued certificate in the agent's hardware-backed key store.

## Validate before rollout

1. Send test batches to the staging gateway for 48 hours.
2. Confirm that fewer than 0.1% of batches are rejected.
3. Roll out to 5% of vehicles, then 50%, then 100%, waiting one day between stages.
