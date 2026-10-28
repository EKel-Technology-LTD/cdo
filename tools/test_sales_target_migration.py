"""Offline pure-function tests. Never invoke the action runner, sf, or an org."""
import ast
import datetime as dt
import json
import os
import stat
import io
from types import SimpleNamespace
from unittest.mock import patch
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
         'previous_quarter', 'parse_expiry', 'check_window', 'formula_matches',
         'verify_sales_rep_metadata', 'unique_json_object', 'validate_authorization',
         'verify_authorized_org', 'verify_machine_actor', 'load_release_inputs'}
nodes = [n for n in parsed.body if isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name in names]
nodes += [n for n in parsed.body if isinstance(n, ast.Assign) and
          any(isinstance(t, ast.Name) and t.id in {'STAGE_ONE_PROTECTION', 'PROTECTION_MESSAGE'} for t in n.targets)]
ns = {'dt': dt, 're': re, 'json': json, 'os': os, 'stat': stat}
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

    def test_declared_runner_inputs_are_first_gate(self):
        execution = next(n for n in parsed.body if isinstance(n, ast.Try))
        self.assertEqual('load_release_inputs', execution.body[0].value.func.id)
        self.assertNotIn('migration is disabled', body)

    def test_only_declared_environment_inputs(self):
        env_calls = [n for n in ast.walk(parsed) if isinstance(n, ast.Call) and
                     isinstance(n.func, ast.Attribute) and isinstance(n.func.value, ast.Attribute)
                     and isinstance(n.func.value.value, ast.Name) and n.func.value.value.id == 'os'
                     and n.func.value.attr == 'environ']
        self.assertEqual({'SALES_TARGET_RELEASE_CONTEXT', 'SALES_TARGET_MACHINE_ORG'},
                         {ast.literal_eval(n.args[0]) for n in env_calls})
        self.assertNotIn('force://', body)
        self.assertNotIn('org login', body)

    def test_formal_post_declaration(self):
        manifest = json.loads((SOURCE.parent / 'orchard-run.json').read_text())
        self.assertEqual({'version', 'actions'}, set(manifest))
        self.assertEqual(1, manifest['version'])
        action = next(a for a in manifest['actions'] if a['id'] == 'sales-target-preflight')
        self.assertEqual({'id', 'type', 'file', 'timeoutMinutes', 'scopeMode', 'deploymentEffect', 'metadataBoundary', 'releaseInputs'}, set(action))
        self.assertEqual('bash', action['type'])
        self.assertEqual(SOURCE.name, action['file'])
        self.assertEqual(10, action['timeoutMinutes'])
        self.assertEqual('selected_delivery', action['scopeMode'])
        self.assertEqual('data', action['deploymentEffect'])
        self.assertEqual(dict(authorizationToken='SALES_TARGET_AUTHORIZATION',
                              machineAuthToken='SALES_TARGET_MACHINE_AUTH',
                              contextFileEnv='SALES_TARGET_RELEASE_CONTEXT',
                              machineOrgEnv='SALES_TARGET_MACHINE_ORG'), action['releaseInputs'])
        boundary = action['metadataBoundary']
        self.assertEqual({'after', 'before'}, set(boundary))
        self.assertFalse(set(boundary['after']) & set(boundary['before']))
        for paths in boundary.values():
            self.assertTrue(1 <= len(paths) <= 200)
            self.assertEqual(len(paths), len(set(paths)))
            for path in paths:
                self.assertLessEqual(len(path), 240)
                self.assertNotIn('\\', path)
                self.assertFalse(any(p in ('', '.', '..') for p in path.split('/')))
                self.assertTrue((ROOT / path).is_file(), path)
                self.assertTrue(path.startswith('force-app/main/default/'))
        self.assertTrue(any('Sales_Rep__c.field-meta.xml' in p for p in boundary['after']))
        self.assertTrue(any('Active_Sales_Rep_On_Assignment' in p for p in boundary['after']))
        self.assertEqual(['force-app/main/default/objects/Sales_Target__c/validationRules/System_Fields_Protected.validationRule-meta.xml',
                          'force-app/main/default/flows/Sales_Target_Set_Unique_Key.flow-meta.xml'], boundary['before'])
        self.assertFalse(any('Sales_Rep_Required.' in p for p in boundary['after']))
        # This is source-path validation, NOT proof of planner metadataPaths selection.

    def sales_rep_metadata(self):
        # Synthetic fixture for guard logic, NOT an org read or delivery evidence.
        return dict(type='Lookup', referenceTo='User', label='Sales Rep',
                    relationshipName='Sales_Quarterly_Targets',
                    relationshipLabel='Sales Quarterly Targets', required=False,
                    deleteConstraint='SetNull')

    def test_explicit_setnull_and_nondeletable_user_accepted(self):
        ns['verify_sales_rep_metadata'](self.sales_rep_metadata(), dict(name='User', deletable=False))

    def test_omitted_deletion_constraint_is_not_evidence(self):
        metadata = self.sales_rep_metadata()
        del metadata['deleteConstraint']
        with self.assertRaisesRegex(ns['GateError'], 'deletion constraint differs or is unverified'):
            ns['verify_sales_rep_metadata'](metadata, dict(name='User', deletable=False))

    def test_clear_or_cascade_deletion_rejected(self):
        for constraint in ('Restrict', 'Cascade', None, ''):
            metadata = self.sales_rep_metadata()
            metadata['deleteConstraint'] = constraint
            with self.subTest(constraint=constraint), self.assertRaises(ns['GateError']):
                ns['verify_sales_rep_metadata'](metadata, dict(name='User', deletable=False))

    def test_preservation_contract_changes_rejected(self):
        for field in self.sales_rep_metadata():
            metadata = self.sales_rep_metadata()
            del metadata[field]
            with self.subTest(field=field), self.assertRaises(ns['GateError']):
                ns['verify_sales_rep_metadata'](metadata, dict(name='User', deletable=False))

    def test_required_false_is_not_coerced_or_rewritten(self):
        for required in (True, 'false', 0, None):
            metadata = self.sales_rep_metadata()
            metadata['required'] = required
            with self.subTest(required=required), self.assertRaises(ns['GateError']):
                ns['verify_sales_rep_metadata'](metadata, dict(name='User', deletable=False))

    def test_active_lookup_filter_blocks_migration(self):
        metadata = self.sales_rep_metadata()
        metadata['lookupFilter'] = {'active': True}
        with self.assertRaises(ns['GateError']):
            ns['verify_sales_rep_metadata'](metadata, dict(name='User', deletable=False))

    def test_required_rule_source_preserved(self):
        path = ROOT / 'force-app/main/default/objects/Sales_Target__c/validationRules/Sales_Rep_Required.validationRule-meta.xml'
        rule = ET.parse(path)
        prefix = '{http://soap.sforce.com/2006/04/metadata}'
        self.assertEqual('true', rule.findtext(prefix + 'active'))
        self.assertEqual('ISBLANK(Sales_Rep__c)', rule.findtext(prefix + 'errorConditionFormula'))
        self.assertEqual('Sales_Rep__c', rule.findtext(prefix + 'errorDisplayField'))
        self.assertEqual('Sales Rep is required.', rule.findtext(prefix + 'errorMessage'))

    def test_stage_one_gate_is_not_replaced_with_stage_two(self):
        xml = ET.parse(ROOT / 'force-app/main/default/objects/Sales_Target__c/validationRules/System_Fields_Protected.validationRule-meta.xml')
        formula = xml.findtext('{http://soap.sforce.com/2006/04/metadata}errorConditionFormula')
        self.assertFalse(ns['formula_matches'](formula, ns['STAGE_ONE_PROTECTION']))
        expected = 'AND(NOT($Permission.Sales_Target_System_Write),OR(AND(ISNEW(),OR(NOT(ISBLANK(Actual_Amount__c)),NOT(ISBLANK(Won_Opportunity_Count__c)),NOT(ISBLANK(Last_Calculated_At__c)),NOT(ISBLANK(Target_Key__c)))),AND(NOT(ISNEW()),OR(ISCHANGED(Actual_Amount__c),ISCHANGED(Won_Opportunity_Count__c),ISCHANGED(Last_Calculated_At__c),ISCHANGED(Target_Key__c)))))'
        self.assertTrue(ns['formula_matches'](expected, ns['STAGE_ONE_PROTECTION']))
        for field in ('Actual_Amount__c', 'Won_Opportunity_Count__c', 'Last_Calculated_At__c', 'Target_Key__c'):
            with self.subTest(field=field):
                self.assertFalse(ns['formula_matches'](expected.replace(field, 'Notes__c'), ns['STAGE_ONE_PROTECTION']))

    def test_missing_and_bypassed_protection_rejected(self):
        with self.assertRaises(ns['GateError']):
            ns['formula_matches'](None, ns['STAGE_ONE_PROTECTION'])
        self.assertFalse(ns['formula_matches']('FALSE', ns['STAGE_ONE_PROTECTION']))
        self.assertFalse(ns['formula_matches']('OR(TRUE,' + ns['STAGE_ONE_PROTECTION'] + ')', ns['STAGE_ONE_PROTECTION']))

    def test_explicit_utc_expiry(self):
        for value in ('2026-10-28T22:00:00Z', '2026-10-28T22:00:00.123Z'):
            self.assertEqual(dt.timedelta(0), ns['parse_expiry'](value).utcoffset())

    def test_missing_local_or_non_timestamp_expiry_rejected(self):
        for value in (None, '', True, '2026-10-28', '2026-10-28T22:00:00', '2026-10-28T22:00:00-07:00', '2026-10-28T22:00:00+00:00'):
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

