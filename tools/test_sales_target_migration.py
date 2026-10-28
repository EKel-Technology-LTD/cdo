"""Offline pure-function tests. Never invoke the action runner, sf, or an org."""
import ast
import datetime as dt
import json
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'force-app/scripts/post/common/sales-target-preflight.sh'
body = SOURCE.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
parsed = ast.parse(body)
# Load only declarations needed by pure tests, not the action's execution block.
names = {'GateError', 'require', 'sfid', 'canonical', 'audit_keys', 'period',
         'previous_quarter', 'parse_expiry', 'check_window', 'formula_matches'}
nodes = [n for n in parsed.body if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name in names]
nodes += [n for n in parsed.body if isinstance(n, ast.Assign) and
          any(isinstance(t, ast.Name) and t.id in {'STAGE_ONE_PROTECTION', 'PROTECTION_MESSAGE'} for t in n.targets)]
ns = {'dt': dt, 're': re}
exec(compile(ast.Module(body=nodes, type_ignores=[]), str(SOURCE), 'exec'), ns)


def row(**changes):
    result = dict(Id='synthetic-target-1', Sales_Rep__c='005000000000001AAA',
                  Fiscal_Year__c=2026, Fiscal_Quarter__c='Q4', Product_Line__c=None,
                  Target_Key__c=None, Period_Start__c='2026-10-01', Period_End__c='2026-12-31')
    result.update(changes)
    return result


class MigrationGuards(unittest.TestCase):
    def test_source_compiles_without_executing_action(self):
        compile(body, str(SOURCE), 'exec')

    def test_no_pre_registration(self):
        manifest = json.loads((ROOT / 'force-app/scripts/pre/common/orchard-run.json').read_text())
        self.assertFalse(any(a['id'] == 'sales-target-preflight' for a in manifest['actions']))

    def test_exact_protection_matches_stage_one_source(self):
        xml = ET.parse(ROOT / 'force-app/main/default/objects/Sales_Target__c/validationRules/System_Fields_Protected.validationRule-meta.xml')
        formula = xml.findtext('{http://soap.sforce.com/2006/04/metadata}errorConditionFormula')
        self.assertTrue(ns['formula_matches'](formula, ns['STAGE_ONE_PROTECTION']))
        for field in ('Actual_Amount__c', 'Won_Opportunity_Count__c', 'Last_Calculated_At__c', 'Target_Key__c'):
            with self.subTest(field=field):
                self.assertFalse(ns['formula_matches'](formula.replace(field, 'Notes__c'), ns['STAGE_ONE_PROTECTION']))

    def test_missing_and_bypassed_protection_rejected(self):
        with self.assertRaises(ns['GateError']):
            ns['formula_matches'](None, ns['STAGE_ONE_PROTECTION'])
        self.assertFalse(ns['formula_matches']('FALSE', ns['STAGE_ONE_PROTECTION']))
        self.assertFalse(ns['formula_matches']('OR(TRUE,' + ns['STAGE_ONE_PROTECTION'] + ')', ns['STAGE_ONE_PROTECTION']))

    def test_explicit_utc_expiry(self):
        for value in ('2026-10-28T22:00:00Z', '2026-10-28T22:00:00+00:00', '2026-10-28T22:00:00.123Z'):
            self.assertEqual(dt.timedelta(0), ns['parse_expiry'](value).utcoffset())

    def test_missing_local_or_non_timestamp_expiry_rejected(self):
        for value in (None, '', True, '2026-10-28', '2026-10-28T22:00:00', '2026-10-28T22:00:00-07:00'):
            with self.subTest(value=value), self.assertRaises(ns['GateError']):
                ns['parse_expiry'](value)

    def test_expired_window_rejected(self):
        ns['CONTEXT'] = {'expiresAt': dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=1)}
        with self.assertRaises(ns['GateError']):
            ns['check_window']()

    def test_canonical_all_and_specific(self):
        self.assertEqual('005000000000001AAA-2026-Q4-ALL', ns['canonical'](row()))
        self.assertEqual('005000000000001AAA-2026-Q4-Water_Purifier', ns['canonical'](row(Product_Line__c='Water_Purifier')))

    def test_invalid_dimensions_rejected(self):
        for change in ({'Sales_Rep__c': '005000000000001'}, {'Fiscal_Year__c': True}, {'Fiscal_Quarter__c': 'Q5'}):
            with self.subTest(change=change), self.assertRaises(ns['GateError']):
                ns['canonical'](row(**change))

    def test_duplicate_dimensions_rejected(self):
        with self.assertRaises(ns['GateError']):
            ns['audit_keys']([row(), row(Id='synthetic-target-2')])

    def test_canonical_readback_and_legacy_mismatch(self):
        self.assertEqual([], ns['audit_keys']([row(Target_Key__c=ns['canonical'](row()))]))
        self.assertEqual(1, len(ns['audit_keys']([row()])))

    def test_quarter_rollover_and_date_contract(self):
        self.assertEqual(dt.date(2025, 10, 1), ns['previous_quarter'](dt.date(2026, 1, 1)))
        self.assertEqual((dt.date(2026, 10, 1), dt.date(2026, 12, 31)), ns['period'](row()))
        with self.assertRaises(ns['GateError']):
            ns['period'](row(Period_End__c='2026-12-30'))

    def test_backfill_has_transaction_expiry_guard(self):
        self.assertIn("System.assert(Datetime.now().getTime() < EXPIRY_MS, 'Release authorization expired before backfill DML');\nDatabase.update", body)
        self.assertIn(".replace('EXPIRY_MS',", body)

if __name__ == '__main__':
    unittest.main(verbosity=2)
