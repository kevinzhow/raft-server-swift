# Upstream behavior verification

This is the execution contract for checking the Swift port against pinned
`raft-source` tag `v1.21.23-source.1`. Current work and installed/candidate versions
belong in [PLAN.md](PLAN.md). Deliberate differences belong in
[DEVIATIONS.md](DEVIATIONS.md). The historical [PARITY.tsv](PARITY.tsv) remains a
module/locking-test ledger, not a complete behavior or runtime-acceptance result.

## Three independent questions

| Question | Evidence |
| --- | --- |
| Are supported entries missing? | Raw upstream and Swift registrations, effective paths, transport/listener/conditions, explicit unresolved registrations and scope decisions |
| Does each behavior match? | Pinned source references, independent rules and matching-baseline results for each implementation |
| Can the user complete the flow? | Real HTTP/client/storage/event/state results across the required operation sequence, including promised restart behavior |

Route counts, test counts and code coverage are separate measures. A matched route
shape or green helper test does not establish the other measures.

## Baseline and environments

Record source commit/tree/archive and lockfile hashes, build identity, running
artifact/version, client/overlay identity, feature flags, storage capabilities and
dependency replacements separately for each implementation. Preserve the source
oracle and run installations/builds in a separate data-disk export. A source or
configuration change invalidates affected evidence until re-executed.

Use independent databases, storage roots/buckets, Redis namespaces, ports,
credentials and test identities. Setup must verify resource ownership. Do not mirror
writes to shared production data. Default development tooling may start tunnels,
reuse a listening Redis, bind shared metrics ports, seed databases or destroy volumes;
inspect and configure those behaviors before use. Retained-data restart must not
reseed, migrate, bootstrap replacement views or delete storage.

Declare evidence fidelity. An official test app with an orchestrator stub or
RisingWave reference queries is useful route evidence, but it is not production
bootstrap, managed Agent execution or real persistence evidence. A real CLI process
using an external Agent credential proves CLI behavior, not managed Agent delivery.

## Minimal traceability record

Each rule has a stable `operation_id` and `behavior_id`, pinned source references,
preconditions, stimulus, expected observable results and applicable configuration
profiles. Link it to exact test/scenario IDs and run evidence. Capture authentication,
tenant/channel scope, required/nested fields, failure response, authoritative
business state, side effects/events and restart boundary. Mark inapplicable dimensions
only with a source-based reason.

Keep these states separate:

- Entry exists; contract reviewed; behavior executed; real client flow executed.
- Per-implementation execution: `PASS`, `FAIL`, `NOT_RUN`, `BLOCKED`.
- Disposition: implementation defect, environment, nondeterminism, upstream issue,
  pending adjudication or approved deviation with scope and re-evaluation trigger.
- `execution_ok`: the runner completed without an execution failure.
- `acceptance_complete`: every required behavior/flow has usable evidence for the
  declared baseline and profile.
- `release_eligible`: completion plus required gates and no unresolved critical
  permission, consistency or persistence differences.

A required `NOT_RUN`/`BLOCKED` item prevents completion. A deviation remains visible
and does not become a behavioral `PASS`. Preserve discovered, skipped, executed and
parameterized cases distinctly; do not reuse a historical test total as a new run's
executed-case denominator.

## Inventory and contract rules

Preserve the original method, path expression and constraints, mounted prefix,
source location, configuration condition, transport, listener and entry kind.
Normalized paths are only matching aids. A literal route is not proof of every
parameter value, and an authentication catch-all is not a functional implementation.
Unrecognized registration syntax must be visible. HTTP middleware, implicit
HEAD/OPTIONS behavior, daemon WebSocket and Socket.IO entries require their own
verification; one framework table is not the whole service.

Reuse pinned schemas where available, then check actual mounting, middleware,
handler, authorization/storage calls and real consumer fields. Generate OpenAPI for
reviewed HTTP modules as they are completed. State transitions and events need
executable scenarios. Do not derive expectations from the Swift implementation.
If source/schema and official execution disagree, retain and investigate the
mismatch instead of changing expectations to make the run pass.

## Paired scenario execution

Prepare semantically equivalent initial states, then apply the same logical
operations to separate instances. Compare status, declared headers, JSON shape,
types, missing/null/default semantics, original file bytes and post-write business
results. Observe events before the triggering action; compare source-required
ordering and bounded asynchronous convergence without assuming a total order.

Preserve first HTTP responses before following redirects. Treat presigned URLs as
bearer capabilities and do not forward API credentials to object hosts. Keep client
redirect restrictions intact. Compare IDs through one-to-one aliases with reference
consistency, and times through explicit causal/expiry rules; do not drop IDs, times,
array order or unknown fields globally to erase differences.

Retain replayable requests, exact configurations, first/final responses, output
hashes, state reads and minimal failing inputs. Secrets, auth-bearing headers and
signed URLs belong only in private local evidence, never shared reports or Git.
Every normalization/ignore rule needs a reviewed scope and version.

## First attachment batch

The initial flow is ordinary multipart upload -> message association -> Agent
history -> human and Agent download -> fixed real CLI file output -> access change
-> retained-data restart and readback. Use PNG and a file containing all 256 byte
values, plus text, an empty file and filename/MIME boundary cases derived from the
pinned implementation. Image re-encoding policies for avatars/logos are distinct
from attachment byte identity; existing deviations still apply.

