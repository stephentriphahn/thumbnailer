# Findings

Running log of verified facts, emulator fidelity results, decisions and gotchas.
Decisions that deserve more than a line get an ADR in `doc/adr/`.

## Phase 0

### Slice 0.1 — Tooling and cluster (2026-11-17)

Host: macOS (Darwin 25.5.0), **arm64** (use the aarch64 emulator RPM).

| Tool | Result |
|---|---|
| docker | 29.9.3 (storage driver `overlay2`, 11 CPUs, ~8 GB RAM for the VM) |
| kubectl | v1.37.2 (client) |
| helm | **v4.3.2** (major version 4; differs from most tutorials written for v3) |
| aws CLI | 2.40.3 |
| jq | 1.8.2 |
| git | 2.51.0 |
| make | GNU Make 3.81 (old macOS default; avoid newer-only features) |
| terraform | v1.17.2 (installed after this check; `terraform-local`/`tflocal` is a LocalStack wrapper and is not used) |
| kind CLI | **MISSING** (not required locally; needed to reproduce CI by hand) |
| just | not installed (using Make) |

Cluster:

- Context `docker-desktop`, initially one node `desktop-control-plane`, **Ready**, Kubernetes **v1.36.1**, containerd 2.3.1.
- Cluster mode confirmed as **kind**. Changed to **2 nodes** (`desktop-control-plane`, `desktop-worker`), both Ready, v1.36.1.
- kubectl (1.37) is one minor version ahead of the server (1.36), which is within the supported skew.

Observations that affect later slices:

- Docker uses the classic `overlay2` store, **not** the containerd image store. This matters for Slice 0.2: images built with `docker build` may not be visible to the kind node's containerd. Expect to need the containerd image store or a local registry.
- ~8 GB for the Docker VM is tight for the emulator (2 GB) plus the platform stack, Prometheus and Grafana (Phase 6). Consider raising it before Phase 2.

### Open items

- [x] Install terraform. [x] Confirm kind mode and 2 nodes.
- [ ] Optionally install `kind`, `kubeconform`, `helm-diff` later.
- [ ] Consider raising the Docker VM memory before Phase 2/6 (~8 GB now, shared by 2 nodes).
- [x] Slice 0.2: can locally built images run with `imagePullPolicy: IfNotPresent`? Yes, once the containerd image store is enabled. See `doc/adr/0001-local-image-delivery.md`.

### Slice 0.2 — Local image delivery (2026-11-17)

- With the classic `overlay2` store, a pod using `local-test:0.1` failed on **both** nodes: the node tried `docker.io/library/local-test:0.1` (`repository does not exist`, then `insufficient_scope`).
- Enabling Docker Desktop's containerd image store changed the storage driver to `overlayfs` (`io.containerd.snapshotter.v1`). The old store's images were not visible afterwards (not deleted), so the image had to be rebuilt.
- After the rebuild, pods pinned to `desktop-control-plane` and `desktop-worker` both reached `Running` with `imagePullPolicy: IfNotPresent`.
- Gotcha: a failed pod does not recover on its own after the image appears. Delete and re-apply it.
- Decision recorded in ADR 0001. CI will need `kind load docker-image` or a registry (Phase 8).

## Phase 1

### Slice 1.1 — Emulator image and host run (2026-11-17)

- `emulator/Dockerfile` follows the official Docker setup page, using the **aarch64** RPM (Apple silicon).
- Version reported by the emulator: **1.0.500**. Image tagged `aws-emulator:1.0.500` (a local `latest` tag also exists from `docker build -t aws-emulator .`; never reference it).
- Image size is about **1.84 GB**, which is large for a pod image. Worth remembering for kind node disk use and pull time.
- Gotcha: the download URL only offers `LTS/latest`. There is no pinned-version URL, so rebuilding later can fetch a **different** RPM than the tag claims. The docs show no checksum or signature check for the RPM either.
- Host run (docs command, `--memory=2g --memory-swap=2g`, bound to `127.0.0.1`): the health check returned `ok`, and `aws sts get-caller-identity` returned account `000000000000`.
- `ca.pem` **differs on every start**, confirming the gotcha that Phase 2's CA sidecar and the restart-on-change mechanism exist for.
- Per-run credentials are written to `~/.aws/emulator/<port>/emulator_credentials` (Phase 2 switches to `--auth off`).

