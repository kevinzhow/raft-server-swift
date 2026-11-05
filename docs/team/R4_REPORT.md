# R4 report — architecture guardrails and target layering

- **Member**: `r4-guardrails` (shared task `task-8`)
- **Date**: 2026-11-05 (Asia/Tokyo)
- **Repo**: `/mnt/data/raft-server-swift`
- **Base commit**: `3565f92ec74c6b83582e47b7f7a57cf1f4939081` — *Credit the product feedback module lock.*
- **Write scope**: `docs/ARCHITECTURE.md`, `scripts/check_architecture.py`, `docs/team/R4_REPORT.md`. No tracked file was modified (`git diff --stat` empty); `Sources/`, `Tests/`, `Makefile`, `Package.swift`, `docs/PARITY.tsv`, `docs/BEHAVIOR.md`, `docs/PLAN.md` were not touched.

## Deliverables

| File | Purpose |
| --- | --- |
| [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md) | Target Swift Vapor layering mapped from upstream Raft: Features (`RouteCollection`) → Services → Stores (per-domain locks) → DTO/JSON, test seams in `TestSupport`, shared contracts in `RaftShared`. Includes dependency rules, composition-root contract, migration order (R1–R5), and guardrail policy. |
| `scripts/check_architecture.py` | Standard-library-only Python 3 guardrail runner. Text report by default, `--json` machine report, `--root` override. Exit `0` pass/warn, `1` violation, `2` operational error. |
| `docs/team/R4_REPORT.md` | This report. |

## Guardrails enforced

| Check id | Rule | On failure |
| --- | --- | --- |
| `email-login-ceiling` | `Sources/RaftHTTP/EmailLogin.swift` ≤ **31,656 lines** (baseline measured on this tree: `wc -l` = 31,656; the task brief's "~31650" is this measured value) | **Fail**; lowering is allowed, the constant is a ratchet that may only be lowered |
| `feature-file-ceiling` | Every `.swift` under `Sources/RaftHTTPServer/Features/` ≤ **1,200 lines** | **Fail**; a missing `Features/` directory is zero files, not an error |
| `email-login-test-seams` | `ForTesting` markers in `EmailLogin.swift` ≤ **243**, `private func …ForTesting` ≤ **0** | **Warn only** (exit code unchanged); new seams belong in `TestSupport` (R5) |

The 243 count is intentionally not zero: `EmailLogin.swift` already carries 243
legacy `…ForTesting` members. Guardrail 3 warns about them and about growth, but
only guards 1 and 2 can fail the run, as specified.

## Captured run (text mode)

Command and output on the tree at 2026-11-05 16:07 JST:

```console
$ scripts/check_architecture.py
architecture guardrails — raft-server-swift
root: /mnt/data/raft-server-swift

[PASS] EmailLogin.swift line ceiling  Sources/RaftHTTP/EmailLogin.swift is 31,656 lines (0 lines of headroom)
[PASS] Features/*.swift line ceiling  4 feature files, largest 243 / 1,200 lines
[WARN] EmailLogin.swift test seams    243 ForTesting markers (baseline 243), 0 private func …ForTesting (baseline 0)

warnings:
  - 243 legacy ForTesting markers remain in Sources/RaftHTTP/EmailLogin.swift; new seams belong in TestSupport (R5)

result: PASS — 2 passed, 1 warning, 0 failed

$ echo $?
0
```

The four feature files present at capture time belong to the parallel R1 route
extraction slices (`AuthFeature.swift` 243, `PublicFeature.swift` 110,
`FeedbackFeature.swift` 58, `TranslationFeature.swift` 52 lines). They are
untracked work from other members and were still being edited during this
slice; the script scans the directory dynamically, so later feature files and
line-count changes are covered without a script change. `EmailLogin.swift` did
not change during the slice (31,656 lines, 243 `ForTesting` markers).

## Captured `--json` evidence

```console
$ scripts/check_architecture.py --json
{
  "schema": "raft-server-swift.architecture-guardrails/1",
  "result": "pass",
  "exit_code": 0,
  "counts": { "passed": 2, "warnings": 1, "failed": 0 },
  "baselines": {
    "email_login_lines": 31656,
    "feature_file_line_limit": 1200,
    "email_login_for_testing_markers": 243,
    "email_login_private_func_for_testing": 0
  }
}
# per-check status: [("email-login-ceiling", "pass"),
#                     ("feature-file-ceiling", "pass"),
#                     ("email-login-test-seams", "warn")]
```

Full JSON also contains the per-file feature inventory, headroom, and every
violation/warning string.

## Failure-mode verification

Each guardrail was exercised against a throwaway `--root` so the real tree
stayed untouched:

| Scenario | Observed | Exit |
| --- | --- | --- |
| Copy of `EmailLogin.swift` with one appended line | `[FAIL] … grew to 31,657 lines, 1 over the 31,656-line baseline`; `result: FAIL` | `1` |
| Synthetic 1,300-line `Features/Big/BigFeature.swift` | `[FAIL] … largest 1,300 / 1,200 lines`; per-file violation listed | `1` |
| `--json` on the failing root | `"result": "fail"`, `"exit_code": 1`, violations array populated | `1` |
| `--root /nonexistent-root-xyz` | `check_architecture: root is not a directory` (JSON mode emits `"result": "error"`) | `2` |
| Root without `Sources/RaftHTTP/EmailLogin.swift` | `check_architecture: missing required file` | `2` |

## Integration notes and limitations

- Not wired into `make` or CI: `Makefile` is out of scope for this slice. A
  Makefile-owning slice can add `arch: scripts/check_architecture.py` and a CI
  step without touching the script.
- The script is deterministic (no timestamps, sorted file inventory) and reads
  only repository files; it makes no network or toolchain calls.
- Baselines are a ratchet: when R3/R5 shrink `EmailLogin.swift` or remove
  `ForTesting` seams, lower the corresponding constant in the same commit and
  update `docs/ARCHITECTURE.md` §7 and this report. No slice raises a constant
  to make the check pass.
- The architecture document describes the **target** layering; the current tree
  is still transitional (`FallbackApplication.swift` composition root +
  `EmailLogin.swift` ledger). R1–R3 own the code movement; R4 owns the boundary
  definition and the guardrails that keep it visible.
