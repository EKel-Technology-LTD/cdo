"""Offline activation contract tests; neither Bash entry point nor Salesforce is run.
Apex text checks are source guards, NOT Salesforce compilation/acceptance evidence.
"""
import ast
import datetime as dt
import json
import re
import unittest
from pathlib import Path
from unittest.mock import Mock
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
FOLDER = ROOT / 'force-app/scripts/post/common'
ACTIVATION = FOLDER / 'sales-target-activate.sh'
SOURCE = ACTIVATION.read_text()
BODY = SOURCE.split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
TREE = ast.parse(BODY)
DECLARATIONS = [n for n in TREE.body if isinstance(n, (ast.FunctionDef, ast.ClassDef))]
DECLARATIONS += [n for n in TREE.body if isinstance(n, ast.Assign) and
                 any(isinstance(t, ast.Name) and t.id in {'STAGE_TWO_PROTECTION', 'PROTECTION_MESSAGE'} for t in n.targets)]
USER = '005000000000001AAA'
JOB = '08e000000000001AAA'
ASYNC = '707000000000001AAA'

def namespace():
    ns = {'dt': dt, 'json': json, 're': re, 'USER': USER, 'MACHINE': 'synthetic@example.invalid'}
    exec(compile(ast.Module(body=DECLARATIONS, type_ignores=[]), str(ACTIVATION), 'exec'), ns)
    return ns

def job(**changes):
    row = dict(Id=JOB, OwnerId=USER, TimeZoneSidKey='America/Los_Angeles',
               CronExpression='0 0 2 * * ?', State='WAITING',
               NextFireTime=(dt.datetime.now(dt.timezone.utc)+dt.timedelta(days=1)).isoformat())
    row.update(changes)
    return row

