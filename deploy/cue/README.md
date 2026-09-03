# Chronicle Deployment CUE

This package models infrastructure and Kubernetes deployment constraints that
are awkward to express directly in LinkML.

Source-of-truth split:

- `ontology/chronicle.linkml.yaml` owns Chronicle domain names and shared enum
  values.
- `deploy/cue/chronicle_contracts.gen.cue` is generated from LinkML and
  provides those enum constraints to CUE.
- `deploy/cue/profiles.cue` owns deployment profile sizing, observability
  placement, and Kubernetes resource ceilings.

Regenerate the LinkML-derived CUE file with:

```bash
scripts/generate-chronicle-contracts.py
```

Validate the package and rendered Kubernetes overlays with:

```bash
tests/security/cue-k8s-guardrails.sh /tmp/chronicle-cue-k8s
```
