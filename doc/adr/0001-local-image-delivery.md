# ADR 0001: How locally built images reach the cluster

- Status: Accepted
- Date: 2026-11-17

## Context

The local cluster is Docker Desktop Kubernetes in **kind mode** (2 nodes: `desktop-control-plane`, `desktop-worker`, containerd runtime). We build service images with `docker build` and want to run them with `imagePullPolicy: IfNotPresent` and no registry.

Initially Docker used the classic `overlay2` image store. A pod pinned to each node with image `local-test:0.1` failed with `ErrImagePull`: the node qualified the name as `docker.io/library/local-test:0.1`, tried Docker Hub, and got `repository does not exist` / `insufficient_scope`. The node's containerd could not see images in Docker's store.

## Decision

Enable Docker Desktop's **"Use containerd for pulling and storing images"** setting (storage driver `overlayfs`, `driver-type: io.containerd.snapshotter.v1`) and use locally built images directly, with explicit non-`latest` tags and `imagePullPolicy: IfNotPresent`.

Verified: after enabling it and rebuilding the image, pods pinned to both nodes ran the local image.

## Consequences

- No local registry is needed for now, so there is one less moving part.
- Toggling the setting switches image stores. Images built under the old store are not visible in the new one (they are not deleted), so images must be rebuilt after a switch.
- Never use the `latest` tag: Kubernetes defaults it to `imagePullPolicy: Always`, which hides this behaviour and tries to pull.
- This path does not teach the registry workflow (push, pull secrets, ECR). Phase 8 pushes to GHCR, and a real-AWS deployment would use ECR. If we want that practice earlier, add a local `registry:2` as a follow-up ADR.
- CI (kind in a runner) does not share Docker's store, so CI images must be loaded with `kind load docker-image` or pushed to a registry. Revisit this in Phase 8.
