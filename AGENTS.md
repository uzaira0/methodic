# Repository Agent Instructions

## Local-Hosting Scope

Chronicle is currently operated as a locally hosted BCM deployment. Do not spend
implementation time on third-party integrations that are intentionally unused in
this deployment unless the user explicitly re-enables them.

Ignore for now:
- Twilio/SMS delivery and Twilio BAA/compliance follow-up.
- Alertmanager outbound notification receivers such as Slack, PagerDuty,
  OpsGenie, or email webhooks.
- External warehouse runtime, warehouse JDBC, warehouse migration/flush jobs, and
  warehouse-specific cleanup. Chronicle local hosting uses local Postgres only.
- Cloud object-storage runtime features, cloud launch configuration, and
  cloud-provider-specific cleanup.
- Firebase/FCM or other external push providers.
- Cloud deployment, hosted staging, and non-local cloud-provider runbooks.

Still in scope:
- Local backend security, authorization, RLS, data deletion, upload handling,
  database hardening, local Docker/Traefik/Postgres, VictoriaMetrics,
  VictoriaLogs, tests, Semgrep, ast-grep, and CI guardrails that apply to the
  local deployment.
- VictoriaTrace/OpenTelemetry tracing is future scope only unless the user
  explicitly asks to implement tracing now.

## Domain: Survey / Questionnaire / Time Use Diary

These three are participant-data features. **None is a UI hosted inside the
Android app** — all three are web forms, served and exported by the backend.

- **App-usage Survey** (internal code name `AWARENESS`) — web form `/survey`,
  backend `SurveyController`, table `app_usage_survey`.
- **Questionnaire** — researcher-authored, web form `/questionnaire`, backend
  `SurveyController`, table `questionnaire_submissions`.
- **Time Use Diary (TUD)** — web-only module (`TimeUseDiaryPage`,
  `StudyTimeUseDiaryPage`, `TimeUseDiaryController`). The Android app has **zero**
  TUD code by design.

The Android app's only role for Survey/Questionnaire is `NotificationsWorker`
scheduling notifications (`NotificationType` = `{AWARENESS, QUESTIONNAIRE}`) that
deep-link to the web forms. TUD has no notification path. Do not describe any of
these as Android-hosted UIs, and do not invent a TUD reminder path. The reserved
`CollectionModuleId.time_use_diary` enum entry stays.
