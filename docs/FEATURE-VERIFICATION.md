# Every feature change: mandatory completion workflow

This is the how-to for adding or repairing observable behavior. The current
[status](PLAN.md), [verification contract](VERIFICATION.md) and
[upgrade method](PARITY-UPGRADES.md) remain separate. Historical `locked` modules
are dispositions, not current feature or runtime qualification.

## 1. Review the affected contract before testing

Work on an area branch from `deploy-linux-docker`. Preserve the pinned oracle.
Find the family mappings in
[the registry](../scripts/verification/families.json). Its initial twenty contracts
are **DRAFT_NOT_QUALIFIABLE**. Registering an old module is not approving a contract.

Read the actual upstream producer/route/state calls and the fields read by the
fixed Web/CLI consumer. Version the affected contract with source and consumer
file hashes. Declare the exact operations and behavior/profile scope. A family
may contain many modules; completion never means the whole family was reviewed.

Required dimensions are producer, consumer, query state/side effects,
authorization, configuration and restart. An inapplicable dimension needs a
specific source-backed reason and is not a PASS. Required dimensions must point
to actual obligations. Preserve missing/null/type distinctions and every required
consumer field. A known unresolved boundary stays visible and prevents completion
of the affected scope.

Do not replace a production producer with `add*ForTesting`, manually seeded target
facts, a success flag, a default empty port or an injected provider. Setup may
create identities/resources, but the behavior under test must enter through its
real public path. Pure helper tests remain useful and have their own scope.

## 2. Generate a plan from the real change

The repository entry point independently uses the merge base against
`origin/deploy-linux-docker`. It does not accept an arbitrary `BASE=HEAD` to hide a
feature change. Fetch that protected ref when needed. Unknown production paths,
renames/deletions and untracked files require review/mapping. Shared changes widen
the impact. Removing an existing rule, consumer field, required profile or path
mapping is a review stop; a changed registry cannot quietly reduce its denominator.

After editing, generate a plan and run focused tests:

```sh
make verification-plan VERIFY_PLAN="${RUN:?}/plan.json"
VERIFY_PLAN="${RUN:?}/plan.json" make check FILTER='<affected suites>'
```

`RUN` is an operator-owned artifact directory on the data disk, outside Git.
Regenerate the plan after an edit. `plan` and `verification-preflight` permit
work; they never grant completion. A business change without a valid plan fails
before the Swift build. Draft contracts must be completed/reviewed first.

## 3. Capture the real scenario and current baseline

The [completion guard](../scripts/verification/completion_guard.py) provides
`baseline`, `capture-http` and `qualify` commands. Use `--help` and the
[executable contract fixtures](../scripts/verification/test_completion_guard.py)
for the exact schema. Keep bindings, auth, raw responses and state private.

The baseline binds the actual git delta, contracts, oracle and consumer files,
guard/collector tools, effective configuration, runtime binary/build/process and
client implementation/dependency closure. A loader hash is insufficient. Product
proof requires the runtime build receipt to match real source inputs and binary,
and actual process/executable/environment/manifest validation. Configuration
values must match the bound effective-config file; a hand-written
`connected=true` is not evidence of a real provider call.

Product HTTP capture currently requires a direct loopback target in the same
network namespace. The collector verifies the listener socket belongs to the
bound PID and checks that origin's version/source before and after the request;
each raw observation records that target identity. A correct Node/oracle response
cannot be used as a Swift response. Proxy/public routes and cross-namespace
container ports need a real route-proof adapter; until one is implemented they
are unsupported/BLOCKED, not an unchecked origin exception. Synthetic fixtures do
not gain product qualification from these checks.

Collect the ordinary producer request, its authoritative before/after state, the
consumer response for the same object and complete fields, positive/refusal
controls, and applicable real-provider and retained-data restart receipts. A
`consume=false` read needs state before and after to remain unchanged. Provider
success needs the actual call receipt. HTTP200 or a matching byte count is not a
substitute for the declared JSON/byte/state assertion.

Only `qualify` replays the raw assertions. A caller-written PASS is checked against
raw file hashes, typed selectors, expected values, request/response object and
input propagation, state relations and causal order. Synthetic controls always
remain tool tests and cannot qualify a product. Scope-missing, stale or tampered
inputs reject completion; old attachment35 evidence is not a grant for Activity.

## 4. Handoff and integrate through the same system

Set these artifact paths when handing off and running the integration gate:

```sh
export VERIFY_PLAN="${RUN:?}/plan.json"
export VERIFY_BASELINE="${RUN:?}/baseline.json"
export VERIFY_REPORT="${RUN:?}/results.json"
export VERIFY_EVIDENCE_ROOT="${RUN:?}"
make verification-handoff
make gate
```

Handoff validates current scoped evidence. The full gate additionally runs the
Python verification controls, sharded Swift tests, real process E2E, smoke,
architecture and historical ledger validation, then creates an immutable
completion receipt bound to the completed integration steps. Persistence/execution
changes still require sequential `make test-pg` in the warm area worktree.

Pass the **integration** receipt to normal deployment:

```sh
VERIFY_QUALIFICATION='<gate-log-dir>/completion-qualification.json' make deploy COMMIT='<qualified integration SHA>'
```

A handoff-only receipt is insufficient. The deploy entry checks target commit,
committed input bytes, actual installed source baseline, full-gate summary and
current archived product evidence. Tooling-only receipts cannot authorize changed
application code. Preserve the standard stage verification, quick dump and
rollback assets. Do not bypass the `make deploy` entry point for a feature release;
the documented emergency manifest rollback remains a separate recovery procedure.

## 5. Report the exact result

- A development plan is NOT_RUN, even if its command exits0.
- Tooling-only qualification runs tool tests and has `product_verified=false`.
- Product completion names contract/version/obligation/profile IDs, not just a
  module/family label. `whole_family_complete` and `global_complete` remain false.
- The acceptance runner separates `execution_ok` from `acceptance_complete`.
  Required missing/SKIP/BLOCKED/duplicate checks and dry runs cannot complete.
  Read-only mode's mutation/restart checks are outside its active scope.
- A missing database snapshot is SKIP, never “0 rows unchanged”. Historical
  declaration counts are never executed-case or user-path coverage.

The guard cannot infer every semantic obligation from arbitrary source or prove
that a privileged collector is honest. Independent source/consumer review and
owned-runtime capture remain necessary. It mechanically rejects the documented
false-completion classes; it does not promise the absence of every future bug.
