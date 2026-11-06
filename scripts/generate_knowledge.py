#!/usr/bin/env python3
"""Generate the embedded Manual registry for the Swift knowledge feature.

Reads the upstream raft-source v1.21.23 corpus and the ported service constants,
then fills the generated markers in the hand-written template.
"""
import argparse
import os
from pathlib import Path
import re
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--upstream-root", required=True, type=Path,
                    help="raft-source v1.21.23-source.1 checkout or extracted source")
parser.add_argument("--check", action="store_true", help="compare without writing")
args = parser.parse_args()
ROOT = Path(__file__).resolve().parents[1]
UP = str(args.upstream_root.resolve())
SERVICE = f"{UP}/packages/server/src/services/agentKnowledgeService.ts"
TEMPLATE = ROOT / "scripts/templates/knowledge.swift"
OUT = ROOT / "Sources/RaftHTTPServer/Generated/KnowledgeCorpus.swift"

ts = Path(SERVICE).read_text(encoding="utf-8")


def quoted_strings(text):
    return re.findall(r'"((?:[^"\\]|\\.)*)"', text)


def const_array(name):
    m = re.search(r"const " + name + r"\s*=\s*\[(.*?)\]\s*as const;", ts, re.S)
    if not m:
        raise SystemExit(f"array not found: {name}")
    return quoted_strings(m.group(1))


def const_set(name):
    m = re.search(r"const " + name + r"\s*=\s*new Set\(\[(.*?)\]\);", ts, re.S)
    if not m:
        raise SystemExit(f"set not found: {name}")
    return quoted_strings(m.group(1))


def strip_line_comments(text):
    return "\n".join(line.split("//", 1)[0] if not line.lstrip().startswith("*") else line for line in text.split("\n"))


def const_object_block(name):
    m = re.search(r"const " + name + r"[^=]*=\s*\{(.*?)\n\};", ts, re.S)
    if not m:
        raise SystemExit(f"object not found: {name}")
    return strip_line_comments(m.group(1))


def parse_string_array_object(name):
    """Parse `key: [ "a", "b" ]` entries (keys identifier or quoted)."""
    block = const_object_block(name)
    result = {}
    for m in re.finditer(r'(?:"([^"]+)"|([A-Za-z0-9_$]+))\s*:\s*\[', block):
        key = m.group(1) or m.group(2)
        start = m.end()
        depth = 1
        i = start
        while i < len(block) and depth:
            if block[i] == "[":
                depth += 1
            elif block[i] == "]":
                depth -= 1
            i += 1
        inner = block[start: i - 1]
        result[key] = quoted_strings(inner)
    return result


def parse_scalar_object(name, value_type):
    block = const_object_block(name)
    result = {}
    for m in re.finditer(r'(?:"([^"]+)"|([A-Za-z0-9_$]+))\s*:\s*("([^"]*)"|\d+)', block):
        key = m.group(1) or m.group(2)
        raw = m.group(3)
        if raw.startswith('"'):
            result[key] = raw[1:-1]
        else:
            result[key] = int(raw)
    return result


agent_paths = const_array("AGENT_KNOWLEDGE_SOURCE_PATHS")
recipe_paths = const_array("RECIPE_SOURCE_PATHS")
legacy_groups = parse_scalar_object("LEGACY_AGENT_KNOWLEDGE_GROUP_BY_DOC_ID", str)
extra_aliases = parse_string_array_object("EXTRA_AGENT_KNOWLEDGE_ALIASES_BY_DOC_ID")
stop_words = const_set("SEARCH_STOP_WORDS")
synonyms = parse_string_array_object("SEARCH_SYNONYMS")
synonym_replacements = const_set("SEARCH_SYNONYM_REPLACEMENTS")
low_signal = const_set("LOW_SIGNAL_SEARCH_TERMS")
stem_overrides = parse_scalar_object("SEARCH_STEM_OVERRIDES", str)

fuzzy_m = re.search(r"const FUZZY_FIELD_SCORES = \{(.*?)\} as const;", ts, re.S)
fuzzy = {}
for m in re.finditer(r"(docId|title|alias|content)\s*:\s*(\d+)", fuzzy_m.group(1)):
    fuzzy[m.group(1)] = int(m.group(2))

