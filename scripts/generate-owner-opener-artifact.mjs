#!/usr/bin/env node
// Regenerates the pinned Owner Opener v2 Team-Mode artifact resource.
//
// Upstream `packages/server/src/services/onboardingService.ts` returns the
// constant `OWNER_OPENER_TEAM_MODE_HTML` from
// `packages/server/src/services/ownerOpenerArtifactHtml.ts` as the artifact
// bytes (UTF-8). This port ships those exact bytes as a SwiftPM resource; this
// script evaluates the pinned TypeScript module with Node's type stripping and
// writes/verifies the resource without retyping any content.
//
// Usage:
//   node scripts/generate-owner-opener-artifact.mjs --upstream-root <raft-source-root> [--check]
//
// `--check` exits 1 when the checked-in resource differs from the pinned bytes.

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const outputPath = join(repoRoot, "Sources/RaftHTTP/Resources/owner-opener-team-mode.html");

function parseArgs(argv) {
  let upstreamRoot = null;
  let check = false;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--upstream-root") upstreamRoot = argv[++index] ?? null;
    else if (arg === "--check") check = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!upstreamRoot) throw new Error("--upstream-root <raft-source-root> is required");
  return { upstreamRoot: resolve(upstreamRoot), check };
}

const { upstreamRoot, check } = parseArgs(process.argv.slice(2));
const modulePath = join(upstreamRoot, "packages/server/src/services/ownerOpenerArtifactHtml.ts");
const moduleUrl = pathToFileURL(modulePath).href;
const { OWNER_OPENER_TEAM_MODE_HTML } = await import(moduleUrl);
if (typeof OWNER_OPENER_TEAM_MODE_HTML !== "string") {
  throw new Error(`${modulePath} did not export OWNER_OPENER_TEAM_MODE_HTML`);
}
const bytes = Buffer.from(OWNER_OPENER_TEAM_MODE_HTML, "utf8");
const sha256 = createHash("sha256").update(bytes).digest("hex");

if (check) {
  const current = readFileSync(outputPath);
  if (!current.equals(bytes)) {
    console.error(`Artifact resource differs from the pinned bytes (${sha256}).`);
    process.exit(1);
  }
  console.log(`Artifact resource matches the pinned bytes (${bytes.length} bytes, sha256 ${sha256}).`);
} else {
  writeFileSync(outputPath, bytes);
  console.log(`Wrote ${outputPath} (${bytes.length} bytes, sha256 ${sha256}).`);
}
