#!/usr/bin/env python3
"""Fail-closed change-scoped completion accounting; stdlib, no business execution.

A plan permits development, never completion. qualify replays raw assertions and
binds the git delta, contracts, sources, consumers, tools and declared executable
closure. This cannot prove the honesty/completeness of human declarations or a
collector controlled by an attacker; it never treats a hash as proof of reality.
"""
from __future__ import annotations

import argparse
import base64
import fnmatch
import hashlib
import http.client
import ipaddress
import socket
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import ssl
import subprocess
import sys
import time
from urllib.parse import urlsplit

SCHEMA = 1
TOOL_PATHS = ('docs/**', 'scripts/**', '.github/**', 'README*', 'AGENTS.md', 'Makefile', '.gitignore')
BUSINESS_PATHS = ('Sources/**', 'Tests/**', 'Package.swift', 'Package.resolved', 'Config/**', 'config/**')
TOOL_FILES = ('completion_guard.py', 'evidence.py', 'transport.py', 'upgrade_delta.py')
MISSING = object()


class GuardError(ValueError):
    pass


def need(value, message):
    if not value:
        raise GuardError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def equal(left, right):
    return left is not MISSING and right is not MISSING and canonical(left) == canonical(right)


def unique(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'duplicate JSON key: ' + key)
        result[key] = value
    return result


def finite_float(value):
    result = float(value)
    need(math.isfinite(result), 'non-finite JSON')
    return result


def loads(raw):
    try:
        return json.loads(raw, object_pairs_hook=unique,
                          parse_float=lambda value: finite_float(value),
                          parse_constant=lambda value: (_ for _ in ()).throw(GuardError('non-finite JSON')))
    except (ValueError, UnicodeError) as error:
        raise GuardError('invalid strict JSON: ' + str(error)) from error


def load(path):
    try:
        result = loads(Path(path).read_text())
    except OSError as error:
        raise GuardError('cannot read input: ' + str(path)) from error
    need(isinstance(result, dict), 'document must be an object')
    return result


def document(value, kind=None):
    need(type(value.get('schema_version')) is int and value['schema_version'] == SCHEMA,
         'schema_version must be integer 1')
    if kind:
        need(value.get('kind') == kind, 'expected kind=' + kind)


def relative(value):
    need(isinstance(value, str) and value and '\\' not in value, 'invalid relative path')
    p = PurePosixPath(value)
    need(not p.is_absolute() and '..' not in p.parts and str(p) != '.', 'unsafe relative path')
    return str(p)


def contained(root, value):
    p = (Path(root).resolve() / relative(value)).resolve()
    need(p.is_relative_to(Path(root).resolve()), 'path escapes declared root')
    return p


def write(path, value):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + '\n')


def git(repo, *args, optional=False):
    p = subprocess.run(['git', *args], cwd=repo, capture_output=True)
    if optional and p.returncode:
        return None
    need(p.returncode == 0, 'git operation failed: ' + ' '.join(args[:2]))
    return p.stdout


def snapshot(repo, base):
    repo = Path(repo).resolve()
    need(base and isinstance(base, str), 'explicit --base is required; HEAD is not an implicit base')
    need(git(repo, 'rev-parse', '--show-toplevel').decode().strip() == str(repo), 'repo must be its git root')
    resolved = git(repo, 'rev-parse', '--verify', base + '^{commit}').decode().strip()
    head = git(repo, 'rev-parse', 'HEAD').decode().strip()
    parts = git(repo, 'diff', '--name-status', '-z', '--find-renames', resolved, '--').decode().split('\0')
    changes, cursor = [], 0
    while cursor < len(parts) and parts[cursor]:
        status = parts[cursor]; cursor += 1
        old = None
        if status.startswith(('R', 'C')):
            old = relative(parts[cursor]); cursor += 1
        path = relative(parts[cursor]); cursor += 1
        p = contained(repo, path)
        prior_path = old or path
        prior = git(repo, 'show', resolved + ':' + prior_path, optional=True)
        changes.append({'status': status, 'path': path, 'old_path': old,
                        'sha256': sha(p) if p.is_file() else None,
                        'base_sha256': hashlib.sha256(prior).hexdigest() if prior is not None else None})
    for path in git(repo, 'ls-files', '--others', '--exclude-standard', '-z').decode().split('\0'):
        if path:
            path = relative(path); p = contained(repo, path)
            changes.append({'status': '?', 'path': path, 'old_path': None,
                            'sha256': sha(p) if p.is_file() else None, 'base_sha256': None})
    changes.sort(key=lambda row: (row['path'], row['old_path'] or ''))
    return {'base': resolved, 'head': head,
            'head_tree': git(repo, 'rev-parse', 'HEAD^{tree}').decode().strip(), 'changes': changes}


def patterns(path, values):
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in values)


def indexed(rows, key, label):
    need(isinstance(rows, list), label + ' must be an array')
    result = {}
    for row in rows:
        need(isinstance(row, dict) and isinstance(row.get(key), str) and row[key], label + ' missing ' + key)
        need(row[key] not in result, label + ' duplicate ' + key)
        result[row[key]] = row
    return result


def registry_value(value):
    document(value)
    families = indexed(value.get('families'), 'id', 'families')
    for row in families.values():
        need(isinstance(row.get('paths'), list) and all(isinstance(p, str) and p for p in row['paths']), 'family paths required')
        relative(row['contract'])
    need(isinstance(value.get('shared_paths', []), list), 'shared_paths must be array')
    return families


def contract_weakening(old, current):
    """A conservative review stop, not an automatic semantic approval."""
    findings = []
    if old.get('review_state') in ('DRAFT', 'DRAFT_NOT_QUALIFIABLE'):
        return findings  # Unreviewed bootstrap debt was never an approved denominator.
    old_ob = {row['id']: row for row in old.get('obligations', [])}
    new_ob = {row['id']: row for row in current.get('obligations', [])}
    if old_ob.keys() - new_ob.keys():
        findings.append('required obligation removed')
    old_profiles = {row['id'] for row in old.get('profiles', []) if row.get('required') is True}
    new_profiles = {row['id'] for row in current.get('profiles', []) if row.get('required') is True}
    if old_profiles - new_profiles:
        findings.append('required profile removed')
    old_profile_rows = {row['id']: row for row in old.get('profiles', [])}
    new_profile_rows = {row['id']: row for row in current.get('profiles', [])}
    for identity in old_profiles & new_profiles:
        if not equal(old_profile_rows[identity].get('configuration', MISSING), new_profile_rows[identity].get('configuration', MISSING)):
            findings.append('required profile applicability/configuration changed: ' + identity)
    old_consumers = {row['id']: row for row in old.get('consumers', [])}
    new_consumers = {row['id']: row for row in current.get('consumers', [])}
    for identity, consumer in old_consumers.items():
        old_fields = {canonical(field) for field in consumer.get('required_fields', [])}
        new_fields = {canonical(field) for field in new_consumers.get(identity, {}).get('required_fields', [])}
        if old_fields - new_fields:
            findings.append('consumer field/type/value obligation removed or changed: ' + identity)
    for identity in old_ob.keys() & new_ob.keys():
        before, after = old_ob[identity], new_ob[identity]
        if set(before.get('response_fields', [])) - set(after.get('response_fields', [])):
            findings.append('source response field removed: ' + identity)
        if {canonical(item) for item in before.get('assertions', [])} - {canonical(item) for item in after.get('assertions', [])}:
            findings.append('assertion removed or replaced: ' + identity)
        if set(before.get('steps', {})) - set(after.get('steps', {})):
            findings.append('public/state/provider step removed: ' + identity)
        if set(before.get('profiles', [])) - set(after.get('profiles', [])):
            findings.append('obligation profile coverage removed: ' + identity)
        for name in ('kind', 'consumer', 'flow', 'state', 'provider', 'restart'):
            if name in before and not equal(before[name], after.get(name, MISSING)):
                findings.append('behavioral relation removed/replaced: ' + identity + '/' + name)
        for name, step in before.get('steps', {}).items():
            target = after.get('steps', {}).get(name, {})
            for key in ('kind', 'method', 'path', 'status'):
                if key in step and not equal(step[key], target.get(key, MISSING)):
                    findings.append('public stimulus/expected result changed: ' + identity + '/' + name)
            if {canonical(item) for item in step.get('assertions', [])} - {canonical(item) for item in target.get('assertions', [])}:
                findings.append('step assertion removed: ' + identity + '/' + name)
    for name, dimension in old.get('dimensions', {}).items():
        if dimension.get('applicability') == 'required' and current.get('dimensions', {}).get(name, {}).get('applicability') != 'required':
            findings.append('required dimension became inapplicable: ' + name)
        elif dimension.get('applicability') == 'not_applicable' and current.get('dimensions', {}).get(name, {}).get('applicability') != 'required' and not equal(dimension, current.get('dimensions', {}).get(name, MISSING)):
            findings.append('NA applicability/source preconditions changed: ' + name)
    return sorted(set(findings))