### Slice 1.2 — Service probes (by hand, emulator 1.0.500, CLI v2 with `AWS_CA_BUNDLE`)

Legend: OK = behaved like AWS, DEV = works but differs, FAIL = unsupported, ? = not yet checked.

#### S3

| Operation | Result | Notes |
|---|---|---|
| CreateBucket (`uploads`, `processed`), ListBuckets, HeadBucket | OK | |
| PutObject, GetObject, HeadObject, ListObjectsV2 (prefix) | OK | |
| Multipart upload (`aws s3 cp`, 20 MB) | OK | `ContentLength` correct (20971520) |
| GetBucketLocation | OK | `LocationConstraint: null` for us-east-1, as in AWS |
| GetPublicAccessBlock | OK | all four settings `true`, as new AWS buckets |
| GetBucketCors / Lifecycle / Policy / Tagging | OK (reported) | "not configured" errors, which the Terraform provider expects |
| GetBucketAcl / GetBucketEncryption | ? | Reported as "not configured" errors. AWS returns data here (owner `FULL_CONTROL`, default `AES256`), so this may differ. Exact output not captured. Re-check with `TF_LOG=debug` in Phase 3 |
| PutBucketVersioning / GetBucketVersioning | OK (reported) | |
| PutBucketTagging / GetBucketTagging | OK (reported) | |
| Presigned GET (`aws s3 presign`) + curl | OK | |
| Presigned PUT (boto3) + curl | OK | Needs `--cacert`. A browser would not trust the CA, hence presigned uploads stay a stretch goal |
| Error codes: NoSuchKey, missing-bucket 404, BucketNotEmpty | OK | `NoSuchKey`, `404 Not Found` on HeadBucket, `BucketNotEmpty` |
| CreateBucket on an existing bucket you own | OK | Returns success `{Location: /uploads}`. This matches real S3 in `us-east-1` (legacy idempotent behavior; other regions return `BucketAlreadyOwnedByYou`). Makes `create-bucket` safe to re-run |

Gotcha: pasting a presigned URL into the shell with backslash escapes inside double quotes breaks it (the query string becomes part of the path, so the request is anonymous and returns `AccessDenied`). Capture the URL in a shell variable instead.

#### SQS

- **Gotcha: SQS needs a client that speaks the SQS JSON protocol.** With an old CLI (2.15.25, x86_64, from `/usr/local/bin`) every SQS call failed with `Unable to parse response (not well-formed (invalid token)) ... SerializationException: missing required header x-amz-target`. The old CLI sent the legacy *query* protocol (form-encoded `Action=ListQueues`). The emulator answered in `application/x-amz-json-1.0` and expects `x-amz-target`.
- Cause on this machine: two CLI installs. `/usr/local/bin/aws` (old pkg install, x86_64) shadowed `/opt/homebrew/bin/aws` (2.40.3, arm64). Removed the old install; `aws sqs list-queues` then worked.
- Implication: services need recent AWS SDKs. Pin minimum SDK versions in each service's ADR. S3 and STS were unaffected, since they use other protocols.
- Tip: `type -a aws` shows every `aws` on `PATH`; `aws --version` should say 2.40.x / arm64.

| SQS operation | Result | Notes |
|---|---|---|
| CreateQueue (`jobs`, `jobs-dlq`), redrive policy | OK (reported) | |
| SendMessage / ReceiveMessage / DeleteMessage | OK | MD5, receive count and visibility timeout (5 s) behaved like AWS |
| Visibility timeout: message reappears with `ApproximateReceiveCount` 2 | OK | |
| Long polling, message arrives mid-wait | OK | 10 s poll returned after about 3 s (20:27:21 to 20:27:24) |
| Long polling, empty queue | ? | Expected about 10 s and no message. Not yet confirmed |
| Redrive to DLQ after `maxReceiveCount` | ? | Reported fine; exact output not captured (pager may have hidden it) |
| Message attributes (`traceparent`) | ? | Reported fine; exact output not captured |

