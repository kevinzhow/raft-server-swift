"""HTTP observations without automatic redirects or credential forwarding."""
from __future__ import annotations

import base64
from dataclasses import dataclass
import http.client
import json
import os
from pathlib import Path
import ssl
from urllib.parse import urljoin, urlsplit

from evidence import digest


@dataclass(frozen=True)
class Observation:
    status: int
    headers: list[tuple[str, str]]
    body: bytes
    evidence: dict

    def header(self, name: str) -> str | None:
        values = [value for key, value in self.headers if key.lower() == name.lower()]
        return ", ".join(values) if values else None

    def json(self):
        return json.loads(self.body)

    def safe_summary(self) -> dict:
        allowed = ("Content-Type", "Content-Length", "Content-Disposition", "Cache-Control",
                   "X-Content-Type-Options", "Content-Range", "Accept-Ranges")
        return {"status": self.status, "bytes": len(self.body), "sha256": digest(self.body),
                "headers": {name.lower(): self.header(name) for name in allowed},
                "has_location": self.header("Location") is not None}


class PrivateEvidence:
    def __init__(self, run_root: Path):
        self.run_root = run_root.resolve()
        self.directory = self.run_root / "private"
        self.directory.mkdir(parents=True, mode=0o700, exist_ok=True)
        if self.directory.stat().st_mode & 0o077:
            raise PermissionError("private evidence directory permissions are too broad")
        self.index = max((int(path.stem.split("-")[1]) for path in self.directory.glob("http-*.json")), default=0)

    def save(self, content: dict) -> dict:
        self.index += 1
        path = self.directory / f"http-{self.index:05d}.json"
        raw = (json.dumps(content, sort_keys=True, indent=2) + "\n").encode()
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(raw)
        return {"path": str(path.relative_to(self.run_root)), "sha256": digest(raw)}


def origin(url: str) -> tuple[str, str, int]:
    parsed = urlsplit(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("invalid HTTP origin")
    return parsed.scheme, parsed.hostname.lower(), parsed.port or (443 if parsed.scheme == "https" else 80)


class Client:
    def __init__(self, base_url: str, evidence: PrivateEvidence, *, ca_file: str | None = None,
                 timeout: float = 30, maximum_bytes: int = 16 * 1024 * 1024):
        self.base_url = base_url.rstrip("/")
        self.origin = origin(self.base_url)
        parsed = urlsplit(self.base_url)
        if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
            raise ValueError("API base must be an origin without a path or query")
        self.evidence = evidence
        self.timeout = timeout
        self.maximum_bytes = maximum_bytes
        self.ca_file = ca_file

    def request(self, method: str, path: str, *, body: bytes | dict | None = None,
                headers: dict[str, str] | None = None) -> Observation:
        if not path.startswith("/") or path.startswith("//"):
            raise ValueError("API requests require an origin-relative path")
        data = json.dumps(body, separators=(",", ":")).encode() if isinstance(body, dict) else body
        outgoing = {"User-Agent": "raft-paired-verification/1", **(headers or {})}
        if isinstance(body, dict):
            outgoing.setdefault("Content-Type", "application/json")
        scheme, host, port = self.origin
        if scheme == "https":
            context = ssl.create_default_context()
            if self.ca_file:
                context.load_verify_locations(cafile=self.ca_file)
            connection = http.client.HTTPSConnection(host, port, timeout=self.timeout, context=context)
        else:
            connection = http.client.HTTPConnection(host, port, timeout=self.timeout)
        try:
            connection.request(method, path, body=data, headers=outgoing)
            response = connection.getresponse()
            payload = response.read(self.maximum_bytes + 1)
            if len(payload) > self.maximum_bytes:
                raise ValueError("response exceeds this run's declared evidence budget")
            response_headers = response.getheaders()
            reference = self.evidence.save({
                "method": method, "path": path, "request_body_sha256": digest(data or b""),
                "request_headers": {key: "<redacted>" if key.lower() in ("authorization", "cookie") else value
                                    for key, value in outgoing.items()},
                "status": response.status, "response_headers": response_headers,
                "response_body_base64": base64.b64encode(payload).decode(),
                "response_body_sha256": digest(payload),
                "privacy": "private local evidence; can contain tokens or signed URLs",
            })
            return Observation(response.status, response_headers, payload, reference)
        finally:
            connection.close()

    def binary(self, path: str, *, headers: dict[str, str] | None = None) -> tuple[Observation, Observation]:
        """Mirror pinned CLI redirect policy, retaining both HTTP observations."""
        first = self.request("GET", path, headers=headers)
        if first.status != 302:
            return first, first
        location = first.header("Location")
        target = urljoin(self.base_url + path, location or "")
        parsed = urlsplit(target)
        if (not location or parsed.scheme != "https" or parsed.username is not None
                or parsed.password is not None or origin(target) == self.origin):
            raise ValueError("attachment redirect violates pinned CLI target policy")
        # A fresh connection with no API headers. Object redirects are not followed.
        object_base = f"{parsed.scheme}://{parsed.netloc}"
        client = Client(object_base, self.evidence, ca_file=self.ca_file,
                        timeout=self.timeout, maximum_bytes=self.maximum_bytes)
        target_path = parsed.path or "/"
        if parsed.query:
            target_path += "?" + parsed.query
        final = client.request("GET", target_path)
        if 300 <= final.status < 400:
            raise ValueError("attachment object returned a second redirect")
        return first, final