class ActivationContract(unittest.TestCase):
    def setUp(self):
        self.ns = namespace()
        self.error = self.ns['GateError']

    def test_complete_python_compiles_without_running_entry(self):
        compile(BODY, str(ACTIVATION), 'exec')

    def test_post_action_has_declared_inputs_and_no_boundary(self):
        actions=json.loads((FOLDER/'orchard-run.json').read_text())['actions']
        action=next(a for a in actions if a['id']=='sales-target-activate')
        self.assertEqual('bash',action['type'])
        self.assertEqual('sales-target-activate.sh',action['file'])
        self.assertEqual('data',action['deploymentEffect'])
        self.assertEqual('selected_delivery',action['scopeMode'])
        self.assertEqual(10,action['timeoutMinutes'])
        self.assertNotIn('metadataBoundary',action)
        self.assertNotIn('reviewPrerequisite',action)
        self.assertEqual(next(a for a in actions if a['id']=='sales-target-preflight')['releaseInputs'],action['releaseInputs'])

    def test_guard_helpers_match_migration_implementation(self):
        before=(FOLDER/'sales-target-preflight.sh').read_text().split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
        originals={n.name:ast.dump(n,include_attributes=False) for n in ast.parse(before).body if isinstance(n,(ast.FunctionDef,ast.ClassDef))}
        for node in DECLARATIONS:
            if isinstance(node,(ast.FunctionDef,ast.ClassDef)) and node.name in originals and node.name!='metadata_gates':
                self.assertEqual(originals[node.name],ast.dump(node,include_attributes=False),node.name)

    def test_exact_stage_two_formula_is_pinned(self):
        root=ET.parse(ROOT/'force-app/main/default/objects/Sales_Target__c/validationRules/System_Fields_Protected.validationRule-meta.xml')
        expected=root.find('{http://soap.sforce.com/2006/04/metadata}errorConditionFormula').text
        self.assertEqual(expected,self.ns['STAGE_TWO_PROTECTION'])
        self.assertIn("formula_matches(detail.get('errorConditionFormula'), STAGE_TWO_PROTECTION)",BODY)

    def test_no_grants_backfill_login_or_auto_resume(self):
        for prohibited in ('def backfill(', "'data','create','record'", 'PermissionSetAssignment(', 'force://', 'System.runAs(', 'org login', 'Database.update('):
            self.assertNotIn(prohibited,BODY)
        self.assertIn('writesRemainQuiesced=True',BODY)
        self.assertIn('load_release_inputs()',BODY)

    def test_readback_and_reaudit_follow_scheduling(self):
        entry=next(n for n in TREE.body if isinstance(n,ast.Try))
        text=ast.unparse(entry)
        self.assertLess(text.index('load_release_inputs'),text.index('metadata_gates'))
        self.assertLess(text.index('metadata_gates'),text.index('verify_active_flow'))
        self.assertLess(text.index('audit_currencies(before'),text.index('System.schedule('))
        self.assertLess(text.index('verify_schedule_inventory()'),text.index('System.schedule('))
        self.assertLess(text.index('System.schedule('),text.index('job = verify_schedule'))
        self.assertLess(text.index('job = verify_schedule'),text.index('after = target_rows'))
        self.assertIn('schedule_uncertain_readback',text)
        self.assertIn('raise',text)

    def test_single_owned_schedule_is_accepted(self):
        self.assertEqual(JOB,self.ns['verify_schedule']([job()])['Id'])

    def test_empty_schedule_is_not_success(self):
        with self.assertRaises(self.error):self.ns['verify_schedule']([])

    def test_multiple_schedules_fail(self):
        with self.assertRaises(self.error):self.ns['verify_schedule']([job(),job()])

    def test_other_owner_fails(self):
        with self.assertRaises(self.error):self.ns['verify_schedule']([job(OwnerId='005000000000002AAA')])

    def test_wrong_timezone_fails(self):
        with self.assertRaises(self.error):self.ns['verify_schedule']([job(TimeZoneSidKey='GMT')])

    def test_wrong_cron_fails(self):
        with self.assertRaises(self.error):self.ns['verify_schedule']([job(CronExpression='0 0 3 * * ?')])

    def test_nonwaiting_schedule_fails(self):
        with self.assertRaises(self.error):self.ns['verify_schedule']([job(State='ERROR')])

    def test_missing_fire_fails(self):
        with self.assertRaises(self.error):self.ns['verify_schedule']([job(NextFireTime=None)])

    def test_stale_fire_fails(self):
        with self.assertRaises(self.error):self.ns['verify_schedule']([job(NextFireTime='2020-01-01T00:00:00Z')])

    def test_unzoned_fire_fails(self):
        with self.assertRaises(self.error):self.ns['verify_schedule']([job(NextFireTime='2099-01-01T00:00:00')])

    def test_wrong_id_type_fails(self):
        with self.assertRaises(self.error):self.ns['verify_schedule']([job(Id=USER)])

    def test_verified_class_binding_passes(self):
        self.ns['query']=Mock(side_effect=[
            [dict(Id=ASYNC,ApexClass=dict(Name='SalesTargetActualsSchedulable'),CreatedById=USER)],
            [dict(Id=JOB)], [dict(Id=ASYNC,CronTriggerId=JOB)]])
        self.assertEqual([ASYNC],self.ns['verify_schedule_binding'](job()))

    def test_wrong_class_binding_fails(self):
        self.ns['query']=Mock(return_value=[dict(Id=ASYNC,ApexClass=dict(Name='OtherClass'),CreatedById=USER)])
        with self.assertRaises(self.error):self.ns['verify_schedule_binding'](job())

    def test_unproven_class_binding_fails(self):
        self.ns['query']=Mock(return_value=[])
        with self.assertRaises(self.error):self.ns['verify_schedule_binding'](job())

    def test_alternate_named_schedule_blocks_before_write(self):
        self.ns['query']=Mock(side_effect=[[dict(Id=JOB)],[dict(Id=ASYNC,CronTriggerId=JOB)]])
        with self.assertRaises(self.error):self.ns['verify_schedule_inventory']()

    def test_empty_inventory_allows_new_install(self):
        self.ns['query']=Mock(side_effect=[[],[]])
        self.ns['verify_schedule_inventory']()

    def test_unrelated_jobs_are_preserved(self):
        self.ns['query']=Mock(side_effect=[[dict(Id=JOB)],[]])
        self.ns['verify_schedule_inventory']()
        self.assertNotIn('System.abortJob(',BODY.split('except (GateError, subprocess.TimeoutExpired, ValueError, KeyError')[0])

    def test_active_flow_exact_contract(self):
        flow=ET.parse(ROOT/'force-app/main/default/flows/Sales_Target_Set_Unique_Key.flow-meta.xml')
        expected=flow.find('{http://soap.sforce.com/2006/04/metadata}formulas/{http://soap.sforce.com/2006/04/metadata}expression').text
        self.ns['query']=Mock(side_effect=[[dict(ActiveVersionId='301000000000001AAA')],[dict(Metadata=dict(
            status='Active',apiVersion=67.0,start=dict(object='Sales_Target__c',recordTriggerType='CreateAndUpdate',triggerType='RecordBeforeSave'),
            formulas=[dict(name='Canonical_Key',expression=expected)]))]])
        self.assertEqual('301000000000001AAA',self.ns['verify_active_flow']())

    def test_inactive_flow_fails(self):
        self.ns['query']=Mock(side_effect=[[dict(ActiveVersionId='301000000000001AAA')],[dict(Metadata=dict(status='Draft',apiVersion=67.0))]])
        with self.assertRaises(self.error):self.ns['verify_active_flow']()

