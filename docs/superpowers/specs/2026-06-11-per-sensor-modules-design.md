# Per-Sensor Collection Modules — Design (2026-06-11)

## Summary

Each hardware sensor becomes its own first-class collection module. The study marks each
sensor **Required / Optional / Unavailable** with its **own sampling rate + duty cycle**;
the participant consents to each sensor individually, exactly like an App & Device Usage
module. There is no grouped "Hardware Sensors" toggle anywhere user- or study-facing. The
former `hardware_sensors` umbrella module is retired.

This supersedes the "no per-sensor opt-out (module-level only)" model — sensors are now the
same kind of thing as `usage_events` / `battery_telemetry`, riding the existing per-module
consent machinery (state machine, `CollectionGate`, Data Sharing rows, study form) rather
than a parallel mechanism.

## Model (chronicle-models)

- `CollectionModuleId` gains 14 active sensor modules — one per `AndroidSensorType`:
  `sensor_accelerometer`, `sensor_gyroscope`, `sensor_magnetometer`, `sensor_gravity`,
  `sensor_linear_acceleration`, `sensor_rotation_vector`, `sensor_step_counter`,
  `sensor_light`, `sensor_proximity`, `sensor_significant_motion`, `sensor_tilt_detector`,
  `sensor_screen_orientation`, `sensor_samsung_grip_wifi`, `sensor_samsung_motion` — all
  `PHYSICAL_TELEMETRY`, `active=true`.
- `HARDWARE_SENSORS` is retired to `active=false`: never registered, gated, offered, or
  written afresh — kept only so legacy persisted settings/acknowledgments containing
  `"hardware_sensors"` still deserialize via `fromId`.
- `SensorCollectionModules` is the single source of truth for the `AndroidSensorType ↔
  CollectionModuleId` bijection (`moduleFor`, `sensorTypeOf`, `sensorModuleIds`).
- **State**: `Required` = `enabled && required`; `Optional` = `enabled && !required`;
  `Unavailable` = `!enabled`.
- **Per-sensor sampling** rides `CollectionModuleSetting.sensorPolicy` (reuses
  `AndroidSensorSetting`): each sensor module carries its own `samplingRateHz` +
  `dutyCycleActiveSeconds` + `dutyCyclePeriodSeconds`, defaulting to the legacy
  **5 Hz / 30 s / 300 s**. `CollectionDefaults.moduleSetting` seeds a sensor module's
  default policy with its single owning sensor.
- **Legacy bridge**: `AndroidDataCollectionSetting.fromLegacy` maps each sensor named in a
  legacy `AndroidSensor` setting to its per-sensor module (carrying the legacy study-wide
  rate/duty), instead of the old single `hardware_sensors` entry.

## Consent + gate (chronicle / collection-core)

- `CollectionStateMachine.ACK_GATED_MODULES` = `{usage_events, device_lifecycle,
  user_identification, battery_telemetry} + SensorCollectionModules.sensorModuleIds`, so
  each sensor runs the full required/optional/unavailable lifecycle independently.
- `CollectionSettingsResolver` accepts a `sensorPolicy` on any per-sensor module (not just
  `hardware_sensors`).

## Runtime (chronicle / app + collection-sensors + collection-base)

- One shared `HardwareSensorService` still hosts collection; it runs while **any** sensor
  module collects and stops when none do. Each sensor is gated by **its own**
  `CollectionGate.collects(ctx, sensorModule)` — at registration and per-sample on flush.
- `SensorRuntimeController` runs an **independent per-sensor duty-cycle loop** at each
  sensor's own rate/period (was one shared loop); `SensorGateway` gains per-sensor
  continuous teardown (`unregisterContinuousSensor`).
- `SensorSettings` caches per-sensor rate/duty (written from the resolved DataCollection
  per-sensor modules by `CollectionLoopCoordinator.sync`). The old local per-sensor opt-in
  store is removed — consent lives in `CollectionLoopStore` / `CollectionGate`.
- `CollectionModules` registry drops `hardware_sensors`; sensor modules are
  service-realized (like `usage_events`), not registered `DataCollectionModule` singletons.

## Surfaces

- **Web study form** (`chronicle-web`): each sensor renders as a Data Collection module
  card with Required/Optional + **editable** sampling-rate / duty-active / duty-period
  inputs (`COLLECTION_MODULES` gains the 14 sensor descriptors with a `sensorType`;
  `study-form-helpers` writes each sensor's `sensorPolicy`).
- **Mobile** (`DataSharingFragment`): each sensor is its own row — toggle (optional) or
  locked (required), with its study-set Hz/duty shown **read-only**. Toggling a sensor
  accepts/declines just that sensor module via the same path the usage modules use.
- **API** (`chronicle.yaml`): the 14 sensor ids are added to the `CollectionModuleId`
  enum; web types regenerated.

## Also in this change

- The legacy `SettingsActivity` (old per-sensor preference screen) is deleted; both
  foreground-service notifications now open `MainActivity` → Data Sharing tab.

## Verification

Run CI locally (GitHub Actions is infra-broken on these repos):
`:chronicle-models:test`, `:collection-*`/`:app:testDebugUnitTest`, `:chronicle-server:test`,
web `bun run check`, and the security ast-grep `collection-module-id-no-raw-string` rule —
all green. On-device QA of the per-sensor Data Sharing rows + collection is pending a device
unlock.
