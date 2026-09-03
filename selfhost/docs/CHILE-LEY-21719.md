# Chronicle & Chile's Ley 21.719 (Data Protection)

**Not legal advice.** This summarizes how Chile's data-protection law bears on running a
Chronicle instance, to help you scope the deployment. Confirm every point with your
institution's legal team / Data Protection Officer before collecting real data.

## What the law is

**Ley N° 21.719**, published 13 December 2024, overhauls Chile's personal-data regime along
GDPR lines and creates a data-protection **Agencia**. It **enters into force on
1 December 2026**. It applies to anyone processing the personal data of people in Chile,
regardless of where the servers are.

## The parts that actually shape a Chronicle deployment

### 1. Security duty is risk-based — not a fixed "encrypt everything" rule
The law requires **"medidas técnicas y organizativas apropiadas"** (appropriate technical
and organizational measures) **proportionate to the nature, scope, and risk** of the
processing. Encryption is named as **one example** of an appropriate measure — alongside
**pseudonymization, access control, backups, and periodic evaluation**. There is no clause
mandating transparent database encryption-at-rest specifically.

**Implication for this stack:** you get encryption-at-rest anyway, without the
unrecoverable-key failure mode that usually makes it a hard call. `pg_tde` is enabled by
default, and the SQL dumps stay key-free so a lost key can never strand the data (see
[At-rest encryption](../README.md#at-rest-encryption)). On top of that Chronicle
**pseudonymizes** — sensor/usage rows are keyed by random per-enrollment UUIDs, not names
or RUT — which is itself an explicitly-listed measure. Combined with **TLS in transit**
(Caddy), **access control** on the dashboard, and **off-box backups**, that is a solid
"appropriate measures" posture for pseudonymized research data.

Note the law's standard is risk-based, so encryption is not what makes you compliant here —
it is one listed measure among several. If you would rather manage keys at the platform
layer, set `ENABLE_ENCRYPTION=false` and use OS/volume encryption instead.

### 2. Sensitive data → explicit consent + a DPIA (this you cannot skip)
Health and behavioral data are **datos sensibles**. Processing them requires the
participant's **explicit consent**, and high-risk processing requires a **Data Protection
Impact Assessment** — in Chile, an **Evaluación de Impacto en la Protección de Datos
(EIPD)** — completed **before** collection begins.

**Implication:** Chronicle's per-module consent flow (the app asks the participant to
consent to each data type) supports the consent requirement. The **EIPD is a document you
must produce** — the app can't do it for you.

### 3. Breach notification
Security breaches must be reported to the Agencia **without undue delay (target ~72 hours)**;
high-risk breaches must also be communicated to affected individuals. Have an incident
contact and a written procedure ready.

### 4. Other obligations to check with your DPO
- **Data Protection Officer (DPO)** may be mandatory depending on your organization.
- **Data protection by design and by default** (Chronicle's data-minimizing module toggles
  and pseudonymization help here — collect only the modules the study needs).
- **Data-subject rights** (access, rectification, erasure, portability) and a way to honor
  them.
- **International transfers** if any processor/host sits outside Chile.

## Practical checklist for the deploying team

- [ ] Complete an **EIPD** for the study before enrolling anyone.
- [ ] Confirm the **consent** text in the app meets Chilean "explicit consent" for sensitive data.
- [ ] Enable only the **collection modules the study needs** (data minimization).
- [ ] Turn on **TLS** (automatic with Caddy) and a **dashboard gate** (basic_auth or Keycloak).
- [ ] Enable the **backups overlay**; store copies **encrypted and off-box**.
- [ ] Write a **breach-response** procedure with the ~72h Agencia notification.
- [ ] Check whether a **DPO** is required for your organization.
- [ ] Decide on **at-rest encryption** based on your risk assessment (OS/volume encryption
      preferred over database TDE).

## Sources

Consult the official text for anything you rely on:

- Ley 21.719 overview — Didomi: https://www.didomi.io/regulations/chile
- "Law No. 21.719 explained" — Pandectes: https://pandectes.io/blog/chiles-law-no-21-719-explained-what-businesses-need-to-know/
- Seguridad y notificación de brechas — Confidata: https://confidata.cl/blog/seguridad-notificacion-incidentes-ley-21719
- Guía Ley 21.719 — GRC360: https://www.grc360.cl/blog/ley-21719-proteccion-datos-chile
- Official law text — Biblioteca del Congreso Nacional (BCN): https://www.bcn.cl/leychile