| Rule family | Required observations |
| --- | --- |
| Privacy prerequisite | Both creation response and GET readback establish the requested private channel; fail before dependent writes if either does not |
| Upload and association | Real multipart response, metadata and ID; associated message/history fields and references |
| Byte identity | Uploaded bytes equal both download bodies and actual CLI output; byte count, SHA-256 and PNG decode where appropriate |
| HTTP contract | First status, content type/disposition/length, cache/nosniff headers, redirects and final object result |
| Access | Valid-access witness plus malformed/missing/denied/cross-server/private-thread cases; exact cloaking/error behavior and no unintended writes |
| Capability branches | Streaming/no-presign, presign/302 and enabled upload sessions listed separately; capability-off refusals are tested independently |
| Revocation | New download/new URL mint after revocation, plus already issued URL behavior before and after expiry |
| Persistence | Message, metadata, attachment association and original content remain correct after server restart without reseeding |

Streaming and presign need capability-aligned expectations. Official presign
redirects have different initial responses from streaming; automatic redirect
following can hide the difference. A previously issued signed URL can remain valid
until its own expiry; membership revocation must not be assumed to invalidate it
immediately.

Retained-data restart requires a receipt tied to the run baseline: before/after
process identities must differ, source/artifact identities must still match, and
the receipt's evidence hashes must verify. Running the readback phase immediately
after setup is not a restart test. A revoked attachment also needs an owner read of
the same original bytes after restart; a 404 caused by losing that object is not
proof that permission removal persisted.

The existing candidate regression uses service-level upload setup and an
SDK-compatible object-storage fixture. It locks the binary serialization repair
but does not stand in for multipart upload, real CLI or restart evidence.

## Run the tooling

The source-reviewed [attachment contract](../scripts/verification/attachment_contract.json)
links the 35 implemented rules to operations, pinned source lines and scenarios.
Its additional groups remain outside the implemented pilot denominator. Execution
results belong to a run report, not this static contract. New runs retain the
actual tool and contract contents in private evidence as well as their hashes.

Run the focused verification-tool tests without starting either product runtime:

```sh
python3 -m unittest discover -s scripts -p test_route_inventory.py -v
python3 -m unittest discover -s scripts/verification -p 'test_*.py' -v
```

Use the [inventory generator](../scripts/route_inventory.py) with a previously
verified Swift dump, or use `--upstream-only` without triggering a Swift build:

```sh
python3 scripts/route_inventory.py --upstream-only --json-out "${ENTRY_OUTPUT:?}"
python3 scripts/route_inventory.py --swift-dump "${SWIFT_ROUTE_DUMP:?}" --json-out "${PAIRED_ENTRY_OUTPUT:?}"
```

The [pilot](../scripts/verification/attachment_pilot.py) accepts a mode-0600 private
JSON configuration. It needs `baseline`, independently established
`baselineVerified` flags, and `targets.upstream` / `targets.swift`. Each target
records `baseUrl`, owner login inputs, `serverId`, optional `caFile`, actual
`sourceSHA` and the initial process `runtimeIdentity`. CLI configuration records
its command array, working directory, isolated optional environment and artifact
path/SHA-256. The baseline's `tooling` map hashes the pilot, evidence model,
transport and static contract by their relative filenames. Do not infer a verified
runtime solely from a version string supplied through environment configuration.

```sh
python3 scripts/verification/attachment_pilot.py --config "${PRIVATE_CONFIG:?}" --out "${RUN_OUTPUT:?}" --phase initial
python3 scripts/verification/attachment_pilot.py --config "${PRIVATE_CONFIG:?}" --out "${RUN_OUTPUT:?}" --phase after-restart --restart-evidence "${RESTART_RECEIPT:?}"
```

The second command follows operator-controlled, retained-data restarts. Its receipt
contains `baseline_id` and per-target `before`, `after`, `sourceSHA` and hashed
`evidence` references within the run root. An initial-phase retry uses a fresh run
directory; the restart phase can retry while preserving earlier attempt history.
A nonzero pilot exit also represents ordinary reported product mismatches or
incomplete required scope. Inspect the separate execution/completion/release fields.
The pilot keeps release eligibility false until integration supplies gate evidence.

## Discrimination, handoff and extension

Run the known binary corruption against the old implementation and the repair
against the same assertion. In isolated copies, confirm that selected missing-route,
permission and byte-decoding faults fail the relevant checks. An undetected fault is
a verification defect to fix, not a passing product result.

Continue independent checks after ordinary defects and mark dependent cases
`BLOCKED`; preserve the existing outage/data-corruption/security stop policy. Assign
confirmed defects promptly to an area owner. Fixes report pinned references, locked
observable behaviors, red-to-green evidence, deviations and gate paths. Follow the
repository focused/affected/integration/PG gates and build ownership rules.

Report entry, behavior, flow and fault-detection denominators separately, with
unknowns and evidence limits. After the attachment sample, prioritize identity and
isolation, messages/history/threads/events, tasks/notifications/read state, then
Agent/Computer lifecycle and recovery. Estimate later batches from the sample's
actual rule, defect and execution costs.