class ExactFormulaGuards(unittest.TestCase):
    def test_formatting_between_tokens_is_accepted(self):
        self.assertTrue(ns['formula_matches'](' AND ( TRUE , FALSE ) \n', 'AND(TRUE,FALSE)'))

    def test_identifier_split_is_not_normalized(self):
        self.assertFalse(ns['formula_matches']('ISBLANK(Sales_ Rep__c)', 'ISBLANK(Sales_Rep__c)'))

    def test_function_split_is_not_normalized(self):
        self.assertFalse(ns['formula_matches']('IS BLANK(Sales_Rep__c)', 'ISBLANK(Sales_Rep__c)'))

    def test_double_quoted_literal_whitespace_is_significant(self):
        self.assertFalse(ns['formula_matches']('Name="A B"', 'Name="AB"'))

    def test_single_quoted_literal_whitespace_is_significant(self):
        self.assertFalse(ns['formula_matches']("Name='A B'", "Name='AB'"))

    def test_multi_character_operator_is_not_repaired(self):
        self.assertFalse(ns['formula_matches']('A < = B', 'A <= B'))

    def test_unknown_syntax_fails_closed(self):
        with self.assertRaises(ns['GateError']):
            ns['formula_matches']('ISBLANK(A) /*comment*/ @', 'ISBLANK(A)')

    def test_unterminated_string_fails_closed(self):
        with self.assertRaises(ns['GateError']):
            ns['formula_matches']('Name="A', 'Name="A"')

    def test_user_deletion_evidence_required(self):
        metadata = MigrationGuards().sales_rep_metadata()
        for evidence in (None, {}, {'name': 'Account', 'deletable': False},
                         {'name': 'User'}, {'name': 'User', 'deletable': True},
                         {'name': 'User', 'deletable': 0}, {'name': 'User', 'deletable': 'false'}):
            with self.subTest(evidence=evidence), self.assertRaises(ns['GateError']):
                ns['verify_sales_rep_metadata'](metadata, evidence)


