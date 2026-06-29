# Programmable Motion Rig — Research Findings

**Purpose.** Pick the hardware + control stack to *physically and reproducibly* stimulate
Chronicle's on-device motion sensors (phones, tablets, standalone research accelerometers)
under full programmatic, no-human-in-the-loop control. The driving constraint: Android
event/wake-up sensors — `significant_motion`, `tilt_detector`, vendor motion sensors
(`samsungMotion`, etc.) — fire only on **real physical movement**, including genuine
**translation** (displacement), which a pure rotation stage cannot produce. This is the
hardware lane that the sensor-collection fix (persistent arming of event sensors) needs a
live test for, and which we currently can't exercise by hand reproducibly.

This was produced by a fan-out / adversarial-verify research pass (5 search angles, 17
sources fetched, 81 claims extracted, 25 verified by 3-vote, 2 refuted). Every claim below
is tagged with its verification outcome. **Cost figures were not verified and are not stated
as findings.**

---

## TL;DR — Ranked recommendation

1. **6- or 7-axis collaborative robot arm** (UFACTORY **xArm 6/7**, or **Universal Robots**
   e-Series) — **primary rig.** The only option that combines *true 6-DOF* (3 translation +
   3 rotation), *human-scale* reach (~700 mm) and payload (~5 kg, fits a phone or most
   tablets + fixture), and a *mature documented host-side API*. Best for reproducing
   human-wear motion at realistic reach to trip wake-up/significant-motion sensors. Cost is
   deprioritized per the brief.
2. **Physik Instrumente H-840 Stewart-platform hexapod** — high-precision secondary rig.
   Genuine 6-DOF including real X/Y/Z translation (±50/±50/±25 mm) over a Python/macro API,
   but the translation envelope is **sub-human-scale** (±50 mm), so it can't reproduce a
   walking stride — good for precise, bounded perturbations, not gross wear motion.
3. **Electrodynamic-shaker controller** (Vibration Research **VibrationVIEW**; Aerotech
   **Automation1**) — the ISO 16063 / NIST-traceable, single-axis **calibration** lane.
   Programmable arbitrary acceleration-waveform replay, but single-axis, not whole-device
   6-DOF pose. Use it for traceable accelerometer calibration, not for tripping pose-based
   wake-up sensors.
4. **Rate / positioning tables** (Ideal Aerosmith 1/2/3-axis) — the inertial-sensor
   calibration *standard*, but **rotation-only**: excluded as the primary rig because they
   cannot produce sustained linear displacement.

**The discriminator** is *translation-envelope × reach × payload × API maturity*. Only the
arm clears all four at human scale.

---

## Technology comparison

| Option | DOF / motion | Reach or travel | Payload | Programmatic API (maturity) | Role |
|---|---|---|---|---|---|
| **UFACTORY xArm 6/7** | Full 6-DOF (3 trans + 3 rot); 7-DOF on xArm 7 | ~700 mm reach, ±0.1 mm repeat. | ~5 kg | `xArm-Python-SDK` `XArmAPI` over TCP: `set_position`/`move_line` (linear), `set_position_aa` (axis-angle), `move_arc`, `set_servo_angle` (joint). **Mature, official, Python.** ✓3-0 | **Primary** |
| **Universal Robots e-Series** | Full 6-DOF | ~850–1300 mm (model-dep.) | 3–16 kg | **URScript** over Primary Interface = motion path (`movej`/`movel`); **RTDE** = telemetry/IO/force readback up to **500 Hz**. Free libs `ur_rtde`, `python-urx`; paid UnderAutomation SDK. **Mature.** ✓3-0 | **Primary (alt.)** |
| **`cri` (vendor-agnostic Python)** | Pose = 6-tuple (x,y,z,α,β,γ) | n/a (abstraction layer) | n/a | One `SyncRobot`/`AsyncRobot` interface over **UR (RTDE)**, **Franka Panda (libfranka/FCI via pyfranka)**, **ABB IRB 120**. `move_linear`/`move_joints`/`move_circular`. ✓3-0 | Control glue |
| **PI H-840 hexapod** | True 6-DOF Stewart platform | **X,Y ±50 mm; Z ±25 mm**; θX,θY ±15°, θZ ±30° (interdependent) | ~varies | **C-887** controller: Cartesian coords, user coordinate systems, on-controller **Python scripts/macros** over USB/Ethernet/EtherCAT, standalone (no pendant). ✓3-0 | Precision secondary |
| **VibrationVIEW (VR shaker)** | Single-axis acceleration | n/a | n/a | COM/ActiveX from **Python/VBA/C#/C++** (PyPI `vibrationview-api`), optional REST; start/stop/pause/resume, sine sweep. **Windows-only.** ✓3-0 | Traceable calibration |
| **Aerotech Automation1** | Stage motion / PVT | n/a | n/a | **.NET/C/Python/LabVIEW** APIs + **AeroScript** `MovePvt`/`MovePt` → arbitrary velocity/accel profiles from user-supplied PVT points. ✓3-0 | Trace-replay primitive |
| **Ideal Aerosmith rate tables** | **Rotation only** (angular pos/rate/accel) | 1/2/3-axis models | n/a | Standard inertial-cal class (MEMS/FOG/RLG/accel; IMU/INS/AHRS); pos. accuracy 30–1 arcsec. ✓3-0 | **Excluded** (no translation) |