token_routes = []
tr_m = re.search(r"const KNOWLEDGE_TOKEN_ROUTES[^=]*=\s*\[(.*?)\n\];", ts, re.S)
for m in re.finditer(r"\{ tokens: \[(.*?)\], docId: \"([^\"]+)\" \}", tr_m.group(1), re.S):
    token_routes.append((quoted_strings(m.group(1)), m.group(2)))

whitelist = set(const_array("RECIPE_STRIPPED_PREFIX_WHITELIST_CLASSES") if False else [])
wm = re.search(r"const RECIPE_STRIPPED_PREFIX_WHITELIST_CLASSES[^=]*=\s*new Set\(\[(.*?)\]\);", ts, re.S)
whitelist = set(quoted_strings(wm.group(1)))


def build_agent_aliases(doc_id, relative_path):
    aliases = [
        doc_id,
        relative_path,
        f"agent-knowledge/{relative_path}",
        f"manual/agent-knowledge/{relative_path}",
        f"docs/agent-knowledge/{relative_path}",
    ]
    aliases += extra_aliases.get(doc_id, [])
    group = legacy_groups.get(doc_id)
    if group:
        legacy_path = f"{group}/{doc_id}"
        aliases += [legacy_path, f"agent-knowledge/{legacy_path}", f"manual/agent-knowledge/{legacy_path}", f"docs/agent-knowledge/{legacy_path}"]
    if relative_path == "index":
        aliases += ["agent-knowledge", "manual/agent-knowledge", "docs/agent-knowledge"]
    # preserve first occurrence order for determinism
    seen = set()
    out = []
    for alias in aliases:
        if alias not in seen:
            seen.add(alias)
            out.append(alias)
    return out


def build_recipe_aliases(relative_path):
    aliases = [
        f"recipes/{relative_path}",
        f"manual/recipes/{relative_path}",
        f"docs/recipes/{relative_path}",
    ]
    if relative_path == "index":
        aliases += ["recipes", "manual/recipes", "docs/recipes"]
    if relative_path.split("/")[0] in whitelist:
        aliases.append(relative_path)
    seen = set()
    out = []
    for alias in aliases:
        if alias not in seen:
            seen.add(alias)
            out.append(alias)
    return out


def read_content(source_path):
    path = os.path.join(UP, source_path)
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def swift_raw_string(text, indent):
    # `#"""` raw multiline: no `"""#` sequence exists in the corpus (checked).
    assert '"""#' not in text, "raw string terminator present"
    lines = text.split("\n")
    if text.endswith("\n"):
        lines = lines[:-1]
    pad = " " * indent
    body = "\n".join((pad + line) if line else "" for line in lines)
    return '#"""\n' + body + '\n' + pad + '"""#'


def swift_string(value):
    out = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    return '"' + out + '"'


def swift_string_array(values, indent, per_line=1):
    if not values:
        return "[]"
    pad = " " * indent
    items = [swift_string(v) for v in values]
    if per_line and len(items) > 1:
        return "[\n" + ",\n".join(pad + "    " + item for item in items) + "\n" + pad + "]"
    return "[" + ", ".join(items) + "]"


entries = []
entries.append(
    {
        "docId": "slock-home",
        "aliases": ["slock-home", "raft-home", "rfcs/020-slock-home", "daemon/slock-home", "docs/daemon/slock-home"],
        "sourcePath": "manual/agent-knowledge/slock-home.md",
    }
)
for source_path in agent_paths:
    relative = source_path[len("manual/agent-knowledge/"):-len(".md")]
    if relative != "index" and relative.endswith("/index"):
        raise SystemExit("unexpected nested index")
    doc_id = "index" if relative == "index" else relative.replace("/", ".")
    entries.append(
        {
            "docId": doc_id,
            "aliases": build_agent_aliases(doc_id, relative),
            "sourcePath": source_path,
        }
    )
for source_path in recipe_paths:
    relative = source_path[len("manual/recipes/"):-len(".md")]
    doc_id = f"recipes/{relative}"
    entries.append(
        {
            "docId": doc_id,
            "aliases": build_recipe_aliases(relative),
            "sourcePath": source_path,
        }
    )

# sanity: the upstream registry has exactly this many entries
assert len(entries) == 1 + len(agent_paths) + len(recipe_paths)