def impact(repo, base, registry_path):
    repo = Path(repo).resolve(); reg_path = Path(registry_path).resolve()
    need(reg_path.is_relative_to(repo), 'registry must be a repository input')
    reg = load(reg_path); current = registry_value(reg); snap = snapshot(repo, base)
    prior = git(repo, 'show', snap['base'] + ':' + str(reg_path.relative_to(repo)), optional=True)
    old = registry_value(loads(prior)) if prior is not None else {}
    families = {**old, **current}
    shared = reg.get('shared_paths', [])
    if prior is not None:
        shared = sorted(set(shared + loads(prior).get('shared_paths', [])))
    affected, unknown, business, changed = set(), [], False, []
    for row in snap['changes']:
        names = [row['path']] + ([row['old_path']] if row['old_path'] else [])
        hard = any(patterns(name, BUSINESS_PATHS) for name in names)
        shared_hit = any(patterns(name, shared) for name in names)
        matched = {key for key, item in families.items() if any(patterns(name, item['paths']) for name in names)}
        if shared_hit:
            matched.update(families)
        relevant = hard or shared_hit or any(not patterns(name, TOOL_PATHS) for name in names)
        if relevant:
            business = True
            affected.update(matched)
            if not matched:
                unknown.extend(names)
        changed.append({**row, 'families': sorted(matched), 'business_relevant': relevant})
    missing = sorted(affected - current.keys())
    removed_families = sorted(old.keys() - current.keys())
    unknown = sorted(set(unknown + ['removed-family:' + key for key in set(missing + removed_families)]))
    weakening = {}
    if prior is not None:
        removed_shared = set(loads(prior).get('shared_paths', [])) - set(reg.get('shared_paths', []))
        if removed_shared:
            weakening['registry'] = ['shared paths removed/narrowed: ' + path for path in sorted(removed_shared)]
    for family in sorted(current.keys() & old.keys()):
        findings = []
        removed_paths = set(old[family]['paths']) - set(current[family]['paths'])
        if removed_paths:
            findings.append('family path mapping removed/narrowed')
        old_contract = git(repo, 'show', snap['base'] + ':' + old[family]['contract'], optional=True)
        current_path = contained(repo, current[family]['contract'])
        if old_contract is not None:
            if current_path.is_file():
                findings += contract_weakening(loads(old_contract), load(current_path))
            else:
                findings.append('existing contract deleted')
        if findings:
            weakening[family] = sorted(set(findings))
    return {'schema_version': SCHEMA, 'kind': 'change_impact', 'repo': snap,
            'registry_path': str(reg_path.relative_to(repo)), 'registry_sha256': sha(reg_path),
            'mode': 'business' if business else 'tooling_only', 'changed': changed,
            'affected_families': sorted(affected), 'unknown_paths': unknown, 'policy_weakening': weakening,
            'needs_review': bool(unknown or weakening), 'global_debt': reg.get('global_debt', []),
            'global_complete': False}, reg, current


def ref_shape(ref):
    need(isinstance(ref, dict) and isinstance(ref.get('root'), str) and ref['root'], 'reference requires root')
    relative(ref.get('path'))
    need(isinstance(ref.get('sha256'), str) and re.fullmatch('[0-9a-f]{64}', ref['sha256']), 'reference requires sha256')


def field_shape(field):
    need(isinstance(field, dict) and isinstance(field.get('pointer'), str) and field['pointer'].startswith('/'), 'field pointer required')
    need(field.get('type') in ('string', 'boolean', 'integer', 'float', 'number', 'array', 'object', 'null'), 'strict field type required')


