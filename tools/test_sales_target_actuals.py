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
               NextFireTime=(dt.datetime.now(dt.timezone.utc)+dt.timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%S.000%z'))
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
        self.assertLess(text.index('audit_currencies(before'),text.index('SalesTargetActualsSchedulable.createOwnedSchedule('))
        self.assertLess(text.index('verify_schedule_inventory()'),text.index('SalesTargetActualsSchedulable.createOwnedSchedule('))
        self.assertLess(text.index('SalesTargetActualsSchedulable.createOwnedSchedule('),text.index('job = verify_schedule'))
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

    def test_all_control_paths_share_system_only_mutex(self):
        guard=self.scheduler.split('private static Id acquireMutex()',1)[1].split('/** Returns',1)[0]
        self.assertIn('SalesTargetActualsBatch.requirePermission()',guard)
        self.assertIn('FROM Sales_Target_Mutex__c',guard)
        self.assertIn("Lock_Key__c = 'DAILY_ACTUALS'",guard)
        self.assertIn('locks[0].Machine_User__c != actor',guard)
        self.assertIn('locks.size() != 1',guard)
        self.assertIn('WITH SYSTEM_MODE',guard)
        self.assertIn('FOR UPDATE',guard)
        for query in re.findall(r'\[(.*?)\]',self.scheduler,re.S):
            if re.search(r'FROM\s+User\b',query):
                self.assertNotIn('FOR UPDATE',query)
        for entry in ('launch','createOwnedSchedule','stopOwnedSchedule'):
            method=self.scheduler.split('public static Id '+entry+'()',1)[1].split('\n  }',1)[0]
            self.assertIn('acquireMutex()',method)
        self.assertNotIn('FOR UPDATE',BODY)
        self.assertNotIn('System.schedule(',BODY)
        self.assertNotIn('new Sales_Target_Mutex__c',self.scheduler)

    def test_mutex_sharing_bypass_is_private_and_narrow(self):
        self.assertIn('public with sharing class SalesTargetActualsSchedulable',self.scheduler)
        helper=self.scheduler.split('private without sharing class MutexAccess',1)[1].split('/** Returns',1)[0]
        self.assertLess(helper.index('requirePermission()'),helper.index('FROM Sales_Target_Mutex__c'))
        self.assertIn('FOR UPDATE',helper)
        self.assertIn('locks[0].Machine_User__c != actor',helper)
        self.assertNotIn('FROM User',helper)
        self.assertNotIn('FROM AsyncApexJob',helper)
        self.assertNotIn('Database.',helper)
        guard=self.scheduler.split('private static Id acquireMutex()',1)[1].split('private without sharing',1)[0]
        self.assertLess(guard.index('requirePermission()'),guard.index('new MutexAccess().acquire()'))
        for required in ('separatelyOwnedMutexAllowsLaunchAndRecovery',
                         'separatelyOwnedMutexAllowsScheduleAndStop',
                         'PermissionsModifyAllData = FALSE', 'PermissionsViewAllData = FALSE',
                         'System.runAs(provisioner)'):
            self.assertIn(required,self.tests)

    def test_mutex_metadata_has_no_business_access_grants(self):
        folder=ROOT/'force-app/main/default/objects/Sales_Target_Mutex__c'
        ns='{http://soap.sforce.com/2006/04/metadata}'
        obj=ET.parse(folder/'Sales_Target_Mutex__c.object-meta.xml')
        for name in ('sharingModel','externalSharingModel'):
            self.assertEqual('Private',obj.find(ns+name).text)
        self.assertIsNone(obj.find(ns+'grantAccessUsingHierarchies'))
        # Salesforce requires this capability trio to match; keep all disabled.
        for name in ('enableSharing','enableBulkApi','enableStreamingApi'):
            self.assertEqual('false',obj.find(ns+name).text,name)
        for name in ('enableReports','enableSearch'):
            self.assertEqual('false',obj.find(ns+name).text)
        key=ET.parse(folder/'fields/Lock_Key__c.field-meta.xml')
        self.assertEqual('true',key.find(ns+'unique').text)
        self.assertEqual('true',key.find(ns+'required').text)
        rule=ET.parse(folder/'validationRules/System_Only_Singleton.validationRule-meta.xml')
        formula=rule.find(ns+'errorConditionFormula').text
        for required in ('NOT($Permission.Sales_Target_System_Write)', 'DAILY_ACTUALS', 'ISBLANK(Machine_User__c)'):
            self.assertIn(required,formula)
        for permission in (ROOT/'force-app/main/default/permissionsets').rglob('*.xml'):
            self.assertNotIn('Sales_Target_Mutex__c',permission.read_text(),str(permission))
        for required in ('missingMutexBlocksEveryEntryWithoutProvisioning',
                         'anotherMachineBindingBlocksEveryEntry',
                         'singletonKeyRejectsDuplicateAndInvalidRows',
                         'unauthorizedScheduleCreationAndStopFailBeforeLockRead'):
            self.assertIn(required,self.tests)

    def test_hierarchy_access_is_a_verified_release_prerequisite(self):
        # Documentation/source guards only: this does not verify any org setting.
        metadata=(ROOT/'force-app/main/default/objects/Sales_Target_Mutex__c/Sales_Target_Mutex__c.object-meta.xml').read_text()
        for required in ('Mandatory release prerequisite', 'independently VERIFIED',
                         'before any', 'mutex-record provisioning or activation',
                         'missing or inconclusive evidence blocks'):
            self.assertIn(required,metadata)
        for required in ('MANDATORY RELEASE PREREQUISITE (separately VERIFIED',
                         'Grant Access Using Hierarchies is disabled',
                         'exact-target evidence', 'source revision, verifier, timestamp',
                         'Missing or inconclusive proof',
                         'authorization file is not hierarchy-access evidence',
                         'authorizes NO org changes'):
            self.assertIn(required,SOURCE)

    def test_owned_rollback_is_guarded_and_read_back(self):
        stop=self.scheduler.split('public static Id stopOwnedSchedule()',1)[1]
        self.assertLess(stop.index('acquireMutex()'),stop.index('System.abortJob'))
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

class AcceptanceAssertionContracts(unittest.TestCase):
    """Static assertion/discovery guards, not an Apex parser or runner receipt."""
    FOLDER = ROOT / 'force-app/main/default/classes'
    MESSAGE = ('This salesperson already has a target for the same quarter and product line. '
               'Please edit the existing target instead.')

    def setUp(self):
        self.actuals = (self.FOLDER / 'SalesTargetActualsTest.cls').read_text()
        self.policy = (self.FOLDER / 'SalesTargetCurrencyPolicyTest.cls').read_text()

    def assert_future_blanks(self, source):
        for field in ('Actual_Amount__c', 'Won_Opportunity_Count__c', 'Last_Calculated_At__c'):
            self.assertRegex(source, r'Assert\.isNull\(\s*stored\(targets\[2\]\.Id\)\.' + field + r'\s*,')

    def test_future_target_asserts_all_three_stored_results_blank(self):
        self.assert_future_blanks(self.actuals)

    def test_future_count_guard_detects_removed_or_zero_assertion(self):
        # Mutate only in memory; prove this guard rejects the old missing check.
        check = re.search(r'    Assert\.isNull\(\s*stored\(targets\[2\]\.Id\)\.Won_Opportunity_Count__c,.*?\n    \);', self.actuals, re.S)
        self.assertIsNotNone(check)
        for replacement in ('', check.group().replace('Assert.isNull(', 'Assert.isNotNull(')):
            with self.subTest(replacement=replacement), self.assertRaises(AssertionError):
                self.assert_future_blanks(self.actuals.replace(check.group(), replacement))

    def test_duplicate_create_and_edit_require_entire_business_message(self):
        body = self.policy.split('static void keysCanonicalizeAndRejectCollisions()', 1)[1].split('List<Database.SaveResult> collisions', 1)[0]
        calls = re.findall(r"blocked\(.*?\n      \);", body, re.S)
        self.assertEqual(2, len(calls))
        for call in calls:
            self.assertIn(self.MESSAGE, call)
        self.assertIn('Database.insert(', calls[0])
        self.assertIn('Database.update(', calls[1])
        flow = ET.parse(ROOT / 'force-app/main/default/flows/Sales_Target_Set_Unique_Key.flow-meta.xml')
        ns = '{http://soap.sforce.com/2006/04/metadata}'
        self.assertEqual(self.MESSAGE, flow.find('.//' + ns + 'errorMessage').text)

    def test_duplicate_edit_reads_back_original_quarter_and_key(self):
        body = self.policy.split('static void keysCanonicalizeAndRejectCollisions()', 1)[1].split('Sales_Target__c differentLine', 1)[0]
        self.assertRegex(body, r"Assert\.areEqual\(\s*'Q3',\s*\[SELECT Fiscal_Quarter__c FROM Sales_Target__c WHERE Id = :other.Id\]\s*\.Fiscal_Quarter__c")
        self.assertRegex(body, r"Assert\.areEqual\(\s*String.valueOf\(human.Id\) \+ '-2026-Q3-ALL',\s*reload\(other.Id\).Target_Key__c")

    def test_rejected_mutex_paths_assert_no_cron_as_well_as_no_batch(self):
        body = self.actuals.split('private static void assertMutexEntriesFail()', 1)[1].split('static void singletonKeyRejectsDuplicateAndInvalidRows()', 1)[0]
        for table in ('AsyncApexJob', 'CronTrigger'):
            self.assertRegex(body, r'Assert\.areEqual\(\s*0,\s*\[\s*SELECT COUNT\(\)\s*FROM ' + table)
        self.assertIn('CronJobDetail.Name = :SalesTargetActualsSchedulable.JOB_NAME', body)
        for method in ('missingMutexBlocksEveryEntryWithoutProvisioning', 'anotherMachineBindingBlocksEveryEntry'):
            body = self.actuals.split('static void ' + method + '()', 1)[1].split('\n  }', 1)[0]
            self.assertIn('assertMutexEntriesFail()', body)

    def test_acceptance_methods_are_annotated_not_just_named(self):
        mapping = {
            'SalesTargetActualsTest': ('allLinesOwnerQuarterAndAttainment',  # AC1,2,3,8
                'lineAmountsCountDistinctAndDoNotUseOpportunityAmount',  # AC4
                'reopenReallocateAndEmptyReset', 'nullAmountCountsAsZero',  # AC5,9
                'volume250Targets6000ClosedOpportunities'),  # AC10 source only
            'SalesTargetCurrencyPolicyTest': ('keysCanonicalizeAndRejectCollisions',),  # AC6,7
        }
        for name, methods in mapping.items():
            source = (self.FOLDER / (name + '.cls')).read_text()
            self.assertRegex(source, r'@IsTest\(\s*testFor=')
            for method in methods:
                self.assertRegex(source, r'@IsTest\s+static void ' + method + r'\(\)')
            self.assertNotRegex(source, r'(?i)SeeAllData\s*=\s*true')

    def test_fixture_setup_is_independent_of_invoking_user_permissions(self):
        for name in ('Sales_Target_Manage', 'Discount_Sales_User', 'Product_Catalog_Manage'):
            self.assertIn("'" + name + "'", self.actuals)
        self.assertIn("'Sales_Target_Manage'", self.policy)
        self.assertIn('insert as system grants;', self.actuals)
        self.assertIn('Set<Id> fixtureActors = new Set<Id>{ users[25].Id };', self.actuals)
        self.assertNotIn('UserInfo.getUserId(), users[25].Id', self.actuals)
        for method in ('allLinesOwnerQuarterAndAttainment',
                       'lineAmountsCountDistinctAndDoNotUseOpportunityAmount',
                       'reopenReallocateAndEmptyReset', 'nullAmountCountsAsZero',
                       'yearRolloverCutoffAndFreshDimensions',
                       'inactiveRepStillCalculatesAndReassignmentFails',
                       'failedScopeKeepsOldValuesAndCanRetry',
                       'volume250Targets6000ClosedOpportunities'):
            setup = self.actuals.split('static void ' + method + '()', 1)[1].split('System.runAs(machine)', 1)[0]
            self.assertIn('insert as system', setup, method)
            self.assertNotIn('insert as user', setup, method)
        readback = self.actuals.split('private static Sales_Target__c stored(', 1)[1].split('private static SalesTargetActualsBatch batch(', 1)[0]
        self.assertIn('WITH SYSTEM_MODE', readback)
        self.assertIn('update as user new Opportunity', self.actuals)
        self.assertIn('update as user new Sales_Target__c', self.actuals)
        self.assertIn('WITH USER_MODE', self.policy)
        self.assertIn('insert as user row;', self.policy)
        for source in (self.actuals, self.policy):
            self.assertIn('AccessLevel.USER_MODE', source)
            self.assertNotRegex(source, r'(?i)SeeAllData\s*=\s*true')

    def test_security_personas_never_inherit_the_invoking_admin_profile(self):
        setup = self.policy.split('private static User persona(', 1)[0]
        self.assertIn("Name = 'Minimum Access - Salesforce'", setup)
        self.assertIn("UserLicense.Name = 'Salesforce'", setup)
        self.assertIn('PermissionsModifyAllData = FALSE', setup)
        self.assertIn('PermissionsViewAllData = FALSE', setup)
        self.assertIn('ProfileId = restricted.Id', setup)
        self.assertNotIn('UserInfo.getProfileId()', setup)
        denial = self.policy.split('private static void assertUserModeDenied(', 1)[1].split('@IsTest', 1)[0]
        self.assertIn('insert as user row;', denial)
        self.assertIn('update as user row;', denial)
        self.assertNotIn('as system', denial)

    def test_fls_and_validation_are_independent_security_assertions(self):
        for name in ('userModeProtectedFieldsRemainReadOnly', 'systemModeKeysAreStillCanonicalized'):
            self.assertRegex(self.policy, r'@IsTest\s+static void ' + name + r'\(\)')
        for field in ('Actual_Amount__c', 'Won_Opportunity_Count__c', 'Last_Calculated_At__c', 'Target_Key__c'):
            self.assertIn("'" + field + "'", self.policy)
        self.assertIn('Assert.isFalse(access.isCreateable()', self.policy)
        self.assertIn('Assert.isFalse(access.isUpdateable()', self.policy)
        self.assertIn('assertUserModeDenied(attemptedInsert, true)', self.policy)
        self.assertIn('assertUserModeDenied(change, false)', self.policy)
        self.assertIn('Database.update(clear, false, AccessLevel.SYSTEM_MODE)', self.policy)
        self.assertIn('Database.insert(row, false, AccessLevel.SYSTEM_MODE)', self.policy)
        self.assertIn('Database.update(change, false, AccessLevel.SYSTEM_MODE)', self.policy)

    def test_both_test_classes_are_package_candidates_with_active_api67_metadata(self):
        # Candidate inclusion only: Orchard's generated payload/selection is not in this repo.
        from fnmatch import fnmatchcase
        project = json.loads((ROOT / 'sfdx-project.json').read_text())
        packages = [p['path'].rstrip('/') + '/' for p in project['packageDirectories']]
        patterns = [p.strip() for p in (ROOT / '.forceignore').read_text().splitlines()
                    if p.strip() and not p.lstrip().startswith('#')]
        for name in ('SalesTargetActualsTest', 'SalesTargetCurrencyPolicyTest'):
            for suffix in ('.cls', '.cls-meta.xml'):
                file = self.FOLDER / (name + suffix)
                path = file.relative_to(ROOT).as_posix()
                self.assertTrue(file.is_file(), path)
                self.assertTrue(any(path.startswith(p) for p in packages), path)
                for pattern in patterns:
                    self.assertFalse(fnmatchcase(path, pattern), (path, pattern))
            ns = '{http://soap.sforce.com/2006/04/metadata}'
            metadata = ET.parse(self.FOLDER / (name + '.cls-meta.xml'))
            self.assertEqual('Active', metadata.find(ns + 'status').text)
            self.assertEqual('67.0', metadata.find(ns + 'apiVersion').text)

if __name__ == '__main__':
    unittest.main(verbosity=2)
