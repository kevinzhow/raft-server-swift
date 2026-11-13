"""Adversarial tool tests only; these fixtures never verify a product."""
import base64
import copy
import hashlib
import http.server
import threading
import json
import os
import sys
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
from unittest import mock
import unittest

import completion_guard as g


class Fixture:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix='completion-guard-')
        self.root = Path(self.temp.name)
        self.repo = self.root / 'repo'; self.repo.mkdir()
        self.external = self.root / 'fixed'; self.external.mkdir()
        self.run = self.root / 'run'; self.run.mkdir()
        self.git('init', '-q'); self.git('config', 'user.email', 'test@example.invalid'); self.git('config', 'user.name', 'Tool Test')
        self.file('Sources/Activity.swift', 'old implementation\n')
        self.file('Tests/ActivityTests.swift', 'existing tests\n')
        self.file('Package.swift', 'fixed dependencies\n')
        self.file('docs/status.md', 'unknown historical debt\n')
        self.registry_path = self.repo / 'scripts/verification/families.json'
        self.contract_path = self.repo / 'scripts/verification/activity.json'
        self.fixed = {}
        for name in ('upstream.ts', 'consumer.ts', 'runtime.bin', 'client-entry.js', 'client-bundle.js', 'config.json'):
            path = self.external / name; path.write_text(name + '\n'); self.fixed[name] = path
        self.ref = {'root': 'upstream', 'path': 'upstream.ts', 'sha256': g.sha(self.fixed['upstream.ts'])}
        self.consumer_ref = {'root': 'consumer', 'path': 'consumer.ts', 'sha256': g.sha(self.fixed['consumer.ts'])}
        self.registry = {'schema_version': 1, 'families': [{'id': 'activity', 'paths': ['Sources/Activity.swift', 'Tests/ActivityTests.swift'], 'contract': 'scripts/verification/activity.json'}], 'shared_paths': ['Package.swift', 'Package.resolved'], 'global_debt': [{'unknown_modules': 406}]}
        self.contract = self.make_contract()
        g.write(self.registry_path, self.registry); g.write(self.contract_path, self.contract)
        self.git('add', '.'); self.git('commit', '-qm', 'fixed tool fixture')
        self.base = self.git('rev-parse', 'HEAD').strip()
        self.file('Sources/Activity.swift', 'new implementation\n')
        g.write(self.fixed['config.json'], {'durable': True, 'consume': False})
        self.bindings = {'roots': {'upstream': str(self.external), 'consumer': str(self.external)}, 'evidence_class': 'synthetic_tool_test',
                         'target': {'id': 'synthetic-swift', 'origin': 'http://127.0.0.1:9'},
                         'runtime': {'files': [str(self.fixed['runtime.bin'])]},
                         'client': {'files': [str(self.fixed['client-entry.js']), str(self.fixed['client-bundle.js'])]},
                         'config': {'files': [str(self.fixed['config.json'])], 'values_file': str(self.fixed['config.json'])}}
        self.refresh()
        self.report = self.make_report()

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.repo, stderr=subprocess.DEVNULL, text=True)

    def file(self, name, value):
        path = self.repo / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(value)
        return path

    @staticmethod
    def at(step, pointer):
        return {'step': step, 'pointer': pointer}

    def make_contract(self):
        at = self.at
        fields = [{'pointer': '/id', 'type': 'string'}, {'pointer': '/kind', 'type': 'string', 'expected': 'message'},
                  {'pointer': '/channelName', 'type': 'string'}, {'pointer': '/line', 'type': 'integer', 'expected': 3},
                  {'pointer': '/offset', 'type': 'float', 'expected': 1.0}]
        produce = {'id': 'produce-read', 'kind': 'producer_consumer', 'profiles': ['real'],
                   'steps': {'before': {'kind': 'state_snapshot'}, 'write': {'method': 'POST', 'path': '/api/messages', 'status': 200},
                             'read': {'method': 'GET', 'path': '/api/inbox?consume=false', 'status': 200}, 'after': {'kind': 'state_snapshot'}},
                   'assertions': [{'op': 'equals', 'at': at('read', '/response_json/items/0/kind'), 'value': 'message'}],
                   'consumer': {'id': 'web', 'step': 'read', 'pointer': '/response_json/items/0'},
                   'response_fields': [field['pointer'] for field in fields],
                   'flow': {'producer': 'write', 'consumer': 'read', 'transition': 'create',
                            'object_from': at('write', '/response_json/id'), 'object_to': at('read', '/response_json/items/0/id'),
                            'before': at('before', '/data'), 'after': at('after', '/data'),
                            'input_links': [{'from': at('write', '/request_json/channelName'), 'to': at('read', '/response_json/items/0/channelName')}]}}
        query = {'id': 'query-stable', 'kind': 'query', 'profiles': ['real'],
                 'steps': {'before': {'kind': 'state_snapshot'}, 'read': {'method': 'GET', 'path': '/api/inbox?consume=false', 'status': 200}, 'after': {'kind': 'state_snapshot'}},
                 'assertions': [{'op': 'equals', 'at': at('read', '/response_json/items/0/kind'), 'value': 'message'}],
                 'consumer': {'id': 'web', 'step': 'read', 'pointer': '/response_json/items/0'},
                 'response_fields': [field['pointer'] for field in fields],
                 'state': {'relation': 'unchanged', 'before': at('before', '/data'), 'after': at('after', '/data')}}
        required = lambda *ids: {'applicability': 'required', 'obligations': list(ids)}
        na = lambda reason: {'applicability': 'not_applicable', 'reason': reason, 'preconditions': ['Synthetic boundary fixture only; not product authorization/lifecycle evidence'], 'source_refs': [self.ref]}
        return {'schema_version': 1, 'family': 'activity', 'version': 'fixture-1', 'review_state': 'REVIEWED', 'source_refs': [self.ref],
                'production': {'mode': 'producer', 'trigger': 'ordinary public message POST', 'authority': 'durable inbox facts'},
                'consumers': [{'id': 'web', 'refs': [self.consumer_ref], 'required_fields': fields}],
                'profiles': [{'id': 'real', 'required': True, 'configuration': {'durable': True, 'consume': False}}],
                'obligations': [produce, query],
                'dimensions': {'producer': required('produce-read'), 'consumer': required('produce-read', 'query-stable'),
                               'query_state': required('query-stable'), 'authorization': na('Fixture does not make an authorization claim'),
                               'configuration': {**required('produce-read', 'query-stable'), 'profiles': ['real']},
                               'restart': na('Fixture tests assertion machinery rather than product persistence')}}

    def refresh(self):
        g.write(self.contract_path, self.contract)
        self.plan = g.make_plan(self.repo, self.base, self.registry_path)
        self.baseline = g.make_baseline(self.repo, self.plan, self.bindings)

    def save_raw(self, name, value):
        value = {**value, 'baseline_digest': self.baseline['baseline_digest'], 'evidence_class': 'synthetic_tool_test', 'run_id': 'tool-fixture', 'collector_sha256': g.sha(g.__file__), 'target_id': self.baseline['target']['id']}
        if value.get('kind') == 'public_http':
            value.update(origin=self.baseline['target']['origin'], target_binding={'target_digest': g.digest(self.baseline['target'])})
        path = self.run / (name + '.json'); g.write(path, value)
        return {'path': path.name, 'sha256': g.sha(path)}

    def http(self, method, path, response, sequence, request=None):
        def body(value):
            return b'' if value is None else g.canonical(value).encode()
        req, res = body(request), body(response)
        return {'kind': 'public_http', 'method': method, 'path': path, 'status': 200, 'sequence': sequence,
                'request_body_base64': base64.b64encode(req).decode(), 'request_body_sha256': hashlib.sha256(req).hexdigest(),
                'response_body_base64': base64.b64encode(res).decode(), 'response_body_sha256': hashlib.sha256(res).hexdigest()}

    def make_report(self):
        item = {'id': 'new-message-1', 'kind': 'message', 'channelName': 'public-input', 'line': 3, 'offset': 1.0}
        self.item = item
        raws = {'before': {'kind': 'state_snapshot', 'sequence': 0, 'data': {'items': []}},
                'write': self.http('POST', '/api/messages', {'id': item['id']}, 1, {'channelName': item['channelName']}),
                'read': self.http('GET', '/api/inbox?consume=false', {'items': [item]}, 2),
                'after': {'kind': 'state_snapshot', 'sequence': 3, 'data': {'items': [item]}}}
        query = {'before': {'kind': 'state_snapshot', 'sequence': 4, 'data': {'revision': 1, 'items': [item]}},
                 'read': self.http('GET', '/api/inbox?consume=false', {'items': [item]}, 5),
                 'after': {'kind': 'state_snapshot', 'sequence': 6, 'data': {'revision': 1, 'items': [item]}}}
        rows = []
        for identity, values in [('produce-read', raws), ('query-stable', query)]:
            steps = {key: self.save_raw(identity + '-' + key, value) for key, value in values.items()}
            rows.append({'family': 'activity', 'obligation': identity, 'profile': 'real', 'status': 'PASS', 'baseline_digest': self.baseline['baseline_digest'],
                         'configuration': self.contract['profiles'][0]['configuration'], 'steps': steps})
        return {'schema_version': 1, 'kind': 'completion_results', 'plan_digest': self.plan['plan_digest'], 'baseline_digest': self.baseline['baseline_digest'], 'results': rows}

    def raw(self, obligation, step):
        row = next(row for row in self.report['results'] if row['obligation'] == obligation)
        ref = row['steps'][step]; return row, ref, g.load(self.run / ref['path'])

    def alter(self, obligation, step, transform):
        row, ref, raw = self.raw(obligation, step); transform(raw)
        path = self.run / ref['path']; g.write(path, raw); ref['sha256'] = g.sha(path)

    def response(self, transform):
        def change(raw):
            payload = g.loads(base64.b64decode(raw['response_body_base64'])); transform(payload)
            body = g.canonical(payload).encode(); raw['response_body_base64'] = base64.b64encode(body).decode(); raw['response_body_sha256'] = hashlib.sha256(body).hexdigest()
        self.alter('produce-read', 'read', change)

    def qualify(self):
        return g.qualify(self.repo, self.base, self.registry_path, self.plan, self.baseline, self.report, self.run)