def contract_value(value, family):
    document(value)
    need(value.get('review_state') == 'REVIEWED', 'DRAFT/unknown contract review_state needs explicit source/consumer review before business qualification')
    need(value.get('family') == family and isinstance(value.get('version'), str) and value['version'], 'family/version mismatch')
    need(isinstance(value.get('source_refs'), list) and value['source_refs'], 'pinned source refs required')
    for ref in value['source_refs']:
        ref_shape(ref)
    production = value.get('production', {})
    need(production.get('mode') in ('producer', 'query'), 'production mode must be producer or query')
    need(isinstance(production.get('trigger'), str) and production['trigger'] and isinstance(production.get('authority'), str) and production['authority'], 'production trigger/authoritative state required')
    consumers = indexed(value.get('consumers'), 'id', 'consumers')
    need(consumers, 'consumer declarations required')
    for consumer in consumers.values():
        need(consumer.get('refs'), 'pinned consumer refs required')
        for ref in consumer['refs']:
            ref_shape(ref)
        fields = consumer.get('required_fields')
        need(isinstance(fields, list) and fields, 'complete consumer field declaration required')
        for field in fields:
            field_shape(field)
        pointers = [field['pointer'] for field in fields]
        need(len(set(pointers)) == len(pointers), 'duplicate consumer field')
    profiles = indexed(value.get('profiles'), 'id', 'profiles')
    need(profiles and any(row.get('required') is True for row in profiles.values()), 'required real profile required')
    for profile in profiles.values():
        need(type(profile.get('required')) is bool and isinstance(profile.get('configuration'), dict) and profile['configuration'], 'profile configuration required')
    obligations = indexed(value.get('obligations'), 'id', 'obligations')
    need(obligations, 'required obligations cannot be empty')
    for obligation in obligations.values():
        need(obligation.get('kind') in ('producer_consumer', 'query', 'protocol', 'boundary', 'restart'), 'unknown obligation kind')
        need(isinstance(obligation.get('profiles'), list) and obligation['profiles'] and set(obligation['profiles']) <= profiles.keys(), 'obligation profiles invalid')
        steps = obligation.get('steps')
        need(isinstance(steps, dict) and steps, 'obligation steps required')
        for step in steps.values():
            need(isinstance(step, dict) and step.get('kind', 'public_http') in ('public_http', 'state_snapshot', 'provider_call', 'process_restart'), 'unknown/helper step cannot substitute for a public or authoritative observation')
            if step.get('kind', 'public_http') == 'public_http':
                need(isinstance(step.get('method'), str) and isinstance(step.get('path'), str) and type(step.get('status')) is int, 'public HTTP stimulus/result required')
        need(isinstance(obligation.get('assertions'), list) and obligation['assertions'], 'raw assertions required')
        need(any(item.get('op') not in ('exists', 'type') for item in obligation['assertions']), 'presence/type-only is not behavioral evidence')
        consumer = obligation.get('consumer')
        need(isinstance(consumer, dict) and consumer.get('id') in consumers and consumer.get('step') in steps, 'bound consumer required')
        need(isinstance(consumer.get('pointer'), str), 'consumer object pointer required')
        need(steps[consumer['step']].get('kind', 'public_http') == 'public_http', 'consumer must be a public observation, not helper/state seeding')
        declared = obligation.get('response_fields')
        need(isinstance(declared, list) and declared, 'source response field list required')
        consumer_fields = {field['pointer'] for field in consumers[consumer['id']]['required_fields']}
        need(set(declared) <= consumer_fields, 'contract response fields omitted from consumer field declaration')
        if obligation['kind'] == 'producer_consumer':
            flow = obligation.get('flow', {})
            need(flow.get('producer') in steps and flow.get('consumer') in steps, 'producer/read flow required')
            need(flow.get('transition') in ('create', 'update'), 'create/update state transition required')
            need(flow.get('input_links') and flow.get('before') and flow.get('after'), 'public input and authoritative before/after links required')
            need(flow.get('object_from') and flow.get('object_to'), 'same-object reference link required')
            need(flow['object_from'].get('step') == flow['producer'] and flow['object_to'].get('step') == flow['consumer'] == consumer['step'], 'object identity must link producer output to bound consumer')
            need(flow['object_to'].get('pointer', '').startswith(consumer['pointer'] + '/'), 'object link must address the declared consumer object')
            for link in flow['input_links']:
                need(link.get('from', {}).get('step') == flow['producer'] and link['from'].get('pointer', '').startswith('/request_json/'), 'input link must originate in public producer request')
                need(link.get('to', {}).get('step') == flow['consumer'] and link['to'].get('pointer', '').startswith(consumer['pointer'] + '/'), 'input must propagate into the declared consumer object')
        if obligation.get('state'):
            state = obligation['state']
            need(state.get('relation') in ('unchanged', 'changed') and state.get('before', {}).get('step') in steps and state.get('after', {}).get('step') in steps, 'explicit state relation and snapshot steps required')
        if obligation['kind'] == 'query':
            need(obligation.get('state', {}).get('relation') == 'unchanged', 'query must prove no state mutation')
        if obligation['kind'] == 'restart':
            need(obligation.get('restart', {}).get('step') in steps, 'restart receipt required')
    dimensions = value.get('dimensions')
    names = {'producer', 'consumer', 'query_state', 'authorization', 'configuration', 'restart'}
    need(isinstance(dimensions, dict) and set(dimensions) == names, 'all completion dimensions must be explicitly mapped')
    for name, dimension in dimensions.items():
        need(isinstance(dimension, dict), 'dimension must be an object')
        applicability = dimension.get('applicability')
        need(applicability in ('required', 'not_applicable'), 'unknown dimension is not inapplicable')
        if applicability == 'not_applicable':
            need(dimension.get('reason') and dimension.get('preconditions') and dimension.get('source_refs'), 'NA needs source-based reason and concrete applicability preconditions')
            for ref in dimension['source_refs']:
                ref_shape(ref)
        else:
            ids = dimension.get('obligations')
            need(isinstance(ids, list) and ids and set(ids) <= obligations.keys(), 'dimension obligations missing')
            if name == 'producer':
                need(any(obligations[key]['kind'] == 'producer_consumer' for key in ids), 'producer dimension lacks public producer')
            if name == 'query_state':
                need(any(obligations[key]['kind'] == 'query' for key in ids), 'query dimension lacks invariant')
            if name == 'restart':
                need(any(obligations[key].get('restart') for key in ids), 'restart dimension lacks receipt obligation')
            if name == 'configuration':
                need(set(dimension.get('profiles', [])) == {key for key, item in profiles.items() if item['required']}, 'configuration must cover every required profile')
            if name == 'authorization':
                for role, positive in (('positive', True), ('negative', False)):
                    witnesses = dimension.get(role)
                    need(isinstance(witnesses, list) and witnesses, 'authorization needs positive and negative witnesses')
                    for witness in witnesses:
                        target = obligations.get(witness.get('obligation'), {}).get('steps', {}).get(witness.get('step'), {})
                        need(target.get('kind', 'public_http') == 'public_http', 'authorization witness must be an actual public HTTP step')
                        status = target.get('status')
                        need(type(status) is int and ((200 <= status < 300) if positive else (400 <= status < 500)), 'authorization witness lacks correct public status')
    required_profiles = {key for key, item in profiles.items() if item['required']}
    for profile_id in required_profiles:
        need(any(profile_id in row['profiles'] for row in obligations.values()), 'required profile has an empty obligation denominator')
    expected_kind = {'producer': 'producer_consumer', 'query_state': 'query', 'restart': 'restart'}
    for name, dimension in dimensions.items():
        if dimension['applicability'] != 'required':
            continue
        for profile_id in required_profiles:
            candidates = [obligations[key] for key in dimension['obligations'] if profile_id in obligations[key]['profiles']]
            if name in expected_kind:
                candidates = [row for row in candidates if row['kind'] == expected_kind[name] or (name == 'restart' and row.get('restart'))]
            need(candidates, 'required dimension hidden in an optional profile: ' + name + '/' + profile_id)
            if name == 'authorization':
                for role in ('positive', 'negative'):
                    need(any(profile_id in obligations[item['obligation']]['profiles'] for item in dimension[role]), 'authorization witness hidden in optional profile: ' + role + '/' + profile_id)
    immutable_gets = {step['path'] for item in obligations.values() for step in item['steps'].values()
                      if step.get('method') == 'GET' and 'consume=false' in step.get('path', '')}
    stable_gets = {step['path'] for item in obligations.values() if item['kind'] == 'query'
                   for step in item['steps'].values() if step.get('method') == 'GET'}
    need(immutable_gets <= stable_gets, 'consume=false GET lacks a matching before/after unchanged-state obligation')
    for name in ('consumer', 'configuration'):
        need(dimensions[name]['applicability'] == 'required', name + ' cannot be excluded from completion')
    if production['mode'] == 'producer':
        need(dimensions['producer']['applicability'] == 'required' and any(row['kind'] == 'producer_consumer' for row in obligations.values()), 'producer family lacks producer flow')
    else:
        need(dimensions['query_state']['applicability'] == 'required' and any(row['kind'] == 'query' for row in obligations.values()), 'query family lacks state invariant')
    return consumers, profiles, obligations


def make_plan(repo, base, registry):
    info, reg, families = impact(repo, base, registry)
    contracts, required = {}, []
    for family in info['affected_families']:
        need(family in families, 'affected family removed from registry')
        path = contained(repo, families[family]['contract']); contract = load(path)
        _, profiles, obligations = contract_value(contract, family)
        contracts[family] = {'path': str(path.relative_to(Path(repo).resolve())), 'sha256': sha(path), 'version': contract['version']}
        for identity, row in obligations.items():
            for profile in row['profiles']:
                if profiles[profile]['required']:
                    required.append({'family': family, 'obligation': identity, 'profile': profile, 'status': 'NOT_RUN'})
    return {'schema_version': SCHEMA, 'kind': 'change_plan', 'impact': info,
            'contracts': contracts, 'required': required, 'plan_digest': digest({'impact': info, 'contracts': contracts, 'required': required}),
            'acceptance_complete': False, 'global_complete': False,
            'review_boundary': 'Humans must review source/consumer declaration completeness and applicable profiles; generated plans never approve semantics.'}


def verify_plan(repo, base, registry, plan):
    document(plan, 'change_plan')
    actual = make_plan(repo, base, registry)
    need(equal(plan, actual), 'plan is stale or weakened; regenerate from actual git inputs')
    need(not actual['impact']['needs_review'], 'unknown affected paths require review/mapping')
    if actual['impact']['mode'] == 'business':
        need(actual['required'], 'business change has no required obligations')
    return actual


