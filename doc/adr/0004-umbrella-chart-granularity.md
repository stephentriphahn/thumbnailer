# ADR 0004: One umbrella chart per layer; environments are values files

- Status: Accepted
- Date: 2026-11-24

## Context

We need Helm packaging for two layers with different lifecycles: a rarely changing `platform` (AWS emulator, KEDA, External Secrets) and a constantly changing `app` (api, worker, notifier, frontend). We also expect more than one environment over time (local now, real AWS later; dev and staging app environments). An option considered was an umbrella chart per environment (for example `env-stage-platform`, `env-prod-platform`).

## Decision

- One umbrella chart per **layer**, named for the layer: `charts/platform` now, `charts/app` in Phase 5.
- Variation between environments or clusters lives in **values files** (`values-local.yaml` now; `values-aws.yaml` later for platform; `values-dev.yaml` and `values-staging.yaml` for app), not in separate charts.
- `platform` and `app` are separate Helm releases. `platform` contains only dependencies (our own `aws-emulator` chart via `file://`, plus KEDA and External Secrets, all version-pinned). The applications are never added to it.
- `Chart.lock` is committed. Downloaded dependency archives (`charts/*/charts/*.tgz`) are gitignored; CI runs `helm dependency build`.
- Install through a Makefile target (`make platform-up`) so the correct `-f` values file is always passed.

## Consequences

- `platform` is a per-cluster concept, so naming it after a stage (`env-stage-platform`) would mislead: dev and staging share one platform in the local cluster.
- A future real-AWS platform differs by values (`awsEmulator.enabled: false`, real resources), not by a copied chart, so dependency lists cannot drift between environments.
- Promoting a platform dependency bump between environments is done by versioning the chart (or pinning a git revision per environment in Argo CD, Phase 9), not by separate charts.
- `helm upgrade` does not remember earlier `-f` files; omitting one silently reverts to chart defaults. The Makefile target is the guard. `--reuse-values` is avoided.
- Verified: a no-change `helm upgrade platform ...` does not restart the emulator pod, and a KEDA-only change does not either.
- Helm installs CRDs from a chart's `crds/` directory once and does not upgrade them; bumping KEDA or External Secrets versions will need a manual CRD step.
- Open for Phase 5: whether the four services share one `app` release or get one release each (trade-off: independent rollback vs. fewer releases). To be settled in its own ADR.
