# ADR 0002: Keep SNS to SQS for job-complete notifications

- Status: Accepted
- Date: 2026-11-22

## Context

The plan publishes a job-complete event from the worker to an SNS topic, with an SQS `notify` queue subscribed and the notifier consuming from it. The plan flagged SNS to SQS delivery as unverified and gave a fallback: the worker sends to the `notify` queue directly.

Probe results (emulator 1.0.500): with a subscription in place but no queue policy, a publish was not delivered. After setting an SQS queue policy that allows `sns.amazonaws.com` to `sqs:SendMessage` from the topic ARN, delivery worked and the message arrived in `notify` as the standard SNS envelope.

## Decision

Keep the design: the worker publishes to the `job-complete` topic, and the notifier reads the subscribed `notify` queue. No direct worker-to-queue fallback.

## Consequences

- The Terraform module must create the queue policy (`aws_sqs_queue_policy`) alongside the topic subscription, scoped to the topic ARN. Without it, nothing is delivered and nothing errors visibly.
- By default the notifier receives the SNS **envelope**. The payload is the `Message` field, a JSON **string** that must be parsed a second time. Either handle that in the notifier or enable `RawMessageDelivery` on the subscription (not yet tested here; check it in a later slice).
- This path also behaves like real AWS, so the same Terraform and code should work later against real AWS.
- Do not use the envelope's `UnsubscribeURL`; it points at the real SNS host.
- Revisit if a future emulator release changes delivery behavior (re-run this probe when bumping the version).