def bound_files(bindings):
    result = {}
    for category in ('runtime', 'client', 'config'):
        block = bindings.get(category)
        need(isinstance(block, dict) and isinstance(block.get('files'), list) and block['files'], category + ' requires actual file closure')
        files, resolved_paths = {}, {}
        for name in block['files']:
            p = Path(os.path.abspath(name)); target = p.resolve(strict=True)
            need(p.is_file(), category + ' dependency is not a file')
            files[str(p)] = sha(p); resolved_paths[str(p)] = str(target)
        result[category] = {'files': files, 'resolved_paths': resolved_paths, 'fingerprint': digest({'files': files, 'resolved_paths': resolved_paths})}
        if category == 'config':
            need(block.get('values_file'), 'effective configuration values_file is required')
            values_path = Path(block['values_file']).resolve(strict=True)
            need(str(values_path) in files, 'configuration values_file must be in hashed file closure')
            result[category]['values_file'] = str(values_path)
            result[category]['values'] = load(values_path)
    for category in ('tools',):
        files, resolved_paths = {}, {}
        for name in bindings.get(category, {}).get('files', []):
            p = Path(os.path.abspath(name)); files[str(p)] = sha(p); resolved_paths[str(p)] = str(p.resolve(strict=True))
        result[category] = {'files': files, 'resolved_paths': resolved_paths, 'fingerprint': digest({'files': files, 'resolved_paths': resolved_paths})}
    return result


BUILD_INPUTS = ('Sources/**', 'Resources/**', 'Config/**', 'config/**', 'Package.swift', 'Package.resolved', '.swift-version', '.tool-versions')


def source_files(repo, commit=None):
    if commit:
        names = git(repo, 'ls-tree', '-r', '--name-only', '-z', commit).decode().split('\0')
    else:
        names = git(repo, 'ls-files', '--cached', '--others', '--exclude-standard', '-z').decode().split('\0')
    result = {}
    for name in names:
        if not name or not patterns(name, BUILD_INPUTS):
            continue
        if commit:
            body = git(repo, 'show', commit + ':' + name)
            result[name] = hashlib.sha256(body).hexdigest()
        else:
            path = contained(repo, name)
            if path.is_file():
                result[name] = sha(path)
    return result


def process_pid(locator):
    if locator.get('kind') == 'systemd_user':
        need(isinstance(locator.get('unit'), str) and locator['unit'], 'systemd unit locator required')
        observed = subprocess.run(['systemctl', '--user', 'show', locator['unit'], '--property=MainPID', '--value'], capture_output=True, text=True)
        need(observed.returncode == 0 and observed.stdout.strip().isdigit(), 'cannot resolve actual runtime unit PID')
        pid = int(observed.stdout.strip())
    else:
        need(locator.get('kind') == 'pid' and type(locator.get('pid')) is int, 'actual process locator required')
        pid = locator['pid']
    need(pid > 0, 'runtime is not running')
    return pid


def canonical_origin(value):
    try:
        parsed = urlsplit(value)
        need(parsed.scheme in ('http', 'https') and parsed.hostname and not parsed.username and not parsed.password, 'invalid target origin')
        need(parsed.path in ('', '/') and not parsed.query and not parsed.fragment, 'target must be an origin')
        host = parsed.hostname.lower()
        host = '127.0.0.1' if host == 'localhost' else host
        port = parsed.port or (443 if parsed.scheme == 'https' else 80)
        return f'{parsed.scheme}://{"[" + host + "]" if ":" in host else host}:{port}'
    except (TypeError, ValueError) as error:
        raise GuardError('invalid target origin') from error


def listener_identity(target, proof):
    """Direct loopback only: no caller-declared proxy or container-port mapping."""
    parsed = urlsplit(target['origin'])
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError as error:
        raise GuardError('product target requires a literal direct loopback address') from error
    need(address.is_loopback, 'product target requires direct loopback origin; remote/proxy adapter is not implemented')
    pid = process_pid(proof['locator']); process_root = Path('/proc') / str(pid)
    need(os.readlink(process_root / 'ns/net') == os.readlink('/proc/self/ns/net'), 'target is in another network namespace; trusted port adapter required')
    need(sha(process_root / 'exe') == proof['binary_sha256'], 'target process binary changed')
    need(sha(process_root / 'environ') == proof['environment_sha256'], 'target process environment changed')
    owned = set()
    for fd in (process_root / 'fd').iterdir():
        try:
            link = os.readlink(fd)
        except FileNotFoundError:
            continue
        if link.startswith('socket:['):
            owned.add(link[8:-1])
    candidates = set()
    for name, family in (('tcp', socket.AF_INET), ('tcp6', socket.AF_INET6)):
        table = process_root / 'net' / name
        if not table.exists():
            continue
        for line in table.read_text().splitlines()[1:]:
            fields = line.split()
            if len(fields) < 10 or fields[3] != '0A':
                continue
            encoded, port = fields[1].split(':')
            if int(port, 16) != parsed.port:
                continue
            raw = bytes.fromhex(encoded)
            raw = raw[::-1] if family == socket.AF_INET else b''.join(raw[index:index + 4][::-1] for index in range(0, 16, 4))
            local = ipaddress.ip_address(socket.inet_ntop(family, raw))
            if local.is_unspecified or local == address or getattr(local, 'ipv4_mapped', None) == address:
                candidates.add(fields[9])
    need(candidates and candidates <= owned, 'target listener is not exclusively owned by the bound runtime PID')
    stat = (process_root / 'stat').read_text().rpartition(')')[2].split()
    need(len(stat) > 19 and stat[19].isdigit(), 'runtime start ticks unavailable')
    return {'pid': pid, 'start_ticks': stat[19], 'binary_sha256': proof['binary_sha256'],
            'environment_sha256': proof['environment_sha256'], 'listener_inodes': sorted(candidates), 'port': parsed.port}


def target_value(bindings, plan, files):
    supplied = bindings.get('target')
    need(isinstance(supplied, dict) and isinstance(supplied.get('id'), str) and supplied['id'], 'fixed target id/origin required')
    target = {'id': supplied['id'], 'origin': canonical_origin(supplied.get('origin'))}
    product = bindings.get('evidence_class', 'product') == 'product'
    proof = files['runtime'].get('proof', {})
    target.update(source_commit=proof.get('build_source_commit', plan['impact']['repo']['head']),
                  source_tree=proof.get('build_source_tree', plan['impact']['repo']['head_tree']),
                  runtime_fingerprint=files['runtime']['fingerprint'])
    if product:
        listener_identity(target, proof)  # OS proof, never an origin/PID compatibility flag.
    return target


def runtime_proof(repo, bindings, files):
    block = bindings['runtime']
    for key in ('build_receipt', 'process_receipt'):
        need(block.get(key), 'product runtime requires ' + key)
        path = Path(block[key]).resolve(strict=True)
        need(str(path) in files['runtime']['files'], key + ' must be in runtime closure')
    build = load(block['build_receipt']); document(build, 'runtime_build')
    commit = git(repo, 'rev-parse', '--verify', str(build.get('source_commit')) + '^{commit}').decode().strip()
    tree = git(repo, 'rev-parse', commit + '^{tree}').decode().strip()
    need(tree == build.get('source_tree'), 'runtime build source tree mismatch')
    original = source_files(repo, commit); current = source_files(repo)
    need(original and equal(original, current), 'runtime binary was built from different source/dependency inputs')
    binary = str(Path(build['binary']).resolve(strict=True))
    need(binary in files['runtime']['files'] and files['runtime']['files'][binary] == build.get('binary_sha256'), 'build receipt binary is not the actual bound binary')
    process = load(block['process_receipt']); document(process, 'process_identity')
    locator = process.get('locator', {})
    pid = process_pid(locator)
    exe = sha(Path('/proc') / str(pid) / 'exe')
    need(exe == process.get('binary_sha256') == build['binary_sha256'], 'actual process executable differs from built binary')
    environment = sha(Path('/proc') / str(pid) / 'environ')
    need(environment == process.get('environment_sha256'), 'actual process effective environment changed')
    manifest = process.get('manifest', {})
    manifest_path = str(Path(manifest['path']).resolve(strict=True))
    need(manifest_path in files['config']['files'] and sha(manifest_path) == manifest.get('sha256'), 'actual runtime manifest missing/not bound')
    manifest_value = load(manifest_path)
    need(manifest_value.get('gitCommit', manifest_value.get('source_commit')) == commit, 'runtime manifest source does not match build receipt')
    manifest_binary = manifest_value.get('binary_sha256', manifest_value.get('files', {}).get('RaftServer'))
    need(manifest_binary == build['binary_sha256'], 'runtime manifest binary differs from actual build')
    need(any(digest_value == build['binary_sha256'] for digest_value in files['runtime']['files'].values()), 'runtime artifact absent')
    return {'build_receipt': str(Path(block['build_receipt']).resolve()),
            'process_receipt': str(Path(block['process_receipt']).resolve()),
            'build_source_commit': commit, 'build_source_tree': tree,
            'source_input_files': original, 'source_input_digest': digest(original),
            'current_source_input_digest': digest(current), 'binary_sha256': exe,
            'environment_sha256': environment, 'locator': locator}


