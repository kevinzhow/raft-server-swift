#!/usr/bin/env python3
"""Historical dispositions must not qualify live features or omit new modules."""
import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('ledger_under_test', Path(__file__).with_name('parity.py'))
ledger = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ledger)


class HistoricalLedgerTests(unittest.TestCase):
    def run_report(self, modules, rows, check=True):
        areas = {'route': [(name, 2, Path(name + '.test.ts')) for name in modules], 'socket': [], 'daemon': []}
        output = io.StringIO()
        with patch.object(ledger, 'commit_exists', return_value=True), contextlib.redirect_stdout(output):
            result = ledger.report(areas, rows, check)
        return result, output.getvalue()

    def row(self, module='known', area='route'):
        return {'module': module, 'area': area, 'status': 'locked', 'commit': '1234567', 'notes': 'reviewed exclusions', 'tests': []}

    def test_new_upstream_module_without_disposition_blocks_check(self):
        code, output = self.run_report(['known', 'new-feature'], [self.row()])
        self.assertEqual(code, 1)
        self.assertIn('no ledger disposition', output)

    def test_locked_without_test_mapping_never_claims_runtime_coverage(self):
        code, output = self.run_report(['known'], [self.row()])
        self.assertEqual(code, 0)
        self.assertIn('runtime acceptance: NOT_ESTABLISHED', output)
        self.assertIn('not executed cases', output)
        self.assertNotIn('100.0%', output)
        self.assertNotIn('route coverage', output)
        self.assertIn('0/1 modules', output)

    def test_wrong_area_cannot_silently_disappear_from_ledger_totals(self):
        code, output = self.run_report(['known'], [self.row(area='daemon')])
        self.assertEqual(code, 1)
        self.assertIn('area does not match', output)

    def test_report_mode_shows_debt_without_claiming_qualification(self):
        code, output = self.run_report(['new-feature'], [], check=False)
        self.assertEqual(code, 0)
        self.assertIn('no ledger disposition', output)
        self.assertIn('NOT_ESTABLISHED', output)


if __name__ == '__main__':
    unittest.main()