---

## Peer-reviewed precedent (confirmed)

- **Gorzelniak L, Dias A, Soyer H, Knoll A, Horsch A. "Using a robotic arm to assess the
  variability of motion sensors." *Stud Health Technol Inform.* 2011;169:897-901.
  PMID 21893876.** ✓3-0 — A programmable robot arm drove the **ActiGraph GT1M**, **ActiGraph
  GT3X**, and **StayHealthy RT3** through two movement sequences to measure inter-device
  variability; explicitly positioned as an alternative to mechanical shakers. Self-described
  feasibility study; devices are research activity monitors, not phones/tablets.
- **Białecka M et al. "Shoulder Range of Motion Measurement Using IMU — Validation with a
  Robot Arm." *Sensors* 2023;23(12):5364. DOI 10.3390/s23125364 (PMC10304346).** ✓3-0 — A
  6-axis **KUKA KR3 R540 AGILUS** (±0.02 mm pose repeatability) was used as *ground truth* to
  validate an RSQ Motion **IMU** over 9 angular positions × 9 repetitions. Note: the protocol
  was **pure rotation**, no translation.
- **ARBot (Chhajed & Guo, WPI, MMSys 2026, arXiv:2602.06273).** ✓3-0 on its 6-DOF coverage
  and motivating premise — a robotic-manipulator teleoperation framework giving natural 6-DOF
  control (end-effector "physically translates in 3D space"), built on the rationale that
  *"human testers cannot reliably reproduce the same motion across multiple trials"* — the
  same reproducibility argument that justifies a robot rig here. **But** see the refuted
  claim below: its "capture-and-replay of human motion" framing did **not** survive
  verification, and its arms (PiPER, OpenManipulator-X) are small/low-payload — fine for a
  phone, marginal for a tablet.

---

## Context resolved: van Hees / GGIR is software-only

**van Hees VT et al., *J Appl Physiol* 117:738-744, 2014 (PMC4187052)** ✓3-0, corroborated by
GGIR `g.calibrate` docs and PMID 25103964: autocalibration is a **purely data-driven,
software** method requiring **no physical calibration rig**. It extracts nonmovement periods
(retained only if SD < 13 mg on all three axes), where the resting vector magnitude should
equal local gravity (1 g), and fits a 3D ellipsoid toward a unit sphere via iterative
closest-point to derive per-axis offset/gain corrections — across four free-living cohorts
(UK/Kuwait/Cameroon/Brazil) with **zero** calibration experiments. GGIR non-wear detection is
likewise algorithmic (SD + value-range thresholds over long windows).

**Implication:** the van Hees papers do *not* describe a motion apparatus — their whole
contribution is *eliminating* the need for one. They belong to the calibration-software stack,
not the controlled-physical-motion validation stack (ISO 16063 shakers, rate tables, robot
arms). If we want to physically exercise wake-up sensors, the hardware answer is the robot
arm; van Hees is the software lane we'd apply to the *resulting* accelerometer data.

---

## Critical caveats (what verification killed or qualified)

- **No turnkey "record-a-human-then-replay."** REFUTED: the xArm SDK does *not* expose
  `record_trajectory`/`playback_trajectory` (0-3); ARBot is *not* a turnkey human-trace
  replay system (1-2). Arbitrary programmatic 6-DOF motion is strongly supported, but
  **reproducible replay of a recorded human-wear trace must be engineered** by streaming the
  trace as a pose/PVT sequence to the chosen API. The one *confirmed* trace-replay primitive
  is **Aerotech `MovePvt`/`MovePt`**; for an arm it means scripting a sequence of
  `set_position`/`move_line` (xArm) or `movel` (URScript) calls from the recorded samples.
  VibrationVIEW *Field Data Replay* exists but is a separate single-axis-shaker feature, not
  whole-device 6-DOF pose replay.