def make_baseline(repo, plan, bindings):
    need(isinstance(bindings.get('roots'), dict), 'fixed external source/consumer roots required')
    files = bound_files(bindings)
    if bindings.get('evidence_class', 'product') == 'product':
        executables = []
        for name in files['runtime']['files']:
            p = Path(name)
            with p.open('rb') as stream:
                if stream.read(4) == b'\x7fELF' and os.access(p, os.X_OK):
                    executables.append(name)
        need(executables, 'product runtime closure lacks an actual executable ELF; fixture files are tool tests only')
        files['runtime']['proof'] = runtime_proof(repo, bindings, files)
    repo = Path(repo).resolve(); refs = {}
    for family, item in plan['contracts'].items():
        contract = load(contained(repo, item['path']))
        contract_value(contract, family)
        if bindings.get('evidence_class', 'product') == 'product' and any(row.get('restart') for row in contract['obligations']):
            need(files['runtime']['proof']['locator']['kind'] == 'systemd_user', 'product restart requires a stable service locator; direct PID cannot follow restart')
        all_refs = contract['source_refs'] + [ref for row in contract['consumers'] for ref in row['refs']]
        all_refs += [ref for dimension in contract['dimensions'].values() for ref in dimension.get('source_refs', [])]
        for ref in all_refs:
            need(ref['root'] in bindings['roots'], 'reference root unbound: ' + ref['root'])
            p = contained(bindings['roots'][ref['root']], ref['path'])
            need(sha(p) == ref['sha256'], 'pinned source/consumer reference changed')
            refs[str(p)] = sha(p)
    tools = files['tools']['files']
    here = Path(__file__).resolve().parent
    for name in TOOL_FILES:
        p = here / name
        if p.is_file():
            tools[str(p)] = sha(p)
            files['tools']['resolved_paths'][str(p)] = str(p.resolve())
    files['tools']['fingerprint'] = digest({'files': tools, 'resolved_paths': files['tools']['resolved_paths']})
    value = {'schema_version': SCHEMA, 'kind': 'completion_baseline', 'repo': plan['impact']['repo'],
             'plan_digest': plan['plan_digest'], 'contracts': plan['contracts'],
             'registry_sha256': plan['impact']['registry_sha256'], 'source_consumer_files': refs,
             'bindings': files, 'roots': {key: str(Path(path).resolve()) for key, path in bindings['roots'].items()},
             'evidence_class': bindings.get('evidence_class', 'product'), 'target': target_value(bindings, plan, files),
             'observation_clock': observation_clock()}
    need(value['evidence_class'] in ('product', 'synthetic_tool_test'), 'unknown evidence class')
    value['baseline_digest'] = digest(value)
    return value


def verify_baseline(repo, plan, baseline):
    document(baseline, 'completion_baseline')
    claimed = baseline.get('baseline_digest'); payload = dict(baseline); payload.pop('baseline_digest', None)
    need(digest(payload) == claimed, 'baseline digest mismatch')
    bindings = {'roots': baseline['roots'], 'evidence_class': baseline['evidence_class'], 'target': baseline['target']}
    for category in ('runtime', 'client', 'config', 'tools'):
        bindings[category] = {'files': list(baseline['bindings'][category]['files'])}
    bindings['config']['values_file'] = baseline['bindings']['config']['values_file']
    if baseline['evidence_class'] == 'product':
        bindings['runtime'].update({key: baseline['bindings']['runtime']['proof'][key] for key in ('build_receipt', 'process_receipt')})
    need(equal(make_baseline(repo, plan, bindings), baseline), 'current repo/source/tool/contract/runtime/client/config fingerprint differs')


def pointer(value, path):
    need(isinstance(path, str) and (not path or path.startswith('/')), 'invalid JSON pointer')
    for part in path.split('/')[1:] if path else []:
        part = part.replace('~1', '/').replace('~0', '~')
        if isinstance(value, dict):
            value = value.get(part, MISSING)
        elif isinstance(value, list) and re.fullmatch('0|[1-9][0-9]*', part):
            index = int(part); value = value[index] if index < len(value) else MISSING
        else:
            return MISSING
    return value


def typed(value, kind):
    types = {'string': str, 'boolean': bool, 'integer': int, 'float': float,
             'array': list, 'object': dict, 'null': type(None)}
    return type(value) in (int, float) if kind == 'number' else type(value) is types.get(kind)


def select(steps, ref):
    need(isinstance(ref, dict) and ref.get('step') in steps, 'assertion references missing step')
    return pointer(steps[ref['step']], ref.get('pointer', ''))


def assert_raw(assertion, steps):
    op = assertion.get('op'); value = select(steps, assertion.get('at'))
    if op == 'exists':
        need(value is not MISSING, 'raw field missing')
    elif op == 'type':
        need(typed(value, assertion.get('type')), 'raw field wrong strict type')
    elif op == 'equals':
        need('value' in assertion and equal(value, assertion['value']), 'raw expected value differs')
    elif op in ('equal', 'unchanged', 'changed'):
        other = select(steps, assertion.get('other'))
        need(value is not MISSING and other is not MISSING, 'comparison field missing')
        need(equal(value, other) if op != 'changed' else not equal(value, other), 'raw relation differs: ' + op)
    elif op == 'contains':
        need(isinstance(value, list) and any(equal(item, assertion.get('value', MISSING)) for item in value), 'raw array does not contain expected value')
    else:
        raise GuardError('unknown assertion operation')


def contains(value, target):
    if equal(value, target):
        return True
    if isinstance(value, dict):
        return any(contains(item, target) for item in value.values())
    if isinstance(value, list):
        return any(contains(item, target) for item in value)
    return False


def observation_clock():
    need(hasattr(time, 'CLOCK_BOOTTIME'), 'product observation clock requires Linux CLOCK_BOOTTIME')
    boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    need(bool(boot), 'host boot identity unavailable')
    return {'clock': 'CLOCK_BOOTTIME_NS', 'boot_id': boot}


def observation_now():
    return time.clock_gettime_ns(time.CLOCK_BOOTTIME)


def observation_interval(raw, baseline):
    need(equal(raw.get('observation_clock', MISSING), baseline['observation_clock']), 'observation clock/host boot is missing or differs')
    start, end = raw.get('observation_started_ns'), raw.get('observation_completed_ns')
    need(type(start) is int and type(end) is int and 0 <= start <= end, 'trusted observation interval missing/invalid')
    if raw.get('kind') == 'public_http':
        wall = [raw.get(key) for key in ('request_started_at_ns', 'response_completed_at_ns', 'captured_at_ns')]
        need(all(type(item) is int and item > 0 for item in wall) and wall[0] <= wall[1] <= wall[2], 'HTTP wall observation timestamps missing/inconsistent')
    return start, end


def validate_observations(steps, baseline):
    if baseline['evidence_class'] != 'product':
        return
    intervals = {name: observation_interval(raw, baseline) for name, raw in steps.items()}
    for left_name, left in steps.items():
        for right_name, right in steps.items():
            if left['sequence'] >= right['sequence']:
                continue
            need(intervals[left_name][0] <= intervals[right_name][0], 'sequence contradicts actual observation time')
            if left.get('kind') == right.get('kind') == 'public_http':
                need(left['request_started_at_ns'] <= right['request_started_at_ns'], 'sequence contradicts recorded HTTP wall time')


