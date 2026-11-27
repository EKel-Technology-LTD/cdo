import copy
import json
import pathlib
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'force-app/scripts/post/common/taiwan-service-hours-merge.sh'
MODULE = types.ModuleType('calendar_action')
exec(compile(SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0], str(SCRIPT), 'exec'), MODULE.__dict__)
NS = MODULE.NS


def fixture():
    fields = {'active': 'true', 'default': 'true', 'name': 'Default', 'timeZoneId': 'America/Los_Angeles'}
    for day in MODULE.DAYS:
        for suffix in ('StartTime', 'EndTime'):
            fields[day.lower() + suffix] = '00:00:00.000Z'
    calendar = '<businessHours>' + ''.join('<%s>%s</%s>' % (k, v, k) for k, v in sorted(fields.items())) + '</businessHours>'
    holiday = ('<holidays><activityDate>2027-02-06</activityDate><businessHours>Default</businessHours>'
               '<description>Keep &amp; preserve</description><isRecurring>true</isRecurring><name>Unit holiday</name>'
               '<recurrenceDayOfMonth>6</recurrenceDayOfMonth><recurrenceEndDate>2029-02-06</recurrenceEndDate>'
               '<recurrenceMonthOfYear>February</recurrenceMonthOfYear><recurrenceStartDate>2027-02-06</recurrenceStartDate>'
               '<recurrenceType>RecursYearly</recurrenceType></holidays>')
    xml = ('<?xml version="1.0"?><BusinessHoursSettings xmlns="' + NS + '">' + calendar + holiday +
           '<futureFlag preserved="yes"><unknown>original value</unknown></futureFlag></BusinessHoursSettings>').encode()
    record = {'Id': '01m000000000001AAA', 'CreatedDate': '2026-01-01T00:00:00Z'}
    for field, rest in MODULE.BH_MAP.items():
        value = fields.get(field)
        record[rest] = value == 'true' if field in ('active', 'default') else value
    return {'orgId': '00D000000000001AAA', 'xml': xml, 'calendars': [record], 'exists': False,
            'holidays': [{**dict.fromkeys(MODULE.HOLIDAY_FIELDS), 'Id': '01m000000000002AAA', 'Name': 'Unit holiday', 'ActivityDate': '2027-02-06',
                          'IsRecurrence': True, 'RecurrenceType': 'RecursYearly', 'RecurrenceDayOfMonth': 6,
                          'RecurrenceMonthOfYear': 'February', 'RecurrenceStartDate': '2027-02-06',
                          'RecurrenceEndDateOnly': '2029-02-06'}]}


def added_snapshot(before):
    result = copy.deepcopy(before)
    result['xml'], _ = MODULE.merge(before['xml'])
    result['exists'] = True
    record = {'Id': '01m000000000003AAA'}
    for field, rest in MODULE.BH_MAP.items():
        value = MODULE.EXPECTED.get(field)
        record[rest] = value == 'true' if field in ('active', 'default') else value
    result['calendars'].append(record)
    return result


