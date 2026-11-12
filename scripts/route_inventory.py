#!/usr/bin/env python3
"""Static route inventory candidates: upstream Express server -> Swift Vapor port.

The upstream half parses `packages/server/src/app.ts` mounts plus every
`routes/*.ts` router registration (including nested mounts, factory routers and
local path constants). The Swift half reads a `METHOD<TAB>path` dump produced by
`Tests/RaftHTTPServerTests/RouteInventoryDumpTests.swift`; when no dump is given
the script boots that test through the pinned toolchain and reads its output.

Both sides normalize path parameters (`:id`, `{id}`) to `:param`, then report
exact matches, parameter-variant matches (one side has a literal where the other
has a parameter), missing upstream routes and extra Swift routes. Missing routes
are annotated with whether the pinned Web/CLI sources reference the path.

Usage:
  python3 scripts/route_inventory.py --write docs/route-inventory.md
  python3 scripts/route_inventory.py --check
  python3 scripts/route_inventory.py --swift-dump /tmp/swift-routes.tsv
  python3 scripts/route_inventory.py --upstream-only --json-out /data/entries.json

JSON preserves raw registrations and source locations, including unresolved
candidates. It explicitly excludes any completeness or behavioral parity claim.
`--upstream-only` never invokes Swift. The normal Markdown comparison remains a
normalized shape comparison; it is not a parameter-domain or behavior check.

Exit status: 0 = report generated (or `--check` matched), 1 = `--check` drift or
unparsable input, 2 = usage/IO error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field, replace
from pathlib import Path

DEFAULT_UPSTREAM = "/mnt/data/tmp/grok/raft-source-v1.21.23"
DEFAULT_SWIFT = "/mnt/data/opt/swift-6.4.1-RELEASE-ubuntu26.04/usr/bin/swift"
METHODS = ("get", "post", "put", "patch", "delete", "head", "options", "all")
HTTP_METHODS = {method: method.upper() for method in METHODS}
ROUTE_IMPORT_RE = re.compile(r'import\s*\{([^}]*)\}\s*from\s*["\'](\./routes/[^"\']+)["\']')
DEFAULT_IMPORT_RE = re.compile(r'import\s+(\w+)\s+from\s*["\'](\./routes/[^"\']+)["\']')
ROUTER_VAR_RE = re.compile(r'(?:export\s+)?const\s+(\w+)\s*(?::\s*[\w$.]+\s*)?=\s*Router\s*\([^)]*\)')
CONST_STRING_RE = re.compile(r'(?:export\s+)?const\s+(\w+)\s*(?::\s*[^=]+)?=\s*("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')')
CONTRACT_ROUTE_RE = re.compile(
    r'(?:export\s+)?const\s+(\w+)\s*(?::\s*[^=]+)?=\s*(uuidContractRoute|contractRoute)\s*\(\s*["\'](\w+)["\']\s*,\s*["\'](\w+)["\']\s*\)(\.replace\([^)]*\))?'
)


class ParseError(Exception):
    pass


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def strip_comments(text: str) -> str:
    """Remove // and /* */ comments while preserving string literals."""
    out: list[str] = []
    i, n = 0, len(text)
    quote: str | None = None
    while i < n:
        ch = text[i]
        if quote:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch == '"' or ch == "'" or ch == "`":
            quote = ch
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] not in "/*":
            previous = i - 1
            while previous >= 0 and text[previous].isspace():
                previous -= 1
            if previous < 0 or text[previous] in "(,=:[!&|?{};":
                try:
                    end = skip_regex(text, i)
                except ParseError:
                    pass
                else:
                    out.append(text[i:end])
                    i = end
                    continue
        if ch == "/" and i + 1 < n:
            if text[i + 1] == "/":
                while i < n and text[i] != "\n":
                    out.append(" ")
                    i += 1
                continue
            if text[i + 1] == "*":
                out.extend("  ")
                i += 2
                while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
                out.extend("  ")
                i += 2
                continue
        out.append(ch)
        i += 1
    return "".join(out)


def is_ident_start(ch: str) -> bool:
    return ch.isalpha() or ch in "_$"


def is_ident_char(ch: str) -> bool:
    return ch.isalnum() or ch in "_$"


def skip_string(text: str, i: int) -> int:
    quote = text[i]
    i += 1
    while i < len(text):
        if text[i] == "\\":
            i += 2
            continue
        if text[i] == quote:
            return i + 1
        i += 1
    raise ParseError("unterminated string")


def skip_regex(text: str, i: int) -> int:
    """Skip a JS regex literal starting at i (the opening slash)."""
    i += 1
    in_class = False
    while i < len(text):
        ch = text[i]
        if ch == "\\":
            i += 2
            continue
        if ch == "[":
            in_class = True
        elif ch == "]":
            in_class = False
        elif ch == "/" and not in_class:
            i += 1
            while i < len(text) and text[i].isalpha():
                i += 1
            return i
        elif ch == "\n":
            raise ParseError("unterminated regex")
        i += 1
    raise ParseError("unterminated regex")


def extract_call(text: str, open_index: int) -> tuple[str, int]:
    """Return argument text inside `( ... )` and the index after `)`."""
    if text[open_index] != "(":
        raise ParseError(f"expected '(' at {open_index}")
    i = open_index + 1
    start = i
    depth = 1
    while i < len(text):
        ch = text[i]
        if ch in "\"'`":
            i = skip_string(text, i)
            continue
        if ch == "/" and i + 1 < len(text) and text[i + 1] not in "/*":
            # A slash after an operator/comma is a regex literal; after an
            # identifier it is division, which none of these route files use in
            # an argument head.
            prev = text[start:i].rstrip()[-1:] or ""
            if prev in "(,=:[!&|?{};\n" or prev == "":
                i = skip_regex(text, i)
                continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return text[start:i], i + 1
        i += 1
    raise ParseError("unterminated call")


def split_args(text: str) -> list[str]:
    """Split a call argument list at top-level commas."""
    args: list[str] = []
    start = 0
    i = 0
    depth = 0
    while i < len(text):
        ch = text[i]
        if ch in "\"'`":
            i = skip_string(text, i)
            continue
        if ch == "/" and i + 1 < len(text) and text[i + 1] not in "/*":
            prev = text[start:i].rstrip()[-1:] or ""
            if prev in "(,=:[!&|?{};\n" or prev == "":
                i = skip_regex(text, i)
                continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            args.append(text[start:i].strip())
            start = i + 1
        i += 1
    tail = text[start:].strip()
    if tail:
        args.append(tail)
    return args