def observed_before(steps, left, right, baseline, message):
    if baseline['evidence_class'] == 'product':
        need(observation_interval(steps[left], baseline)[1] <= observation_interval(steps[right], baseline)[0], message)


def verify_target_binding(raw, baseline):
    target = baseline['target']
    need(raw.get('target_id') == target['id'], 'raw evidence target identity mismatch')
    if raw.get('kind') != 'public_http':
        return
    need(raw.get('origin') == target['origin'], 'HTTP evidence came from another origin')
    binding = raw.get('target_binding', {})
    need(binding.get('target_digest') == digest(target), 'raw HTTP target binding missing/stale')
    if baseline['evidence_class'] != 'product':
        return
    proof = baseline['bindings']['runtime']['proof']
    before, after = binding.get('before', {}), binding.get('after', {})
    need(equal(before, after), 'runtime incarnation changed during HTTP capture')
    need(type(before.get('pid')) is int and before['pid'] > 0 and str(before.get('start_ticks', '')).isdigit(), 'actual process incarnation missing')
    need(before.get('binary_sha256') == proof['binary_sha256'] and before.get('environment_sha256') == proof['environment_sha256'], 'HTTP target process differs from bound runtime')
    need(before.get('listener_inodes') and all(isinstance(value, str) and value.isdigit() for value in before['listener_inodes']) and equal(before.get('port', MISSING), urlsplit(target['origin']).port), 'HTTP listener ownership proof missing')
    for version in (binding.get('version_before', {}), binding.get('version_after', {})):
        need(equal(version.get('status', MISSING), 200) and version.get('origin') == target['origin'], 'target version handshake missing')
        try:
            body = base64.b64decode(version['body_base64'], validate=True)
        except (KeyError, ValueError, TypeError) as error:
            raise GuardError('invalid target version response') from error
        need(hashlib.sha256(body).hexdigest() == version.get('body_sha256'), 'target version raw hash mismatch')
        data = loads(body)
        need(isinstance(data, dict) and data.get('sha') == target['source_commit'], 'HTTP target source differs from built runtime')


def raw_evidence(root, ref, baseline):
    need(isinstance(ref, dict), 'evidence reference required')
    path = contained(root, ref.get('path')); need(path.is_file() and sha(path) == ref.get('sha256'), 'raw evidence missing or tampered')
    raw = load(path)
    need(raw.get('baseline_digest') == baseline['baseline_digest'], 'raw evidence belongs to another baseline')
    need(raw.get('evidence_class') == baseline['evidence_class'], 'evidence class mismatch')
    need(raw.get('collector_sha256') in baseline['bindings']['tools']['files'].values(), 'collector implementation is not bound to current baseline')
    verify_target_binding(raw, baseline)
    if baseline['evidence_class'] == 'product':
        observation_interval(raw, baseline)
    need(type(raw.get('sequence')) is int and raw['sequence'] >= 0, 'raw causal sequence required')
    need(isinstance(raw.get('run_id'), str) and raw['run_id'], 'capture run_id required')
    for label in ('response', 'request'):
        body_key = label + '_body_base64'
        if body_key in raw:
            try:
                body = base64.b64decode(raw[body_key], validate=True)
            except (ValueError, TypeError) as error:
                raise GuardError('invalid raw body encoding') from error
            need(hashlib.sha256(body).hexdigest() == raw.get(label + '_body_sha256'), 'raw body hash mismatch')
            if body:
                try:
                    decoded = loads(body)
                except GuardError:
                    decoded = MISSING
                if label + '_json' in raw:
                    need(decoded is not MISSING and equal(raw[label + '_json'], decoded), 'parsed body differs from raw bytes')
                if decoded is not MISSING:
                    raw[label + '_json'] = decoded
            else:
                need(label + '_json' not in raw, 'empty bytes cannot contain parsed JSON')
    return raw


