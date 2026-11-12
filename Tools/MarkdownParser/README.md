# Native message Markdown verification

Production uses the pinned MD4C C parser in `Sources/CRaftMarkdown`. Swift keeps
original UTF16 source slices and the existing mention policy. Each invocation
owns and releases its native scratch; no JS runtime or global parsing lock is
required. Vendored upstream hashes, license and local patches are documented in
`Sources/CRaftMarkdown/vendor`.

`reference/` retains the former production mdast/GFM bundle, license and
provenance, unchanged, as a development-only oracle. `entry.mjs` is its source
adapter. None of these files are SwiftPM production resources. Node is needed
for differential checks only; no npm install is needed.

## Differential comparison

Compile a shared copy of the same C sources, then compare its output with the
pinned JS adapter:

```bash
mkdir -p /mnt/data/raft-swift-development/artifacts/native-markdown
cc -std=c11 -O2 -shared -fPIC -I Sources/CRaftMarkdown/include \
  Sources/CRaftMarkdown/raft_markdown.c Sources/CRaftMarkdown/vendor/md4c.c \
  Sources/CRaftMarkdown/vendor/entity.c \
  -o /mnt/data/raft-swift-development/artifacts/native-markdown/native.so
python3 Tools/MarkdownParser/compare-native.py \
  --library /mnt/data/raft-swift-development/artifacts/native-markdown/native.so \
  --output /mnt/data/raft-swift-development/artifacts/native-markdown/comparison.json
```

The deterministic corpus covers source ranges, references and definitions,
nested images/links/code, disabled indented code, GFM autolinks, named/numeric
entities, emoji, CJK, malformed input, long backticks, line endings and container
boundaries. Pass `--spec /path/to/CommonMark-spec.json` to add specification
examples, prose-wrapped examples and variants containing mention handles.
The external spec corpus is optional and is not downloaded during tests.

A mismatch exits nonzero and writes the input, both range lists and both
surfaces (original prose runs and linked handles). Raw range differences are
counted separately. This checks the tested inputs, not equivalence for every
possible Markdown document. Public HTTP mention tests remain the acceptance
surface for resolution, warnings, pending actions and persisted records.

## Isolated parser memory

`measure-memory.py` runs a repeated deterministic corpus through the C API and
reports Linux RSS/PSS/anonymous memory before initialization, after initialization,
after parsing and after destruction. Use a fresh process for every run:

```bash
python3 Tools/MarkdownParser/measure-memory.py \
  --library /mnt/data/raft-swift-development/artifacts/native-markdown/native.so
```

For a historical bridge library, also pass
`--reference-bundle Tools/MarkdownParser/reference/raft-markdown-parser.js` and
make that release's JavaScriptCore library available to the dynamic loader.
Use identical corpus versions and round counts for both runs. Driver overhead
is included; these results do not predict the whole server's production RSS.

`measure-server-memory.py --reference <old-RaftServer> --native <new-RaftServer>
--artifacts <directory>` compares three fresh startups of each executable with
identical development settings, no database, and full loopback listener
configuration. It samples at the parser/application startup log checkpoint,
before user traffic; it does not verify HTTP readiness or measure throughput.
Use matching compiler/build configurations. It records RSS, anonymous/file pages
and requires JavaScriptCore mapped in the reference and absent in the native
process. These are startup checkpoints, not production memory or a deployment.

`check-pathological.py --library <native.so>` verifies the pinned outcomes for
repeated rejected URL candidates and checks CPU growth as input grows about 4×.
The guard permits 8.5× growth to allow timing noise but rejects the former
roughly 16× quadratic growth. Run it against an optimized library.

`sanitize-native.c` accepts length-prefixed UTF16 input for ASan/UBSan checks.
Build it with the same three C parser sources and
`-fsanitize=address,undefined -fno-omit-frame-pointer`, then feed independent
malformed-input and Unicode cases. It creates/destroys a context per case and
frees every returned allocation. Sanitizer success is bounded by that corpus.

## Service and release checks

```bash
make check FILTER='nativeMarkdown|publicMention'
make gate
python3 deploy/swift-production/test_markdown_runtime.py
```

The real-process startup test checks that the executable completes its parser
self-check without JavaScriptCore mapped. Public mention tests exercise both
human and agent send paths, raw and typed names, and actual pending/stored
mention outcomes. Staged release verification checks the exact resource bundle
and rejects any mapped JavaScriptCore for a native release; historical JS
releases still require the packaged engine.
