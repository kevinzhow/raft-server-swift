# How to align a new upstream release

Use this procedure to turn a new upstream version into a reviewed change queue,
then produce new behavior and client evidence. Keep the current accepted baseline
available until the new candidate is qualified. The governing rules are in
[VERIFICATION.md](VERIFICATION.md); installed/candidate status remains in
[PLAN.md](PLAN.md).

## Prerequisites

- Two frozen upstream source exports, with explicit tags/commits and dependency
  locks. Keep both exports on the data disk and read-only during comparison.
- The same version of the [inventory generator](../scripts/route_inventory.py)
  and [upgrade planner](../scripts/verification/upgrade_delta.py) for both inputs.
- A source-reviewed old contract and a separate candidate contract. The
  [attachment contract](../scripts/verification/attachment_contract.json) is the
  first template; it does not establish complete attachment or service coverage.
- Python 3 with the standard library. Product runs also need the toolchains,
  real dependencies, clients and private configuration recorded for that version.
- An output directory on the data disk, outside Git and both source exports.
  Keep credentials, deployment paths and signed URLs outside committed files.

Set `OLD_SOURCE`, `NEW_SOURCE`, `OLD_CONTRACT`, `NEW_CONTRACT` and
`UPGRADE_ARTIFACTS` to these explicit local paths. Do not point `NEW_SOURCE` at
an in-place replacement of the accepted oracle. Comparing a candidate version
never changes the active specification automatically.

## 1. Check the verification tools

```sh
python3 -m unittest discover -s scripts -p test_route_inventory.py -v
python3 -m unittest discover -s scripts/verification -p 'test_*.py' -v
```

These tests validate the tools and include synthetic upgrade/fault cases. They do
not exercise a new server version. The planner must reject duplicate identities,
retain unresolved inputs and keep plans separate from acceptance results.

## 2. Record the two source sets

```sh
mkdir -p "${UPGRADE_ARTIFACTS:?}"
python3 scripts/verification/upgrade_delta.py manifest --source-root "${OLD_SOURCE:?}" --include . --out "${UPGRADE_ARTIFACTS:?}/old-sources.json"
python3 scripts/verification/upgrade_delta.py manifest --source-root "${NEW_SOURCE:?}" --include . --out "${UPGRADE_ARTIFACTS:?}/new-sources.json"
```

The generated manifests retain relative file paths, SHA-256 values, scan scope,
exclusions and coverage issues. Automatic manifests declare partial coverage.
They cannot prove that an excluded generated asset, external dependency or
unscanned runtime input is irrelevant. Do not flip a coverage flag to obtain a
smaller queue. A complete external manifest needs a reviewed account of the
source, shared schemas, real clients, bootstrap/configuration and dependency
inputs it covers.

Record source/archive/tree, lockfile, extractor and client artifact identities
alongside these files. An API version string alone is insufficient build proof.
If a parser change caused the inventory difference, regenerate both old and new
inventories with the corrected parser before investigating upstream.

## 3. Extract raw entry inventories

```sh
python3 scripts/route_inventory.py --upstream-root "${OLD_SOURCE:?}" --upstream-only --json-out "${UPGRADE_ARTIFACTS:?}/old-entries.json"
python3 scripts/route_inventory.py --upstream-root "${NEW_SOURCE:?}" --upstream-only --json-out "${UPGRADE_ARTIFACTS:?}/new-entries.json"
```

Review raw expressions, constraints, mounts, conditions, unresolved registrations
and extraction errors. Match these later to a freshly identified Swift router
dump and separate middleware/socket/daemon inventories. The HTTP extractor does
not establish runtime activation or independent-listener coverage.

Use raw `operation_id` and stable `behavior_id` for traceability. A path/parameter
rename may appear as removal plus addition; decide whether compatibility or an
explicit mapping is needed. Do not turn a normalized path match into an identity
or permission equivalence. Line/offset registration IDs can move without a new
operation.

## 4. Generate the upgrade review and rerun queue

```sh
python3 scripts/verification/upgrade_delta.py compare --old-inventory "${UPGRADE_ARTIFACTS:?}/old-entries.json" --new-inventory "${UPGRADE_ARTIFACTS:?}/new-entries.json" --old-contract "${OLD_CONTRACT:?}" --new-contract "${NEW_CONTRACT:?}" --old-sources "${UPGRADE_ARTIFACTS:?}/old-sources.json" --new-sources "${UPGRADE_ARTIFACTS:?}/new-sources.json" --out "${UPGRADE_ARTIFACTS:?}/upgrade-plan.json"
```

The output is a `kind=upgrade_review_plan`, not a run report. It exposes:

| Field | Review action |
| --- | --- |
| `entry_changes` | Inspect added/removed entries and raw dispatch/constraint changes |
| `registration_changes` | Inspect registration/mount uncertainty and source-location movement |
| `source_changes` | Follow implementation, shared-helper, consumer, lock and configuration changes |
| `rule_changes` | Review expected results, profiles, prerequisites and source dependency changes |
| `pending_inputs` | Retain old/new unresolved registrations and extraction failures |
| `coverage` | Establish whether the source/dependency footprint can support bounded review |
| `reverification_queue` | Assign each obligation to a source owner, scenario/profile and future run |

Queue items start at `NOT_RUN`. Missing source manifests, insufficient coverage,
unmapped changes and unknown entries require conservative global review. A new
entry without a rule needs specification work. A removed entry needs a consumer
and compatibility decision. A line moving is a location change; changed file
bytes require semantic inspection and do not themselves prove behavior changed.