class AuthorizationGuards(unittest.TestCase):
    # These are deliberately synthetic inputs, not identities or approvals for an org.
    NOW = dt.datetime(2026, 10, 28, 20, 0, tzinfo=dt.timezone.utc)

    def authorization(self, **changes):
        result = dict(orgId='00D000000000001EAA', machineUserId='005000000000001AAA',
                      operationsOwnerId='005000000000002AAA', artifactSha='a' * 40,
                      targetFingerprint='b' * 64, approvalReference='synthetic-test-only',
                      syntheticOnly=True, writesQuiesced=True, expiresAt='2026-10-28T22:00:00Z')
        result.update(changes)
        return result

    def validate(self, value):
        return ns['validate_authorization'](value, self.NOW)

    def test_exact_authorization_accepted_without_mutating_input(self):
        original = self.authorization()
        validated = self.validate(original)
        self.assertEqual(dt.datetime(2026, 10, 28, 22, tzinfo=dt.timezone.utc), validated['expiresAt'])
        self.assertEqual('2026-10-28T22:00:00Z', original['expiresAt'])
        self.assertEqual('a' * 40, validated['artifactSha'])
        self.assertEqual('b' * 64, validated['targetFingerprint'])

    def test_missing_authorization_fields_rejected(self):
        for field in self.authorization():
            candidate = self.authorization()
            del candidate[field]
            with self.subTest(field=field), self.assertRaises(ns['GateError']):
                self.validate(candidate)

    def test_extra_and_wrapped_authorization_rejected(self):
        for candidate in (self.authorization(extra='x'), {'authorization': self.authorization()},
                          {'context': self.authorization()}, None, []):
            with self.subTest(candidate=candidate), self.assertRaises(ns['GateError']):
                self.validate(candidate)

    def test_duplicate_json_keys_rejected(self):
        with self.assertRaises(ns['GateError']):
            json.loads('{"orgId":"first","orgId":"second"}', object_pairs_hook=ns['unique_json_object'])

    def test_checksum_prefix_and_length_not_repaired(self):
        for field in ('orgId', 'machineUserId', 'operationsOwnerId'):
            for value in (None, '', '005000000000001', '005000000000001aaa',
                          '00D000000000001AAA', '001000000000001AAA'):
                with self.subTest(field=field, value=value), self.assertRaises(ns['GateError']):
                    self.validate(self.authorization(**{field: value}))

    def test_source_revision_shape_exact(self):
        for value in (None, '', 'A'*40, 'a'*39, 'a'*41, 'g'*40, 'a'*40+'\n'):
            with self.subTest(value=value), self.assertRaises(ns['GateError']):
                self.validate(self.authorization(artifactSha=value))

    def test_target_fingerprint_shape_exact(self):
        for value in (None, '', 'B'*64, 'b'*63, 'b'*65, 'g'*64, 'b'*64+'\n'):
            with self.subTest(value=value), self.assertRaises(ns['GateError']):
                self.validate(self.authorization(targetFingerprint=value))

    def test_synthetic_authorization_is_not_truthy_coercion(self):
        for value in (None, False, 1, 'true', 'false', ''):
            with self.subTest(value=value), self.assertRaises(ns['GateError']):
                self.validate(self.authorization(syntheticOnly=value))

    def test_quiescence_requires_explicit_true(self):
        for value in (None, False, 1, 'true', 'false', ''):
            with self.subTest(value=value), self.assertRaises(ns['GateError']):
                self.validate(self.authorization(writesQuiesced=value))

    def test_human_reference_required_and_bounded(self):
        for value in (None, '', '  ', 1, 'x'*501):
            with self.subTest(value=value), self.assertRaises(ns['GateError']):
                self.validate(self.authorization(approvalReference=value))
        self.assertEqual('x'*500, self.validate(self.authorization(approvalReference='x'*500))['approvalReference'])

    def test_expired_and_exact_expiry_rejected(self):
        for value in ('2026-10-28T19:59:59Z', '2026-10-28T20:00:00Z'):
            with self.subTest(value=value), self.assertRaises(ns['GateError']):
                self.validate(self.authorization(expiresAt=value))

    def test_invalid_calendar_expiry_rejected(self):
        with self.assertRaises(ValueError):
            self.validate(self.authorization(expiresAt='2026-02-30T20:00:00Z'))

    def test_target_mismatch_rejected(self):
        with self.assertRaises(ns['GateError']):
            ns['verify_authorized_org'](self.authorization(), dict(Id='00D000000000002EAA', IsSandbox=True))

    def test_production_or_omitted_sandbox_evidence_rejected(self):
        for value in (False, None, 1, 'true'):
            with self.subTest(value=value), self.assertRaises(ns['GateError']):
                ns['verify_authorized_org'](self.authorization(), dict(Id=self.authorization()['orgId'], IsSandbox=value))

    def test_exact_sandbox_identity_accepted(self):
        ns['verify_authorized_org'](self.authorization(), dict(Id=self.authorization()['orgId'], IsSandbox=True))

    def actor(self, **changes):
        result = dict(Id=self.authorization()['machineUserId'], IsActive=True, TimeZoneSidKey='America/Los_Angeles')
        result.update(changes)
        return result

    def owner(self, **changes):
        result = dict(Id=self.authorization()['operationsOwnerId'], IsActive=True)
        result.update(changes)
        return result

    def test_exact_machine_and_owner_accepted(self):
        ns['verify_machine_actor'](self.authorization(), self.actor(), self.owner(), True)

    def test_machine_identity_mismatch_rejected(self):
        with self.assertRaises(ns['GateError']):
            ns['verify_machine_actor'](self.authorization(), self.actor(Id='005000000000003AAA'), self.owner(), True)

    def test_inactive_or_wrong_timezone_machine_rejected(self):
        for change in ({'IsActive': False}, {'IsActive': 'true'}, {'TimeZoneSidKey': 'GMT'}, {'TimeZoneSidKey': None}):
            with self.subTest(change=change), self.assertRaises(ns['GateError']):
                ns['verify_machine_actor'](self.authorization(), self.actor(**change), self.owner(), True)

    def test_owner_mismatch_or_inactive_rejected(self):
        for change in ({'Id': '005000000000003AAA'}, {'IsActive': False}, {'IsActive': 1}):
            with self.subTest(change=change), self.assertRaises(ns['GateError']):
                ns['verify_machine_actor'](self.authorization(), self.actor(), self.owner(**change), True)

    def test_human_machine_access_rejected(self):
        for value in (False, None, 1, 'true'):
            with self.subTest(value=value), self.assertRaises(ns['GateError']):
                ns['verify_machine_actor'](self.authorization(), self.actor(), self.owner(), value)

    def test_no_source_target_self_comparison_as_proof(self):
        validator = next(n for n in parsed.body if isinstance(n, ast.FunctionDef) and n.name == 'validate_authorization')
        self.assertNotIn('environ', ast.unparse(validator))
        self.assertIn('Exact source/target equality is enforced by prepareReleaseInputs', body)
        # Source/target pin equality is the platform contract. These tests prove
        # shape validation only, not execution of that external platform code.

