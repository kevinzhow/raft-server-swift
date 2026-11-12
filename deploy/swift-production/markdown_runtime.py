"""Resource profiles for native Markdown and historical JavaScriptCore releases."""
from __future__ import annotations

BASE_RESOURCES = frozenset({"Info.plist", "owner-opener-team-mode.html"})
JSC_RESOURCES = frozenset({
    "raft-markdown-parser.js",
    "raft-markdown-parser.LICENSE.txt",
    "raft-markdown-parser.provenance.json",
})


def resource_profile(names: set[str]) -> str:
    """Accept only a complete known bundle; never treat partial JS as native."""
    if names == BASE_RESOURCES | {"MD4C.LICENSE.txt"}:
        return "native"
    if names == BASE_RESOURCES | JSC_RESOURCES:
        return "javascriptcore"
    raise ValueError(f"unexpected resource bundle contents: {sorted(names)}")


def check_parser_mapping(profile: str, mappings: list[dict[str, str]]) -> bool:
    """Native forbids JSC anywhere; historical JS requires its packaged engine."""
    if profile not in {"native", "javascriptcore"}:
        raise ValueError(f"unknown Markdown runtime profile: {profile}")
    engines = [
        item for item in mappings
        if item["name"].startswith("libjavascriptcoregtk-")
        or item["name"] == "JavaScriptCore"
    ]
    if profile == "native" and engines:
        raise ValueError("JavaScriptCore is mapped by a native Markdown release")
    staged_engine = any(
        item["kind"] == "staged-release"
        and item["name"].startswith("libjavascriptcoregtk-4.1.so.")
        for item in engines
    )
    if profile == "javascriptcore" and not staged_engine:
        raise ValueError("JavaScriptCore is not mapped from the staged runtime")
    return staged_engine