- **No smartphone/tablet-specific published rig.** All surviving precedents validated research
  activity monitors / research IMUs — **not** consumer phones/tablets, and none documents
  tripping Android `significant_motion`/`tilt`/wake-up sensors. Our smartphone case is a
  sound extrapolation from the established method, not a cited result.
- **Existing precedent leans rotational.** The KUKA validation and rate tables are rotation
  only. The translation requirement is our own (correct) physics constraint; the arm/hexapod
  satisfy it, but it isn't demonstrated in the cited papers.
- **Cost (verified retail, June 2026).** Prices pulled and confirmed after the research pass:
  - **Budget tier, under $5K — current (June 2026), turnkey, no self-assembly.** Payload is
    the deciding spec for our **SM-T510 test tablet (469 g)**: a grip fixture adds ~100–250 g
    and brisk motion derates rated payload, so the loaded-and-moving target is ~570–720 g —
    rules out anything rated under ~1 kg.
    - **AgileX PiPER** **$1,999 direct (~$2,499 US resellers)** — 6-DOF, **1.5 kg payload**
      (~2.2× headroom), 626 mm reach, ±0.1 mm, 4.2 kg arm. **Python SDK (`piper_sdk`, PyPI) +
      ROS1/ROS2**, driven over **CAN bus** (USB-CAN adapter). **Ships turnkey/ready-to-use.**
      Current product. **Best fit for the SM-T510 and cheapest.** ⭐
    - **igus ReBeL** — 6-DOF, **2 kg**, 664 mm, ROS/Python, turnkey, ~$5K. ±1 mm repeatability
      (loose, irrelevant for motion-sensor stimulation). More payload headroom.
    - **DOBOT Nova 2** — 6-DOF, **2 kg**, 625 mm, turnkey cobot, Python/TCP API. Proper cobot;
      price runs above $5K.
    - **Elephant myCobot Pro 630** — 6-DOF, **2 kg**, Python, turnkey, ~$5,600–6,999 (the
      *current* Elephant model; the 2022 myCobot 320 / 280 are superseded — do not use).
    - **Avoid:** DOBOT **Magician E6** (only 750 g payload *and* $6,995); UFACTORY **Lite 6**
      (600 g payload — fine for phones, at/over limit for the SM-T510 fixtured + moving);
      xArm 5 Lite (5-DOF only); Annin **AR4** (1.9 kg but ships as a build-it-yourself kit —
      excluded once turnkey is required).
  - **Full-size cobot tier:** UFACTORY **xArm 6** **~$8,849** (arm + AC control box + cables;
    base config "from $5,000"); **xArm 7** **~$10,449**; Universal Robots **UR5e** **~$30–45K**
    arm, **~$60K** as an integrated system with grippers/setup.
  - **Metrology tier (quote-only):** PI **H-840 + C-887** mid-to-high five figures; traceable
    shaker / rate-table systems (VibrationVIEW, Aerotech, Ideal Aerosmith) high five-to-six
    figures.
  - **Verdict:** the **Lite 6 (~$3,299)** does the full programmatic 6-DOF job for ~1/3 the
    xArm 6 price with byte-identical driver code; only payload headroom for heavier tablets
    favors the AR4 or stepping up. The metrology rigs' precision/traceability is unnecessary
    for tripping Android wake-up sensors.
- **Platform constraints.** VibrationVIEW automation is Windows-only (COM/pywin32). Some SDKs
  are paid/licensed (UnderAutomation UR SDK; Aerotech LabVIEW driver), though free UR
  equivalents (`ur_rtde`, `python-urx`) exist. ARBot is a 2026 arXiv preprint — recent, may
  pre-date formal peer review.
- **Payload/reach for tablets.** xArm 6 (~5 kg, ~700 mm) comfortably handles a phone fixture
  and most tablets; confirm the *specific* arm's rated payload covers the heaviest
  fixture+tablet, and design fixturing that rigidly couples device motion to the end-effector
  without resonance artifacts that could confound readings.

---

## Procurement (Rice, via Quartzy)

The PiPER is not a Quartzy catalog SKU, but Quartzy's **non-catalog / custom-order** workflow
handles it (confirmed from Quartzy support docs):

