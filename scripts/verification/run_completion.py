#!/usr/bin/env python3
"""Repository entry point: trusted merge base, mandatory plans and release receipts."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

import completion_guard as guard

PROTECTED = 'refs/remotes/origin/deploy-linux-docker'
REGISTRY = 'scripts/verification/families.json'
BUSINESS = ('Sources', 'Tests', 'Resources', 'Package.swift', 'Package.resolved', 'Config', 'config')
REQUIRED_GATE_STEPS = {'verification-preflight', 'verification-selftest', 'test-sharded', 'test-e2e', 'smoke', 'architecture', 'parity-check'}


def gate_identity(repo, registry, plan, baseline=None, report=None):
    return {'snapshot': guard.snapshot(repo, plan['impact']['repo']['base']),
            'plan_digest': plan['plan_digest'], 'registry_sha256': guard.sha(registry),
            'tools': {name: guard.sha(repo / name) for name in
                      ('Makefile', 'scripts/gate.sh', 'scripts/verification/run_completion.py',
                       'scripts/verification/completion_guard.py')},
            'baseline_sha256': guard.sha(Path(baseline)) if baseline else None,
            'report_sha256': guard.sha(Path(report)) if report else None}


def gate_binding(path, identity=None):
    path = Path(path).resolve()
    value = guard.load(path)
    guard.document(value, 'integration_steps')
    context = value['context']
    guard.need(context.get('run_id') and type(context.get('started_ns')) is int, 'gate run identity missing')
    if identity is not None:
        guard.need(guard.equal(context['identity'], identity), 'integration steps belong to another source/plan/tool/config baseline')
    run_dir = Path(context['run_dir']).resolve()
    guard.need(path.parent == run_dir, 'gate receipt is outside its run directory')
    steps = guard.indexed(value.get('steps'), 'name', 'gate steps')
    guard.need(set(steps) == REQUIRED_GATE_STEPS, 'integration gate is missing required PASS steps')
    for name, row in steps.items():
        log = Path(row['log']).resolve()
        guard.need(row.get('status') == 'PASS' and log == run_dir / (name + '.log'), 'gate step log belongs to another run')
        guard.need(log.stat().st_mtime_ns >= context['started_ns'], 'gate step log predates this run')
        guard.need(guard.sha(log) == row['sha256'], 'integration step log changed')
    return {'path': str(path), 'sha256': guard.sha(path), 'context': context, 'passed_steps': sorted(steps)}


def finish_gate(context_path, steps_path, identity, output):
    context = guard.load(context_path)
    guard.document(context, 'integration_context')
    guard.need(guard.equal(context['identity'], identity), 'source inputs changed during the integration gate')
    steps = []
    for line in Path(steps_path).read_text().splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[0] in REQUIRED_GATE_STEPS:
            log = Path(parts[-1]).resolve()
            steps.append({'name': parts[0], 'status': parts[1], 'log': str(log), 'sha256': guard.sha(log)})
    result = {'schema_version': 1, 'kind': 'integration_steps', 'context': context, 'steps': steps}
    immutable_json(output, result)
    gate_binding(output, identity)
    return result


def trusted_base(repo):
    protected = guard.git(repo, 'rev-parse', '--verify', PROTECTED + '^{commit}').decode().strip()
    return guard.git(repo, 'merge-base', 'HEAD', protected).decode().strip()


def immutable_json(path, value):
    path = Path(path).resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write('\n')


def reject_review(info):
    guard.need(not info['needs_review'], 'unknown/removed scope or weakened policy requires review; no completion is granted')


def current_plan(args, repo, registry, base):
    info, _, _ = guard.impact(repo, base, registry)
    reject_review(info)
    if args.plan:
        plan = guard.load(args.plan)
        guard.need(plan['impact']['repo']['base'] == base, 'plan base differs from the protected remote merge base')
        return guard.verify_plan(repo, base, registry, plan)
    guard.need(info['mode'] == 'tooling_only', 'business changes require VERIFY_PLAN from make verification-plan')
    return guard.make_plan(repo, base, registry)


def verify_target_inputs(repo, snapshot, target):
    guard.need(snapshot['head_tree'] == guard.git(repo, 'rev-parse', snapshot['head'] + '^{tree}').decode().strip(), 'qualification tree does not match its actual git commit')
    guard.need(guard.git(repo, 'merge-base', snapshot['head'], target).decode().strip() == snapshot['head'], 'qualified source is not an ancestor of the release commit')
    guard.need(snapshot['head_tree'] == guard.git(repo, 'rev-parse', target + '^{tree}').decode().strip(), 'qualification tree differs from release tree')
    for row in snapshot['changes']:
        raw = guard.git(repo, 'show', target + ':' + row['path'], optional=True)
        actual = hashlib.sha256(raw).hexdigest() if raw is not None else None
        guard.need(actual == row['sha256'], 'qualification contained dirty or untracked release input: ' + row['path'])


def check_release(repo, target, receipt, installed_commit):
    target = guard.git(repo, 'rev-parse', '--verify', target + '^{commit}').decode().strip()
    guard.document(receipt, 'workflow_qualification')
    snapshot = receipt['snapshot']
    proof_repo = Path(receipt['qualified_repo']).resolve()
    guard.need(guard.git(proof_repo, 'rev-parse', 'HEAD').decode().strip() == snapshot['head'], 'qualified worktree HEAD moved')
    guard.need(not guard.git(proof_repo, 'status', '--porcelain', '--untracked-files=normal').strip(), 'qualified worktree is dirty or has untracked inputs')
    guard.need(receipt.get('registry') == REGISTRY, 'release receipt must use the repository mandatory registry')
    guard.need(receipt.get('integration_gate'), 'deployment requires the full integration gate, not a handoff-only receipt')
    gate = receipt['integration_gate']
    guard.need(guard.sha(Path(gate['path'])) == gate['sha256'], 'integration gate summary changed')
    gate_binding(gate['path'])
    actual_snapshot = guard.snapshot(proof_repo, snapshot['base'])
    guard.need(guard.equal(snapshot, actual_snapshot), 'outer receipt snapshot differs from the actual qualified worktree')
    gate_value = guard.load(gate['path'])
    guard.need(guard.equal(snapshot, gate_value['context']['identity']['snapshot']), 'outer receipt snapshot differs from its integration gate')
    if receipt['qualification'].get('product_verified') is True:
        guard.need(guard.equal(snapshot, receipt['qualification'].get('repo')), 'outer receipt snapshot differs from raw qualification')
    verify_target_inputs(repo, snapshot, target)
    # An arbitrary BASE=HEAD cannot turn changed application code into tooling.
    base_delta = guard.git(repo, 'diff', '--name-only', installed_commit, snapshot['base'], '--', *BUSINESS)
    guard.need(not base_delta.strip(), 'receipt base differs from the actual installed application; re-qualify against its source baseline')
    delta = guard.git(repo, 'diff', '--name-only', installed_commit, target, '--', *BUSINESS)
    qualification = receipt['qualification']
    if delta.strip():
        guard.need(qualification.get('product_verified') is True and qualification.get('acceptance_complete') is True,
                   'application change cannot deploy with tooling-only, historical locked or incomplete evidence')
        guard.need(receipt.get('input_files'), 'product release requires archived plan/baseline/report input files')
        for binding in receipt['input_files']:
            guard.need(guard.sha(Path(binding['path'])) == binding['sha256'], 'archived qualification input changed')
        bindings = receipt['input_files']
        guard.need(len(bindings) == 3 and receipt.get('evidence_root'), 'release raw proof inputs are incomplete')
        # Load the verified integration worktree's collector. An equal-tree merge
        # does not rewrite the archived baseline's absolute tool paths or HEAD.
        module_path = proof_repo / 'scripts/verification/completion_guard.py'
        spec = importlib.util.spec_from_file_location('release_proof_guard', module_path)
        proof_guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(proof_guard)
        plan = proof_guard.load(bindings[0]['path'])
        repeated = proof_guard.qualify(proof_repo, snapshot['base'], proof_guard.contained(proof_repo, receipt['registry']),
                                      plan, proof_guard.load(bindings[1]['path']),
                                      proof_guard.load(bindings[2]['path']), Path(receipt['evidence_root']))
        gate_binding(gate['path'], gate_identity(proof_repo, proof_repo / REGISTRY, plan,
                                               bindings[1]['path'], bindings[2]['path']))
        guard.need(repeated.get('product_verified') is True, 'current raw product evidence no longer qualifies')
        guard.need(guard.equal(repeated, qualification), 'qualification changed since the integration gate')
    else:
        guard.need(qualification.get('tool_test_passed') is True or qualification.get('product_verified') is True,
                   'tooling-only release requires actual tool tests')
        plan = guard.make_plan(proof_repo, snapshot['base'], proof_repo / REGISTRY)
        gate_binding(gate['path'], gate_identity(proof_repo, proof_repo / REGISTRY, plan))
    return {'schema_version': 1, 'kind': 'release_completion_check', 'target': target,
            'installed_commit': installed_commit, 'application_changed': bool(delta.strip()),
            'product_verified': qualification.get('product_verified') is True,
            'global_complete': False}


def deployment_settings(repo):
    path = repo / 'deploy/swift-production/env.py'
    spec = importlib.util.spec_from_file_location('completion_deploy_settings', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.load()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('plan', 'preflight', 'handoff', 'release', 'gate-start', 'gate-finish'))
    parser.add_argument('--repo', default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument('--registry', default='scripts/verification/families.json')
    parser.add_argument('--plan', default=os.environ.get('VERIFY_PLAN'))
    parser.add_argument('--baseline', default=os.environ.get('VERIFY_BASELINE'))
    parser.add_argument('--report', default=os.environ.get('VERIFY_REPORT'))
    parser.add_argument('--evidence-root', default=os.environ.get('VERIFY_EVIDENCE_ROOT'))
    parser.add_argument('--qualification', default=os.environ.get('VERIFY_QUALIFICATION'))
    parser.add_argument('--commit')
    parser.add_argument('--gate-summary')
    parser.add_argument('--context')
    parser.add_argument('--steps')
    parser.add_argument('--out')
    args = parser.parse_args(argv)
    try:
        repo = Path(args.repo).resolve()
        registry = guard.contained(repo, args.registry)
        if args.phase == 'release':
            guard.need(args.commit and args.qualification, 'deploy requires COMMIT and VERIFY_QUALIFICATION from the integration gate')
            settings = deployment_settings(repo)
            installed = guard.load(Path(settings['PRODUCTION_ROOT']) / 'production/supervision/manifests/main.release.json')['gitCommit']
            receipt = guard.load(args.qualification)
            result = check_release(repo, args.commit, receipt, installed)
        else:
            base = trusted_base(repo)
            if args.phase == 'plan':
                result = guard.make_plan(repo, base, registry)
                output = Path(args.out) if args.out else repo / '.build/verification/current-plan.json'
                output.parent.mkdir(parents=True, exist_ok=True)
                # A development plan may be refreshed; final receipts are immutable.
                output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
                print(json.dumps({'plan': str(output.resolve()), 'acceptance_complete': False, 'global_complete': False}))
                return 0
            plan = current_plan(args, repo, registry, base)
            identity = gate_identity(repo, registry, plan, args.baseline or None, args.report or None)
            if args.phase == 'gate-start':
                guard.need(args.out, 'gate-start needs an immutable output path')
                result = {'schema_version': 1, 'kind': 'integration_context', 'run_id': uuid.uuid4().hex,
                          'started_ns': time.time_ns(), 'run_dir': str(Path(args.out).resolve().parent), 'identity': identity}
                immutable_json(args.out, result)
                print(json.dumps({'gate_context': str(Path(args.out).resolve())}))
                return 0
            if args.phase == 'gate-finish':
                guard.need(args.context and args.steps and args.out, 'gate-finish requires context/steps/out')
                finish_gate(args.context, args.steps, identity, args.out)
                print(json.dumps({'integration_steps': str(Path(args.out).resolve())}))
                return 0
            if args.phase == 'preflight':
                result = {'schema_version': 1, 'kind': 'development_preflight', 'mode': plan['impact']['mode'],
                          'plan_digest': plan['plan_digest'], 'acceptance_complete': False, 'global_complete': False}
            else:
                paths = []
                if plan['impact']['mode'] == 'tooling_only':
                    qualification = guard.tool_test(repo, plan)
                else:
                    guard.need(args.baseline and args.report and args.evidence_root, 'handoff requires current baseline, report and raw evidence root')
                    qualification = guard.qualify(repo, base, registry, plan, guard.load(args.baseline), guard.load(args.report), Path(args.evidence_root))
                    guard.need(qualification.get('product_verified') is True, 'synthetic controls cannot qualify an application change')
                    for value in (args.plan, args.baseline, args.report):
                        guard.need(value, 'archived product inputs required')
                        path = Path(value).resolve()
                        paths.append({'path': str(path), 'sha256': guard.sha(path)})
                result = {'schema_version': 1, 'kind': 'workflow_qualification',
                          'snapshot': guard.snapshot(repo, base), 'qualification': qualification,
                          'input_files': paths, 'qualified_repo': str(repo), 'evidence_root': args.evidence_root,
                          'registry': args.registry, 'global_complete': False,
                          'scope_boundary': 'Only named contract obligations/profiles; never all modules in a family.'}
                if args.gate_summary:
                    result['integration_gate'] = gate_binding(args.gate_summary, identity)
                stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
                output = Path(args.out) if args.out else repo / '.build/verification' / stamp / 'qualification.json'
                immutable_json(output, result)
                print(json.dumps({'qualification': str(output.resolve()), 'product_verified': qualification.get('product_verified'), 'global_complete': False}))
                return 0
        if args.out:
            immutable_json(args.out, result)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (guard.GuardError, OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({'kind': 'workflow_rejected', 'acceptance_complete': False, 'global_complete': False, 'error': str(error)}), file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