Successful planner exit means the plan was generated. Its
`acceptance_complete` and `release_eligible` remain false, and old PASS results
are not inherited. Do not use an empty entry delta or exit zero as an upgrade
gate.

## 5. Review and version the contract

Read the new handler, mounting/middleware, authorization/state/storage services,
shared schemas and actual Web/CLI consumers. Update the candidate rule pack with
source evidence. Preserve the old pack and its expected behavior.

For every changed operation, account for principal/tenant scope, full required and
nested fields, null/default semantics, first-response headers, bytes, effects,
authoritative state and restart behavior. Review the same pattern across its
consumers. For example, a permission advertised during creation must also agree
with detail/list projections and the later management action.

Record service construction, global admission, per-server flags and actual
storage capabilities independently. A false capability does not imply a null
service. Streaming, signed downloads, recovery-only sessions and enabled uploads
need separate profile decisions and results. Test injection is not production
wiring evidence.

Resolve discrepancies as implementation defects, controlled ENV findings,
upstream inconsistencies or explicit version-scoped deviations. Follow
[DEVIATIONS.md](DEVIATIONS.md) for deliberate differences and re-evaluation
triggers. Neither a broad storage exclusion nor an old test expectation approves
a new observable difference.

## 6. Port and prove the affected behavior

Assign one source owner per area, use its warm worktree, and lock public HTTP/
frame behavior with focused regressions. Add a negative control when a bug could
escape detection: same length with corrupted bytes, correct route with missing
fields, same UUID in different principal namespaces, no real restart, or stale
baseline evidence. Fix the verifier as well when it misclassifies a failure.

Run affected suites and independent review before declaring the candidate ready.
A review finding returns to the same owner. Permission regressions need positive
and negative witnesses across the relevant principal, membership, representation
and parent-state boundaries. In particular, distinguish an absent legacy row from
an explicit denial: fallback must not restore access after typed membership
removal or a tombstone anywhere on the authority path. Keep this matrix in the
rule/profile scope rather than assuming one happy-path request covers it.
Follow the working contract's real
merge, integration gate and required persistence gate. Do not copy changes into
trunk or treat the parity ledger as user-path acceptance.

## 7. Execute fresh paired runs

Create independent, owned resources and semantically equivalent fixtures for both
implementations. Record real process/binary/library/client identities and actual
configuration before starting. Keep logical operations and source-derived
expectations shared; isolate endpoint, credentials, trust and lifecycle details
in the private target configuration. Normalize only declared fields and entity
namespaces; equal human and Agent UUIDs do not identify the same membership.

For the implemented streaming sample:

```sh
python3 scripts/verification/attachment_pilot.py --config "${PRIVATE_CONFIG:?}" --out "${RUN_OUTPUT:?}" --phase initial
python3 scripts/verification/attachment_pilot.py --config "${PRIVATE_CONFIG:?}" --out "${RUN_OUTPUT:?}" --phase after-restart --restart-evidence "${RESTART_RECEIPT:?}"
```

Use a fresh run directory for the new baseline. The second command follows real
operator-controlled retained-data restarts; it is not a substitute for them.
The current streaming pilot has pinned expectations in both its rule pack and
scenario code. Update and review both when upstream changes the contract; merely
changing the tag does not adapt the assertions. Additional profiles need their
own implemented scenarios and real evidence.

Preserve first responses, exact bytes/JSON, client exit/output hashes, ownership
and same-object witnesses. Continue after ordinary failures and mark known
prerequisite dependencies `BLOCKED`; preserve the security/outage/corruption stop
policy. A real external-key CLI flow does not establish managed Agent delivery.

## 8. Decide, archive and release

Assess entry completeness, reviewed rules, paired behavior, actual clients and
fault detection separately. Required `NOT_RUN` or `BLOCKED` results prevent the
declared scope's completion. Keep known differences outside that scope visible;
a passing sample is not whole-service parity.

Archive immutable inputs, contracts, tool contents/hashes, private configuration,
observations, defects, dispositions, gate logs and scope limits. Rerun changed
baselines rather than relabeling old evidence. Follow the verified deployment,
backup and rollback procedure in [AGENTS.md](../AGENTS.md); update the current
status in [PLAN.md](PLAN.md). An upgrade plan never authorizes release.

## Troubleshooting

| Observation | Required response |
| --- | --- |
| Same route, changed shared auth/helper/client | Review affected rules; widen to all candidates when dependencies are unmapped |
| Only line numbers changed | Refresh source provenance; do not infer changed behavior or new operations from offsets |
| Parser output shrank or reports new unknowns | Preserve errors/unknowns and investigate extraction before declaring routes removed |
| Planner requires global review | Supply reviewed source coverage or perform broad review; do not suppress unknown inputs |
| Source/schema and official runtime disagree | Keep both observations and investigate the pinned implementation/configuration |
| New-version run has old PASS rows | Start a fresh baseline/run and reproduce the behavior with current evidence |
| Most checks pass, remaining profile unexecuted | Report the bounded success and missing profile explicitly; leave completion false for the larger scope |

The upgrade planner deliberately does not implement a complete dependency graph,
a schema inference engine, environment provisioning or automatic semantic
approval. Its conservative queue and the executable verifier regressions make
those limits visible while preserving a repeatable starting point for the next
release.