class ReleaseInputAdapter(unittest.TestCase):
    # Exercise only the extracted file adapter with mocked file descriptors; never
    # execute Bash, the main block, subprocess, sf, auth, DML or action runner.
    def raw(self):
        value = AuthorizationGuards().authorization()
        value['expiresAt'] = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ')
        return value

    def load(self, text=None, mode=stat.S_IFREG | 0o600, uid=None):
        text = json.dumps(self.raw()) if text is None else text
        stream = io.StringIO(text)
        stream.fileno = lambda: 42
        env = {'SALES_TARGET_RELEASE_CONTEXT': '/synthetic/authorization.json',
               'SALES_TARGET_MACHINE_ORG': 'machine.synthetic@example.invalid'}
        with patch.dict(os.environ, env, clear=True), patch.object(os, 'open', return_value=42) as opened, \
             patch.object(os, 'fdopen', return_value=stream), \
             patch.object(os, 'fstat', return_value=SimpleNamespace(st_mode=mode, st_uid=os.geteuid() if uid is None else uid)):
            value = ns['load_release_inputs']()
            opened.assert_called_once_with(env['SALES_TARGET_RELEASE_CONTEXT'], os.O_RDONLY | os.O_NOFOLLOW)
            return value

    def test_raw_nine_field_file_and_machine_username(self):
        context, machine = self.load()
        self.assertEqual('machine.synthetic@example.invalid', machine)
        self.assertEqual('005000000000001AAA', context['machineUserId'])

    def test_missing_inputs_rejected_before_open(self):
        for env in ({}, {'SALES_TARGET_MACHINE_ORG': 'x@example.invalid'},
                    {'SALES_TARGET_RELEASE_CONTEXT': '/synthetic/authorization.json'}):
            with self.subTest(env=env), patch.dict(os.environ, env, clear=True), patch.object(os, 'open') as opened:
                with self.assertRaises(ns['GateError']):
                    ns['load_release_inputs']()
                opened.assert_not_called()

    def test_relative_context_file_rejected(self):
        with patch.dict(os.environ, {'SALES_TARGET_RELEASE_CONTEXT': 'relative.json', 'SALES_TARGET_MACHINE_ORG': 'x@example.invalid'}, clear=True), patch.object(os, 'open') as opened:
            with self.assertRaises(ns['GateError']):
                ns['load_release_inputs']()
            opened.assert_not_called()

    def test_invalid_machine_selector_rejected(self):
        for machine in ('', ' ', '--target-org', ' x@example.invalid', 'x\ny@example.invalid'):
            with self.subTest(machine=machine), patch.dict(os.environ, {'SALES_TARGET_RELEASE_CONTEXT': '/synthetic/authorization.json', 'SALES_TARGET_MACHINE_ORG': machine}, clear=True), patch.object(os, 'open') as opened:
                with self.assertRaises(ns['GateError']):
                    ns['load_release_inputs']()
                opened.assert_not_called()

    def test_insecure_file_mode_rejected(self):
        for mode in (stat.S_IFREG | 0o644, stat.S_IFREG | 0o660, stat.S_IFREG | 0o700, stat.S_IFDIR | 0o600):
            with self.subTest(mode=mode), self.assertRaises(ns['GateError']):
                self.load(mode=mode)

    def test_wrong_file_owner_rejected(self):
        with self.assertRaises(ns['GateError']):
            self.load(uid=os.geteuid()+1)

    def test_wrapped_context_file_rejected(self):
        with self.assertRaises(ns['GateError']):
            self.load(json.dumps({'authorization': self.raw()}))

    def test_duplicate_file_key_rejected(self):
        with self.assertRaises(ns['GateError']):
            self.load('{"orgId":"first","orgId":"second"}')

    def test_oversize_file_rejected(self):
        with self.assertRaises(ns['GateError']):
            self.load(' '*16385)

    def test_malformed_file_rejected(self):
        with self.assertRaises(ValueError):
            self.load('{')

    def test_invalid_product_line_type_rejected(self):
        for line in (False, 0, [], {}):
            with self.subTest(line=line), self.assertRaises(ns['GateError']):
                ns['canonical'](row(Product_Line__c=line))

    def test_literal_escape_and_case_are_preserved(self):
        formula = r'Name = "A \" B"'
        self.assertTrue(ns['formula_matches'](formula, formula))
        self.assertFalse(ns['formula_matches'](formula, formula.replace('A ', 'A')))
        self.assertFalse(ns['formula_matches']('Name="Ab"', 'Name="ab"'))


