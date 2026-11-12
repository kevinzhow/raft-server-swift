"""Load environment-specific deployment settings for the Swift production tools.

Everything that differs between machines -- repository paths, production
directories, container names, loopback ports and the public canary URL -- lives
in ``local.env`` next to this file.  That file is git-ignored; ``local.env.example``
documents the keys.  No secret, domain or IP address is committed.

Resolution order for each key: the process environment wins, then ``local.env``.
"""

from __future__ import annotations

import os
from pathlib import Path

DEPLOY_DIR = Path(__file__).resolve().parent
LOCAL_ENV = Path(os.environ.get("SWIFT_PRODUCTION_ENV", DEPLOY_DIR / "local.env"))

# Every key the tools need.  Optional keys are read with a default.
REQUIRED = (
    "DEV_ROOT",
    "SOURCE_REPO",
    "SWIFT",
    "SWIFT_SDK",
    "PRODUCTION_ROOT",
    "RELEASE_ROOT_PREFIX",
    "BASELINE_COMMIT",
    "HOST_PLATFORM_PROOF",
)
OPTIONAL_DEFAULTS = {
    # Only needed when staging a historical release with a JS parser bundle.
    "JSC_LIBRARY": "",
    "LAUNCHER": "",
    "GATEWAY_FILE": "",
    "GATEWAY_CLOSED_PROFILE": "",
    "GATEWAY_CONTAINER": "",
    "GATEWAY_HEALTH_URL": "",
    "PRIVATE_HEALTH_URL": "",
    "PUBLIC_VERSION_URL": "",
    "POSTGRES_CONTAINER": "",
    "PRODUCTION_DATABASE": "",
    "SERVICE_UNIT": "",
    "ARTIFACT_ROOT": "",
}


class ConfigError(SystemExit):
    pass


def _parse_local_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :]
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        values[key] = value
    return values


def load() -> dict[str, str]:
    """Return the deployment settings, or exit with a usable diagnostic."""
    file_values = _parse_local_env(LOCAL_ENV)
    config: dict[str, str] = {}
    missing: list[str] = []
    for key in REQUIRED:
        value = os.environ.get(key) or file_values.get(key, "")
        if not value:
            missing.append(key)
        config[key] = value
    for key, default in OPTIONAL_DEFAULTS.items():
        config[key] = os.environ.get(key) or file_values.get(key, default)
    if missing:
        raise ConfigError(
            "missing deployment settings: "
            + ", ".join(missing)
            + f"\nCreate {LOCAL_ENV} from local.env.example (see deploy/swift-production/README.md)."
        )
    return config


def git_commit(config: dict[str, str], argument: str) -> str:
    import re
    import subprocess

    repo = config["SOURCE_REPO"]
    result = subprocess.run(
        ["git", "-C", repo, "rev-parse", "--verify", argument + "^{commit}"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ConfigError(f"cannot resolve commit {argument!r} in {repo}")
    commit = result.stdout.strip()
    if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise ConfigError(f"invalid commit: {commit}")
    return commit
