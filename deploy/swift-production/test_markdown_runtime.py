"""Bounded release tooling checks; no Swift build, service or release tree access."""
from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True
TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))
import env
from markdown_runtime import BASE_RESOURCES, JSC_RESOURCES, check_parser_mapping, resource_profile


def load_stage(root: Path):
    config = {key: str(root / key.lower()) for key in env.REQUIRED}
    config.update(env.OPTIONAL_DEFAULTS)
    spec = importlib.util.spec_from_file_location("stage_markdown_test", TOOLS / "stage-main-release.py")
    module = importlib.util.module_from_spec(spec)
    with patch.object(env, "load", return_value=config):
        spec.loader.exec_module(module)
    return module


class ResourceProfiles(unittest.TestCase):
    def test_native_without_js_or_engine(self):
        self.assertEqual(resource_profile(set(BASE_RESOURCES) | {"MD4C.LICENSE.txt"}), "native")
        self.assertFalse(check_parser_mapping("native", []))

    def test_native_missing_md4c_notice_fails(self):
        with self.assertRaisesRegex(ValueError, "unexpected resource bundle contents"):
            resource_profile(set(BASE_RESOURCES))

    def test_native_cannot_carry_stale_js_resources(self):
        with self.assertRaises(ValueError):
            resource_profile(set(BASE_RESOURCES | JSC_RESOURCES) | {"MD4C.LICENSE.txt"})

    def test_repository_native_notice_matches_vendor_and_is_packaged(self):
        repo = TOOLS.parents[1]
        self.assertEqual(
            (repo / "Sources/RaftHTTP/Resources/MD4C.LICENSE.txt").read_bytes(),
            (repo / "Sources/CRaftMarkdown/vendor/LICENSE.md").read_bytes(),
        )
        package = (repo / "Package.swift").read_text()
        self.assertIn('.copy("Resources/MD4C.LICENSE.txt")', package)
        for name in JSC_RESOURCES:
            self.assertNotIn(f'.copy("Resources/{name}")', package)

    def test_historical_js_requires_complete_resources_and_loaded_engine(self):
        self.assertEqual(resource_profile(set(BASE_RESOURCES | JSC_RESOURCES)), "javascriptcore")
        with self.assertRaisesRegex(ValueError, "not mapped"):
            check_parser_mapping("javascriptcore", [])
        self.assertTrue(check_parser_mapping("javascriptcore", [
            {"name": "libjavascriptcoregtk-4.1.so.0.10.14", "kind": "staged-release"}
        ]))

    def test_native_rejects_engine_from_any_mapping_kind(self):
        for kind in ("staged-release", "host-platform", "host-data"):
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, "native Markdown release"):
                check_parser_mapping("native", [
                    {"name": "libjavascriptcoregtk-4.1.so.0.10.14", "kind": kind}
                ])

    def test_unknown_profile_cannot_bypass_mapping_check(self):
        with self.assertRaisesRegex(ValueError, "unknown Markdown runtime profile"):
            check_parser_mapping("naitve", [])

    def test_historical_engine_outside_staged_release_fails(self):
        with self.assertRaisesRegex(ValueError, "not mapped from the staged runtime"):
            check_parser_mapping("javascriptcore", [
                {"name": "libjavascriptcoregtk-4.1.so.0.10.14", "kind": "host-platform"}
            ])

    def test_partial_js_and_unexpected_files_fail(self):
        for name in JSC_RESOURCES | {"unexpected.txt"}:
            with self.subTest(name=name), self.assertRaises(ValueError):
                resource_profile(set(BASE_RESOURCES) | {name})
        with self.assertRaises(ValueError):
            resource_profile({"Info.plist"})

    def test_config_no_longer_requires_jsc(self):
        values = {key: "/configured/" + key for key in env.REQUIRED}
        with patch.dict(env.os.environ, values, clear=True), patch.object(env, "_parse_local_env", return_value={}):
            self.assertEqual(env.load()["JSC_LIBRARY"], "")


class RuntimeClosure(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="native-markdown-tooling-", dir="/mnt/data")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.stage = load_stage(self.root)
        self.swift = self.root / "swift"
        self.native = self.root / "native"
        self.swift.mkdir()
        self.native.mkdir()
        self.stage.SWIFT_LIB = self.swift
        self.stage.NATIVE_SEARCH_DIRS = [self.native]
        self.binary = self.file(self.root / "RaftServer")
        self.core = self.file(self.swift / "libswiftCore.so")
        self.foo = self.file(self.native / "libfoo.so.1")
        self.bar = self.file(self.native / "libbar.so.2")
        self.jsc = self.file(self.native / "libjavascriptcoregtk-4.1.so.0")
        self.dependencies = {
            self.binary: [self.core.name, self.foo.name],
            self.core: [], self.foo: [self.bar.name], self.bar: [],
            self.jsc: [self.bar.name],
        }
        self.mock = patch.object(self.stage, "readelf_dynamic", side_effect=lambda path: {
            "needed": self.dependencies[path], "soname": [], "rpathOrRunpath": []
        })
        self.mock.start()
        self.addCleanup(self.mock.stop)

    def file(self, path):
        path.write_bytes(path.name.encode())
        return path

    def test_native_keeps_recursive_needed_closure_without_jsc(self):
        closure = self.stage.Closure(self.binary, {})
        closure.build()
        self.assertEqual(set(closure.graph), {str(p) for p in (self.binary, self.core, self.foo, self.bar)})
        self.assertNotIn(str(self.jsc), closure.graph)
        self.assertIn("lib/native/" + self.bar.name, closure.files)

    def test_historical_extra_root_still_inventoried(self):
        closure = self.stage.Closure(self.binary, {}, (self.jsc,))
        closure.build()
        self.assertIn(str(self.jsc), closure.graph)
        self.assertIn("lib/native/" + self.jsc.name, closure.files)

    def test_missing_transitive_dependency_fails(self):
        self.dependencies[self.foo] = ["libmissing.so.1"]
        with self.assertRaisesRegex(self.stage.StageError, "unresolved DT_NEEDED"):
            self.stage.Closure(self.binary, {}).build()

    def test_unapproved_host_dependency_fails(self):
        libc = self.file(self.native / "libc.so.6")
        self.dependencies[self.foo] = [libc.name]
        with self.assertRaisesRegex(self.stage.StageError, "outside the deployed allowlist"):
            self.stage.Closure(self.binary, {}).build()

    def test_old_installed_runtime_manifest_still_checked(self):
        release = self.root / "old-installed"
        runtime = release / "swift-runtime"
        runtime.mkdir(parents=True)
        self.file(runtime / self.jsc.name)
        manifest = self.root / "old-manifest.json"
        inventory = self.stage.inventory(runtime)
        manifest.write_text(json.dumps({
            "files": {"swift-runtime/" + k: v for k, v in inventory["files"].items()},
            "symlinks": {},
        }))
        self.stage.DEPLOYED_RELEASE = release
        self.stage.DEPLOYED_MANIFEST = manifest
        self.assertEqual(self.stage.verify_deployed_manifest_runtime(), inventory)
        (runtime / self.jsc.name).write_bytes(b"tampered")
        with self.assertRaisesRegex(self.stage.StageError, "do not match"):
            self.stage.verify_deployed_manifest_runtime()


if __name__ == "__main__":
    unittest.main()