# This intentionally small interpreter tests the committed formula's Boolean
# branches, not Salesforce compilation, runtime order or text collation. Unknown
# grammar raises rather than silently simulating a different Salesforce function.
class FormulaModel:
    def __init__(self, source):
        pattern = re.compile(r'\s+|"[^"\\]*"|<>|[A-Za-z_$][A-Za-z0-9_.$]*|[(),&]')
        self.tokens = []
        offset = 0
        while offset < len(source):
            token = pattern.match(source, offset)
            if token is None:
                raise ValueError('Unsupported formula syntax at ' + source[offset:])
            if not token.group().isspace():
                self.tokens.append(token.group())
            offset = token.end()
        self.index = 0
        self.tree = self.expression()
        if self.index != len(self.tokens):
            raise ValueError('Trailing formula tokens')

    def take(self, expected=None):
        token = self.tokens[self.index]
        self.index += 1
        if expected is not None and token != expected:
            raise ValueError('Expected ' + expected)
        return token

    def peek(self):
        return self.tokens[self.index] if self.index < len(self.tokens) else None

    def expression(self):
        left = self.concat()
        if self.peek() == '<>':
            self.take('<>')
            return ('different', left, self.concat())
        return left

    def concat(self):
        left = self.atom()
        while self.peek() == '&':
            self.take('&')
            left = ('concat', left, self.atom())
        return left

    def atom(self):
        token = self.take()
        if token == '(':
            result = self.expression()
            self.take(')')
            return result
        if token.startswith('"'):
            return ('literal', token[1:-1])
        if self.peek() != '(':
            return ('field', token)
        self.take('(')
        args = []
        if self.peek() != ')':
            args.append(self.expression())
            while self.peek() == ',':
                self.take(',')
                args.append(self.expression())
        self.take(')')
        return ('call', token, args)

    def evaluate(self, current, prior=None, machine=False):
        def value(node):
            kind = node[0]
            if kind == 'literal':
                return node[1]
            if kind == 'field':
                if node[1] == '$Permission.Sales_Target_System_Write':
                    return machine
                return current.get(node[1])
            if kind == 'concat':
                return str(value(node[1]) or '') + str(value(node[2]) or '')
            if kind == 'different':
                return value(node[1]) != value(node[2])
            name, args = node[1:]
            if name == 'ISNEW':
                return prior is None
            if name == 'ISCHANGED':
                if len(args) != 1 or args[0][0] != 'field':
                    raise ValueError('ISCHANGED requires a field')
                field = args[0][1]
                return prior is not None and current.get(field) != prior.get(field)
            values = [value(arg) for arg in args]
            if name == 'AND': return all(values)
            if name == 'OR': return any(values)
            if name == 'NOT': return not values[0]
            if name == 'ISBLANK': return values[0] in (None, '')
            if name == 'BLANKVALUE': return values[1] if values[0] in (None, '') else values[0]
            if name == 'TEXT': return '' if values[0] is None else str(values[0])
            if name == 'CASESAFEID':
                candidate = values[0]
                if candidate is None: return ''
                if len(candidate) == 18: return ns['sfid'](candidate)
                if len(candidate) != 15: raise ValueError('Unsupported Id')
                alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'
                return candidate + ''.join(alphabet[sum(1 << j for j, c in enumerate(candidate[i:i+5]) if c.isupper())] for i in (0, 5, 10))
            raise ValueError('Unsupported formula function ' + name)
        return value(self.tree)


