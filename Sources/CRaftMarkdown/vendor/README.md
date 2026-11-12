# Native Markdown parser dependency

Vendored from [MD4C release-0.5.2](https://github.com/mity/md4c/tree/release-0.5.2/src), under the MIT license in LICENSE.md. The original copyright/license comments remain in all four upstream files. `entity.c` is the release's generated HTML named-entity table (`scripts/build_entity_map.py` in upstream); it is copied rather than regenerated. It decodes Markdown link destinations only, not ordinary prose.

`PROVENANCE.json` records original downloaded source hashes and the local file hashes. The parent bridge is Raft code; MD4C is built directly into the target, with no JavaScript runtime and no external parser process.

## Local patch record

All source offsets are half-open indices in the original UTF16 input. Parsing is synchronous and all per-message allocations are freed before returning. There is no process-global parser state.

- `md4c.h`: enable the existing UTF16 parser mode on Unix using `uint16_t`; append one private `source_range` callback to `MD_PARSER`. This header is private to this target, not an upstream ABI promise.
- `md4c.c`: use C11 UTF16 literals and a UTF16 string-search helper on Unix. Replace Windows-only `WORD` casts with `MD_CHAR`. Correct upstream UTF16 defects: the previous-codepoint helper reads `off-1` and recognizes surrogate pairs at offset two; the HTML tag-length macro measures the actual UTF16 literal; the emphasis palette uses the configured literal type.
- `md4c.c`: report accepted code spans, links, images and definitions through the private hook at parser recognition/output sites. Preserve reference-vs-inline metadata with one mark flag; reference-use href is deliberately empty. The callback observes parser decisions and never recognizes Markdown independently.
- `md4c.c`: retain raw fence source boundaries and quote/list container facts in block records, including discarded closing fences, implicit container termination, and unclosed EOF. These fields affect source reporting only.
- `md4c.c`: restore the destination endpoint when an optional reference-definition title has trailing invalid content; include accepted definition trailing horizontal whitespace in source reporting. Initialize the definition label's line index for strict compiler analysis.
- `md4c.c`: ordinary link definitions beginning with a caret are not consumed, matching the adapter's GFM footnote treatment; footnote text remains eligible for normal parsing.
- `md4c.c`: replace the fixed 32-backtick closer cache with a lazily allocated paragraph-sized cache, preserving the no-rescan optimization for arbitrary delimiter lengths.
- `md4c.c`: the existing permissive resolver delegates HTTP(S), WWW and email to GFM-compatible recognizers. This adapts the pinned MIT-licensed [micromark GFM autolink literal 2.1.0](https://github.com/micromark/micromark-extension-gfm-autolink-literal/blob/2.1.0/dev/lib/syntax.js) `tokenizeDomain`, `tokenizePath`, `tokenizeTrail`, `tokenizeEmailAutolink`, and preceding-character rules. It retains literal href spelling, permits mention characters in paths/queries/fragments, balances closing parentheses, handles named-reference-like trailing punctuation, and gives email recognition priority over WWW. It accepts case-insensitive HTTP(S)/WWW and does not recognize FTP literals. The original angle-autolink parser is unchanged. Both MIT notices are in LICENSE.md.
- `md4c.c`: URL/email recognition uses amortized per-pass mark cursors to preserve unmatched-label state through emphasis while treating only actual code/link/image syntax as opaque. It validates hosts before scanning URL tails and caches rejected underscore-domain intervals, avoiding repeated scans of invalid literal candidates. Host punctuation follows the reference tokenizer's UTF16-unit classification, including astral host characters.
- `md4c.c`: HTML declaration blocks require an ASCII uppercase letter after `<!`, correcting upstream's broader ASCII check. Empty fenced list items include the opening line break only at actual sibling-item termination or true EOF; ordinary implicit container termination leaves the line break outside the code range.
- The bridge enables only explicit URL/email/WWW autolink, table, strikethrough and task-list flags, plus disabled indented code. No future upstream dialect flag can silently enable another extension.

The JavaScript reference parser remains a development-only differential oracle. A finite passing corpus is evidence for those inputs, not a proof of equivalence for every Markdown string.