Gotcha: the **AWS CLI v2 pager** (`less`) captures output and blocks the terminal. It hides command output and inflates `time` measurements (a first long-poll run showed 15.6 s because `less` stayed open). Set `AWS_PAGER=""`; include it in `make emulator-env`.

Gotcha: a long-polling test needs an empty queue first. Leftover messages make the receive return at once and look like a failure.

#### DynamoDB

| Operation | Result | Notes |
|---|---|---|
| CreateTable (PAY_PER_REQUEST), DescribeTable | OK | |
| PutItem, GetItem | OK | |
| UpdateItem with expression and reserved-word alias, `ALL_NEW` | OK | worker's status update |
| Query, Scan | OK | |
| DescribeTimeToLive | OK | `DISABLED`, as AWS |
| DescribeContinuousBackups | OK | `ENABLED`, PITR `DISABLED`, as AWS |
| ListTagsOfResource | OK | empty list, no error |

#### SNS to SQS (the design fork)

| Operation | Result | Notes |
|---|---|---|
| CreateTopic, Subscribe (`sqs` protocol), ListSubscriptionsByTopic | OK | |
| Publish, with no queue policy | No delivery | The first receive after publishing returned nothing. The diagnostics (longer wait, subscription state) were not captured, so treat "emulator enforces the policy" as likely, not proven |
| SetQueueAttributes `Policy` allowing `sns.amazonaws.com` from the topic ARN | OK | |
| Publish, with the policy | **OK** | Message arrived in `notify` |
| RawMessageDelivery=true | ? | Not tested yet |

- Delivered body is the standard SNS envelope: `Type: Notification`, `MessageId`, `TopicArn`, `Message` (the original payload **as a JSON string**), `Timestamp`, `Signature`, `SigningCertURL`, `UnsubscribeURL`.
- Quirk: `SigningCertURL` points at the emulator (`https://127.0.0.1:9297/...pem`), but `UnsubscribeURL` points at the real `sns.us-east-1.amazonaws.com`. Never follow it.
- Decision: keep SNS to SQS in the design. See ADR 0002.

#### SSM Parameter Store

| Operation | Result | Notes |
|---|---|---|
| PutParameter (String, SecureString) | OK | |
| GetParameter | OK | ARN and `DataType: text` as AWS |
| SecureString without `--with-decryption` | OK | returns ciphertext, as AWS |
| SecureString with `--with-decryption` | OK | returns clear text |
| GetParametersByPath (`--recursive`) | OK (reported) | |
| PutParameter `--overwrite`, version bump | OK | version increments |
| PutParameter without `--overwrite` | OK | fails with `ParameterAlreadyExists`, as AWS |

Gotcha: zsh globs unquoted brackets, so `--query Parameter.[Value,Version]` fails with `zsh: no matches found`. Always single-quote `--query` values.

#### Secrets Manager

| Operation | Result | Notes |
|---|---|---|
| CreateSecret, GetSecretValue, DescribeSecret | OK (reported) | |
| PutSecretValue, then read shows new value | OK (reported) | |
| ListSecrets | OK (reported) | |
| CreateSecret with an existing name | OK (reported) | fails with `ResourceExistsException`, as AWS |

### Phase 1 summary

- Emulator 1.0.500 (aarch64 image, 1.84 GB) supports everything the v1 design needs: S3, SQS, SNS to SQS, DynamoDB, SSM, Secrets Manager.
- Required deviations from the original plan: none. SNS to SQS works, so the design is unchanged (ADR 0002), but the queue policy is mandatory.
- Open items (non-blocking): SQS empty-queue wait, redrive to DLQ and message attributes were reported fine but their exact output was not captured; S3 `GetBucketAcl`/`GetBucketEncryption` exact responses; SNS `RawMessageDelivery`. Phase 3 and the worker slice will exercise these.
- Environment gotchas to carry forward: AWS CLI pager (`AWS_PAGER=""`), old x86_64 CLI shadowing the arm64 one (needs SDKs that speak the SQS JSON protocol), zsh globbing of unquoted `--query` brackets, presigned URLs must be captured in a variable.

## Phase 2

### Slice 2.1 and 2.2 — Emulator chart and CA sidecar (2026-11-23)