class StageTwoSource(unittest.TestCase):
    prefix = '{http://soap.sforce.com/2006/04/metadata}'
    flow_path = 'force-app/main/default/flows/Sales_Target_Set_Unique_Key.flow-meta.xml'
    rule_path = 'force-app/main/default/objects/Sales_Target__c/validationRules/System_Fields_Protected.validationRule-meta.xml'

    def setUp(self):
        self.flow = ET.parse(ROOT / self.flow_path).getroot()
        self.rule = ET.parse(ROOT / self.rule_path).getroot()
        self.formula = FormulaModel(self.rule.findtext(self.prefix + 'errorConditionFormula'))

    def text(self, node, path):
        return node.findtext('/'.join(self.prefix + part for part in path.split('/')))

    def target(self, **changes):
        target = row()
        target['Target_Key__c'] = ns['canonical'](target)
        target.update(changes)
        return target

    def test_manager_canonical_insert_without_actuals_allowed(self):
        self.assertFalse(self.formula.evaluate(self.target()))

    def test_manager_actuals_insert_including_zero_rejected(self):
        for field in ('Actual_Amount__c', 'Won_Opportunity_Count__c', 'Last_Calculated_At__c'):
            for result in (0, 1, '2026-10-28T09:00:00Z'):
                with self.subTest(field=field, result=result):
                    self.assertTrue(self.formula.evaluate(self.target(**{field: result})))

    def test_manager_actuals_change_and_clear_rejected(self):
        for field in ('Actual_Amount__c', 'Won_Opportunity_Count__c', 'Last_Calculated_At__c'):
            for before, after in ((None, 0), (0, 1), (1, None)):
                with self.subTest(field=field, before=before, after=after):
                    self.assertTrue(self.formula.evaluate(self.target(**{field: after}), self.target(**{field: before})))

    def test_unchanged_actuals_allow_manager_dimension_edit(self):
        before = self.target(Actual_Amount__c=95000, Won_Opportunity_Count__c=3)
        after = dict(before, Fiscal_Quarter__c='Q3')
        after['Target_Key__c'] = ns['canonical'](after)
        self.assertFalse(self.formula.evaluate(after, before))

    def test_machine_actuals_insert_change_and_clear_allowed(self):
        for field in ('Actual_Amount__c', 'Won_Opportunity_Count__c', 'Last_Calculated_At__c'):
            self.assertFalse(self.formula.evaluate(self.target(**{field: 1}), machine=True))
            self.assertFalse(self.formula.evaluate(self.target(**{field: None}), self.target(**{field: 1}), machine=True))

    def test_every_caller_rejects_blank_or_noncanonical_key(self):
        for machine in (False, True):
            for bad in (None, '', 'legacy-key', '005000000000001AAA-2026-Q3-ALL'):
                for prior in (None, self.target()):
                    with self.subTest(machine=machine, key=bad, new=prior is None):
                        self.assertTrue(self.formula.evaluate(self.target(Target_Key__c=bad), prior, machine))

    def test_flow_and_rule_use_same_canonical_dimensions(self):
        expression = self.text(self.flow.find(self.prefix + 'formulas'), 'expression')
        expression = re.sub(r'\{!\$Record\.([A-Za-z0-9_]+)\}', r'\1', expression)
        canonical_formula = FormulaModel(expression)
        for rep in ('005000000000001AAA', '005000000000002AAA'):
            for quarter in ('Q1', 'Q2', 'Q3', 'Q4'):
                for line in (None, '', 'Water_Purifier', 'Dehumidifier'):
                    target = self.target(Sales_Rep__c=rep, Fiscal_Quarter__c=quarter, Product_Line__c=line)
                    target['Target_Key__c'] = canonical_formula.evaluate(target)
                    self.assertEqual(ns['canonical'](target), target['Target_Key__c'])
                    self.assertFalse(self.formula.evaluate(target))
        target = self.target(Sales_Rep__c='005000000000001')
        self.assertEqual('005000000000001AAA-2026-Q4-ALL', canonical_formula.evaluate(target))

    def test_actuals_error_message_and_location_preserved(self):
        self.assertEqual('true', self.text(self.rule, 'active'))
        self.assertEqual(ns['PROTECTION_MESSAGE'], self.text(self.rule, 'errorMessage'))
        self.assertIsNone(self.text(self.rule, 'errorDisplayField'))

    def test_flow_always_runs_before_create_and_update_at_api67(self):
        self.assertEqual('67.0', self.text(self.flow, 'apiVersion'))
        self.assertEqual('AutoLaunchedFlow', self.text(self.flow, 'processType'))
        self.assertEqual('Active', self.text(self.flow, 'status'))
        start = self.flow.find(self.prefix + 'start')
        self.assertEqual('Sales_Target__c', self.text(start, 'object'))
        self.assertEqual('CreateAndUpdate', self.text(start, 'recordTriggerType'))
        self.assertEqual('RecordBeforeSave', self.text(start, 'triggerType'))
        self.assertIsNone(self.text(start, 'filterFormula'))
        self.assertEqual([], start.findall(self.prefix + 'filters'))
        # Record-triggered before-save flows run in system context; no user-context override.
        self.assertIsNone(self.text(self.flow, 'runInMode'))

    def test_flow_graph_assigns_key_before_lookup_and_errors_only_on_match(self):
        self.assertEqual('Set_Canonical_Key', self.text(self.flow, 'start/connector/targetReference'))
        assignments = self.flow.findall(self.prefix + 'assignments')
        self.assertEqual(1, len(assignments))
        assign = assignments[0]
        self.assertEqual('Set_Canonical_Key', self.text(assign, 'name'))
        self.assertEqual('$Record.Target_Key__c', self.text(assign, 'assignmentItems/assignToReference'))
        self.assertEqual('Assign', self.text(assign, 'assignmentItems/operator'))
        self.assertEqual('Canonical_Key', self.text(assign, 'assignmentItems/value/elementReference'))
        self.assertEqual('Find_Other_Target', self.text(assign, 'connector/targetReference'))
        lookup = self.flow.find(self.prefix + 'recordLookups')
        self.assertEqual('Check_Duplicate', self.text(lookup, 'connector/targetReference'))
        decision = self.flow.find(self.prefix + 'decisions')
        self.assertEqual('Find_Other_Target.Id', self.text(decision, 'rules/conditions/leftValueReference'))
        self.assertEqual('IsNull', self.text(decision, 'rules/conditions/operator'))
        self.assertEqual('false', self.text(decision, 'rules/conditions/rightValue/booleanValue'))
        self.assertEqual('Duplicate_Target_Error', self.text(decision, 'rules/connector/targetReference'))
        self.assertIsNone(decision.find(self.prefix + 'defaultConnector'))
        error = self.flow.find(self.prefix + 'customErrors')
        self.assertEqual('Duplicate_Target_Error', self.text(error, 'name'))
        self.assertEqual('This salesperson already has a target for the same quarter and product line. Please edit the existing target instead.', self.text(error, 'customErrorMessages/errorMessage'))
        self.assertEqual('false', self.text(error, 'customErrorMessages/isFieldError'))

    def test_lookup_excludes_self_without_owner_filter(self):
        lookups = self.flow.findall(self.prefix + 'recordLookups')
        self.assertEqual(1, len(lookups))
        lookup = lookups[0]
        self.assertEqual('Sales_Target__c', self.text(lookup, 'object'))
        self.assertEqual('true', self.text(lookup, 'getFirstRecordOnly'))
        self.assertEqual('true', self.text(lookup, 'assignNullValuesIfNoRecordsFound'))
        self.assertEqual('and', self.text(lookup, 'filterLogic'))
        filters = [(self.text(f, 'field'), self.text(f, 'operator'), self.text(f, 'value/elementReference')) for f in lookup.findall(self.prefix + 'filters')]
        self.assertEqual([('Target_Key__c', 'EqualTo', '$Record.Target_Key__c'), ('Id', 'NotEqualTo', '$Record.Id')], filters)

    def test_flow_has_no_loop_or_dml_or_external_action(self):
        for tag in ('loops', 'recordCreates', 'recordUpdates', 'recordDeletes', 'subflows', 'actionCalls', 'screens'):
            self.assertEqual([], self.flow.findall(self.prefix + tag), tag)

    def test_atomic_unique_field_is_preserved(self):
        field = ET.parse(ROOT / 'force-app/main/default/objects/Sales_Target__c/fields/Target_Key__c.field-meta.xml').getroot()
        for name, expected in (('type', 'Text'), ('length', '80'), ('unique', 'true'), ('caseSensitive', 'false'), ('externalId', 'true')):
            self.assertEqual(expected, self.text(field, name))

    def test_staged_boundary_contains_only_approved_stage_members(self):
        manifest = json.loads((SOURCE.parent / 'orchard-run.json').read_text())
        boundary = manifest['actions'][0]['metadataBoundary']
        self.assertEqual([
            'force-app/main/default/objects/Sales_Target__c/fields/Sales_Rep__c.field-meta.xml',
            'force-app/main/default/objects/Sales_Target__c/validationRules/Active_Sales_Rep_On_Assignment.validationRule-meta.xml'
        ], boundary['after'])
        self.assertEqual([self.rule_path, self.flow_path], boundary['before'])
        # Actual changedFiles membership is verified by Orchard's immutable plan,
        # not inferred from file existence or synthesized remote Git state.

    def test_regressions_are_in_standard_package_test_command(self):
        scripts = json.loads((ROOT / 'package.json').read_text())['scripts']
        self.assertEqual('npm run test:migration && npm run test:unit', scripts['test'])
        self.assertEqual('python3 -B tools/test_sales_target_migration.py', scripts['test:migration'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