registry_parts = []
for entry in entries:
    content = read_content(entry["sourcePath"])
    registry_parts.append(
        "    KnowledgeRegistryEntry(\n"
        f"        docId: {swift_string(entry['docId'])},\n"
        "        aliases: " + swift_string_array(entry["aliases"], 8) + ",\n"
        '        docState: "published",\n'
        '        contentType: "text/markdown",\n'
        f"        sourcePath: {swift_string(entry['sourcePath'])},\n"
        "        content: " + swift_raw_string(content, 8) + "\n"
        "    )"
    )
registry_swift = (
    "/// Embedded corpus: every entry is one upstream registry row. Contents are the\n"
    "/// raw markdown bytes; `sanitizeAgentKnowledgeContent` runs at read time.\n"
    "let knowledgeRegistry: [KnowledgeRegistryEntry] = [\n" + ",\n".join(registry_parts) + ",\n]\n"
)

tables_swift = []
tables_swift.append("struct KnowledgeTokenRoute: Sendable {\n    let tokens: [String]\n    let docId: String\n}\n")
tables_swift.append(
    "let knowledgeTokenRoutes: [KnowledgeTokenRoute] = [\n"
    + ",\n".join(
        "    KnowledgeTokenRoute(tokens: " + swift_string_array(tokens, 4) + f", docId: {swift_string(doc_id)})"
        for tokens, doc_id in token_routes
    )
    + ",\n]\n"
)
tables_swift.append(
    "let searchStopWords: Set<String> = [\n"
    + ",\n".join("    " + swift_string(word) for word in stop_words)
    + ",\n]\n"
)
tables_swift.append(
    "let searchSynonyms: [String: [String]] = [\n"
    + ",\n".join(
        "    " + swift_string(key) + ": " + swift_string_array(value, 4)
        for key, value in synonyms.items()
    )
    + ",\n]\n"
)
tables_swift.append(
    "let searchSynonymReplacements: Set<String> = [\n"
    + ",\n".join("    " + swift_string(word) for word in synonym_replacements)
    + ",\n]\n"
)
tables_swift.append(
    "let lowSignalSearchTerms: Set<String> = [\n"
    + ",\n".join("    " + swift_string(word) for word in low_signal)
    + ",\n]\n"
)
tables_swift.append(
    "let searchStemOverrides: [String: String] = [\n"
    + ",\n".join(
        "    " + swift_string(key) + ": " + swift_string(value)
        for key, value in stem_overrides.items()
    )
    + ",\n]\n"
)
tables_swift.append(
    "let fuzzyFieldScores: [String: Int] = [\n"
    + ",\n".join("    " + swift_string(key) + ": " + str(value) for key, value in fuzzy.items())
    + ",\n]\n"
)
tables_swift = "\n".join(tables_swift)

template = TEMPLATE.read_text(encoding="utf-8")
for section in ("TABLES", "REGISTRY"):
    marker = f"// ==== GENERATED {section} START ====\n// ==== GENERATED {section} END ===="
    if template.count(marker) != 1:
        raise SystemExit(f"template needs exactly one empty {section} marker pair")
template = template.replace(
    "// ==== GENERATED TABLES START ====\n// ==== GENERATED TABLES END ====",
    "// ==== GENERATED TABLES START ====\n" + tables_swift + "\n// ==== GENERATED TABLES END ====",
)
template = template.replace(
    "// ==== GENERATED REGISTRY START ====\n// ==== GENERATED REGISTRY END ====",
    "// ==== GENERATED REGISTRY START ====\n" + registry_swift + "\n// ==== GENERATED REGISTRY END ====",
)
# The template contains the maintained Swift support code. Recovered from the
# original one-time generator; corpus inputs remain the pinned upstream tag.
if args.check:
    if not OUT.is_file() or OUT.read_bytes() != template.encode("utf-8"):
        print(f"out of date: {OUT}", file=sys.stderr)
        raise SystemExit(1)
else:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(template, encoding="utf-8")

print(f"{'checked' if args.check else 'wrote'} {OUT}: {len(entries)} entries, {os.path.getsize(OUT)} bytes")
print(f"agents={len(agent_paths)} recipes={len(recipe_paths)} aliases_total={sum(len(e['aliases']) for e in entries)}")
