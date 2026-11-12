# Web overlay patches

The product Web client is the pinned upstream `@botiverse/raft-web` build
(`v1.21.23-source.1`). Release Web bytes are produced only by exporting the
pinned base commit with `git archive` and applying a reviewed overlay patch. A
release is never built from a development checkout.

`batch/web` (outside this repository) is a **development-only area**: it is a
clone of the pinned reference used to author, test and review the patch. The
pinned reference checkout itself is read-only input; neither it nor an overlay
authoring area is a release source. No commit is pushed to the vendor origin.

## Layout

```
web/patches/<pinned-tag>/
  <overlay-name>.patch   unified diff against the pinned base commit
  manifest.json          pinned base commit/tag/archive hash, lockfile hash,
                         patch hash, allowlisted files and per-file hashes
scripts/build-patched-web.py
  Replays the release build from the pinned archive + the exact patch, probes the
  Tailwind candidate scan, audits CSS class presence against a reference release
  CSS, and writes provenance into a private stage directory.
```

`manifest.json` is the single source of truth for pinned hashes; do not copy
abbreviated hashes into other documents.

## Current overlay

| Field | Value |
| --- | --- |
| Overlay | `avatar-member-cache` |
| Base tag | `v1.21.23-source.1` |
| Base commit, archive hash, lockfile hash | `manifest.json` → `pinnedBase` |
| Patch hash, allowlisted files, per-file hashes | `manifest.json` → `overlay` |

### Why

A successful `POST /api/auth/me/avatar` or `PATCH /api/auth/me` is the
authoritative identity for the signed-in user, but the mounted rosters are
membership snapshots: the server roster keeps the pre-write row, and channel
message rows resolve their sender avatar from the channel roster, which is only
re-read on membership events. Uploading from Settings or the member panel
therefore left the previous avatar in an already-open channel until a reload.

The overlay makes `updateProfile` and `uploadAvatar` re-read the server roster and
broadcast the existing channel-member invalidation after the write succeeds. The
invalidation also drops a coalesced roster request that started before it, so the
reload issues a fresh GET instead of adopting a pre-write response that may land
after the write; the per-hook request version discards the late old response. It
adds no WebSocket frame and no server change; the refresh is best-effort so a
failed roster read cannot turn a successful write into a failed action. The
backend roster payloads (`avatarUrl`/`gravatarHash` on channel members) are a
separate Swift fix; this overlay does not mask their absence.

## Build

```bash
scripts/build-patched-web.py --out /path/to/private/stage \
  --overlay-commit <web-overlay-source-commit> \
  --reference-css /path/to/released/app-shell-*.css
```

The script asserts:

- the pinned archive SHA-256 equals `manifest.pinnedBase.archiveSHA256`;
- the patch SHA-256 equals `manifest.overlay.patchSHA256`;
- manifest paths are safe relative paths inside the Web workspace and every
  changed file is allowlisted;
- after applying, the extracted tree differs from the base only in the
  allowlisted files, each with the manifest's expected post-patch hash;
- `pnpm-lock.yaml` is byte-identical to the base;
- after the dependency install and again after the build, every
  baseline/allowlisted source file still hashes to its post-patch value
  (the allowlist authorizes the patch, never later drift), and the
  baseline-vs-patch difference is exactly the allowlist;
- the `node --version` / `pnpm --version` outputs equal the expected versions,
  not just the configured tool names.

Verifiability scope: the **inputs** are byte-verifiable (pinned archive hash +
patch hash + allowlisted source delta + unchanged lockfile). Produced artifact
bytes are expected to be stable for the same inputs and toolchain, but this
script does not claim environment independence (no `SOURCE_DATE_EPOCH` pinning);
chunk file names may differ across environments. The class-presence audit is the
rendering-regression guard that survives that drift.

### Staging path safety (Tailwind candidate scan)

Tailwind v4's candidate scanner honours ancestor ignore files, so a staging path
under a directory whose ancestor `.gitignore` hides the tree produces a bundle
with **silently missing utilities**. This was reproduced on 2026-11-12: a stage
under `/mnt/data/raft-swift-development/tmp/` was hidden by that directory's
`.gitignore` (`*`, created after the 2026-11-08 pinned build), the candidate scan
saw 18 files instead of the full source, and the built `app-shell` CSS lost 715
classes, 120 of them used by the built JS. Building the same archive + patch from
a data-disk path without such an ancestor ignore file reproduces the released CSS
byte for byte.

The builder therefore runs a **scan probe** before the release build (real
`@tailwindcss/oxide` scanner over `packages/web`, asserting the component tree is
present and known source-used utilities are candidates) and fails closed with the
ancestor-ignore diagnosis. Pick `--out` on the data disk outside any tree hidden
by an ancestor `.gitignore`.

After the build, `class-presence-audit.json` records the difference between the
reference release CSS classes and the built CSS classes; the build fails if a
class that is both present in the reference CSS and used as a literal in the
built JS is missing from the built CSS (reference-class ∩ built-JS-literal
guard). It is not a proof over every dynamically constructed class name. For this
overlay the built `app-shell` CSS is additionally byte-identical to the released
pinned CSS, which is stronger evidence than the class audit alone. Reusing
already-qualified CSS by concatenation is not used.

## Verification performed for this overlay

- Source replay: pinned archive hash and patch hash match the manifest, only the
  two allowlisted files differ, lockfile unchanged.
- Behavior: the new `avatarProfileMemberCacheInvalidation` suite passes 6/6 on
  the overlay. As a **control**, the same test source executed against the
  unpatched pinned archive tree fails 4 of 6 (the two cache-neutrality cases pass
  because they assert the absence of invalidation).
- Roster race: two DOM cases hold a channel-roster GET pending, then deliver an
  avatar upload / channel-member invalidation, then release the old response.
  The overlay passes 2/2 (a fresh GET is issued and the final roster avatar is
  the new URL). As a **control**, the same tests against the unpatched hook fail
  2/2: no fresh GET is issued (the invalidation reuses the in-flight request).
- Focused/affected Web suites (Node and DOM selections) and `typecheck` pass.
- Release build from the replayed archive + patch: `tsc --noEmit`, `vite build`
  and the four bundle guards pass from a scan-safe staging path; the post-install
  and post-build source proofs pass for every baseline/allowlisted file;
  `app-shell` CSS is byte-identical to the released pinned CSS and the
  class-presence audit reports zero missing classes.
- Artifact delta against the pinned release: identical CSS, 19 renamed JS chunks
  from content-hash propagation, 5 changed metadata files (`index.html`,
  `.vite` manifests, `desktop-manifest.json`, `_headers`); total bytes differ
  only by the overlay JS delta.
- Status: **private build candidate only, not qualified for deployment.** Root
  owns integration gate, release metadata, static publish and activation.

Logs and stage artifacts live on the data disk under a private evidence
directory, never in Git.
