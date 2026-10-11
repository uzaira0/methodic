# Capture cutoff upload acknowledgments

Android and iOS batch upload routes admit rows individually while holding the study and
participant locks until commit. A paused or completed participant's dated captures strictly
before `capture_cutoff` are stored. Captures at or after it, and undated captures, are permanently
discarded. A missing legacy cutoff discards the whole batch. Usage capture time is the event's
`timestamp`, never the later queue-write `collectedAt`; health records use `endMillis`, network
windows use `bucketEndMillis`, and iOS Screen Time uses the observation interval's end.
The purge watermark still excludes captures before erasure, including in mixed batches.

The shared rule covers Android usage, hardware sensors, battery, interaction, audio activity,
ambient audio, audio content, notifications, sleep, activity recognition, health metrics,
connectivity, app network usage, device settings, and diagnostics, plus iOS battery,
SensorKit and Screen Time. Opaque encrypted envelopes have no verifiable capture timestamp
and are acknowledged and discarded while paused or completed.

For the existing integer responses, HTTP success acknowledges the number of handled submitted
rows, including cutoff discards and duplicate records. This count is not a count of newly
inserted database rows. An all-discarded nonempty batch receives its full acknowledgment count.
After success, clients remove the acknowledged batch and continue their queued backlog. They
must not put cutoff discards through credential retry blocking. The Android usage, dedicated
telemetry, and sensor uploaders already drain these full-count acknowledgments.
Android treats an older server's 403 as bounded backoff across every upload family. The retry
fingerprint includes that credential policy, releasing terminal blocks saved by older clients;
401 and 410 continue to wait for enrollment correction.

The sensor receipt route identifies cutoff and purge discards in `discardedIds`, stored eligible
captures in `acceptedIds`, and only otherwise eligible captures awaiting consent in `heldIds`.
The diagnostics route acknowledges all handled event IDs, including permanent cutoff discards.
Enrollment, credentials, lifecycle, and consent failures retain their existing rejection contracts.

V133 backfills previously paused and completed participants from participant-bound transactional
status audit descriptions: the first stop after their last audited enrollment, including the
study's transactional duration-pause audit. Legacy individual audits bind the study in their
description even when the audit's `study_id` field is unset. These audits are
written before the status transaction commits. Later completion, HTTP audit timestamps, and
annotation `updated_at` values cannot extend the real stop. Without bound status evidence, study
creation supplies a conservative earlier cutoff; some otherwise valid backlog can be discarded.
An earlier fingerprinted stop cannot be tied to one participant, so it conservatively shortens
known enrollment intervals in that study rather than risking a cutoff after that participant's stop.
Existing cutoffs are preserved, and active participants receive no backfill.