- `charts/aws-emulator`: Deployment (`Recreate`, 1 replica), Service, ServiceAccount, Role, RoleBinding. Pod QoS class `Guaranteed` (both containers have equal requests and limits).
- Emulator `args` are `-p 9297 --auth off`. `-b 0.0.0.0` stays in the image `ENTRYPOINT`, and the emulator's default bind is `127.0.0.1`. Never set `command:` in the pod spec, because it would replace the ENTRYPOINT.
- `ca-publisher` sidecar working: the ConfigMap's `ca.pem` hash matches the emulator's. Images versioned `0.1.0` to `0.1.2`.
- Gotcha: forgetting `serviceAccountName` runs the pod as `default`, giving `Forbidden` from the sidecar. Diagnose with the user named in the error and `kubectl auth can-i --as=...`.
- Gotcha: in `a | b` under `set -e`, only the last command's status counts; use `if a | b; then` to test it.
- Gotcha: a chart change that edits the pod spec restarts the emulator (`Recreate`), which wipes all state and changes the CA. Restart any port-forward afterwards.
- Slice 2.2 validated: deleting the pod produced a new `ca.pem` hash in the ConfigMap; killing only the emulator container (`docker exec <node> crictl stop --timeout 0 <id>`, simulating an OOM kill) left the pod and `emptyDir` intact, and the ConfigMap again matched the container's regenerated certificate.
- `kill` is a shell builtin and is not available as a binary in the emulator image, so `kubectl exec ... -- kill 1` fails; stop containers through the node runtime (`crictl`) instead.

### Slice 2.3 — Makefile targets (2026-11-24)

- `Makefile` in the repo root: `emulator-forward`, `emulator-ca` (fails clearly, leaves the previous `.emulator/ca.pem` untouched), `emulator-env` (prints `unset`/`export` lines; use `eval "$(make -s emulator-env)"`), and a self-documenting `help` as the default goal.
- Make 3.81 (macOS default) supports `.DEFAULT_GOAL` and `$(MAKEFILE_LIST)`; avoid newer features.
- Gotcha: builtins (`unset`, `export`, `cd`) are not programs. A simple recipe line is exec'd without a shell, so they fail with "No such file or directory", and a child process could not change the parent shell anyway. Print the lines and `eval` them.
- Gotcha: `cmd > file` truncates `file` before `cmd` runs, and `jsonpath` on a missing key exits 0 with empty output. Write to a temp file, check `test -s`, then `mv`.
- Gotcha: the sidecar does not recreate a deleted `aws-emulator-ca` ConfigMap until the certificate changes (known limitation; restart the pod to restore it).

### Slice 2.4 — Platform umbrella (2026-11-24)

- Pinned chart versions (looked up with `helm show chart --repo ...`): KEDA chart 2.21.1 (app 2.21.1), External Secrets chart 2.15.0 (app v2.15.0). Chart version and app version are different things; the `dependencies` pin is the chart version.
- `charts/platform` renders 7 Deployments, 31 CRDs. All pods Running; everything schedules onto `desktop-worker`.
- Helm values precedence: subchart defaults < umbrella `values.yaml` < `-f` files (later wins) < `--set`. Maps merge, lists are replaced. A dependency `condition` path that is missing from values leaves the dependency **enabled**.
- Verified Phase 2 "done when": the emulator pod survives `helm upgrade platform` (no-change and a KEDA-only change), the CA ConfigMap follows pod restarts, and the AWS CLI works through the port-forward.
- Decision recorded in ADR 0004.

### Phase 2 summary

- Delivered: `charts/aws-emulator` (Deployment, Service, RBAC, CA sidecar), `images/ca-publisher`, `charts/platform` umbrella, Makefile (`help`, `emulator-forward`, `emulator-ca`, `emulator-env`, `platform-up`). ADRs 0003 and 0004.
- Open items: emulator CPU is `100m` request/limit (may throttle under load; raise if sluggish). The Service has no `helm.sh/resource-policy: keep`; undecided and probably unnecessary inside an umbrella. Docker VM memory (~8 GB) is shared by the emulator (2 Gi) and 6 platform pods; consider raising before Phase 6. The sidecar does not recreate a ConfigMap deleted by hand until the cert changes.