1. Get a PDF quote from a US reseller that stocks the PiPER — **InDro Robotics**, **RoboBuy**
   (US warehouse), **Generation Robots**, or **Roboworks** (Amazon does **not** carry the
   tablet-capable arms — only Elephant's 250 g myCobot 280, which is too small).
2. Quartzy → Lab → **Vendors** → add the reseller manually (Name/URL/Contact).
3. **Add Request** → item name `AgileX PiPER 6-DOF robot arm [see attached quote]`, set vendor
   + unit price, attach the quote → processes as a **non-Quartzy (externally-fulfilled)
   order** through Rice's approval/PO flow.
4. For capital equipment, email **orders@quartzy.com** with the item details / Quote # (starts
   with `EQ`) so Quartzy coordinates with the supplier and places the order.
5. If Rice purchasing uses **Jaggaer/SciQuest**, Quartzy supports handing the order off there.

## Concrete path for Chronicle

1. **Rig:** UFACTORY xArm 6 (or a UR e-Series if one is already on hand) with a printed/clamped
   fixture holding the SM-T510 tablet (and a swappable phone mount).
2. **Driver:** `xArm-Python-SDK` (`XArmAPI`) on the host, or `cri` if we want to stay
   vendor-agnostic across a UR/Franka we might borrow.
3. **Motion source:** take a recorded human-wear acceleration trace (or synthesize walking /
   tilt / pick-up profiles), convert to a kinematically-feasible pose sequence within the
   arm's reach, and **stream it as `set_position`/`move_line` calls** — there is no built-in
   replay, so this is the engineering step.
4. **Validation loop:** run the motion → the tablet's `significant_motion` / `tilt_detector` /
   `samsungMotion` fire → query `android_sensor_data` and confirm the rows that don't exist
   today. This is the reproducible, automatable live test the sensor-collection fix needs.

---

## Open questions

1. Current cost tiers (capex + controller + fixturing) for xArm 6/7 vs a UR e-Series vs PI
   H-840 + C-887 vs a traceable shaker — does the deprioritized-cost brief still favor the arm?
2. Any published peer-reviewed robotic/hexapod rig driving **consumer smartphone/tablet**
   sensors specifically, and tripping Android wake-up/significant-motion events?
3. Cleanest path to convert a recorded human-wear IMU/mocap trace into a streamable pose/PVT
   trajectory (sampling rate, smoothing, kinematic feasibility within reach / the hexapod's
   ±50 mm envelope)?
4. Does the chosen arm's rated payload + end-effector envelope accommodate the heaviest target
   fixture (largest tablet + mount) without resonance artifacts?

---

## Sources

- xArm Python SDK — https://github.com/xArm-Developer/xArm-Python-SDK · https://docs.ufactory.cc/xarm_python_sdk
- UnderAutomation UR SDK — https://github.com/underautomation/UniversalRobots.py · UR RTDE: https://www.universal-robots.com/developer/communication-protocol/rtde
- `cri` vendor-agnostic arm control — https://github.com/jlloyd237/cri · pyfranka: https://github.com/jlloyd237/pyfranka
- PI H-840 hexapod — https://www.physikinstrumente.com/en/products/parallel-kinematic-hexapods/h-840-6-axis-hexapod-700810 · C-887: https://www.pi-usa.us/en/products/6-axis-hexapods-parallel-positioners/c-8873-c-8874-hexapod-motion-controller
- Ideal Aerosmith rate tables — https://www.ideal-aerosmith.com/products/1-2-or-3-axis-rate-and-positioning-tables/
- VibrationVIEW automation — https://vibrationresearch.com/vibrationview/automation/ · https://pypi.org/project/vibrationview-api
- Aerotech Automation1 APIs — https://www.aerotech.com/product/automation1-apis/ · https://help.aerotech.com/automation1/Content/APIs/Overview-APIs.htm
- Gorzelniak et al. 2011 — https://pubmed.ncbi.nlm.nih.gov/21893876/
- Białecka et al. 2023 (IMU vs KUKA) — https://www.ncbi.nlm.nih.gov/pmc/articles/PMC10304346/ · https://doi.org/10.3390/s23125364
- ARBot — https://arxiv.org/abs/2602.06273
- van Hees autocalibration 2014 — https://www.ncbi.nlm.nih.gov/pmc/articles/PMC4187052/ · https://pubmed.ncbi.nlm.nih.gov/25103964/
- ISO 16063 accelerometer calibration — https://www.modalshop.com/calibration/learn/standards/iso-16063/accelerometer-calibration
- Android sensor types — https://source.android.com/docs/core/interaction/sensors/sensor-types
