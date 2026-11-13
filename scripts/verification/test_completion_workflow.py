#!/usr/bin/env python3
"""Workflow controls that cannot be replaced by an arbitrary BASE or PASS flag."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import completion_guard as guard
import run_completion as entry


class WorkflowControls(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.git('init', '-q')
        self.git('config', 'user.email', 'verification@example.test')
        self.git('config', 'user.name', 'Verification control')
        self.write('Sources/Feature.swift', 'let feature = 1\n')
        self.write('README.md', 'baseline\n')
        self.write('.gitignore', '.build/\n')
        self.write(entry.REGISTRY, json.dumps({'schema_version': 1, 'families': [], 'shared_paths': [], 'global_debt': []}))
        for name in ('Makefile', 'scripts/gate.sh', 'scripts/verification/run_completion.py', 'scripts/verification/completion_guard.py'):
            self.write(name, 'synthetic tool fixture\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'baseline')
        self.base = self.git('rev-parse', 'HEAD').strip()
        self.git('update-ref', entry.PROTECTED, self.base)

    def tearDown(self):
        self.directory.cleanup()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True)

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)
        return path

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-qm', 'change')
        return self.git('rev-parse', 'HEAD').strip()

    def full_gate(self, base):
        run_dir = self.root / '.build/gate-fixture'
        run_dir.mkdir(parents=True, exist_ok=True)
        plan = guard.make_plan(self.root, base, self.root / entry.REGISTRY)
        context = {'schema_version': 1, 'kind': 'integration_context', 'run_id': 'fixture-run',
                   'started_ns': __import__('time').time_ns(), 'run_dir': str(run_dir),
                   'identity': entry.gate_identity(self.root, self.root / entry.REGISTRY, plan)}
        steps = []
        for name in sorted(entry.REQUIRED_GATE_STEPS):
            log = run_dir / (name + '.log')
            log.write_text('synthetic tool-control step executed\n')
            steps.append({'name': name, 'status': 'PASS', 'log': str(log), 'sha256': guard.sha(log)})
        path = run_dir / 'integration-steps.json'
        path.write_text(json.dumps({'schema_version': 1, 'kind': 'integration_steps', 'context': context, 'steps': steps}))
        return entry.gate_binding(path)

    def receipt(self, base, target):
        return {'schema_version': 1, 'kind': 'workflow_qualification',
                'registry': entry.REGISTRY, 'qualified_repo': str(self.root),
                'snapshot': guard.snapshot(self.root, base),
                'integration_gate': self.full_gate(base),
                'qualification': {'tool_test_passed': True, 'product_verified': False},
                'input_files': []}

    def test_trusted_base_remains_protected_parent_after_feature_commit(self):
        self.write('Sources/Feature.swift', 'let feature = 2\n')
        target = self.commit()
        self.assertNotEqual(target, self.base)
        self.assertEqual(entry.trusted_base(self.root), self.base)

    def test_source_change_cannot_deploy_with_base_head_tooling_receipt(self):
        self.write('Sources/Feature.swift', 'let feature = 2\n')
        target = self.commit()
        receipt = self.receipt(target, target)
        with self.assertRaisesRegex(guard.GuardError, 'actual installed application'):
            entry.check_release(self.root, target, receipt, self.base)

    def test_source_change_cannot_deploy_with_tooling_only_qualification(self):
        self.write('Sources/Feature.swift', 'let feature = 2\n')
        target = self.commit()
        receipt = self.receipt(self.base, target)
        with self.assertRaisesRegex(guard.GuardError, 'application change cannot deploy'):
            entry.check_release(self.root, target, receipt, self.base)

    def test_uncommitted_input_cannot_be_installed_as_the_commit(self):
        self.write('Sources/Feature.swift', 'let feature = 2\n')
        receipt = self.receipt(self.base, self.base)
        with self.assertRaisesRegex(guard.GuardError, 'dirty|untracked'):
            entry.check_release(self.root, self.base, receipt, self.base)

    def test_handoff_alone_is_not_a_full_gate(self):
        receipt = self.receipt(self.base, self.base)
        del receipt['integration_gate']
        with self.assertRaisesRegex(guard.GuardError, 'full integration gate'):
            entry.check_release(self.root, self.base, receipt, self.base)

    def test_incomplete_gate_steps_cannot_be_certified(self):
        path = self.write('partial.txt', 'parity-check PASS 1s log\n')
        with self.assertRaises(guard.GuardError):
            entry.gate_binding(path)

    def test_old_green_gate_cannot_be_attached_to_changed_source(self):
        old = self.full_gate(self.base)
        self.write('README.md', 'different qualified input\n')
        plan = guard.make_plan(self.root, self.base, self.root / entry.REGISTRY)
        with self.assertRaisesRegex(guard.GuardError, 'another source/plan'):
            entry.gate_binding(old['path'], entry.gate_identity(self.root, self.root / entry.REGISTRY, plan))

    def test_old_log_cannot_be_stamped_as_a_new_run(self):
        old = self.full_gate(self.base)
        value = json.loads(Path(old['path']).read_text())
        value['context']['started_ns'] = __import__('time').time_ns() + 1_000_000_000
        Path(old['path']).write_text(json.dumps(value))
        with self.assertRaisesRegex(guard.GuardError, 'predates this run'):
            entry.gate_binding(old['path'])

    def test_equal_tree_ancestor_merge_is_valid_source_mapping(self):
        self.write('README.md', 'qualified docs\n')
        source = self.commit()
        snapshot = guard.snapshot(self.root, self.base)
        tree = self.git('rev-parse', 'HEAD^{tree}').strip()
        target = self.git('commit-tree', tree, '-p', source, '-p', self.base, '-m', 'synthetic no-ff mapping').strip()
        entry.verify_target_inputs(self.root, snapshot, target)

    def test_equal_tree_nonancestor_cannot_inherit_source_proof(self):
        snapshot = guard.snapshot(self.root, self.base)
        tree = self.git('rev-parse', 'HEAD^{tree}').strip()
        target = self.git('commit-tree', tree, '-m', 'unrelated root').strip()
        with self.assertRaises(guard.GuardError):
            entry.verify_target_inputs(self.root, snapshot, target)

    def test_one_field_tree_forgery_cannot_extend_qualified_source(self):
        snapshot = guard.snapshot(self.root, self.base)
        self.write('Sources/Unverified.swift', 'let unverified = true\n')
        target = self.commit()
        snapshot['head_tree'] = self.git('rev-parse', target + '^{tree}').strip()
        with self.assertRaisesRegex(guard.GuardError, 'actual git commit'):
            entry.verify_target_inputs(self.root, snapshot, target)

    def test_outer_snapshot_must_equal_real_source_and_gate_snapshot(self):
        receipt = self.receipt(self.base, self.base)
        receipt['snapshot']['changes'] = [{'path': 'README.md', 'sha256': '0' * 64, 'status': 'M', 'old_path': None, 'base_sha256': '0' * 64}]
        with self.assertRaisesRegex(guard.GuardError, 'actual qualified worktree'):
            entry.check_release(self.root, self.base, receipt, self.base)

    def test_alternative_weak_registry_cannot_deploy(self):
        receipt = self.receipt(self.base, self.base)
        receipt['registry'] = 'scripts/verification/empty-registry.json'
        with self.assertRaisesRegex(guard.GuardError, 'mandatory registry'):
            entry.check_release(self.root, self.base, receipt, self.base)

    def test_documentation_only_release_keeps_product_qualification_false(self):
        self.write('README.md', 'updated documentation\n')
        target = self.commit()
        receipt = self.receipt(self.base, target)
        result = entry.check_release(self.root, target, receipt, self.base)
        self.assertFalse(result['application_changed'])
        self.assertFalse(result['product_verified'])
        self.assertFalse(result['global_complete'])

    def test_immutable_receipt_cannot_be_silently_overwritten(self):
        path = self.root / 'receipt.json'
        entry.immutable_json(path, {'scope': 'first'})
        with self.assertRaises(FileExistsError):
            entry.immutable_json(path, {'scope': 'replacement'})
        self.assertEqual(json.loads(path.read_text()), {'scope': 'first'})


if __name__ == '__main__':
    unittest.main()
