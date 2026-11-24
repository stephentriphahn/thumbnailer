# Pet Project: Event-Driven File Pipeline on Local Kubernetes + AWS Emulator

## Goal

Build a small file-processing pipeline (upload → queue → process → notify) as a way to learn:

- **Helm** — charts, umbrella/library charts, per-environment values, hooks, upgrades/rollbacks
- **Multiple AWS services** — S3, SQS, SNS, DynamoDB, Secrets Manager / SSM (and Lambda / Step Functions / EventBridge if the emulator supports them)
- **Terraform** — the same modules for local (emulator) and, later, real AWS
- **CI/CD** — GitHub Actions, then GitOps with Argo CD

All of it runs locally: **Docker Desktop Kubernetes** plus the **AWS Emulator**
(https://docs.aws.amazon.com/emulator/latest/userguide/what-is-service.html).

The product itself doesn't matter; pick a flavor (thumbnailer, receipt text extractor, meme generator). Only the worker's processing step changes.

---

## Working agreement

This is a **learning project**, so the process matters as much as the result.

- **Hands-on, not hands-off.** The owner is directly involved in development: writing code, building, running and testing it. Claude Code pairs, explains and reviews. It doesn't build whole services unattended.
- **Phases are split into slices.** Before starting a phase, plan its slices together. A slice is a small, bite-sized chunk with:
  - a clear **validation path** (a command or test that shows it works), and
  - enough change to do real testing, not just scaffolding.
- **ADRs and design notes per phase.** Record decisions in `doc/adr/NNNN-title.md` (context, decision, consequences) and write a short design note in `doc/design/` when a phase begins or ends. Emulator results and gotchas go in `doc/findings.md`.
- **Monorepo.** Apps, Helm charts, Terraform, CI and docs all live in this one repo. Services are still separate deployments with their own images, Helm subcharts and scaling rules (the worker scales on queue depth, the api on CPU or requests, and so on).
- **Polyglot by design, decided per service.** Languages are not fixed up front. When we reach each service (api, worker, notifier, frontend), choose its language then and record an ADR. Evaluate each choice on what it teaches (build, test, dependency and container workflow) and how it handles the emulator's CA bundle.
- **Product: thumbnailer.** The worker is a **swappable processing step**. Keep the queue message contract and the DynamoDB/S3 conventions generic (`{id, key}` in, an output key and status out), and isolate the thumbnail logic behind a small interface, so a different processor (receipt text extraction, etc.) can replace it without touching the api, notifier, or charts.
- **Environment:** Docker Desktop Kubernetes locally, kind in CI. The repo is a git repo (initialized).

## Notes for whoever executes this plan (Claude Code)

- Work **one phase at a time**. Don't start the next phase until the current phase's **Done when** checks pass.
- Several things below are **unverified assumptions** (marked ⚠️ VERIFY). Check each one early, write down what you find in `doc/findings.md`, and change the plan if one turns out wrong.
- Prefer small, working increments over scaffolding everything up front.
- Keep a `Makefile` (or `justfile`) as the single entry point for common commands.

---

## Architecture

```
 frontend ──► api ──► S3 (uploads bucket)
               │
               └──► SQS (jobs queue) ──► worker (KEDA-scaled)
                                           │  ├─► S3 (processed bucket)
                                           │  ├─► DynamoDB (items table)
                                           │  └─► SNS (job-complete topic)
                                           │             │
                                           │             └─► SQS (notify queue) ──► notifier
                                           │
 Secrets Manager / SSM ──► External Secrets Operator ──► k8s Secrets (config for all apps)
```

v1 deliberately avoids the integrations that are less likely to be emulated well (S3 event notifications, Lambda execution). The **api sends the SQS message itself** after an upload, and the **notifier is a k8s consumer** instead of a Lambda. Add those integrations back in the stretch phase if the emulator supports them.

### Two Helm releases with separate lifecycles

| Release | Contents | How often it changes |
|---|---|---|
| `platform` (namespace `platform`) | AWS Emulator, KEDA, External Secrets Operator, later Argo CD | Rarely |
| `app` (namespaces `app-dev`, `app-staging`) | api, worker, notifier, frontend | Constantly |

Upgrading, rolling back, or uninstalling `app` must **never** restart the emulator. The emulator keeps all its state in memory, so a restart wipes every resource and also generates a new TLS certificate.

---

## Repo layout (target)

```
.
├── Makefile
├── doc/
│   ├── 001-overview.md          # this plan
│   ├── adr/                     # architecture decision records (NNNN-title.md)
│   ├── design/                  # per-phase design notes
│   └── findings.md              # emulator fidelity results, decisions, gotchas
├── emulator/
│   └── Dockerfile               # builds the AWS Emulator image
├── apps/
│   ├── api/
│   ├── worker/
│   ├── notifier/
│   └── frontend/
├── charts/
│   ├── aws-emulator/            # our own chart for the emulator
│   ├── platform/                # umbrella: aws-emulator + keda + external-secrets
│   ├── app-lib/                 # library chart: shared templates (deployment, socat sidecar, AWS env)
│   └── app/                     # umbrella: api, worker, notifier, frontend
│       ├── values.yaml
│       ├── values-dev.yaml
│       └── values-staging.yaml
├── terraform/
│   ├── modules/pipeline/        # buckets, queues, topic, table, params, secrets
│   └── envs/
│       ├── local/               # provider pointed at emulator, local backend
│       └── aws/                 # (later) real AWS provider + S3 backend
├── scripts/
│   ├── emulator-ca.sh           # copy ca.pem out of the emulator pod
│   └── port-forward.sh
└── .github/workflows/
```

---

## Phase 0 — Prerequisites and decisions

- [ ] Turn on Kubernetes in Docker Desktop. Install `kubectl`, `helm`, `terraform`, `aws` (CLI v2), and `jq`.
- [ ] **Languages are chosen per service, when we reach it** (see Working agreement), not up front. Reference for the choice: Python (boto3) and Go (SDK v2) read `AWS_CA_BUNDLE` with no extra setup. Node needs `NODE_EXTRA_CA_CERTS`. Java needs a truststore. Record each choice as an ADR.
- [ ] Decide how images reach the cluster.
  - ⚠️ VERIFY: whether Docker Desktop's Kubernetes can use images built locally with `imagePullPolicy: IfNotPresent`. This depends on the cluster mode (kubeadm vs. kind-based). If it can't, run a local registry (`registry:2` on `localhost:5000`).
- [ ] Create the repo with the layout above (empty directories are fine), plus `doc/findings.md`.

**Done when:** `kubectl get nodes` shows a ready node, and the tools are installed.

---

## Phase 1 — Emulator image + check what it supports

1. [ ] Write `emulator/Dockerfile` following https://docs.aws.amazon.com/emulator/latest/userguide/getting-started-docker.html. It's based on `amazonlinux:2023-minimal`, installs the RPM (x86_64 or aarch64 for your CPU), has `ENTRYPOINT ["aws-emulator", "-b", "0.0.0.0"]`, runs as `USER 1000`, and has `EXPOSE 9297`.
2. [ ] Build it, tagged with the emulator version (for example `aws-emulator:<version>`). **Never use `latest`.**
3. [ ] Run it on the host as the docs show (`-p 127.0.0.1:9297:9297`, mount `~/.aws/emulator`). Then set the SDK environment variables from https://docs.aws.amazon.com/emulator/latest/userguide/point-sdk-to-emulator.html and check:
   - `aws sts get-caller-identity` → account `000000000000`
   - `curl --cacert ~/.aws/emulator/9297/ca.pem https://127.0.0.1:9297/__admin/health` → `ok`
4. [ ] **Check which services work.** By hand, run the operations this project needs against the emulator and record the results in `doc/findings.md`:
   - S3: CreateBucket, PutObject, GetObject, ListObjectsV2, presigned PUT
   - SQS: CreateQueue, SendMessage, ReceiveMessage (long polling), DeleteMessage, redrive policy / DLQ
   - SNS: CreateTopic, Subscribe (SQS protocol), Publish → **does the message actually arrive in the SQS queue?**
   - DynamoDB: CreateTable, PutItem, GetItem, Query
   - Secrets Manager: CreateSecret, GetSecretValue. SSM: PutParameter, GetParameter(s)ByPath
   - Stretch candidates: S3 event notifications → SQS, Lambda Invoke (does code actually run?), EventBridge rules, Step Functions
   - Compare with the fidelity scores on the releases page (https://github.com/aws/aws-emulator/releases) and `manifest.jsonl` in https://github.com/aws/aws-emulator-evaluation-suite
5. [ ] If **SNS → SQS delivery doesn't work**, change the design: the worker sends to the notify queue directly. Write the decision in `findings.md`.

**Done when:** the image builds, the health check passes, and `findings.md` has a supported / unsupported table for every operation above.

---

## Phase 2 — Emulator in Kubernetes (the `platform` release)

### `charts/aws-emulator`

- [ ] A Deployment with `replicas: 1` and `strategy: Recreate`.
- [ ] Container args: `-b 0.0.0.0 -p 9297 --auth off`. Turning auth off means clients can use dummy keys, so the per-run credentials file doesn't have to be shared.
- [ ] Set `HOME` to a writable path (for example `/home/emulator`) and mount an `emptyDir` at `$HOME/.aws`, so the emulator can write `ca.pem`.
- [ ] Set memory requests/limits with some headroom. The docs run it with `--memory=2g` and no swap. An OOM kill means losing all state.
- [ ] Readiness/liveness probes: `httpGet` on `/__admin/health`, port 9297, `scheme: HTTPS`. The kubelet doesn't verify the certificate, so a self-signed cert is fine.
- [ ] A ClusterIP Service on port 9297.
- [ ] **Publishing the CA certificate:** add a small sidecar in the emulator pod that waits for `$HOME/.aws/emulator/9297/ca.pem` on the shared volume, then creates or updates a ConfigMap `aws-emulator-ca` (key `ca.pem`) with `kubectl`. This needs a ServiceAccount plus a Role/RoleBinding that can get/create/patch that one ConfigMap.
  - The cert changes **every time the emulator starts**, so the sidecar must update the ConfigMap on every pod start.
- [ ] Add the `helm.sh/resource-policy: keep` annotation to the Service and the CA ConfigMap.
- [ ] Turn telemetry off (`-t off`) if you prefer.

### `charts/platform` (umbrella)

- [ ] Dependencies in `Chart.yaml`: `aws-emulator` (local path, `condition: awsEmulator.enabled`), `keda`, `external-secrets`. Pin every version.
- [ ] Install: `helm upgrade --install platform charts/platform -n platform --create-namespace`

### Scripts / Makefile targets

- [ ] `make emulator-forward` runs `kubectl -n platform port-forward svc/aws-emulator 9297:9297`
- [ ] `make emulator-ca` copies the ConfigMap's `ca.pem` to `.emulator/ca.pem` (gitignored)
- [ ] `make emulator-env` prints the `export` lines for host tools: `AWS_ENDPOINT_URL=https://127.0.0.1:9297`, `AWS_CA_BUNDLE=.emulator/ca.pem`, `AWS_ACCESS_KEY_ID=local`, `AWS_SECRET_ACCESS_KEY=local`, `AWS_REGION=us-east-1`, `AWS_DEFAULT_REGION=us-east-1`, `AWS_EC2_METADATA_DISABLED=true`, `AWS_DISABLE_HOST_PREFIX_INJECTION=true`

**Done when:**
- With the port-forward running, `aws sts get-caller-identity` and `aws s3 ls` work from the host.
- Deleting the emulator pod → the new pod comes up → the ConfigMap holds the **new** CA.
- `helm upgrade platform ...` with no value changes does **not** restart the emulator pod (check the pod age).

---

## Phase 3 — Terraform for local AWS resources

Use the host + port-forward approach first. Endpoint `https://127.0.0.1:9297` matches the S3 requirement (`127.0.0.1`, not `localhost`) and probably the certificate's hostname.

- [ ] Write `terraform/envs/local/providers.tf`:

```hcl
provider "aws" {
  region     = "us-east-1"
  access_key = "local"
  secret_key = "local"

  custom_ca_bundle            = "${path.root}/../../../.emulator/ca.pem"
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3             = "https://127.0.0.1:9297"
    sqs            = "https://127.0.0.1:9297"
    sns            = "https://127.0.0.1:9297"
    dynamodb       = "https://127.0.0.1:9297"
    secretsmanager = "https://127.0.0.1:9297"
    ssm            = "https://127.0.0.1:9297"
    sts            = "https://127.0.0.1:9297"
  }
}
```

- [ ] Use a local backend (`terraform.tfstate` in `envs/local`, gitignored). **Never** store state in an S3 bucket inside the emulator, because a reset would wipe the state too.
- [ ] Build `modules/pipeline` **one resource at a time**, running `terraform apply` after each:
  1. SQS `jobs` queue + `jobs-dlq` with a redrive policy
  2. DynamoDB `items` table
  3. S3 `uploads` and `processed` buckets. S3 is the most likely to fail, because Terraform reads ACL, versioning, CORS, etc. on every refresh.
  4. SNS `job-complete` topic + SQS `notify` queue + subscription (only if Phase 1 showed delivery works)
  5. SSM parameters under `/pipeline/local/...` (queue URLs, bucket names, table name, topic ARN)
  6. One Secrets Manager secret (for example a fake third-party API key) so External Secrets has something to sync
- [ ] When something fails, run `TF_LOG=debug terraform plan` to find the failing API call, check it against the fidelity scores, and log it in `findings.md`. Work around it (leave out that resource argument, or create the resource with the CLI instead).
- [ ] Add `make tf-local` (copy the CA, then `terraform apply` in `envs/local`).

**Done when:**
- `terraform apply` succeeds, and running it a second time shows **no changes**.
- **Reset test:** delete the emulator pod, wait for it to be ready, run `make emulator-ca && make tf-local`. Everything comes back without deleting the state file. (When the provider gets "not found" on refresh, it drops the resource from state and recreates it. If the emulator's errors don't match AWS, fall back to deleting the state, and note it in `findings.md`.)

---

## Phase 4 — Application services (v1), run on the host first

Run each service on your machine against the port-forwarded emulator before containerizing it. Use the env vars from `make emulator-env`. The code should **never** hard-code endpoints or credentials. It relies on the standard SDK environment variables only, so it works unchanged against real AWS.

- [ ] **api**
  - `POST /uploads`: takes a file (multipart), puts it in `uploads/`, writes a DynamoDB item (`status=PENDING`), sends an SQS message `{id, key}`
  - `GET /items` and `GET /items/{id}`: read from DynamoDB
  - `GET /healthz`
  - Uploads go **through the API**, not presigned URLs. A presigned URL would point at `https://127.0.0.1:9297` with the emulator's self-signed cert, which the browser won't trust. Presigned uploads are a stretch goal.
- [ ] **worker**
  - Long-polls `jobs`, downloads the object, processes it, writes to `processed/`, updates DynamoDB (`status=DONE`, output key), publishes to SNS (or sends to `notify` directly, if Phase 1 showed SNS → SQS doesn't work), deletes the message
  - Lets failures retry, so messages end up in the DLQ after N attempts
  - Shuts down cleanly on SIGTERM (finish the current message)
- [ ] **notifier**: long-polls `notify` and logs the "notification". Later it could call SES or a webhook.
- [ ] **frontend**: a minimal page with an upload form and a list of items with their status. It talks to the api only.
- [ ] Config (queue URLs, bucket names, etc.) comes from **environment variables**. Locally, fill them from Terraform outputs.

**Done when:** an upload on the host flows all the way through, and the item reaches `DONE` with the notifier logging it.

---

## Phase 5 — Helm charts for the apps

### `charts/app-lib` (library chart)

- [ ] A shared Deployment template (image, resources, probes, env, securityContext)
- [ ] A shared **AWS client setup** helper that every AWS-calling pod includes:
  - A **socat sidecar** listening on `127.0.0.1:9297` and forwarding to `aws-emulator.platform.svc.cluster.local:9297`. This keeps the hostname `127.0.0.1`, which S3 requires and the cert most likely covers. ⚠️ VERIFY first whether pointing straight at the Service DNS name works; if it does, drop the sidecar.
  - Mounts the `aws-emulator-ca` ConfigMap. Because that ConfigMap lives in the `platform` namespace, copy it into each app namespace (with the Phase 2 sidecar, a small Job, or the `reflector` controller). ⚠️ Decide which and record it.
  - Env: `AWS_ENDPOINT_URL=https://127.0.0.1:9297`, `AWS_CA_BUNDLE=/etc/aws-emulator/ca.pem`, dummy keys, `AWS_REGION`, `AWS_EC2_METADATA_DISABLED=true`, `AWS_DISABLE_HOST_PREFIX_INJECTION=true`
  - Everything behind `awsEmulator.enabled`, so a real-AWS values file turns it off completely
- [ ] **Restarting when the CA changes:** pods must restart when the emulator's CA changes. Pick one:
  - Stakater **Reloader** (annotate Deployments to watch the CA ConfigMap) — simplest
  - A `checksum/emulator-ca` pod annotation computed with Helm's `lookup`. Note that `lookup` returns nothing during `helm template` and dry-runs.

### `charts/app` (umbrella)

- [ ] Subcharts: api, worker, notifier, frontend. Each depends on `app-lib`.
- [ ] `values.yaml` (defaults), `values-dev.yaml`, `values-staging.yaml` (different replica counts, resources, image tags, SSM prefix)
- [ ] An Ingress or NodePort for the frontend and api
- [ ] A `pre-install,pre-upgrade` **hook Job** that checks the AWS resources exist (for example `aws dynamodb describe-table`) and fails with a clear message ("run make tf-local") if they don't
- [ ] Install into two namespaces:
  ```
  helm upgrade --install app charts/app -n app-dev -f charts/app/values-dev.yaml --create-namespace --atomic
  helm upgrade --install app charts/app -n app-staging -f charts/app/values-staging.yaml --create-namespace --atomic
  ```

### Helm practice exercises

- [ ] Change an image tag → `helm upgrade` → watch the rolling update
- [ ] Deploy a deliberately broken image with `--atomic` → watch it roll back automatically
- [ ] `helm history` / `helm rollback`
- [ ] `helm diff` (plugin) before upgrades
- [ ] Confirm that none of the above restarts the emulator

**Done when:** end-to-end upload works in both `app-dev` and `app-staging`, and the exercises above all behave as expected.

---

## Phase 6 — Observability (metrics + OpenTelemetry)

Placed before KEDA so the Phase 7 load test can be watched on a dashboard.

- [ ] Add `kube-prometheus-stack` (Prometheus, Alertmanager, Grafana) to the `platform` release. Pin the version.
- [ ] **Metrics:** each service exposes `/metrics` (Prometheus format) with a `ServiceMonitor` in the app chart. Cover RED metrics for the api, and for the worker: jobs processed, failures, processing duration, and in-flight messages.
- [ ] **Queue metrics:** queue depth and age of the oldest message. ⚠️ VERIFY whether CloudWatch metrics exist in the emulator. If not, export queue depth from a small exporter or from the worker itself.
- [ ] **OpenTelemetry:** add an OTel Collector to the platform (DaemonSet or Deployment). Instrument each service with its language's OTel SDK, using traces and metrics over OTLP. Propagate trace context through the SQS message attributes, so one upload is a single trace from api to worker to notifier. Send traces to Tempo or Jaeger, and metrics either through the Collector to Prometheus or by scraping.
- [ ] Structured JSON logs carrying the trace ID, collected with Loki or by reading `kubectl logs`.
- [ ] Grafana dashboards (committed as code in the chart): queue depth vs. worker replicas, processing time percentiles, error rate. Alerts for DLQ depth > 0 and a stalled queue.
- [ ] ADR: Prometheus scrape vs. OTLP push for metrics, and the choice of trace backend.

**Done when:** one upload shows as a single trace across api → worker → notifier, a Grafana dashboard shows queue depth and processing time while a script floods the queue (worker replicas are added to the same dashboard in Phase 7 once KEDA is in), and a DLQ alert fires when a poison message is sent.

---

## Phase 7 — External Secrets + KEDA

### External Secrets Operator

- [ ] Create a `ClusterSecretStore` using the AWS provider (SSM Parameter Store and Secrets Manager), pointed at the emulator.
  - ⚠️ VERIFY: ESO's AWS provider needs a **custom endpoint** and **custom CA** to reach the emulator. Check whether it supports both (provider settings, or the `AWS_ENDPOINT_URL` / `AWS_CA_BUNDLE` env vars on the ESO controller set via Helm values, plus a socat sidecar on the controller if needed).
  - Fallback if it can't: render `/pipeline/<env>/...` from Terraform outputs into a values file, and note that ESO only gets used against real AWS.
- [ ] Add an `ExternalSecret` per app namespace that syncs `/pipeline/<env>/*` into a k8s Secret, and change the charts to use `envFrom` with it instead of hard-coded values.

### KEDA

- [ ] Add a `ScaledObject` for the worker with the `aws-sqs-queue` scaler (target queue length, min 0 or 1, max ~10).
  - ⚠️ VERIFY: the KEDA operator must reach the emulator with a custom endpoint and trust its CA. Check the scaler's endpoint setting and how to give the KEDA operator pod the CA (and the socat sidecar, if needed).
  - Fallback: a CPU-based HPA. Note the limitation in `findings.md`.
- [ ] Load test: upload ~500 files with a script and watch the worker scale up and back down.

**Done when:** app config comes from ESO (or the documented fallback), and the worker scales on queue depth (or the documented fallback).

---

## Phase 8 — CI with GitHub Actions

- [ ] **`emulator-image.yml`**: build the emulator image for amd64 + arm64 (buildx) and push to GHCR as `ghcr.io/<you>/aws-emulator:<version>`. Run it on a schedule or manually; optionally open a PR that bumps the version in the platform chart's values when a new AWS Emulator release appears.
- [ ] **`ci.yml`** on PRs:
  - Lint and test each app
  - `helm lint`, `helm template | kubeconform`, chart-testing (`ct lint`)
  - `terraform fmt -check`, `terraform validate`
  - Build app images (push only on main)
- [ ] **`integration.yml`**: create a **kind** cluster in the runner → install the `platform` chart → port-forward → run `terraform apply` (envs/local) → install the `app` chart → run an end-to-end test script (upload → poll until `DONE`) → collect logs if it fails.
- [ ] Switch the charts to images from GHCR, tagged with the git SHA.

**Done when:** a PR runs lint and the integration test automatically, and merging to main publishes images.

---

## Phase 9 — GitOps with Argo CD

- [ ] Add Argo CD to the platform release (or install it separately).
- [ ] App-of-apps: a root Application → `platform`, `app-dev`, `app-staging` Applications pointing at the charts in the repo.
- [ ] Promotion flow: CI updates the image tag in `values-dev.yaml` with a commit or PR → Argo CD syncs dev → a PR that copies the tag to `values-staging.yaml` promotes it.
- [ ] Optional: Argo CD Image Updater instead of commits from CI.
- [ ] Optional: run the Terraform apply as an Argo CD PreSync hook Job (in-cluster Terraform: socat sidecar + CA ConfigMap), so an emulator reset fixes itself on the next sync.

**Done when:** merging a PR deploys to dev with no manual `helm` commands, and promoting to staging is a PR.

---

## Stretch ideas

- [ ] Replace the api → SQS message with **S3 event notifications → SQS**, if the emulator supports it
- [ ] Replace the notifier with a **Lambda** subscribed to SNS, if Lambda execution works
- [ ] A **Step Functions** workflow (validate → process → notify), or **EventBridge** rules for routing
- [ ] **Presigned uploads** from the browser (requires trusting the emulator CA in the browser, or an in-cluster proxy)
- [ ] NetworkPolicies, PodSecurity standards, resource quotas per namespace
- [ ] `terraform/envs/aws` + a `values-aws.yaml` deploying to real AWS (IAM/IRSA will need real work there, because the emulator doesn't enforce IAM policies; watch costs)

---

## Gotchas reference

| Gotcha | Mitigation |
|---|---|
| Emulator state is in memory; a pod restart wipes everything | Separate `platform` release, `Recreate`, pinned image, memory headroom, idempotent `make tf-local` |
| TLS cert regenerates on every start | Sidecar publishes `ca.pem` to a ConfigMap; Reloader or checksum restarts app pods |
| S3 requires `127.0.0.1`, not `localhost`, in the endpoint | Port-forward on the host; socat sidecar in pods; `s3_use_path_style = true` in Terraform |
| Cert likely only valid for `127.0.0.1` (⚠️ VERIFY) | socat sidecar so clients always connect to `127.0.0.1:9297` |
| Some SDKs add host prefixes (`data-127.0.0.1`) | `AWS_DISABLE_HOST_PREFIX_INJECTION=true` (only for emulator use) |
| Real AWS creds in env override emulator config | Always set dummy keys explicitly; `AWS_EC2_METADATA_DISABLED=true` |
| One region / one account per emulator | Use `us-east-1` everywhere locally |
| IAM policies aren't enforced | Don't rely on the emulator for permission testing; expect IAM work when moving to real AWS |
| Terraform makes many read calls (especially S3) | Add resources one at a time; `TF_LOG=debug` to find the unsupported call |
| Data-plane features and integrations between services vary | Phase 1 checks; v1 design avoids S3 events and Lambda |
| Emulator isn't tested for long-running use | Expect occasional resets; make recovery a single command |

## Reference docs

- What is AWS Emulator: https://docs.aws.amazon.com/emulator/latest/userguide/what-is-service.html
- Docker setup: https://docs.aws.amazon.com/emulator/latest/userguide/getting-started-docker.html
- Pointing SDKs at the emulator: https://docs.aws.amazon.com/emulator/latest/userguide/point-sdk-to-emulator.html
- Command reference: https://docs.aws.amazon.com/emulator/latest/userguide/cli-reference.html
- Fidelity: https://docs.aws.amazon.com/emulator/latest/userguide/fidelity.html
- Checking your project: https://docs.aws.amazon.com/emulator/latest/userguide/check-project.html
- Releases / fidelity scores: https://github.com/aws/aws-emulator/releases
- Evaluation suite: https://github.com/aws/aws-emulator-evaluation-suite