def evaluate(obligation, consumers, profile, row, root, baseline):
    need(row.get('status') == 'PASS' and row.get('disposition') not in ('approved_deviation', 'locked', 'seed_only'), 'result is not an executed behavioral PASS')
    need(row.get('baseline_digest') == baseline['baseline_digest'], 'result baseline stale')
    need(equal(row.get('configuration', MISSING), profile['configuration']), 'required runtime profile/configuration missing')
    configured = baseline['bindings']['config']['values']
    configured = configured.get('profiles', {}).get(profile['id'], configured)
    need(all(equal(configured.get(key, MISSING), value) for key, value in profile['configuration'].items()), 'required profile is not configured in fixed effective configuration')
    need(isinstance(row.get('steps'), dict) and set(row['steps']) == set(obligation['steps']), 'required steps missing or unexpected')
    steps = {name: raw_evidence(root, ref, baseline) for name, ref in row['steps'].items()}
    need(len({raw['run_id'] for raw in steps.values()}) == 1, 'steps cross capture runs')
    validate_observations(steps, baseline)
    for name, spec in obligation['steps'].items():
        raw = steps[name]
        if spec.get('kind', 'public_http') == 'public_http':
            need(raw.get('kind') == 'public_http', 'helper/seed is not public HTTP evidence')
            for key in ('method', 'path', 'status'):
                need(key in spec and equal(raw.get(key, MISSING), spec[key]), 'HTTP ' + key + ' mismatch')
            need('response_body_base64' in raw, 'HTTP requires actual response bytes')
        else:
            need(raw.get('kind') == spec['kind'], 'step receipt kind mismatch')
        for assertion in spec.get('assertions', []):
            assert_raw({**assertion, 'at': {'step': name, 'pointer': assertion['pointer']}}, steps)
    for assertion in obligation['assertions']:
        assert_raw(assertion, steps)
    consumer = obligation['consumer']; obj = pointer(steps[consumer['step']], consumer['pointer'])
    need(obj is not MISSING, 'consumer object missing')
    for field in consumers[consumer['id']]['required_fields']:
        value = pointer(obj, field['pointer'])
        need(value is not MISSING and typed(value, field['type']), 'consumer required field missing/wrong type: ' + field['pointer'])
        if 'expected' in field:
            need(equal(value, field['expected']), 'consumer field value differs: ' + field['pointer'])
    if obligation['kind'] == 'producer_consumer':
        flow = obligation['flow']; produced = steps[flow['producer']]; consumed = steps[flow['consumer']]
        need(produced.get('kind') == 'public_http' and produced.get('method') not in ('GET', 'HEAD', 'OPTIONS'), 'producer must be a public mutating input')
        need('request_body_base64' in produced and produced.get('request_json') not in (None, {}), 'producer public input missing')
        need(produced['sequence'] < consumed['sequence'], 'consumer must follow production')
        origin = select(steps, flow['object_from']); result = select(steps, flow['object_to'])
        need(type(origin) in (str, int) and bool(origin) and equal(origin, result), 'producer/read object reference mismatch')
        before = select(steps, flow['before']); after = select(steps, flow['after'])
        need(steps[flow['before']['step']]['sequence'] < produced['sequence'] < consumed['sequence'] < steps[flow['after']['step']]['sequence'], 'authoritative snapshots do not bracket the public flow')
        observed_before(steps, flow['before']['step'], flow['producer'], baseline, 'pre-state was not observed before public production')
        observed_before(steps, flow['producer'], flow['consumer'], baseline, 'consumer was observed before producer completion')
        observed_before(steps, flow['consumer'], flow['after']['step'], baseline, 'post-state was observed before consumer completion')
        need(before is not MISSING and after is not MISSING and not equal(before, after), 'producer did not change authoritative state')
        need(contains(after, origin), 'produced object absent from authoritative state')
        if flow['transition'] == 'create':
            need(not contains(before, origin), 'fixture already contained produced object')
        else:
            need(contains(before, origin), 'update target absent before mutation')
        need(flow['input_links'], 'producer input propagation assertion required')
        for link in flow['input_links']:
            need(equal(select(steps, link['from']), select(steps, link['to'])), 'public input not propagated to consumer/state')
    if obligation.get('state'):
        state = obligation['state']; before = select(steps, state['before']); after = select(steps, state['after'])
        need(steps[state['before']['step']]['sequence'] < steps[consumer['step']]['sequence'] < steps[state['after']['step']]['sequence'], 'state snapshots do not bracket the public query')
        observed_before(steps, state['before']['step'], consumer['step'], baseline, 'query pre-state timing is invalid')
        observed_before(steps, consumer['step'], state['after']['step'], baseline, 'query post-state timing is invalid')
        need(before is not MISSING and after is not MISSING, 'state snapshots missing')
        need(equal(before, after) if state['relation'] == 'unchanged' else not equal(before, after), 'query/state side effect invariant failed')
    if obligation.get('provider'):
        spec = obligation['provider']; raw = steps[spec['step']]
        need(raw.get('kind') == 'provider_call' and raw.get('runtime_fingerprint') == baseline['bindings']['runtime']['fingerprint'], 'real provider call receipt missing/stale')
        need(raw.get('operation') == spec['operation'] and isinstance(raw.get('request'), dict) and raw['request'] and isinstance(raw.get('response'), dict) and raw['response'], 'provider request/response receipt incomplete')
        need(type(raw['response'].get('status')) is int and 200 <= raw['response']['status'] < 300, 'provider call did not succeed')
        need(raw['sequence'] < steps[consumer['step']]['sequence'], 'provider receipt occurs after its consumer')
        observed_before(steps, spec['step'], consumer['step'], baseline, 'provider actually completed after consumer observation')
        if obligation.get('flow'):
            producer_name = obligation['flow']['producer']
            need(steps[producer_name]['sequence'] <= raw['sequence'], 'provider receipt precedes its public stimulus')
            if baseline['evidence_class'] == 'product':
                need(observation_interval(steps[producer_name], baseline)[0] <= observation_interval(raw, baseline)[0], 'provider observation predates its public stimulus')
    if obligation.get('restart'):
        spec = obligation['restart']; raw = steps[spec['step']]
        need(raw.get('kind') == 'process_restart', 'restart receipt missing')
        need(raw['sequence'] < steps[consumer['step']]['sequence'], 'consumer was not read after restart')
        observed_before(steps, spec['step'], consumer['step'], baseline, 'consumer actually ran before restart completion')
        if spec.get('before_step'):
            need(spec['before_step'] in steps and steps[spec['before_step']]['sequence'] < raw['sequence'], 'pre-restart witness does not precede restart')
            observed_before(steps, spec['before_step'], spec['step'], baseline, 'pre-restart witness actually followed restart')
        before, after = raw.get('before', {}), raw.get('after', {})
        need(before.get('identity') and after.get('identity') and before['identity'] != after['identity'], 'process incarnation did not change')
        expected = baseline['bindings']['runtime']['fingerprint']
        need(before.get('runtime_fingerprint') == after.get('runtime_fingerprint') == expected, 'restart changed executable/configuration closure')
        if baseline['evidence_class'] == 'product':
            proof = baseline['bindings']['runtime']['proof']
            for incarnation in (before, after):
                need(incarnation.get('source_commit') == baseline['target']['source_commit'] and incarnation.get('binary_sha256') == proof['binary_sha256'] and incarnation.get('environment_sha256') == proof['environment_sha256'] and incarnation.get('config_fingerprint') == baseline['bindings']['config']['fingerprint'], 'restart source/config/artifact identity mismatch')
            observed = steps[consumer['step']]['target_binding']['before']
            for incarnation in (before, after):
                process = incarnation.get('process', {})
                need(type(process.get('pid')) is int and process['pid'] > 0 and str(process.get('start_ticks', '')).isdigit(), 'restart actual PID/start ticks missing')
            need(all(equal(after['process'].get(key, MISSING), observed.get(key, MISSING)) for key in ('pid', 'start_ticks')), 'post-restart consumer reached a different process incarnation')
            need((before['process']['pid'], before['process']['start_ticks']) != (after['process']['pid'], after['process']['start_ticks']), 'restart process incarnation did not change')
            need(spec.get('before_step'), 'product restart requires an actual pre-restart public witness')
            if spec.get('before_step'):
                prior = steps[spec['before_step']].get('target_binding', {}).get('before', {})
                need(all(equal(before.get('process', {}).get(key, MISSING), prior.get(key, MISSING)) for key in ('pid', 'start_ticks')), 'pre-restart consumer reached a different process incarnation')
    return {'obligation': obligation['id'], 'profile': profile['id'], 'status': 'PASS', 'assertions_replayed': True}


def qualify(repo, base, registry, plan, baseline, report, evidence_root):
    plan = verify_plan(repo, base, registry, plan)
    need(plan['impact']['mode'] == 'business', 'tooling-only uses self-test qualification, not product evidence')
    verify_baseline(repo, plan, baseline)
    document(report, 'completion_results')
    need(report.get('plan_digest') == plan['plan_digest'] and report.get('baseline_digest') == baseline['baseline_digest'], 'report plan/baseline stale')
    rows = report.get('results'); need(isinstance(rows, list), 'result rows required')
    index = {}
    for row in rows:
        key = (row.get('family'), row.get('obligation'), row.get('profile'))
        need(key not in index, 'duplicate result row'); index[key] = row
    required = {(row['family'], row['obligation'], row['profile']) for row in plan['required']}
    need(set(index) == required, 'required obligations/profiles missing or report outside scope')
    checked = []
    for family, item in plan['contracts'].items():
        contract = load(contained(repo, item['path'])); consumers, profiles, obligations = contract_value(contract, family)
        for key in sorted(required):
            if key[0] == family:
                checked.append({'family': family, **evaluate(obligations[key[1]], consumers, profiles[key[2]], index[key], evidence_root, baseline)})
    product = baseline['evidence_class'] == 'product'
    return {'schema_version': SCHEMA, 'kind': 'completion_qualification', 'plan_digest': plan['plan_digest'],
            'baseline_digest': baseline['baseline_digest'], 'repo': plan['impact']['repo'],
            'contracts': plan['contracts'], 'tool_fingerprint': baseline['bindings']['tools']['fingerprint'],
            'complete_scope': [{'family': family, 'contract_sha256': item['sha256'], 'contract_version': item['version'],
                                'obligations': [{'id': key[1], 'profile': key[2]} for key in sorted(required) if key[0] == family]}
                               for family, item in sorted(plan['contracts'].items())], 'verified': checked,
            'whole_family_complete': False,
            'coverage_boundary': 'Only the enumerated contract/version/obligation/profile denominator; family labels are editorial groups, not complete module or entry coverage.',
            'acceptance_complete': product, 'product_verified': product, 'tool_test_passed': not product,
            'global_complete': False, 'global_debt': plan['impact']['global_debt'],
            'review_boundary': 'Field/profile/source declaration completeness and collector authenticity require independent review; raw hashes are not cryptographic proof of external reality.'}


def tool_test(repo, plan):
    test = Path(repo) / 'scripts/verification/test_completion_guard.py'
    need(test.is_file(), 'guard self-tests missing')
    process = subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', str(test.parent), '-p', test.name], capture_output=True)
    output = process.stdout + process.stderr
    sys.stderr.write(output.decode(errors='replace'))
    need(process.returncode == 0, 'guard self-tests failed')
    count = re.search(rb'Ran ([1-9][0-9]*) tests?', output)
    need(count is not None, 'guard self-test runner executed no unittest cases')
    tools = {str(Path(__file__).resolve()): sha(__file__), str(test.resolve()): sha(test)}
    return {'schema_version': SCHEMA, 'kind': 'completion_qualification', 'mode': 'tooling_only',
            'plan_digest': plan['plan_digest'], 'repo': plan['impact']['repo'], 'contracts': {},
            'tool_fingerprint': digest(tools), 'tool_files': tools, 'tool_tests_count': int(count.group(1)),
            'tool_tests_sha256': hashlib.sha256(output).hexdigest(),
            'tool_test_passed': True, 'product_verified': False, 'acceptance_complete': False,
            'complete_scope': [{'tool': 'completion_guard', 'test_file': str(test), 'tests_count': int(count.group(1))}],
            'whole_family_complete': False, 'global_complete': False,
            'global_debt': plan['impact']['global_debt']}