class CompletionGuardTests(unittest.TestCase):
    def setUp(self):
        self.f = Fixture(); self.addCleanup(self.f.temp.cleanup)

    def rejected(self, action=None, text=None):
        with self.assertRaises(g.GuardError) as context:
            (action or self.f.qualify)()
        if text:
            self.assertIn(text, str(context.exception))

    def timed_producer(self):
        baseline = copy.deepcopy(self.f.baseline); baseline['evidence_class'] = 'product'
        row = self.f.report['results'][0]; steps = {}
        for index, (name, ref) in enumerate(row['steps'].items()):
            raw = g.raw_evidence(self.f.run, ref, self.f.baseline)
            start = 10 + index * 20; end = start + 10
            raw.update(observation_clock=baseline['observation_clock'], observation_started_ns=start, observation_completed_ns=end)
            if raw['kind'] == 'public_http':
                raw.update(request_started_at_ns=1000000 + start, response_completed_at_ns=1000000 + end, captured_at_ns=1000001 + end)
            steps[name] = raw
        return baseline, steps

    def evaluate_timed(self, baseline, steps):
        row = self.f.report['results'][0]
        indexed = {ref['path']: steps[name] for name, ref in row['steps'].items()}
        with mock.patch('completion_guard.raw_evidence', side_effect=lambda root, ref, base: indexed[ref['path']]):
            return g.evaluate(self.f.contract['obligations'][0], {'web': self.f.contract['consumers'][0]}, self.f.contract['profiles'][0], row, self.f.run, baseline)

    def test_synthetic_positive_never_product_verified(self):
        result = self.f.qualify()
        self.assertTrue(result['tool_test_passed']); self.assertFalse(result['product_verified'])
        self.assertFalse(result['acceptance_complete']); self.assertFalse(result['global_complete'])
        self.assertEqual(result['complete_scope'][0]['family'], 'activity')
        self.assertEqual(len(result['complete_scope'][0]['obligations']), 2)
        self.assertFalse(result['whole_family_complete'])

    def test_locked_without_evidence(self):
        self.f.report['results'][0]['status'] = 'locked'; self.f.report['results'][0]['steps'] = {}
        self.rejected()

    def test_pass_without_evidence(self):
        self.f.report['results'][0]['steps'] = {}; self.rejected()

    def test_seed_helper_is_not_public_producer(self):
        self.f.alter('produce-read', 'write', lambda row: row.update(kind='seed_helper')); self.rejected()

    def test_fixture_precontains_target(self):
        self.f.alter('produce-read', 'before', lambda row: row['data']['items'].append(self.f.item)); self.rejected()

    def test_ordinary_write_then_empty_consumer(self):
        self.f.response(lambda row: row.update(items=[])); self.rejected()

    def test_consumer_channel_name_missing(self):
        self.f.response(lambda row: row['items'][0].pop('channelName')); self.rejected(text='consumer required field')

    def test_consumer_channel_name_wrong_type(self):
        self.f.response(lambda row: row['items'][0].update(channelName=True)); self.rejected(text='consumer required field')

    def test_consumer_input_not_propagated(self):
        self.f.response(lambda row: row['items'][0].update(channelName='seed-only-value')); self.rejected(text='public input')

    def test_producer_consumer_different_id(self):
        self.f.response(lambda row: row['items'][0].update(id='old-seeded-object')); self.rejected(text='object reference')

    def test_fake_put_success_without_authoritative_change(self):
        self.f.contract['obligations'][0]['steps']['write']['method'] = 'PUT'
        g.write(self.f.contract_path, self.f.contract); self.f.git('add', 'scripts/verification/activity.json'); self.f.git('commit', '-qm', 'fixed PUT fixture contract')
        self.f.base = self.f.git('rev-parse', 'HEAD').strip(); self.f.refresh(); self.f.report = self.f.make_report()
        self.f.alter('produce-read', 'write', lambda row: row.update(method='PUT'))
        self.f.alter('produce-read', 'after', lambda row: row.update(data={'items': []})); self.rejected(text='authoritative state')

    def test_get_consume_false_changes_state(self):
        self.f.alter('query-stable', 'after', lambda row: row['data'].update(revision=2)); self.rejected(text='side effect')

    def test_bool_not_integer(self):
        self.f.response(lambda row: row['items'][0].update(line=True)); self.rejected()

    def test_float_not_integer(self):
        self.f.response(lambda row: row['items'][0].update(line=3.0)); self.rejected()

    def test_integer_not_float(self):
        self.f.response(lambda row: row['items'][0].update(offset=1)); self.rejected()

    def test_missing_not_null(self):
        self.f.response(lambda row: row['items'][0].update(channelName=None)); self.rejected()

    def test_line_offset_business_fields_not_stripped(self):
        self.f.response(lambda row: row['items'][0].update(line=4, offset=2.0)); self.rejected()

    def test_unknown_source_impact_fails_closed(self):
        self.f.file('Sources/Unknown.swift', 'untracked product implementation'); self.rejected(lambda: g.verify_plan(self.f.repo, self.f.base, self.f.registry_path, g.make_plan(self.f.repo, self.f.base, self.f.registry_path)))

    def test_untracked_mapped_source_included(self):
        self.f.registry['families'][0]['paths'].append('Sources/New.swift'); g.write(self.f.registry_path, self.f.registry)
        self.f.file('Sources/New.swift', 'new')
        info, _, _ = g.impact(self.f.repo, self.f.base, self.f.registry_path)
        self.assertIn('Sources/New.swift', [row['path'] for row in info['changed']]); self.assertEqual(info['affected_families'], ['activity'])

    def test_dirty_test_weakening_is_business(self):
        self.f.file('Tests/ActivityTests.swift', 'weakened tests')
        info, _, _ = g.impact(self.f.repo, self.f.base, self.f.registry_path)
        self.assertEqual(info['mode'], 'business'); self.assertIn('Tests/ActivityTests.swift', [row['path'] for row in info['changed']])

    def test_shared_package_impacts_registered_family(self):
        self.f.file('Package.swift', 'changed dependency')
        info, _, _ = g.impact(self.f.repo, self.f.base, self.f.registry_path)
        self.assertEqual(info['affected_families'], ['activity'])

    def test_delete_source_not_omitted(self):
        p = self.f.repo / 'Sources/Activity.swift'; p.unlink()
        info, _, _ = g.impact(self.f.repo, self.f.base, self.f.registry_path)
        self.assertEqual(info['changed'][0]['status'], 'D'); self.assertEqual(info['affected_families'], ['activity'])

    def test_rename_checks_old_and_new_paths(self):
        self.f.git('checkout', '--', 'Sources/Activity.swift'); self.f.git('mv', 'Sources/Activity.swift', 'Sources/Moved.swift')
        info, _, _ = g.impact(self.f.repo, self.f.base, self.f.registry_path)
        self.assertEqual(info['affected_families'], ['activity']); self.assertEqual(info['changed'][0]['old_path'], 'Sources/Activity.swift')

    def test_no_base_rejected(self):
        self.rejected(lambda: g.snapshot(self.f.repo, None)); self.rejected(lambda: g.snapshot(self.f.repo, 'nonexistent'))

    def test_old_plan_after_dirty_source_rejected(self):
        self.f.file('Sources/Activity.swift', 'another edit'); self.rejected(text='plan is stale')

    def test_old_report_cross_family_rejected(self):
        self.f.report['results'][0]['family'] = 'attachments'; self.rejected(text='outside scope')

    def test_missing_profile_not_run_rejected(self):
        self.f.report['results'].pop(); self.rejected(text='profiles missing')

    def test_not_run_not_completion(self):
        self.f.report['results'][0]['status'] = 'NOT_RUN'; self.rejected()

    def test_approved_deviation_not_pass(self):
        self.f.report['results'][0]['disposition'] = 'approved_deviation'; self.rejected()

    def test_raw_hash_tamper_rejected(self):
        _, ref, _ = self.f.raw('produce-read', 'read'); path = self.f.run / ref['path']; path.write_text('{}'); self.rejected(text='tampered')

    def test_pass_row_tamper_does_not_hide_raw_failure(self):
        self.f.response(lambda row: row.update(items=[])); self.f.report['results'][0].update(status='PASS', connected=True); self.rejected()

    def test_stale_baseline_digest_rejected(self):
        self.f.baseline['baseline_digest'] = '0' * 64; self.rejected(text='baseline digest')

    def test_stale_client_implementation_bundle_rejected(self):
        self.f.fixed['client-bundle.js'].write_text('implementation changed'); self.rejected(text='fingerprint')

    def test_stale_runtime_rejected(self):
        self.f.fixed['runtime.bin'].write_text('new binary'); self.rejected(text='fingerprint')

    def test_stale_config_rejected(self):
        g.write(self.f.fixed['config.json'], {'durable': False, 'consume': False}); self.rejected(text='fingerprint')

    def test_stale_source_consumer_ref_rejected(self):
        self.f.fixed['consumer.ts'].write_text('new consumer field'); self.rejected(text='reference changed')

    def test_old_report_cannot_relabel_only_baseline(self):
        self.f.fixed['client-bundle.js'].write_text('changed implementation'); self.f.baseline = g.make_baseline(self.f.repo, self.f.plan, self.f.bindings)
        self.f.report['baseline_digest'] = self.f.baseline['baseline_digest']
        for row in self.f.report['results']:row['baseline_digest'] = self.f.baseline['baseline_digest']
        self.rejected(text='another baseline')

    def test_handwritten_parsed_json_does_not_override_raw(self):
        self.f.alter('produce-read', 'read', lambda row: row.update(response_json={'items': [self.f.item, self.f.item]})); self.rejected(text='parsed body')

    def test_unknown_collector_rejected(self):
        self.f.alter('produce-read', 'read', lambda row: row.update(collector_sha256='0' * 64)); self.rejected(text='collector')

    def test_obvious_consumer_field_omission_contract_rejected(self):
        self.f.contract['consumers'][0]['required_fields'] = self.f.contract['consumers'][0]['required_fields'][:2]
        self.rejected(lambda: self.f.refresh(), text='omitted')

    def test_presence_only_contract_rejected(self):
        self.f.contract['obligations'][0]['assertions'] = [{'op': 'exists', 'at': self.f.at('read', '/response_json/items/0')}]
        self.rejected(lambda: self.f.refresh(), text='presence/type-only')

    def test_missing_dimension_rejected(self):
        self.f.contract['dimensions'].pop('restart'); self.rejected(lambda: self.f.refresh(), text='dimensions')

    def test_unknown_dimension_not_na(self):
        self.f.contract['dimensions']['restart']['applicability'] = 'unknown'; self.rejected(lambda: self.f.refresh())

    def test_na_requires_source_and_preconditions(self):
        self.f.contract['dimensions']['restart'].pop('source_refs'); self.rejected(lambda: self.f.refresh())

    def test_auth_dimension_cannot_omit_negative_control(self):
        self.f.contract['dimensions']['authorization'] = {'applicability': 'required', 'obligations': ['produce-read'], 'positive': [{'obligation': 'produce-read', 'step': 'write'}]}
        self.rejected(lambda: self.f.refresh(), text='positive and negative')

    def test_baseline_contract_weakening_detected(self):
        self.f.contract['consumers'][0]['required_fields'] = [field for field in self.f.contract['consumers'][0]['required_fields'] if field['pointer'] != '/channelName']
        for obligation in self.f.contract['obligations']:
            obligation['response_fields'].remove('/channelName')
        self.f.refresh(); self.assertTrue(self.f.plan['impact']['policy_weakening']); self.rejected(text='unknown affected paths')

    def test_old_registry_mapping_cannot_be_removed(self):
        self.f.registry['families'] = []; g.write(self.f.registry_path, self.f.registry)
        self.rejected(lambda: g.make_plan(self.f.repo, self.f.base, self.f.registry_path), text='removed')

    def test_tool_only_not_blocked_by_406_global_debt(self):
        self.f.git('checkout', '--', 'Sources/Activity.swift'); self.f.file('docs/status.md', 'tooling status update')
        info, _, _ = g.impact(self.f.repo, self.f.base, self.f.registry_path)
        self.assertEqual(info['mode'], 'tooling_only'); self.assertFalse(info['needs_review']); self.assertEqual(info['global_debt'][0]['unknown_modules'], 406)

    def test_provider_connected_flag_is_not_call_receipt(self):
        ob = self.f.contract['obligations'][0]; ob['provider'] = {'step': 'provider', 'operation': 'write-object'}; ob['steps']['provider'] = {'kind': 'provider_call'}
        self.f.refresh(); self.f.report = self.f.make_report(); row = self.f.report['results'][0]
        row['steps']['provider'] = self.f.save_raw('provider', {'kind': 'provider_call', 'sequence': 2, 'connected': True})
        self.rejected(text='provider call')

    def test_restart_same_incarnation_rejected(self):
        ob = self.f.contract['obligations'][0]; ob['restart'] = {'step': 'restart'}; ob['steps']['restart'] = {'kind': 'process_restart'}
        self.f.refresh(); self.f.report = self.f.make_report()
        runtime = self.f.baseline['bindings']['runtime']['fingerprint']
        self.f.report['results'][0]['steps']['restart'] = self.f.save_raw('restart', {'kind': 'process_restart', 'sequence': 1, 'before': {'identity': 'pid-1-start-1', 'runtime_fingerprint': runtime}, 'after': {'identity': 'pid-1-start-1', 'runtime_fingerprint': runtime}})
        self.rejected(text='incarnation')

    def test_restart_missing_not_completion(self):
        ob = self.f.contract['obligations'][0]; ob['restart'] = {'step': 'restart'}; ob['steps']['restart'] = {'kind': 'process_restart'}
        self.f.refresh(); self.f.report = self.f.make_report(); self.rejected(text='steps missing')

    def product_runtime_inputs(self, source_commit):
        executable = Path(sys.executable).resolve()
        build_path = self.f.external / 'build-receipt.json'; process_path = self.f.external / 'process-receipt.json'; manifest_path = self.f.external / 'runtime-manifest.json'
        binary_hash = g.sha(executable)
        build = {'schema_version': 1, 'kind': 'runtime_build', 'source_commit': source_commit, 'source_tree': self.f.git('rev-parse', source_commit + '^{tree}').strip(), 'binary': str(executable), 'binary_sha256': binary_hash}
        manifest = {'source_commit': source_commit, 'binary_sha256': binary_hash}; g.write(manifest_path, manifest)
        process = {'schema_version': 1, 'kind': 'process_identity', 'locator': {'kind': 'pid', 'pid': os.getpid()}, 'binary_sha256': binary_hash, 'environment_sha256': g.sha(Path('/proc') / str(os.getpid()) / 'environ'), 'manifest': {'path': str(manifest_path), 'sha256': g.sha(manifest_path)}}
        g.write(build_path, build); g.write(process_path, process)
        self.f.bindings['runtime'] = {'files': [str(executable), str(build_path), str(process_path)], 'build_receipt': str(build_path), 'process_receipt': str(process_path)}
        self.f.bindings['config']['files'].append(str(manifest_path)); self.f.bindings['evidence_class'] = 'product'
        return build_path, process_path

    def test_product_stale_source_build_rejected(self):
        self.product_runtime_inputs(self.f.base)
        self.rejected(lambda: self.f.refresh(), text='different source/dependency')

    def test_product_bound_binary_receipt_must_match(self):
        self.f.git('add', 'Sources/Activity.swift'); self.f.git('commit', '-qm', 'fixture source revision')
        head = self.f.git('rev-parse', 'HEAD').strip(); build_path, _ = self.product_runtime_inputs(head)
        value = g.load(build_path); value['binary_sha256'] = '0' * 64; g.write(build_path, value)
        self.rejected(lambda: self.f.refresh(), text='actual bound binary')

    def test_product_actual_process_must_match_receipt(self):
        self.f.git('add', 'Sources/Activity.swift'); self.f.git('commit', '-qm', 'fixture source revision')
        head = self.f.git('rev-parse', 'HEAD').strip(); _, process_path = self.product_runtime_inputs(head)
        value = g.load(process_path); value['binary_sha256'] = '0' * 64; g.write(process_path, value)
        self.rejected(lambda: self.f.refresh(), text='actual process executable')

    def test_product_actual_environment_must_match_receipt(self):
        self.f.git('add', 'Sources/Activity.swift'); self.f.git('commit', '-qm', 'fixture source revision')
        head = self.f.git('rev-parse', 'HEAD').strip(); _, process_path = self.product_runtime_inputs(head)
        value = g.load(process_path); value['environment_sha256'] = '0' * 64; g.write(process_path, value)
        self.rejected(lambda: self.f.refresh(), text='effective environment')

    def test_product_requires_build_receipt_not_just_elf_hash(self):
        self.f.bindings['runtime'] = {'files': [str(Path(sys.executable).resolve())]}; self.f.bindings['evidence_class'] = 'product'
        self.rejected(lambda: self.f.refresh(), text='build_receipt')

    def test_client_symlink_resolution_change_invalidates_baseline(self):
        link = self.f.external / 'entry-link.js'; link.symlink_to(self.f.fixed['client-entry.js'])
        alternate = self.f.external / 'same-bytes-different-target.js'; alternate.write_bytes(self.f.fixed['client-entry.js'].read_bytes())
        self.f.bindings['client']['files'].append(str(link)); self.f.refresh(); self.f.report = self.f.make_report()
        self.assertEqual(link.parent.resolve(), self.f.external.resolve()); self.assertTrue(link.is_symlink())
        link.unlink(); link.symlink_to(alternate)
        self.rejected(text='fingerprint')

    def test_object_from_cannot_point_to_consumer_itself(self):
        self.f.contract['obligations'][0]['flow']['object_from'] = self.f.at('read', '/response_json/items/0/id')
        self.rejected(lambda: self.f.refresh(), text='producer output')

    def test_input_link_cannot_compare_consumer_to_itself(self):
        self.f.contract['obligations'][0]['flow']['input_links'][0]['from'] = self.f.at('read', '/response_json/items/0/channelName')
        self.rejected(lambda: self.f.refresh(), text='public producer request')

    def test_consume_false_cannot_drop_query_invariant_with_na(self):
        self.f.contract['obligations'].pop(); self.f.contract['dimensions']['query_state'] = copy.deepcopy(self.f.contract['dimensions']['restart'])
        for dimension in self.f.contract['dimensions'].values():
            if 'obligations' in dimension:dimension['obligations'] = ['produce-read']
        self.rejected(lambda: self.f.refresh(), text='consume=false')

    def test_tooling_selftest_must_execute_cases(self):
        self.f.file('scripts/verification/test_completion_guard.py', '# accidentally empty test discovery\n')
        self.rejected(lambda: g.tool_test(self.f.repo, self.f.plan))

    def test_policy_only_obligation_removal_is_review_not_tool_pass(self):
        self.f.git('checkout', '--', 'Sources/Activity.swift')
        self.f.contract['obligations'].pop()
        g.write(self.f.contract_path, self.f.contract)
        plan = g.make_plan(self.f.repo, self.f.base, self.f.registry_path)
        self.assertEqual(plan['impact']['mode'], 'tooling_only')
        self.assertTrue(plan['impact']['needs_review'])
        self.rejected(lambda: g.verify_plan(self.f.repo, self.f.base, self.f.registry_path, plan))

    def test_policy_only_family_removal_needs_review(self):
        self.f.git('checkout', '--', 'Sources/Activity.swift')
        self.f.registry['families'] = []; g.write(self.f.registry_path, self.f.registry)
        info, _, _ = g.impact(self.f.repo, self.f.base, self.f.registry_path)
        self.assertTrue(info['needs_review']); self.assertIn('removed-family:activity', info['unknown_paths'])

    def test_policy_only_mapping_narrowing_needs_review(self):
        self.f.git('checkout', '--', 'Sources/Activity.swift')
        self.f.registry['families'][0]['paths'].pop(); g.write(self.f.registry_path, self.f.registry)
        info, _, _ = g.impact(self.f.repo, self.f.base, self.f.registry_path)
        self.assertTrue(info['needs_review']); self.assertIn('activity', info['policy_weakening'])

    def test_policy_only_shared_path_removal_needs_review(self):
        self.f.git('checkout', '--', 'Sources/Activity.swift')
        self.f.registry['shared_paths'] = []; g.write(self.f.registry_path, self.f.registry)
        info, _, _ = g.impact(self.f.repo, self.f.base, self.f.registry_path)
        self.assertTrue(info['needs_review']); self.assertIn('registry', info['policy_weakening'])

    def test_contract_draft_cannot_qualify_business(self):
        self.f.contract['review_state'] = 'DRAFT_NOT_QUALIFIABLE'; self.rejected(lambda: self.f.refresh(), text='DRAFT')

    def test_fixture_cannot_be_relabelled_as_product(self):
        self.f.bindings['evidence_class'] = 'product'
        self.rejected(lambda: self.f.refresh(), text='actual executable ELF')

    def test_unconfigured_profile_rejects_handwritten_configuration(self):
        g.write(self.f.fixed['config.json'], {'durable': False, 'consume': False})
        self.f.refresh(); self.f.report = self.f.make_report(); self.rejected(text='not configured')

    def test_configuration_boolean_not_integer(self):
        self.f.report['results'][0]['configuration'] = {'durable': 1, 'consume': False}; self.rejected(text='configuration missing')

    def test_guard_additional_collector_tool_change_invalidates_baseline(self):
        collector = self.f.external / 'independent-collector.py'; collector.write_text('old collector')
        self.f.bindings['tools'] = {'files': [str(collector)]}; self.f.refresh(); self.f.report = self.f.make_report()
        collector.write_text('changed collector'); self.rejected(text='fingerprint')

    def test_state_capture_must_bracket_public_producer(self):
        self.f.alter('produce-read', 'before', lambda row: row.update(sequence=10)); self.rejected(text='bracket')

    def test_query_capture_must_bracket_get(self):
        self.f.alter('query-stable', 'after', lambda row: row.update(sequence=0)); self.rejected(text='bracket')

    def test_state_relation_unknown_rejected(self):
        self.f.contract['obligations'][1]['state']['relation'] = 'whatever'; self.rejected(lambda: self.f.refresh())

    def test_nonfinite_float_overflow_rejected(self):
        self.rejected(lambda: g.loads('{"x":1e999}'))

    def test_state_snapshot_cannot_masquerade_as_auth_refusal(self):
        self.f.contract['obligations'][1]['steps']['before']['status'] = 403
        self.f.contract['dimensions']['authorization'] = {'applicability': 'required', 'obligations': ['query-stable'], 'positive': [{'obligation': 'query-stable', 'step': 'read'}], 'negative': [{'obligation': 'query-stable', 'step': 'before'}]}
        self.rejected(lambda: self.f.refresh(), text='actual public HTTP')

    def test_actual_get_before_write_cannot_be_relabelled_with_sequence(self):
        baseline, steps = self.timed_producer()
        steps['write'].update(observation_started_ns=55, observation_completed_ns=60)
        self.rejected(lambda: self.evaluate_timed(baseline, steps), text='sequence contradicts actual')

    def test_get_started_before_put_completed_is_not_closed_producer_flow(self):
        baseline, steps = self.timed_producer()
        steps['write']['observation_completed_ns'] = 65
        self.rejected(lambda: self.evaluate_timed(baseline, steps), text='before producer completion')

    def test_product_state_receipt_without_observation_interval_rejected(self):
        baseline, steps = self.timed_producer(); steps['before'].pop('observation_started_ns')
        self.rejected(lambda: g.validate_observations(steps, baseline), text='interval missing')

    def test_product_receipts_cannot_mix_boot_clocks(self):
        baseline, steps = self.timed_producer(); steps['before']['observation_clock'] = {'clock': 'CLOCK_BOOTTIME_NS', 'boot_id': 'other-host-or-boot'}
        self.rejected(lambda: g.validate_observations(steps, baseline), text='boot is missing or differs')

    def test_http_saved_wall_time_cannot_contradict_sequence(self):
        baseline, steps = self.timed_producer()
        steps['write'].update(request_started_at_ns=2000000, response_completed_at_ns=2000010, captured_at_ns=2000011)
        self.rejected(lambda: g.validate_observations(steps, baseline), text='recorded HTTP wall time')

    def test_http_saved_wall_interval_must_be_consistent(self):
        baseline, steps = self.timed_producer(); steps['read']['response_completed_at_ns'] = 1
        self.rejected(lambda: g.validate_observations(steps, baseline), text='wall observation timestamps')

    def test_restart_observed_after_consumer_rejected_despite_label(self):
        baseline, steps = self.timed_producer()
        event = {'kind': 'process_restart', 'sequence': 1, 'observation_clock': baseline['observation_clock'], 'observation_started_ns': 90, 'observation_completed_ns': 100}
        steps['restart'] = event
        self.rejected(lambda: g.observed_before(steps, 'restart', 'read', baseline, 'restart completed after consumer'), text='after consumer')

    def test_provider_can_nest_inside_write_but_finish_before_consumer(self):
        baseline, steps = self.timed_producer()
        steps['write']['observation_completed_ns'] = 48
        steps['provider'] = {'kind': 'provider_call', 'sequence': 2, 'observation_clock': baseline['observation_clock'], 'observation_started_ns': 35, 'observation_completed_ns': 40}
        # Pure time-adapter positive control; no qualification or product PASS.
        g.observed_before(steps, 'provider', 'read', baseline, 'provider too late')
        self.assertGreaterEqual(steps['provider']['observation_started_ns'], steps['write']['observation_started_ns'])
        self.assertLess(steps['provider']['observation_completed_ns'], steps['write']['observation_completed_ns'])

    def test_provider_completed_after_consumer_rejected_despite_label(self):
        baseline, steps = self.timed_producer()
        steps['provider'] = {'kind': 'provider_call', 'sequence': 1, 'observation_clock': baseline['observation_clock'], 'observation_started_ns': 35, 'observation_completed_ns': 65}
        self.rejected(lambda: g.observed_before(steps, 'provider', 'read', baseline, 'provider completed after consumer'), text='after consumer')

    def test_optional_profile_cannot_hide_required_producer(self):
        self.f.contract['profiles'].append({'id': 'producer-optional', 'required': False, 'configuration': {'durable': True}})
        self.f.contract['obligations'][0]['profiles'] = ['producer-optional']
        self.rejected(lambda: self.f.refresh(), text='optional profile')

    def test_optional_profile_cannot_hide_authorization_witnesses(self):
        self.f.contract['profiles'].append({'id': 'auth-optional', 'required': False, 'configuration': {'durable': True}})
        for identity, status in [('auth-positive', 200), ('auth-negative', 403)]:
            item = copy.deepcopy(self.f.contract['obligations'][1]); item.update(id=identity, kind='protocol', profiles=['auth-optional'])
            item['steps']['read']['status'] = status; self.f.contract['obligations'].append(item)
        self.f.contract['dimensions']['authorization'] = {'applicability': 'required', 'obligations': ['produce-read', 'auth-positive', 'auth-negative'], 'positive': [{'obligation': 'auth-positive', 'step': 'read'}], 'negative': [{'obligation': 'auth-negative', 'step': 'read'}]}
        self.rejected(lambda: self.f.refresh(), text='optional profile')

    def test_missing_explicit_review_state_is_not_reviewed(self):
        self.f.contract.pop('review_state'); self.rejected(lambda: self.f.refresh(), text='review_state')

    def test_wrong_oracle_origin_rejected_before_network(self):
        path = self.f.external / 'baseline.json'; g.write(path, self.f.baseline)
        args = SimpleNamespace(baseline=str(path), origin='http://127.0.0.1:9999', method='GET', allow_write=False)
        with mock.patch('completion_guard.http.client.HTTPConnection') as connection:
            self.rejected(lambda: g.capture(args), text='wrong oracle')
            connection.assert_not_called()

    def test_raw_wrong_origin_cannot_be_rehashed_into_pass(self):
        self.f.alter('produce-read', 'read', lambda row: row.update(origin='http://127.0.0.1:9999')); self.rejected(text='another origin')

    def test_raw_wrong_target_id_rejected(self):
        self.f.alter('produce-read', 'read', lambda row: row.update(target_id='upstream-node')); self.rejected(text='target identity')

    def test_raw_target_binding_cannot_be_omitted(self):
        self.f.alter('produce-read', 'read', lambda row: row.pop('target_binding')); self.rejected(text='binding missing')

    def test_version_handshake_wrong_source_rejected(self):
        response = mock.Mock(status=200); response.read.return_value = b'{"sha":"official-node-source"}'
        connection = mock.Mock(); connection.getresponse.return_value = response
        self.rejected(lambda: g.version_observation(connection, self.f.baseline['target']), text='source differs')

    def test_honest_collector_wrong_backend_handshake_blocks_business_write(self):
        requests = []
        class OracleLikeHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(('GET', self.path)); body = b'{"sha":"official-node-source"}'
                self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
            def do_POST(self):
                requests.append(('POST', self.path)); self.send_response(200); self.send_header('Content-Length', '2'); self.end_headers(); self.wfile.write(b'{}')
            def log_message(self, *args):
                pass
        server = http.server.HTTPServer(('127.0.0.1', 0), OracleLikeHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            baseline = copy.deepcopy(self.f.baseline); baseline['evidence_class'] = 'product'
            baseline['target']['origin'] = 'http://127.0.0.1:' + str(server.server_port)
            baseline['bindings']['runtime']['proof'] = {'locator': {'kind': 'pid', 'pid': os.getpid()}, 'binary_sha256': g.sha(Path('/proc/self/exe')), 'environment_sha256': g.sha(Path('/proc/self/environ'))}
            baseline.pop('baseline_digest'); baseline['baseline_digest'] = g.digest(baseline)
            path = self.f.external / 'collector-negative-baseline.json'; g.write(path, baseline)
            args = SimpleNamespace(baseline=str(path), origin=None, method='POST', allow_write=True, path='/api/messages', body=None, headers=None, ca=None, out=str(self.f.root / 'capture' / 'wrong-backend.json'), run_id='tool-negative', sequence=1)
            self.rejected(lambda: g.capture(args), text='source differs')
            self.assertEqual(requests, [('GET', '/api/version')])
        finally:
            server.shutdown(); thread.join(timeout=5); server.server_close()

    def test_direct_listener_is_actually_owned_by_pid(self):
        listener = g.socket.socket(); self.addCleanup(listener.close); listener.bind(('127.0.0.1', 0)); listener.listen(1)
        target = {'origin': 'http://127.0.0.1:' + str(listener.getsockname()[1])}
        proof = {'locator': {'kind': 'pid', 'pid': os.getpid()}, 'binary_sha256': g.sha(Path('/proc/self/exe')), 'environment_sha256': g.sha(Path('/proc/self/environ'))}
        observed = g.listener_identity(target, proof)
        self.assertEqual(observed['pid'], os.getpid()); self.assertTrue(observed['listener_inodes'])

    def test_listener_of_another_process_is_not_target_runtime(self):
        script = 'import socket,sys; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(1); print(s.getsockname()[1],flush=True); sys.stdin.read()'
        child = subprocess.Popen([sys.executable, '-c', script], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            port = int(child.stdout.readline().strip())
            target = {'origin': 'http://127.0.0.1:' + str(port)}
            proof = {'locator': {'kind': 'pid', 'pid': os.getpid()}, 'binary_sha256': g.sha(Path('/proc/self/exe')), 'environment_sha256': g.sha(Path('/proc/self/environ'))}
            self.rejected(lambda: g.listener_identity(target, proof), text='not exclusively owned')
        finally:
            child.terminate(); child.wait(timeout=5); child.stdin.close(); child.stdout.close()

    def test_restart_attached_after_all_reads_is_not_restart_coverage(self):
        ob = self.f.contract['obligations'][0]; ob['restart'] = {'step': 'restart'}; ob['steps']['restart'] = {'kind': 'process_restart'}
        self.f.refresh(); self.f.report = self.f.make_report(); runtime = self.f.baseline['bindings']['runtime']['fingerprint']
        self.f.report['results'][0]['steps']['restart'] = self.f.save_raw('restart-after-read', {'kind': 'process_restart', 'sequence': 20, 'before': {'identity': 'old', 'runtime_fingerprint': runtime}, 'after': {'identity': 'new', 'runtime_fingerprint': runtime}})
        self.rejected(text='not read after restart')

    def test_provider_receipt_after_consumer_is_not_flow_coverage(self):
        ob = self.f.contract['obligations'][0]; ob['provider'] = {'step': 'provider', 'operation': 'write-object'}; ob['steps']['provider'] = {'kind': 'provider_call'}
        self.f.refresh(); self.f.report = self.f.make_report(); runtime = self.f.baseline['bindings']['runtime']['fingerprint']
        self.f.report['results'][0]['steps']['provider'] = self.f.save_raw('late-provider', {'kind': 'provider_call', 'sequence': 20, 'runtime_fingerprint': runtime, 'operation': 'write-object', 'request': {'key': 'new-message-1'}, 'response': {'status': 200}})
        self.rejected(text='after its consumer')

    def test_duplicate_json_and_nonfinite_rejected(self):
        self.rejected(lambda: g.loads('{"id":1,"id":2}')); self.rejected(lambda: g.loads('{"x":NaN}'))

    def test_path_escape_rejected(self):
        self.f.report['results'][0]['steps']['read']['path'] = '../outside.json'; self.rejected(text='unsafe relative')


if __name__ == '__main__':
    unittest.main()
