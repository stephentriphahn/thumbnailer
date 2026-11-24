# ADR 0003: Publish the emulator CA with a shell-script sidecar

- Status: Accepted
- Date: 2026-11-23

## Context

The emulator generates a new TLS certificate on every start and writes `ca.pem` into its pod-local volume. Clients (CLI, services, Terraform, External Secrets, KEDA) must trust the current certificate, so it has to be published somewhere other pods can read it.

## Decision

Run a small sidecar container (`ca-publisher`) in the emulator pod. It shares the `emptyDir` that holds `ca.pem`, polls the file every 2 seconds, and when its SHA-256 changes it creates or updates the `aws-emulator-ca` ConfigMap (key `ca.pem`) with `kubectl create --dry-run | apply`.

- Implemented as a POSIX shell script (`images/ca-publisher/publish.sh`) in a minimal Alpine image with the `kubectl` package. The official `registry.k8s.io/kubectl` image has no shell, and we avoid third-party images.
- Polling and comparing a checksum (not publishing once at startup) also handles a container-only restart, where the volume survives and the old `ca.pem` lingers until overwritten.
- RBAC: a dedicated ServiceAccount and a Role limited to ConfigMap `aws-emulator-ca` (`get`, `patch`), plus an unrestricted `create`, because `create` cannot be restricted by resource name.
- The sidecar has equal requests and limits so the pod remains `Guaranteed` QoS.

## Consequences

- A second image to build and load per cluster (tagged and versioned; bumping it means editing `values.yaml` and upgrading, which restarts the emulator because the strategy is `Recreate`).
- The ConfigMap is created by the sidecar, not by Helm. Helm does not track it, so `helm uninstall` leaves it behind.
- Failure handling: the publish step only advances its "last published" checksum when `apply` succeeds, so a transient failure (for example missing RBAC) is retried every 2 seconds.
- Lesson learned: a missing `serviceAccountName` silently runs the pod as `default`, which fails with `Forbidden`. `kubectl auth can-i --as=system:serviceaccount:<ns>:<sa>` tests a Role without redeploying.
- Alternatives not chosen: a program in another language (more build machinery for ~15 lines of logic), and a manual `kubectl exec ... cat` step (breaks every client after each restart).