def version_observation(connection, target):
    connection.request('GET', '/api/version', headers={'User-Agent': 'raft-completion-guard/1'})
    response = connection.getresponse(); body = response.read(1024 * 1024 + 1)
    need(response.status == 200 and len(body) <= 1024 * 1024, 'target source handshake failed')
    value = loads(body)
    need(isinstance(value, dict) and value.get('sha') == target['source_commit'], 'HTTP target source differs from built runtime')
    return {'status': response.status, 'origin': target['origin'], 'body_base64': base64.b64encode(body).decode(), 'body_sha256': hashlib.sha256(body).hexdigest()}


def capture(args):
    baseline = load(args.baseline); document(baseline, 'completion_baseline')
    payload = dict(baseline); claimed = payload.pop('baseline_digest', None)
    need(claimed == digest(payload), 'capture baseline digest mismatch')
    need(sha(__file__) in baseline['bindings']['tools']['files'].values(), 'capture collector changed since baseline')
    need(equal(baseline.get('observation_clock', MISSING), observation_clock()), 'capture host boot/clock changed since baseline')
    need(args.method in ('GET', 'HEAD', 'OPTIONS') or args.allow_write, 'network mutation requires explicit --allow-write')
    target = baseline['target']; requested_origin = canonical_origin(args.origin or target['origin'])
    need(requested_origin == target['origin'], 'capture origin differs from fixed target; wrong oracle/backend')
    parsed = urlsplit(requested_origin)
    need(args.path.startswith('/') and not args.path.startswith('//'), 'origin-relative API path required')
    body = Path(args.body).read_bytes() if args.body else b''
    headers = load(args.headers) if args.headers else {}
    if args.ca:
        ca = str(Path(args.ca).resolve(strict=True))
        need(ca in baseline['bindings']['config']['files'] and sha(ca) == baseline['bindings']['config']['files'][ca], 'TLS CA is not in fixed configuration closure')
    out = Path(args.out); need(not out.exists(), 'do not overwrite raw evidence')
    out.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    need(not out.parent.stat().st_mode & 0o077, 'raw evidence directory must be private0700')
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    connection = None
    try:
        product = baseline['evidence_class'] == 'product'
        proof = baseline['bindings']['runtime'].get('proof', {})
        binding = {'target_digest': digest(target)}
        if product:
            binding['before'] = listener_identity(target, proof)
        connection = (http.client.HTTPSConnection(parsed.hostname, parsed.port, timeout=15, context=ssl.create_default_context(cafile=args.ca))
                      if parsed.scheme == 'https' else http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=15))
        if product:
            binding['version_before'] = version_observation(connection, target)
        started = time.time_ns(); observed_start = observation_now()
        connection.request(args.method, args.path, body=body or None, headers=headers)
        response = connection.getresponse(); response_status = response.status; response_headers = response.getheaders()
        response_body = response.read(16 * 1024 * 1024 + 1); observed_end = observation_now(); completed = time.time_ns()
        need(len(response_body) <= 16 * 1024 * 1024, 'response evidence budget exceeded')
        if product:
            binding['version_after'] = version_observation(connection, target)
            binding['after'] = listener_identity(target, proof)
            need(equal(binding['before'], binding['after']), 'runtime incarnation changed during HTTP capture')
        raw = {'kind': 'public_http', 'baseline_digest': baseline['baseline_digest'], 'evidence_class': baseline['evidence_class'],
               'target_id': target['id'], 'origin': requested_origin, 'target_binding': binding,
               'run_id': args.run_id, 'sequence': args.sequence, 'method': args.method, 'path': args.path,
               'status': response_status, 'response_headers': response_headers,
               'request_body_base64': base64.b64encode(body).decode(), 'request_body_sha256': hashlib.sha256(body).hexdigest(),
               'response_body_base64': base64.b64encode(response_body).decode(), 'response_body_sha256': hashlib.sha256(response_body).hexdigest(),
               'collector_sha256': sha(__file__), 'request_started_at_ns': started, 'response_completed_at_ns': completed,
               'observation_clock': baseline['observation_clock'], 'observation_started_ns': observed_start, 'observation_completed_ns': observed_end,
               'captured_at_ns': time.time_ns()}
        verify_target_binding(raw, baseline)
        if product:
            observation_interval(raw, baseline)
        with os.fdopen(fd, 'w') as stream:
            fd = None
            json.dump(raw, stream, indent=2); stream.write('\n')
        return {'path': str(out), 'sha256': sha(out), 'status': response_status}
    finally:
        if fd is not None:
            os.close(fd)
        if connection is not None:
            connection.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('plan', 'check-impact', 'baseline', 'qualify'):
        item = sub.add_parser(name)
        item.add_argument('--repo', default='.')
        item.add_argument('--base', required=True)
        item.add_argument('--registry', required=True)
        item.add_argument('--out')
        if name != 'plan':
            item.add_argument('--plan', required=name in ('baseline', 'qualify'))
        if name == 'baseline':
            item.add_argument('--bindings', required=True)
        if name == 'qualify':
            item.add_argument('--baseline')
            item.add_argument('--report')
            item.add_argument('--evidence-root')
    item = sub.add_parser('capture-http')
    for name in ('baseline', 'path', 'run-id', 'out'):
        item.add_argument('--' + name, required=True)
    item.add_argument('--origin', help='Optional exact check against the fixed baseline origin; never chooses another target')
    item.add_argument('--method', choices=('GET', 'HEAD', 'OPTIONS', 'POST', 'PUT', 'PATCH', 'DELETE'), default='GET')
    item.add_argument('--sequence', required=True, type=int)
    item.add_argument('--headers'); item.add_argument('--body'); item.add_argument('--ca'); item.add_argument('--allow-write', action='store_true')
    args = parser.parse_args(argv)
    try:
        if args.command == 'capture-http':
            result = capture(args)
        elif args.command == 'plan':
            result = make_plan(args.repo, args.base, args.registry)
        else:
            plan = load(args.plan) if args.plan else None
            if args.command == 'check-impact':
                info, _, _ = impact(args.repo, args.base, args.registry)
                if info['mode'] == 'business':
                    need(plan is not None, 'business change requires a current scope plan before development/handoff')
                    verify_plan(args.repo, args.base, args.registry, plan)
                elif plan is not None:
                    verify_plan(args.repo, args.base, args.registry, plan)
                need(not info['needs_review'], 'unknown changed paths require review')
                result = info
            else:
                plan = verify_plan(args.repo, args.base, args.registry, plan)
                if args.command == 'baseline':
                    result = make_baseline(args.repo, plan, load(args.bindings))
                elif plan['impact']['mode'] == 'tooling_only':
                    result = tool_test(args.repo, plan)
                else:
                    need(args.baseline and args.report and args.evidence_root, 'business qualification requires baseline/report/raw evidence')
                    result = qualify(args.repo, args.base, args.registry, plan, load(args.baseline), load(args.report), Path(args.evidence_root))
        if args.out:
            write(args.out, result)
        print(json.dumps(result, sort_keys=True, ensure_ascii=False))
        return 0
    except (GuardError, OSError, KeyError, TypeError, IndexError) as error:
        print(json.dumps({'schema_version': SCHEMA, 'kind': 'completion_rejected', 'acceptance_complete': False,
                          'global_complete': False, 'error': str(error)}), file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