def unquote(value: str) -> str | None:
    value = value.strip()
    if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
        body = value[1:-1]
        body = body.replace("\\/", "/").replace("\\'", "'").replace('\\"', '"')
        return body
    return None


@dataclass
class UpstreamRoute:
    method: str
    path: str
    file: str
    regex: bool = False
    source_line: int | None = None
    raw_method: str | None = None
    raw_path_expression: str | None = None
    registration_path: str | None = None
    mount_sources: list[dict] = field(default_factory=list)


def upstream_route(method: str, path: str, file: Path, text: str, offset: int,
                   expression: str, regex: bool = False) -> UpstreamRoute:
    return UpstreamRoute(method.upper(), path, str(file), regex,
                         text.count("\n", 0, offset) + 1, method, expression, path)


def mounted_route(route: UpstreamRoute, prefix: str, file: Path, text: str,
                  offset: int, expression: str) -> UpstreamRoute:
    return replace(route, path=join_paths(prefix, route.path), mount_sources=[{
        "file": str(file), "line": text.count("\n", 0, offset) + 1,
        "raw_path_expression": expression, "resolved_prefix": prefix,
        "conditions": "unknown: control flow and feature gates are not evaluated",
    }, *route.mount_sources])


@dataclass
class SwiftRoute:
    method: str
    path: str


@dataclass
class Inventory:
    upstream: list[UpstreamRoute] = field(default_factory=list)
    swift: list[SwiftRoute] = field(default_factory=list)