class ApexSourceContracts(unittest.TestCase):
    def setUp(self):
        folder=ROOT/'force-app/main/default/classes'
        self.batch=(folder/'SalesTargetActualsBatch.cls').read_text()
        self.scheduler=(folder/'SalesTargetActualsSchedulable.cls').read_text()
        self.tests=(folder/'SalesTargetActualsTest.cls').read_text()

    def test_version_and_metadata_pair(self):
        for name in ('SalesTargetActualsBatch','SalesTargetActualsSchedulable','SalesTargetActualsTest'):
            xml=ET.parse(ROOT/f'force-app/main/default/classes/{name}.cls-meta.xml')
            self.assertEqual('67.0',xml.find('{http://soap.sforce.com/2006/04/metadata}apiVersion').text)

    def test_access_mode_and_permission_are_explicit(self):
        self.assertIn('public without sharing class',self.batch)
        self.assertIn('public with sharing class',self.scheduler)
        self.assertIn("FeatureManagement.checkPermission('Sales_Target_System_Write')",self.batch)
        self.assertIn('AccessLevel.SYSTEM_MODE',self.batch)
        self.assertIn('WITH SYSTEM_MODE',self.scheduler)
        self.assertNotIn('@AuraEnabled',self.batch+self.scheduler)
        self.assertNotIn('@InvocableMethod',self.batch+self.scheduler)

    def test_stable_business_clock_and_yesterday(self):
        self.assertIn('private static Date testToday',self.batch)
        self.assertIn("'America/Los_Angeles'",self.batch)
        self.assertIn('cutoff = runToday.addDays(-1)',self.batch)
        self.assertIn('.addMonths(-3)',self.batch)
        self.assertIn('Period_Start__c <= :today AND Period_End__c >= :previous',self.batch)

    def test_re_read_lock_replacement_and_all_or_none(self):
        self.assertIn('WHERE Id IN :ids FOR UPDATE',self.batch)
        self.assertIn('row.Period_Start__c > runToday',self.batch)
        self.assertIn('Database.update(updates, true, AccessLevel.SYSTEM_MODE)',self.batch)
        self.assertIn('Last_Calculated_At__c = calculatedAt',self.batch)
        self.assertNotIn('catch',self.batch)

    def test_source_semantics_and_null_handling(self):
        self.assertIn('IsWon=true',self.batch)
        self.assertIn('CloseDate <= :latest',self.batch)
        self.assertIn('row.Amount',self.batch)
        self.assertIn('row.TotalPrice',self.batch)
        self.assertIn('amount == null ? 0 : amount',self.batch)
        self.assertIn('Set<Id> opportunityIds',self.batch)
        self.assertNotIn('convertCurrency',self.batch)
        self.assertNotIn('IsActive',self.batch.split('public void execute')[1])

    def test_scheduler_locks_before_active_job_query(self):
        self.assertLess(self.scheduler.index('FOR UPDATE'),self.scheduler.index('FROM AsyncApexJob'))
        self.assertIn("'Holding', 'Queued', 'Preparing', 'Processing'",self.scheduler)
        self.assertIn('Database.executeBatch(new SalesTargetActualsBatch(), 25)',self.scheduler)

    def test_owned_rollback_is_guarded_and_read_back(self):
        stop=self.scheduler.split('public static Id stopOwnedSchedule()',1)[1]
        self.assertLess(stop.index('requirePermission()'),stop.index('System.abortJob'))
        self.assertIn('jobs[0].OwnerId != actor',stop)
        self.assertIn('CronTriggerId = :cronId',stop)
        self.assertIn('binding.CreatedById != actor',stop)
        self.assertIn("binding.ApexClass.Name != 'SalesTargetActualsSchedulable'",stop)
        self.assertLess(stop.index('System.abortJob(cronId)'),stop.index('WHERE Id = :cronId'))

    def test_required_acceptance_and_limit_tests_exist(self):
        for name in ('allLinesOwnerQuarterAndAttainment','lineAmountsCountDistinctAndDoNotUseOpportunityAmount',
                     'reopenReallocateAndEmptyReset','nullAmountCountsAsZero','yearRolloverCutoffAndFreshDimensions',
                     'unauthorizedPathsFailBeforeWrites','permissionIsRecheckedEveryTransaction',
                     'inactiveRepStillCalculatesAndReassignmentFails','currencyFailsClosedWithoutConversion',
                     'failedScopeKeepsOldValuesAndCanRetry','launchSerializesRecoveryAndSkipsOverlap',
                     'dailyCronIsOwnedAndLosAngeles','volume250Targets6000ClosedOpportunities'):
            self.assertIn(name,self.tests)
        for counter in ('getQueryRows','getQueries','getDmlStatements','getCpuTime','getHeapSize'):
            self.assertIn(counter,self.tests)
        self.assertNotIn('SeeAllData=true',self.tests)

if __name__ == '__main__':
    unittest.main(verbosity=2)
