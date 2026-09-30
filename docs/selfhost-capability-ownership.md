# Capability ownership

Generated from `contracts/selfhost-capabilities.json`; run `python3 scripts/check-selfhost-capabilities.py --write`.
Infrastructure diagnostics intentionally belong to `./chronicle doctor` and Grafana, not the React application.

| Capability | Backend operation | User-facing owner |
|---|---|---|
| `study-export` | ExportController: create, list, inspect, and download export jobs | `researcher-web` |
| `participant-export` | StudyController: download participant data | `researcher-web` |
| `participant-enrollment-health` | StudyController: participant, device, sensor, upload, and compliance status | `researcher-web`, `mobile-client` |
| `verified-deletion` | DataDeletionController and StudyController: queue and inspect verified deletion | `researcher-web`, `participant-web` |
| `study-lifecycle-deletion` | StudyLifecycleController: quarantine, status, cancel, and erase a study | `researcher-web` |
| `failed-background-operations` | ExportController, PipelineController, and deletion workers expose job state | `researcher-web`, `operator-cli`, `grafana` |
| `backup-visibility` | Self-host backup receipts and verification state | `operator-cli`, `grafana` |
| `deployment-diagnostics` | Compose services, probes, configuration guard, and operational events | `operator-cli`, `grafana` |
| `monitoring-viewers` | Grafana Viewer account administration | `operator-cli` |
| `participant-forms` | SurveyController and TimeUseDiaryController participant forms | `participant-web` |
| `mobile-data-collection` | StudyController v4 enrollment and upload APIs | `mobile-client` |
| `retention-holds` | DataDeletionController retention-hold endpoints | `api-only-by-design` |