class UpstreamParser:
    def __init__(self, root: Path):
        self.root = root
        self.src = root / "packages" / "server" / "src"
        self.shared = root / "packages" / "shared" / "src"
        self.routes_dir = self.src / "routes"
        self.route_cache: dict[Path, list[UpstreamRoute]] = {}
        self.nested_cache: dict[Path, dict[str, list[tuple[str, Path, str]]]] = {}
        self.router_vars_cache: dict[Path, set[str]] = {}
        self.const_cache: dict[Path, dict[str, str]] = {}
        self.contract_paths: dict[str, str] = {}
        self.agent_api_contract: dict[str, tuple[str, str]] = {}
        self.extraction_errors: list[str] = []
        self._load_contract_paths()
        self._load_agent_api_contract()

    # -- shared contract operation paths -----------------------------------
    def _load_contract_paths(self) -> None:
        if not self.shared.exists():
            return
        for path in self.shared.rglob("*.ts"):
            try:
                text = strip_comments(read(path))
            except OSError:
                continue
            for match in re.finditer(r"\b(\w+)\s*:\s*defineOperation\s*\(\s*\{", text):
                op = match.group(1)
                body, _ = extract_call(text, text.index("(", match.start()))
                body_match = re.search(r'\bpath\s*:\s*("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')', body)
                if body_match:
                    value = unquote(body_match.group(1))
                    if value:
                        self.contract_paths.setdefault(op, value)

    def _load_agent_api_contract(self) -> None:
        """Dynamic agent API routes: key -> (METHOD, path) from the shared contract."""
        contract_file = self.shared / "agentApiContract.ts"
        if not contract_file.exists():
            return
        text = strip_comments(read(contract_file))
        for match in re.finditer(r"\b(\w+)\s*:\s*route\s*\(\s*\{", text):
            key = match.group(1)
            body, _ = extract_call(text, text.index("(", match.start()))
            method = re.search(r'\bmethod\s*:\s*"(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)"', body)
            path = re.search(r'\bpath\s*:\s*("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')', body)
            if method and path:
                value = unquote(path.group(1))
                if value is not None:
                    self.agent_api_contract.setdefault(key, (method.group(1), value))

    def dynamic_agent_api_routes(self, file: Path, var: str) -> list[UpstreamRoute]:
        """Routes registered through `registerAgentApiRoute("key", ...)`.

        The helper's body names the Router() variable it registers on; the
        contract key gives the method and the router-relative path.
        """
        text = strip_comments(read(file))
        helper = re.search(r"(?:export\s+)?function\s+registerAgentApiRoute\s*(?:<[^>]*>)?\s*\(", text)
        if not helper:
            return []
        brace = text.find("{", helper.end())
        if brace < 0:
            return []
        depth = 1
        i = brace + 1
        while i < len(text) and depth:
            if text[i] in "\"'`":
                i = skip_string(text, i)
                continue
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        body = text[brace:i]
        target = re.search(r"(?<![\w$.])(\w+)\.(get|post|put|patch|delete|head|options)\(route\.path", body)
        if not target or target.group(1) != var:
            return []
        routes: list[UpstreamRoute] = []
        for match in re.finditer(r"(?<![\w$.])registerAgentApiRoute\s*\(", mask_ts_literals(text)):
            args_text, _ = extract_call(text, match.end() - 1)
            args = split_args(args_text)
            if not args:
                continue
            key = unquote(args[0])
            contract = self.agent_api_contract.get(key or "")
            if contract:
                routes.append(upstream_route(contract[0], contract[1], file, text,
                                             match.start(), args[0]))
        return routes

    # -- file helpers -------------------------------------------------------
    def resolve_import(self, from_file: Path, spec: str) -> Path:
        base = (from_file.parent / spec).resolve()
        if base.suffix == ".ts":
            return base
        candidate = base.with_suffix(".ts")
        if candidate.exists():
            return candidate
        index = base / "index.ts"
        if index.exists():
            return index
        return base

    def router_vars(self, file: Path) -> set[str]:
        if file not in self.router_vars_cache:
            text = strip_comments(read(file))
            self.router_vars_cache[file] = set(ROUTER_VAR_RE.findall(text))
        return self.router_vars_cache[file]

    def consts(self, file: Path) -> dict[str, str]:
        if file in self.const_cache:
            return self.const_cache[file]
        text = strip_comments(read(file))
        consts: dict[str, str] = {}
        for name, literal in CONST_STRING_RE.findall(text):
            value = unquote(literal)
            if value is not None:
                consts[name] = value
        for name, factory, op, _method, replace in CONTRACT_ROUTE_RE.findall(text):
            value = self.contract_paths.get(op)
            if value is None:
                continue
            mount = consts.get("ATTACHMENT_MOUNT")
            if factory in {"contractRoute", "uuidContractRoute"} and mount and value.startswith(mount + "/"):
                value = value[len(mount):]
            if replace:
                pair = re.search(r'\.replace\(\s*("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')\s*,\s*("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')', replace)
                if pair:
                    old, new = unquote(pair.group(1)), unquote(pair.group(2))
                    if old is not None and new is not None:
                        value = value.replace(old, new)
            consts[name] = value
        self.const_cache[file] = consts
        return consts

    def imported_router_names(self, file: Path) -> dict[str, tuple[Path, str]]:
        """local name -> (module file, exported/router/method name)."""
        text = strip_comments(read(file))
        result: dict[str, tuple[Path, str]] = {}
        for names, spec in ROUTE_IMPORT_RE.findall(text):
            module = self.resolve_import(file, spec)
            for item in names.split(","):
                item = item.strip()
                if not item:
                    continue
                if " as " in item:
                    original, alias = [part.strip() for part in item.split(" as ", 1)]
                else:
                    original = alias = item
                result[alias] = (module, original)
        for default, spec in DEFAULT_IMPORT_RE.findall(text):
            result[default] = (self.resolve_import(file, spec), "default")
        return result

    def path_from_arg(self, arg: str, file: Path) -> tuple[str | None, bool]:
        value = unquote(arg)
        if value is not None:
            return value, False
        arg = arg.strip()
        if arg.startswith("`"):
            # Interpolation is executable code, not a resolved literal path.
            return (None, False) if "${" in arg else (arg[1:-1], False)
        if arg.startswith("/"):
            try:
                end = skip_regex(arg, 0)
                body = arg[1:end]
                # Drop the trailing delimiter and flags that skip_regex consumed.
                close = body.rfind("/")
                if close >= 0:
                    body = body[:close]
                return body, True
            except ParseError:
                return arg, True
        if re.fullmatch(r"[A-Za-z_$][\w$]*", arg):
            resolved = self.consts(file).get(arg)
            if resolved is not None:
                return resolved, False
        return None, False

    # -- router extraction --------------------------------------------------
    def parse_router_var(self, file: Path, var: str) -> list[UpstreamRoute]:
        """Only the registrations made on one Router() variable."""
        key = (file, var)
        if key in self.route_cache:
            return self.route_cache[key]
        text = strip_comments(read(file))
        routes: list[UpstreamRoute] = []
        pattern = re.compile(rf"(?<![\w$.]){re.escape(var)}\.(" + "|".join(METHODS) + r")\s*\(")
        for match in pattern.finditer(mask_ts_literals(text)):
            method = match.group(1)
            try:
                args_text, _ = extract_call(text, match.end() - 1)
            except ParseError:
                continue
            args = split_args(args_text)
            if not args:
                continue
            path, is_regex = self.path_from_arg(args[0], file)
            if path is not None:
                routes.append(upstream_route(method, path, file, text, match.start(), args[0], is_regex))
        # Nested mounts: this router.use("prefix", childRouter)
        for match in re.finditer(rf"(?<![\w$.]){re.escape(var)}\.use\s*\(", mask_ts_literals(text)):
            try:
                args_text, _ = extract_call(text, match.end() - 1)
            except ParseError:
                continue
            args = split_args(args_text)
            if len(args) < 2:
                continue
            prefix, is_regex = self.path_from_arg(args[0], file)
            if prefix is None or is_regex:
                continue
            for child_name, (child_file, export_name) in self.imported_router_names(file).items():
                if not re.search(rf"(?<![\w$.]){re.escape(child_name)}(?![\w$])", args_text):
                    continue
                for child in self.router_routes(child_file, export_name, set()):
                    routes.append(mounted_route(child, prefix, file, text, match.start(), args[0]))
        routes.extend(self.dynamic_agent_api_routes(file, var))
        self.route_cache[key] = routes
        return routes

    def parse_router_file(self, file: Path) -> list[UpstreamRoute]:
        routes: list[UpstreamRoute] = []
        for var in self.router_vars(file):
            routes.extend(self.parse_router_var(file, var))
        return routes

    def factory_routes(self, file: Path, function: str) -> list[UpstreamRoute]:
        text = strip_comments(read(file))
        match = re.search(rf"(?:export\s+)?function\s+{re.escape(function)}\s*\(", text)
        if not match:
            return []
        brace = text.find("{", match.end())
        if brace < 0:
            return []
        depth = 1
        i = brace + 1
        while i < len(text) and depth:
            if text[i] in "\"'`":
                i = skip_string(text, i)
                continue
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        body = text[brace:i]
        router_match = ROUTER_VAR_RE.search(body)
        if not router_match:
            return []
        var = router_match.group(1)
        routes: list[UpstreamRoute] = []
        pattern = re.compile(rf"(?<![\w$.]){re.escape(var)}\.(" + "|".join(METHODS) + r")\s*\(")
        for reg in pattern.finditer(mask_ts_literals(body)):
            args_text, _ = extract_call(body, reg.end() - 1)
            args = split_args(args_text)
            if not args:
                continue
            path, is_regex = self.path_from_arg(args[0], file)
            if path is not None:
                routes.append(upstream_route(
                    reg.group(1), path, file, text, brace + reg.start(), args[0], is_regex))
        return routes

    def router_routes(self, file: Path, export_name: str, seen: set[tuple[Path, str]]) -> list[UpstreamRoute]:
        key = (file, export_name)
        if key in seen:
            return []
        seen.add(key)
        if export_name == "default":
            return self.parse_router_file(file)
        if export_name in self.router_vars(file):
            return self.parse_router_var(file, export_name)
        # Factory: createAttachmentUploadSessionRouter(...)
        if re.search(rf"(?:export\s+)?function\s+{re.escape(export_name)}\s*\(", strip_comments(read(file))):
            return self.factory_routes(file, export_name)
        return self.parse_router_file(file)

    # -- app.ts -------------------------------------------------------------
    def parse_app(self) -> list[UpstreamRoute]:
        app_file = self.src / "app.ts"
        text = strip_comments(read(app_file))
        routes: list[UpstreamRoute] = []
        imports = self.imported_router_names(app_file)
        app_consts = self.consts(app_file)
        # Direct app routes.
        for match in re.finditer(r"(?<![\w$.])app\.(" + "|".join(METHODS) + r")\s*\(", mask_ts_literals(text)):
            method = match.group(1)
            args_text, _ = extract_call(text, match.end() - 1)
            args = split_args(args_text)
            if not args:
                continue
            path, is_regex = self.path_from_arg(args[0], app_file)
            if path is None:
                continue
            if is_regex:
                # A regex registration that only attaches rate-limit middleware
                # does not create an endpoint; the limiter is not a handler.
                last = args[-1].strip()
                if len(args) == 2 and re.fullmatch(r"[A-Za-z_$][\w$]*(?:Limiter|Middleware)", last):
                    continue
            routes.append(upstream_route(method, path, app_file, text, match.start(), args[0], is_regex))
        # Mounts.
        for match in re.finditer(r"(?<![\w$.])app\.use\s*\(", mask_ts_literals(text)):
            args_text, _ = extract_call(text, match.end() - 1)
            args = split_args(args_text)
            if len(args) < 2:
                continue
            prefixes: list[str] = []
            first = args[0].strip()
            literal = unquote(first)
            if literal is not None:
                prefixes = [literal]
            else:
                array_items = re.findall(r'("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\')', first)
                prefixes = [value for item in array_items if (value := unquote(item))]
                if not prefixes and re.fullmatch(r"[A-Za-z_$][\w$]*", first):
                    value = app_consts.get(first)
                    if value:
                        prefixes = [value]
            if not prefixes:
                continue
            mounted: list[tuple[Path, str]] = []
            for arg in args[1:]:
                for name, (module, export_name) in imports.items():
                    if re.search(rf"(?<![\w$.]){re.escape(name)}(?![\w$])", arg):
                        # A factory call names its function; a router mount names
                        # its router export.
                        mounted.append((module, export_name))
                        break
            for module, export_name in mounted:
                for route in self.router_routes(module, export_name, set()):
                    for prefix in prefixes:
                        routes.append(mounted_route(route, prefix, app_file, text, match.start(), args[0]))
        return routes


def join_paths(prefix: str, path: str) -> str:
    if not prefix:
        return path
    if not path:
        return prefix
    if path == "/":
        return prefix
    if prefix.endswith("/") and path.startswith("/"):
        return prefix[:-1] + path
    if not prefix.endswith("/") and not path.startswith("/"):
        return prefix + "/" + path
    return prefix + path


def normalize_path(path: str) -> str:
    path = path.strip()
    if not path.startswith("/"):
        path = "/" + path
    path = re.sub(r"\{([A-Za-z_][\w]*)\}", r":\1", path)
    path = re.sub(r":([A-Za-z_][\w]*)", ":param", path)
    # A literal suffix on a parameter (extension-style `:id.png`) is served by
    # the same parameter handler.
    path = re.sub(r":param[^/]*", ":param", path)
    path = re.sub(r"/+", "/", path)
    if len(path) > 1 and path.endswith("/"):
        path = path[:-1]
    return path


def segments(path: str) -> list[str]:
    return [segment for segment in path.split("/") if segment]


def is_param(segment: str) -> bool:
    return segment.startswith(":param")


def param_absorb(upstream: str, swift: str) -> bool:
    """True when Swift's literal is a concrete subset of upstream's parameter.

    The reverse (an upstream literal served only by a generic Swift parameter)
    is a missing endpoint, not a variant: the generic handler would answer a
    different response than the upstream route. The single intended case is
    upstream `…/:targetType/:memberId/role` and Swift
    `…/members/user/:memberId/role`.
    """
    a, b = segments(upstream), segments(swift)
    if len(a) != len(b):
        return False
    return all(x == y or (is_param(x) and not is_param(y)) for x, y in zip(a, b))


@dataclass
class Diff:
    matched: list[tuple[UpstreamRoute, SwiftRoute]]
    param_variants: list[tuple[UpstreamRoute, SwiftRoute]]
    missing: list[UpstreamRoute]
    extra: list[SwiftRoute]


def diff_routes(inventory: Inventory) -> Diff:
    upstream = [route for route in inventory.upstream if not route.regex]
    regex_routes = [route for route in inventory.upstream if route.regex]
    swift = inventory.swift
    swift_by_key: dict[tuple[str, str], list[SwiftRoute]] = {}
    for route in swift:
        swift_by_key.setdefault((route.method, normalize_path(route.path)), []).append(route)
    swift_keys = set(swift_by_key)
    upstream_keys = {(route.method, normalize_path(route.path)) for route in upstream}
    matched: list[tuple[UpstreamRoute, SwiftRoute]] = []
    missing: list[UpstreamRoute] = []
    for route in upstream:
        key = (route.method, normalize_path(route.path))
        candidates = swift_by_key.get(key)
        if candidates:
            matched.append((route, candidates[0]))
        else:
            missing.append(route)
    # A literal path segment on either side can be the other side's parameter
    # (e.g. `/members/user/:id` vs `/members/:targetType/:id`). Only unmatched
    # Swift routes participate, so a generic `/:id` route cannot absorb a
    # distinct literal upstream endpoint it does not exact-match.
    extra_pool = [route for route in swift
                  if (route.method, normalize_path(route.path)) not in upstream_keys]
    param_variants: list[tuple[UpstreamRoute, SwiftRoute]] = []
    still_missing: list[UpstreamRoute] = []
    for route in missing:
        normalized = normalize_path(route.path)
        candidate = next(
            (other for other in extra_pool
             if other.method == route.method and param_absorb(normalized, normalize_path(other.path))),
            None,
        )
        if candidate is not None:
            extra_pool.remove(candidate)
            param_variants.append((route, candidate))
        else:
            still_missing.append(route)
    # A Swift key that satisfies one or more upstream registrations (for example
    # `/share/:param` serving `/share/:id` and `/share/:id.png`) is matched, not
    # extra.
    extra = [route for route in extra_pool if (route.method, normalize_path(route.path)) not in matched_keys(matched)]
    return Diff(matched, param_variants, still_missing + regex_routes, extra)


def matched_keys(matched: list[tuple[UpstreamRoute, SwiftRoute]]) -> set[tuple[str, str]]:
    return {(swift.method, normalize_path(swift.path)) for _, swift in matched}


# -- Web/CLI usage ---------------------------------------------------------

WEB_CLI_CACHE: dict[str, str] = {}


def path_search_patterns(path: str) -> list[re.Pattern[str]]:
    """Build regexes that match both concrete and template-literal call sites."""
    normalized = normalize_path(path)
    suffix = normalized
    if normalized.startswith("/api/"):
        suffix = normalized[len("/api"):]
    patterns = []
    for candidate in {normalized, suffix}:
        parts = []
        for segment in segments(candidate):
            if is_param(segment):
                parts.append(r"(?:\$\{[^}]+\}|[^/\"'`\s]+)")
            else:
                parts.append(re.escape(segment))
        patterns.append(re.compile(r"/" + "/".join(parts) + r"(?=[/\"'`?\s$)]|$)"))
    return patterns


def usage_counts(path: str, source_roots: list[Path]) -> tuple[int, int]:
    web = 0
    cli = 0
    patterns = path_search_patterns(path)
    for root in source_roots:
        if not root.exists():
            continue
        for file in root.rglob("*"):
            if file.suffix not in {".ts", ".tsx", ".js", ".jsx", ".vue", ".svelte"}:
                continue
            key = str(file)
            try:
                text = WEB_CLI_CACHE.get(key)
                if text is None:
                    text = read(file)
                    WEB_CLI_CACHE[key] = text
            except OSError:
                continue
            hits = sum(1 for pattern in patterns if pattern.search(text))
            if hits:
                # `/packages/web/src` and `/packages/cli/src` both end in `src`;
                # classify by the package path, not the leaf directory name.
                if "/packages/web/" in str(root):
                    web += 1
                elif "/packages/cli/" in str(root):
                    cli += 1
    return web, cli


# -- reporting -------------------------------------------------------------

FAMILY_LABELS = {
    "channels": "channels.ts (channel family)",
    "messages": "messages.ts / messageV2",
    "servers": "servers.ts",
    "agents": "agents.ts + agent credentials",
    "internal": "internal*.ts",
    "auth": "auth / login / oauth",
    "public": "public*.ts",
    "attachments": "attachments / upload sessions",
    "tasks": "tasks.ts",
    "notifications": "notifications.ts",
    "misc": "other / top-level",
}


def family_of(path: str) -> str:
    parts = segments(path)
    if not parts:
        return "misc"
    if parts[0] == "api" and len(parts) > 1:
        return parts[1]
    if parts[0] == "internal":
        return "internal"
    if parts[0] in {"share", "oidc", "livez", "health", "robots.txt", ".well-known"}:
        return "misc"
    return parts[0]


def family_label(family: str) -> str:
    return FAMILY_LABELS.get(family, family)


def method_path(route: UpstreamRoute | SwiftRoute) -> str:
    return f"{route.method} {normalize_path(route.path)}"


# Responses `configure` serves through `FallbackMiddleware` rather than the Vapor
# router table, so `app.routes.all` cannot contain them. This list is the set the
# pinned `app.ts` registers at the top level for that middleware.
FALLBACK_HANDLED = {
    ("GET", "/robots.txt"),
    ("GET", "/health"),
    ("GET", "/livez"),
}


def render_report(inventory: Inventory, diff: Diff, usage: dict[str, tuple[int, int]], upstream_root: Path, fallback: list[UpstreamRoute]) -> str:
    total_upstream = len(inventory.upstream)
    total_swift = len(inventory.swift)
    lines: list[str] = []
    lines.append("# Route inventory: upstream Express vs Swift Vapor")
    lines.append("")
    lines.append("Generated by `scripts/route_inventory.py` from the pinned upstream checkout and the")
    lines.append("real FallbackApplication route table. Path parameters are normalized to `:param`.")
    lines.append("")
    lines.append("Raw counts are router-registration counts. The effective-path adjudication is")
    lines.append("[ROUTE-DEVIATIONS.md](ROUTE-DEVIATIONS.md); do not read the raw missing/extra")
    lines.append("counts as missing or newly published user paths.")
    lines.append("")
    lines.append(f"- Upstream: `{upstream_root}` (`v1.21.23-source.1`)")
    lines.append("- Swift table: `Tests/RaftHTTPServerTests/RouteInventoryDumpTests.swift`")
    lines.append("")
    lines.append("## Regenerate")
    lines.append("")
    lines.append("```sh")
    lines.append("python3 scripts/route_inventory.py --write docs/route-inventory.md")
    lines.append("# or with an existing dump:")
    lines.append("python3 scripts/route_inventory.py --swift-dump /tmp/swift-routes.tsv --write docs/route-inventory.md")
    lines.append("```")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append("| Metric | Count |")
    lines.append("| --- | ---: |")
    lines.append(f"| Upstream route registrations | {total_upstream} |")
    lines.append(f"| Swift route registrations | {total_swift} |")
    lines.append(f"| Exact matches | {len(diff.matched)} |")
    lines.append(f"| Parameter-variant matches | {len(diff.param_variants)} |")
    lines.append(f"| Missing in Swift (raw router table) | {len(diff.missing)} |")
    lines.append(f"| Extra in Swift (raw router table) | {len(diff.extra)} |")
    lines.append("")
    lines.append("These raw registration counts are not effective published-path counts. Some raw")
    lines.append("missing rows are served outside the Vapor router table, and some raw extras are")
    lines.append("fail-closed policy wildcards. [ROUTE-DEVIATIONS.md](ROUTE-DEVIATIONS.md)")
    lines.append("classifies every raw missing and extra row and records the effective")
    lines.append("reachable-missing result at the adjudicated commit.")
    lines.append("")
    lines.append("A parameter-variant match means one side registers a literal path segment where")
    lines.append("the other registers a parameter (for example upstream")
    lines.append("`PATCH /:id/members/:targetType/:memberId/role` and Swift")
    lines.append("`PATCH /:channelId/members/user/:memberId/role`). The concrete literal is a")
    lines.append("subset of the parameter route, not a missing endpoint.")
    lines.append("")
    if fallback:
        lines.append("`/robots.txt`, `/health` and `/livez` are served by `FallbackMiddleware` in")
        lines.append("`FallbackApplication.swift`, not by the Vapor router table, so the dump cannot")
        lines.append("list them; they are excluded from the missing count.")
        lines.append("")
    lines.append("## Missing upstream routes")
    lines.append("")
    lines.append("These are raw router-table rows, adjudicated in")
    lines.append("[ROUTE-DEVIATIONS.md](ROUTE-DEVIATIONS.md).")
    lines.append("")
    lines.append("`Web`/`CLI` count source files under `packages/web/src` and `packages/cli/src`")
    lines.append("that reference the normalized call path (full `/api/...` form or the")
    lines.append("path after the API base). `0` means no pinned client reference was found; it")
    lines.append("does not prove no other consumer exists.")
    lines.append("")
    families: dict[str, list[UpstreamRoute]] = {}
    for route in diff.missing:
        families.setdefault(family_of(route.path), []).append(route)
    if not families:
        lines.append("_None._")
        lines.append("")
    for family in sorted(families, key=lambda name: (-len(families[name]), name)):
        routes = sorted(families[family], key=lambda route: (normalize_path(route.path), route.method))
        lines.append(f"### {family_label(family)} — {len(routes)} missing")
        lines.append("")
        lines.append("| Method path | Web | CLI |")
        lines.append("| --- | ---: | ---: |")
        for route in routes:
            web, cli = usage.get(method_path(route), (0, 0))
            lines.append(f"| `{method_path(route)}` | {web} | {cli} |")
        lines.append("")
    lines.append("## Extra Swift routes")
    lines.append("")
    lines.append("These are raw Swift registrations, not parity wins;")
    lines.append("[ROUTE-DEVIATIONS.md](ROUTE-DEVIATIONS.md) classifies every row.")
    lines.append("")
    if not diff.extra:
        lines.append("_None._")
        lines.append("")
    else:
        lines.append("| Method path |")
        lines.append("| --- |")
        for route in sorted(diff.extra, key=lambda route: (normalize_path(route.path), route.method)):
            lines.append(f"| `{method_path(route)}` |")
        lines.append("")
    lines.append("## Parameter variants")
    lines.append("")
    if not diff.param_variants:
        lines.append("_None._")
        lines.append("")
    else:
        lines.append("| Upstream | Swift |")
        lines.append("| --- | --- |")
        for upstream, swift in sorted(diff.param_variants, key=lambda pair: (normalize_path(pair[0].path), pair[0].method)):
            lines.append(f"| `{method_path(upstream)}` | `{method_path(swift)}` |")
        lines.append("")
    lines.append("## Channels family detail")
    lines.append("")
    channel_upstream = [route for route in inventory.upstream if family_of(route.path) == "channels"]
    channel_swift = [route for route in inventory.swift if family_of(route.path) == "channels"]
    channel_missing = {method_path(route) for route in diff.missing if family_of(route.path) == "channels"}
    channel_variant = {method_path(route) for route, _ in diff.param_variants if family_of(route.path) == "channels"}
    lines.append(f"- Upstream channels.ts registrations: {len(channel_upstream)}")
    lines.append(f"- Swift `/api/channels` registrations: {len(channel_swift)}")
    lines.append(f"- Missing: {len(channel_missing)}")
    lines.append(f"- Parameter variants: {len(channel_variant)}")
    lines.append("")
    lines.append("| Upstream method path | Status |")
    lines.append("| --- | --- |")
    for route in sorted(channel_upstream, key=lambda route: (normalize_path(route.path), route.method)):
        key = method_path(route)
        status = "missing" if key in channel_missing else ("parameter variant" if key in channel_variant else "matched")
        lines.append(f"| `{key}` | {status} |")
    lines.append("")
    lines.append("## Full upstream inventory")
    lines.append("")
    lines.append("| Family | Upstream method path | Status |")
    lines.append("| --- | --- | --- |")
    missing_keys = {method_path(route) for route in diff.missing}
    variant_keys = {method_path(route) for route, _ in diff.param_variants}
    for route in sorted(inventory.upstream, key=lambda route: (family_of(route.path), normalize_path(route.path), route.method)):
        key = method_path(route)
        status = "missing" if key in missing_keys else ("parameter variant" if key in variant_keys else "matched")
        lines.append(f"| {family_of(route.path)} | `{key}` | {status} |")
    lines.append("")
    return "\n".join(lines) + "\n"


# -- Swift dump ------------------------------------------------------------

def run_swift_dump(swift_bin: str, swift_root: Path) -> list[SwiftRoute]:
    with tempfile.NamedTemporaryFile(prefix="raft-swift-routes-", suffix=".tsv", delete=False) as handle:
        dump = Path(handle.name)
    env = os.environ.copy()
    env["RAFT_ROUTE_INVENTORY_OUT"] = str(dump)
    try:
        process = subprocess.run(
            [swift_bin, "test", "--filter", "fallbackApplicationRouteTableIsDumpable"],
            cwd=swift_root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if process.returncode != 0:
            sys.stderr.write(process.stdout)
            raise ParseError(f"Swift route dump test failed with exit {process.returncode}")
        return read_swift_dump(dump)
    finally:
        dump.unlink(missing_ok=True)


def read_swift_dump(path: Path) -> list[SwiftRoute]:
    routes: list[SwiftRoute] = []
    for line in read(path).splitlines():
        if not line.strip():
            continue
        method, _, route_path = line.partition("\t")
        if not route_path:
            raise ParseError(f"malformed Swift route line: {line!r}")
        routes.append(SwiftRoute(method.strip(), route_path.strip()))
    return routes


# -- Machine-readable evidence (separate from normalized route matching) -----


def mask_ts_literals(text: str) -> str:
    """Mask comments/literals without moving source offsets; not a TS parser."""
    text = strip_comments(text)
    out = list(text)
    i = 0
    while i < len(text):
        end = i + 1
        if text[i] in "\"'`":
            try:
                end = skip_string(text, i)
            except ParseError:
                end = len(text)
        elif text[i] == "/":
            previous = i - 1
            while previous >= 0 and text[previous].isspace():
                previous -= 1
            if previous < 0 or text[previous] in "(,=:[!&|?{};":
                try:
                    end = skip_regex(text, i)
                except ParseError:
                    pass
        if end > i + 1:
            out[i:end] = ["\n" if ch == "\n" else " " for ch in text[i:end]]
        i = end
    return "".join(out)


def source_ref(file: Path, root: Path, line: int | None) -> dict:
    try:
        name = str(file.relative_to(root))
    except ValueError:
        name = str(file)
    return {"file": name, "line": line}


def raw_constraints(path: str | None, regex: bool = False) -> dict:
    # The complete expression/path remains authoritative. These parameter hints
    # are lexical only; regex groups and escaped slashes need manual review.
    return {
        "raw_path": path,
        "path_kind": "regex" if regex else ("unknown" if path is None else "string"),
        "parameters": [
            {"name": match.group(1), "raw_tail": match.group(2)}
            for match in re.finditer(r":([A-Za-z_][\w]*)([^/]*)", path or "")
        ] if not regex else [],
        "analysis": "verbatim preserved; lexical hints are not validated parameter domains",
    }


def scan_registrations(parser: UpstreamParser, routes: list[UpstreamRoute]) -> tuple[list[dict], list[dict]]:
    """Account for candidate registrations independently of successful extraction.

    The deliberately bounded scanner covers app.ts and non-test routes/**/*.ts,
    known Router variables, the conventional app/router names, computed calls,
    .route chains and the existing Agent helper. Unknown receivers/helpers and
    other files remain explicit coverage limitations, never a completeness claim.
    """
    files = sorted({parser.src / "app.ts", *(
        file for file in parser.routes_dir.rglob("*.ts")
        if not file.name.endswith((".test.ts", ".spec.ts"))
    )})
    effective: dict[tuple[str, int | None], list[UpstreamRoute]] = {}
    for route in routes:
        effective.setdefault((route.file, route.source_line), []).append(route)
    records, sources = [], []
    for file in files:
        raw = read(file)
        text = strip_comments(raw)
        mask = mask_ts_literals(raw)
        sources.append({**source_ref(file, parser.root, None),
                        "sha256": hashlib.sha256(raw.encode()).hexdigest()})
        receivers = {"app", "router", *parser.router_vars(file)}
        receivers.update(re.findall(
            r"\b(?:const|let|var)\s+(\w+)\s*=\s*(?:express\s*\.\s*)?Router\s*\(", mask))
        names = "|".join(re.escape(name) for name in sorted(receivers))
        # Include unsupported member/computed forms rather than allowing a new
        # method or .route(...).get(...) chain to disappear from the report.
        pattern = re.compile(
            rf"(?<![\w$.])(?:{names})\s*(?:\.\s*(\w+)\s*|\[[^\]\n]*\]\s*)\("
            r"|(?<![\w$.])registerAgentApiRoute\s*\(")
        for match in pattern.finditer(mask):
            member = match.group(1)
            helper = mask[match.start():match.end()].lstrip().startswith("registerAgentApiRoute")
            if member in {"set", "disable", "enable", "enabled", "disabled", "listen"}:
                continue  # Configuration is outside the registration scanner.
            line = text.count("\n", 0, match.start()) + 1
            reason = None
            call_complete = True
            try:
                arguments, end = extract_call(text, match.end() - 1)
                args = split_args(arguments)
            except ParseError as error:
                # Preserve a literal first argument even if an unsupported regex
                # later in the handler prevents parsing the complete call.
                literal = re.match(r'''\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')''',
                                   text[match.end():])
                args = [literal.group(1)] if literal else []
                end = text.find("\n", match.end())
                if end < 0:
                    end = len(text)
                reason = str(error)
                call_complete = False
            expression = args[0] if args else None
            path, regex = (None, False)
            if expression and not helper:
                path, regex = parser.path_from_arg(expression, file)
            matches = effective.get((str(file), line), [])
            # Same-line calls must not accidentally consume each other's evidence.
            matches = [route for route in matches if route.raw_path_expression == expression
                       and (helper or route.raw_method == member)]
            kind = "contract_helper" if helper else (
                "mount_or_middleware" if member == "use" else "route")
            if member not in {*METHODS, "use"} and not helper:
                reason = reason or "unsupported registration member, computed method or route chain"
            elif member == "use":
                reason = reason or "mount/middleware candidate: handler role and control flow require review"
            elif not matches:
                reason = reason or "no effective path extracted: dynamic path, unmounted router, middleware or unsupported syntax"
            if path is None and not helper:
                reason = reason or "path expression unresolved"
            record_id = f"{file.relative_to(parser.root)}:{line}:{match.start()}"
            records.append({
                "registration_id": record_id,
                "source": source_ref(file, parser.root, line),
                "raw_call": raw[match.start():end],
                "raw_call_complete": call_complete,
                "raw_method": member,
                "raw_path_expression": expression,
                "registration_path": path,
                "constraints": raw_constraints(path, regex),
                "transport": "HTTP", "listener": "upstream_express_app_candidate",
                "entry_kind": kind,
                "conditions": {"status": "unknown", "reason": "control flow, mount gates and runtime configuration not evaluated"},
                "resolution": "effective_paths_extracted" if matches and reason is None else "needs_review",
                "reason": reason,
                "effective_paths": [{"method": route.method, "path": route.path} for route in matches],
            })
    return records, sources


def machine_inventory(parser: UpstreamParser, routes: list[UpstreamRoute],
                      swift: list[SwiftRoute] | None = None,
                      swift_dump: Path | None = None) -> dict:
    registrations, sources = scan_registrations(parser, routes)
    diff = diff_routes(Inventory(routes, swift or [])) if swift is not None else None
    matched = {id(route): "normalized_shape_match" for route, _ in diff.matched} if diff else {}
    if diff:
        matched.update({id(route): "literal_subset_variant" for route, _ in diff.param_variants})
    operations = []
    for route in routes:
        mounts = [{**item, "file": source_ref(Path(item["file"]), parser.root, item["line"])["file"]}
                  for item in route.mount_sources]
        operations.append({
            "operation_id": f"HTTP {route.method} {route.path}",
            "method": route.method, "path": route.path,
            "raw_method": route.raw_method, "raw_path_expression": route.raw_path_expression,
            "registration_path": route.registration_path,
            "constraints": raw_constraints(route.registration_path, route.regex),
            "source": source_ref(Path(route.file), parser.root, route.source_line),
            "mounts": mounts,
            "transport": "HTTP", "listener": "upstream_express_app_candidate", "entry_kind": "route",
            "conditions": {"status": "unknown", "reason": "static candidate; runtime activation and middleware semantics not verified"},
            "normalized_match": {"method": route.method, "path": normalize_path(route.path),
                                 "status": matched.get(id(route), "unmatched" if diff else "NOT_RUN"),
                                 "behavior_verified": False},
        })
    return {
        "schema_version": 1,
        "extraction_errors": parser.extraction_errors,
        "scope": {
            "complete": False, "behavior_verified": False, "runtime_verified": False,
            "description": "Static entry candidates and unresolved registrations; normalized matches are not behavior verification.",
            "scanned": "packages/server/src/app.ts and non-test packages/server/src/routes/**/*.ts",
            "limitations": [
                "Bounded lexical scanner, not a TypeScript AST/control-flow analysis; unknown receiver aliases and helper APIs may be missed.",
                "No runtime registry/feature matrix; conditions are unknown and implicit HEAD/OPTIONS are not inferred.",
                "Parameter constraints remain verbatim; normalized matching intentionally discards names/constraints/suffixes.",
                "Swift TSV is a Vapor router dump only; listener/middleware coverage and source registration locations are unknown.",
            ],
        },
        "baseline": {"upstream_root": str(parser.root), "source_files": sources,
                     "swift_dump": {"path": str(swift_dump), "sha256": hashlib.sha256(swift_dump.read_bytes()).hexdigest()}
                     if swift_dump else None},
        "operations": operations,
        "registrations": registrations,
        "unresolved_registrations": [item for item in registrations if item["resolution"] == "needs_review"],
        "swift_routes": [{"method": route.method, "path": route.path,
                          "transport": "HTTP", "listener": "swift_vapor_router_table",
                          "entry_kind": "router_table_entry", "source": None,
                          "conditions": {"status": "unknown"}, "behavior_verified": False}
                         for route in swift] if swift is not None else None,
        "review_items": [
            {"transport": "HTTP", "listener": "upstream_express_app", "entry_kind": "middleware",
             "status": "NOT_RUN", "reason": "app.use/router.use candidates need effective-path and handler adjudication"},
            {"transport": "HTTP", "listener": "swift_vapor_middleware", "entry_kind": "middleware",
             "status": "NOT_RUN", "reason": "FallbackMiddleware/PublicSearchMiddleware paths are outside the Vapor dump"},
            {"transport": "WebSocket", "listener": "daemon_connect", "entry_kind": "independent_listener",
             "status": "NOT_RUN", "reason": "/daemon/connect uses SwiftNIO; enumerate upstream and Swift handshake/frame contracts"},
            {"transport": "Engine.IO/Socket.IO", "listener": "socket_io", "entry_kind": "independent_listener",
             "status": "NOT_RUN", "reason": "SwiftNIO listener and upstream socket registry require a separate inventory"},
            {"transport": "HTTP", "listener": "all_http_listeners", "entry_kind": "implicit_method",
             "status": "NOT_RUN", "reason": "Explicit HEAD/OPTIONS are scanned; framework-generated methods and CORS remain unverified"},
        ],
        "counts": {"static_operation_candidates": len(operations), "registration_candidates": len(registrations),
                   "unresolved_registrations": sum(item["resolution"] == "needs_review" for item in registrations)},
    }


def write_machine_inventory(path: Path, parser: UpstreamParser, routes: list[UpstreamRoute],
                            swift: list[SwiftRoute] | None = None, swift_dump: Path | None = None) -> None:
    result = machine_inventory(parser, routes, swift, swift_dump)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    sys.stderr.write(f"wrote {path}: {result['counts']} (static, incomplete, behavior not verified)\n")


# -- main ------------------------------------------------------------------

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--upstream-root", default=os.environ.get("RAFT_UPSTREAM_ROOT", DEFAULT_UPSTREAM))
    parser.add_argument("--swift-root", default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument("--swift", default=os.environ.get("SWIFT", DEFAULT_SWIFT))
    parser.add_argument("--swift-dump", default=None, help="read a pre-generated METHOD<TAB>path TSV")
    parser.add_argument("--json-out", help="write raw candidates, constraints, source references and unknowns as JSON")
    parser.add_argument("--upstream-only", action="store_true", help="with --json-out, scan upstream without building or reading Swift routes")
    parser.add_argument("--write", default=None, help="write the Markdown report to this path")
    parser.add_argument("--check", action="store_true", help="fail when --write output differs from the file")
    parser.add_argument("--no-usage", action="store_true", help="skip the Web/CLI reference scan")
    args = parser.parse_args(argv)
    if args.upstream_only and (not args.json_out or args.swift_dump or args.write or args.check):
        parser.error("--upstream-only requires --json-out and cannot use --swift-dump, --write or --check")

    upstream_root = Path(args.upstream_root).resolve()
    swift_root = Path(args.swift_root).resolve()
    if not (upstream_root / "packages" / "server" / "src" / "app.ts").exists():
        sys.stderr.write(f"upstream app.ts not found under {upstream_root}\n")
        return 2

    upstream_parser = UpstreamParser(upstream_root)
    try:
        upstream_routes = upstream_parser.parse_app()
    except (ParseError, OSError) as error:
        sys.stderr.write(f"upstream parse failed: {error}\n")
        if not args.upstream_only:
            return 1
        upstream_parser.extraction_errors.append(str(error))
        upstream_routes = []
    if not upstream_routes and not args.upstream_only:
        sys.stderr.write("upstream parse produced no routes\n")
        return 1

    if args.upstream_only:
        try:
            write_machine_inventory(Path(args.json_out), upstream_parser, upstream_routes)
        except (ParseError, OSError) as error:
            sys.stderr.write(f"machine inventory failed: {error}\n")
            return 1
        return 0

    try:
        if args.swift_dump:
            swift_routes = read_swift_dump(Path(args.swift_dump))
        else:
            swift_routes = run_swift_dump(args.swift, swift_root)
    except (ParseError, OSError) as error:
        sys.stderr.write(f"Swift route dump failed: {error}\n")
        return 1

    if args.json_out:
        try:
            write_machine_inventory(Path(args.json_out), upstream_parser, upstream_routes,
                                    swift_routes, Path(args.swift_dump) if args.swift_dump else None)
        except (ParseError, OSError) as error:
            sys.stderr.write(f"machine inventory failed: {error}\n")
            return 1

    inventory = Inventory(upstream_routes, swift_routes)
    diff = diff_routes(inventory)
    fallback = [route for route in diff.missing if (route.method, normalize_path(route.path)) in FALLBACK_HANDLED]
    if fallback:
        diff = Diff(
            diff.matched,
            diff.param_variants,
            [route for route in diff.missing if route not in fallback],
            diff.extra,
        )

    usage: dict[str, tuple[int, int]] = {}
    if not args.no_usage:
        source_roots = [upstream_root / "packages" / "web" / "src", upstream_root / "packages" / "cli" / "src"]
        for route in diff.missing:
            usage[method_path(route)] = usage_counts(route.path, source_roots)

    report = render_report(inventory, diff, usage, upstream_root, fallback)

    if args.check:
        if not args.write:
            sys.stderr.write("--check requires --write\n")
            return 2
        target = Path(args.write)
        if not target.exists() or read(target) != report:
            sys.stderr.write(f"{target} is stale; rerun scripts/route_inventory.py --write {target}\n")
            return 1
        return 0

    if args.write:
        target = Path(args.write)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(report, encoding="utf-8")
        sys.stderr.write(f"wrote {target}\n")
    else:
        sys.stdout.write(report)

    # A short summary keeps the default run useful in logs.
    sys.stderr.write(
        f"upstream={len(inventory.upstream)} swift={len(inventory.swift)} "
        f"matched={len(diff.matched)} param_variants={len(diff.param_variants)} "
        f"missing={len(diff.missing)} extra={len(diff.extra)}\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