class MergeTests(unittest.TestCase):
    def test_add_preserves_all_protected_content_and_identity(self):
        before = fixture()
        self.assertFalse(MODULE.reconcile(before['xml'], before['calendars'], before['holidays']))
        after = added_snapshot(before)
        self.assertTrue(MODULE.reconcile(after['xml'], after['calendars'], after['holidays']))
        MODULE.compare(before, after, addition=True)
        root = MODULE.parse(after['xml']).documentElement
        self.assertEqual(len(MODULE.elements(root, 'businessHours')), 2)
        entry = MODULE.elements(root, 'businessHours')[1]
        self.assertEqual(MODULE.text(entry, 'timeZoneId'), 'Asia/Taipei')
        self.assertEqual(MODULE.text(entry, 'saturdayEndTime'), '12:00:00.000Z')
        self.assertIsNone(MODULE.text(entry, 'sundayStartTime'))
        self.assertEqual(MODULE.text(MODULE.elements(root, 'holidays')[0], 'businessHours'), 'Default')
        self.assertIn(b'<unknown>original value</unknown>', after['xml'])

    def test_noop_is_byte_identical(self):
        before = added_snapshot(fixture())
        xml, added = MODULE.merge(before['xml'])
        self.assertFalse(added)
        self.assertEqual(xml, before['xml'])
        MODULE.compare(before, before)

    def test_existing_calendar_associations_preserved(self):
        before = added_snapshot(fixture())
        before['xml'] = before['xml'].replace(b'<businessHours>Default</businessHours>',
                                             b'<businessHours>Taiwan_Service_Hours</businessHours>')
        self.assertTrue(MODULE.reconcile(before['xml'], before['calendars'], before['holidays']))
        self.assertEqual(MODULE.merge(before['xml']), (before['xml'], False))

    def test_missing_holiday_field_fails_closed(self):
        before = fixture()
        del before['holidays'][0]['RecurrenceDayOfWeekMask']
        with self.assertRaises(RuntimeError):
            MODULE.reconcile(before['xml'], before['calendars'], before['holidays'])

    def test_conflicting_hours_default_timezone_and_sunday_fail(self):
        xml = added_snapshot(fixture())['xml']
        variants = [xml.replace(b'09:00:00.000Z', b'08:00:00.000Z'),
                    xml.replace(b'<default>false</default>', b'<default>true</default>'),
                    xml.replace(b'Asia/Taipei', b'Asia/Tokyo'),
                    xml.replace(b'<name>Taiwan_Service_Hours</name>',
                                b'<name>Taiwan_Service_Hours</name><sundayStartTime>00:00:00.000Z</sundayStartTime>')]
        for raw in variants:
            with self.subTest(raw=raw), self.assertRaises(RuntimeError):
                MODULE.merge(raw)

    def test_duplicate_calendar_fails(self):
        doc = MODULE.parse(added_snapshot(fixture())['xml'])
        root = doc.documentElement
        root.appendChild(MODULE.elements(root, 'businessHours')[1].cloneNode(True))
        with self.assertRaises(RuntimeError):
            MODULE.merge(doc.toxml(encoding='UTF-8'))

    def test_malformed_wrong_namespace_and_entities_fail(self):
        for raw in (b'<x>', b'<BusinessHoursSettings/>',
                    b'<!DOCTYPE x [<!ENTITY a "x">]><BusinessHoursSettings/>'):
            with self.subTest(raw=raw), self.assertRaises(Exception):
                MODULE.parse(raw)

    def test_prefixed_namespace_preserved(self):
        raw = fixture()['xml'].decode()
        import re
        raw = re.sub(r'<(/?)([A-Za-z][A-Za-z0-9]*)', r'<\1m:\2', raw).replace('xmlns=', 'xmlns:m=')
        merged, added = MODULE.merge(raw.encode())
        self.assertTrue(added)
        self.assertIn(b'<m:businessHours>', merged)
        self.assertEqual(MODULE.merge(merged), (merged, False))

    def test_observed_drift_always_aborts(self):
        before = fixture()
        for old, new in ((b'2027-02-06', b'2027-02-07'), (b'original value', b'changed'),
                         (b'<businessHours>Default</businessHours>', b''),
                         (b'<recurrenceDayOfMonth>6', b'<recurrenceDayOfMonth>7')):
            after = copy.deepcopy(before)
            after['xml'] = after['xml'].replace(old, new)
            with self.subTest(old=old), self.assertRaises(RuntimeError):
                MODULE.compare(before, after)

    def test_identity_membership_and_record_changes_fail(self):
        before = fixture()
        variants = []
        after = copy.deepcopy(before)
        after['holidays'][0]['Id'] = '01m000000000004AAA'
        variants.append(after)
        after = copy.deepcopy(before)
        after['calendars'][0]['Id'] = '01m000000000004AAA'
        variants.append(after)
        after = copy.deepcopy(before)
        after['orgId'] = '00D000000000002AAA'
        variants.append(after)
        after = copy.deepcopy(before)
        after['holidays'][0]['RecurrenceDayOfMonth'] = 7
        variants.append(after)
        for after in variants:
            with self.subTest(after=after), self.assertRaises(RuntimeError):
                MODULE.compare(before, after)

    def test_incomplete_and_default_inventories_fail(self):
        before = fixture()
        for calendars, holidays in (([], before['holidays']), (before['calendars'], []),
                                     (before['calendars'] * 2, before['holidays'])):
            with self.subTest(calendars=calendars), self.assertRaises(RuntimeError):
                MODULE.reconcile(before['xml'], calendars, holidays)
        before['calendars'][0]['IsDefault'] = False
        with self.assertRaises(RuntimeError):
            MODULE.reconcile(before['xml'], before['calendars'], before['holidays'])

    def test_no_auto_assignment_to_new_calendar(self):
        before = fixture()
        after = added_snapshot(before)
        old = MODULE.elements(MODULE.parse(before['xml']).documentElement, 'holidays')[0].toxml()
        new = MODULE.elements(MODULE.parse(after['xml']).documentElement, 'holidays')[0].toxml()
        self.assertEqual(old, new)


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT)
        self.action = MODULE.Action.__new__(MODULE.Action)
        self.action.org = 'unit-test-only'
        self.action.deadline = MODULE.time.monotonic() + 840
        self.action.evidence = pathlib.Path(self.temp.name)
        self.action.org_id = None
        self.action.job_id = None
        self.action.submitted = False
        self.action.sequence = 0
        self.action.emit = lambda *args: None

    def tearDown(self):
        self.temp.cleanup()

    def test_command_exit_and_json_both_required(self):
        for code, output in ((1, '{"status":0,"result":{}}'), (0, '{"status":1,"result":{}}'),
                             (0, 'not JSON'), (0, '{"status":0}'),
                             (0, '{"status":0,"result":{},"warnings":["partial"]}')):
            with self.subTest(code=code, output=output), patch.object(MODULE.subprocess, 'run',
                    return_value=subprocess.CompletedProcess([], code, output, '')), self.assertRaises(RuntimeError):
                self.action.sf('data', 'query')

    def test_timeout_propagates_without_retry(self):
        with patch.object(MODULE.subprocess, 'run', side_effect=subprocess.TimeoutExpired('sf', 1)) as call:
            with self.assertRaises(subprocess.TimeoutExpired):
                self.action.sf('project', 'deploy', 'start')
            self.assertEqual(call.call_count, 1)

    def test_partial_query_rejected(self):
        for result in ({'done': False, 'records': [], 'totalSize': 0},
                       {'done': True, 'records': [], 'totalSize': 1},
                       {'done': True, 'records': [], 'totalSize': 0, 'nextRecordsUrl': '/next'}):
            with self.subTest(result=result), patch.object(self.action, 'sf', return_value=result), self.assertRaises(RuntimeError):
                self.action.query('unit query')

    def test_read_failure_never_deploys(self):
        with patch.object(self.action, 'snapshot', side_effect=RuntimeError('incomplete')), patch.object(self.action, 'deploy') as deploy:
            with self.assertRaises(RuntimeError):
                self.action.run()
            deploy.assert_not_called()

    def test_drift_never_deploys(self):
        before = fixture()
        after = copy.deepcopy(before)
        after['xml'] = after['xml'].replace(b'original value', b'drift')
        with patch.object(self.action, 'snapshot', side_effect=[before, after]), patch.object(self.action, 'deploy') as deploy:
            with self.assertRaises(RuntimeError):
                self.action.run()
            deploy.assert_not_called()

    def test_successful_add_and_existing_noop_orchestration(self):
        before = fixture()
        after = added_snapshot(before)
        with patch.object(self.action, 'snapshot', side_effect=[before, before, after]), patch.object(self.action, 'deploy') as deploy:
            self.action.run()
            deploy.assert_called_once()
        import shutil
        shutil.rmtree(self.action.evidence / 'candidate')
        with patch.object(self.action, 'snapshot', return_value=after), patch.object(self.action, 'deploy') as deploy:
            self.action.run()
            deploy.assert_not_called()

    def test_job_failure_never_submits_again(self):
        job = '0Af000000000001AAA'
        for state in ('Failed', 'SucceededPartial', 'Canceled', 'Unknown'):
            with self.subTest(state=state), patch.object(self.action, 'sf', side_effect=[{'id': job},
                    {'id': job, 'done': True, 'status': state, 'success': False}]) as call:
                with self.assertRaises(RuntimeError):
                    self.action.deploy(self.action.evidence)
                self.assertEqual(sum('start' in c.args for c in call.call_args_list), 1)

    def test_success_requires_final_job_and_rollback_flags(self):
        job = '0Af000000000001AAA'
        result = {'id': job, 'done': True, 'status': 'Succeeded', 'success': True, 'rollbackOnError': True,
                  'checkOnly': False, 'numberComponentErrors': 0, 'numberComponentsTotal': 1, 'numberComponentsDeployed': 1}
        with patch.object(self.action, 'sf', side_effect=[{'id': job}, result]) as call:
            self.action.deploy(self.action.evidence)
            self.assertNotIn('--ignore-errors', call.call_args_list[0].args)
        for key in ('rollbackOnError', 'numberComponentsTotal', 'checkOnly', 'success'):
            partial = result.copy()
            partial.pop(key)
            with self.subTest(key=key), patch.object(self.action, 'sf', side_effect=[{'id': job}, partial]), self.assertRaises(RuntimeError):
                self.action.deploy(self.action.evidence)

    def test_budget_guard_before_write(self):
        self.action.deadline = MODULE.time.monotonic() + 100
        with patch.object(self.action, 'sf') as call, self.assertRaises(RuntimeError):
            self.action.deploy(self.action.evidence)
        call.assert_not_called()

    def test_manifest_is_template_eligible_and_metadata_changing(self):
        manifest = json.loads((SCRIPT.parent / 'orchard-run.json').read_text())
        entries = [a for a in manifest['actions'] if a['id'] == 'taiwan-service-hours-protected-merge']
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0], {'id': 'taiwan-service-hours-protected-merge', 'type': 'bash',
                                    'file': SCRIPT.name, 'timeoutMinutes': 15, 'scopeMode': 'always',
                                    'deploymentEffect': 'metadata'})
        for env in ('dev', 'ci'):
            overlay = json.loads((SCRIPT.parent.parent / 'environments' / env / 'orchard-run.json').read_text())
            self.assertFalse(any(a['id'] == entries[0]['id'] for a in overlay['actions']))


if __name__ == '__main__':
    unittest.main()
