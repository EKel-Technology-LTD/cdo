#!/usr/bin/env bash
# Orchard action runner only. Schedules only the authorized machine-owned daily job.
# No permission assignment, migration, metadata deployment or automatic writer resume.
# Requires the separately provisioned DAILY_ACTUALS mutex bound to this machine;
# createOwnedSchedule fails closed and never creates or repairs that record.
# MANDATORY RELEASE PREREQUISITE (separately VERIFIED, never inferred):
# Before any persistent mutex-record provisioning OR activation, the release owner
# must retain exact-target evidence that Grant Access Using Hierarchies is disabled
# for Sales_Target_Mutex__c. Record target/org, source revision, verifier, timestamp
# and observed disabled setting in release evidence. Missing or inconclusive proof
# blocks provisioning and activation; neither Private OWD, enableSharing, omitted
# XML nor successful check-only validation proves this setting. The runner's
# authorization file is not hierarchy-access evidence. Do not run this action
# until that separate mandatory gate is verified under future release approval.
# Preserve Private internal/external sharing, no CRUD grants, and fail-closed
# machine binding. This source correction authorizes NO org changes, persistent
# lock creation, backfill, permission assignment, schedule activation or release.
# Stage 2 must already be installed and keys must pass a fresh exhaustive audit.
# Uses only the declared Orchard releaseInputs contract (platform 1.2.1345,
# 6a541555b86616f6de4cffb9b3144fb100ada9de). The runner verifies the exact
# source SHA/target fingerprint and separately authenticates the machine before
# supplying its 0600 authorization file and authenticated username. No login here.
# Keep writers quiesced through stage-2 activation; no automatic writer resume.
set -euo pipefail
: "${ORCHARD_TARGET_ORG:?Orchard must supply the authenticated target alias}"
[[ $# -eq 1 && "$1" == "$ORCHARD_TARGET_ORG" ]] || { echo 'Target arguments disagree' >&2; exit 1; }
command -v sf >/dev/null
command -v python3 >/dev/null
python3 - "$1" <<'PY'
import datetime as dt
import hashlib
import json
import os
import stat
import re
import subprocess
import sys
import time

class GateError(Exception):
    pass

def require(condition, message):
    if not condition:
        raise GateError(message)

def sfid(value, prefix=None):
    require(isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9]{18}', value), 'Expected an 18-character Salesforce ID')
    alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'
    suffix = ''.join(alphabet[sum(1 << j for j, c in enumerate(value[i:i+5]) if c.isupper())] for i in (0, 5, 10))
    require(value[15:] == suffix, 'Invalid Salesforce ID checksum')
    require(prefix is None or value.startswith(prefix), 'Unexpected Salesforce ID type')
    return value

def quote(value):
    return "'" + str(value).replace('\\', '\\\\').replace("'", "\\'").replace('\n', '\\n').replace('\r', '\\r') + "'"

def canonical(row):
    rep = sfid(row.get('Sales_Rep__c'), '005')
    year = row.get('Fiscal_Year__c')
    require(isinstance(year, (int, float)) and not isinstance(year, bool) and int(year) == year and 2025 <= year <= 2030, 'Invalid target year; owner correction required')
    quarter = row.get('Fiscal_Quarter__c')
    require(quarter in ('Q1', 'Q2', 'Q3', 'Q4'), 'Invalid target quarter')
    value = row.get('Product_Line__c')
    require(value is None or isinstance(value, str), 'Invalid product-line API value')
    line = 'ALL' if value in (None, '') else value
    require(line == 'ALL' or re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*', line), 'Invalid product-line API value')
    key = f'{rep}-{int(year)}-{quarter}-{line}'
    require(len(key) <= 80, 'Canonical key exceeds existing Text80 field')
    return key

def audit_keys(rows):
    by_key, changes = {}, []
    for row in rows:
        key = canonical(row)
        require(key.casefold() not in by_key, 'Duplicate business dimensions: owner must resolve; no records changed or deleted by this audit')
        by_key[key.casefold()] = row['Id']
        if row.get('Target_Key__c') != key:
            changes.append(row)
    # Never clear or swap occupied legacy keys automatically.
    for row in rows:
        stored = row.get('Target_Key__c')
        require(not stored or by_key.get(stored.casefold(), row['Id']) == row['Id'], 'A legacy key occupies another canonical key; owner correction required')
    return changes

def period(row):
    year = int(row['Fiscal_Year__c'])
    month = 1 + 3 * (int(row['Fiscal_Quarter__c'][1]) - 1)
    start = dt.date(year, month, 1)
    end = (dt.date(year + 1, 1, 1) if month == 10 else dt.date(year, month + 3, 1)) - dt.timedelta(days=1)
    require(row.get('Period_Start__c') == start.isoformat() and row.get('Period_End__c') == end.isoformat(), 'Delivered date formulas do not match calendar-quarter contract')
    return start, end

def previous_quarter(today):
    start = dt.date(today.year, 1 + 3 * ((today.month - 1) // 3), 1)
    return dt.date(start.year - 1, 10, 1) if start.month == 1 else dt.date(start.year, start.month - 3, 1)

def emit(event, **values):
    print(json.dumps(dict(event=event, **values), sort_keys=True), flush=True)

START = time.monotonic()
TARGET = sys.argv[1]
CONTEXT = None
MACHINE = None
ORG = None
USER = None

def remaining():
    seconds = 540 - (time.monotonic() - START)
    require(seconds > 15, 'Action budget exhausted; retain quiescence and read current keys before a separately authorized rerun')
    return min(90, seconds)

def cli(args, org= None, source=None):
    check_window()
    # No retries: timeout/nonzero may hide a committed write.
    result = subprocess.run(['sf', *args, '--target-org', org or TARGET, '--api-version', '67.0', '--json'], input=source, text=True, capture_output=True, timeout=remaining())
    require(result.returncode == 0, 'Salesforce CLI operation failed; inspect the runner receipt, do not blindly replay writes')
    payload = json.loads(result.stdout)
    require(payload.get('status') == 0 and 'result' in payload, 'Salesforce returned an unsuccessful or incomplete envelope')
    return payload['result']

def query(soql, tooling=False, org=None):
    args = ['data', 'query', '--query', soql]
    if tooling:
        args += ['--use-tooling-api']
    result = cli(args, org)
    rows = result.get('records')
    require(isinstance(rows, list) and result.get('done') is True and result.get('totalSize') == len(rows), 'Incomplete configuration query; cannot treat partial evidence as absence')
    return rows

def one(rows, purpose):
    require(len(rows) == 1, 'Expected exactly one ' + purpose)
    return rows[0]

def parse_expiry(value):
    require(isinstance(value, str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z', value), 'Release expiry must be an explicit UTC ISO8601 timestamp')
    return dt.datetime.fromisoformat(value.replace('Z', '+00:00'))

def check_window():
    require(CONTEXT['expiresAt'] > dt.datetime.now(dt.timezone.utc), 'Release quiescence authorization expired')

def formula_matches(actual, expected):
    # Compare tokens, not whitespace-stripped text: never merge identifiers or
    # change whitespace/escapes inside literals. Unknown syntax fails closed.
    def tokens(value):
        require(isinstance(value, str) and value.strip(), 'Missing protection formula')
        pattern = re.compile('\\s+|"(?:\\\\.|[^"\\\\])*"|\'(?:\\\\.|[^\'\\\\])*\'|[A-Za-z_$][A-Za-z0-9_$]*|[0-9]+(?:\\.[0-9]+)?|<>|!=|<=|>=|&&|\\|\\||[().,=<>+*/&!^%-]')
        result, pos = [], 0
        while pos < len(value):
            match = pattern.match(value, pos)
            require(match is not None, 'Unsupported protection formula syntax')
            token = match.group()
            if not token.isspace():
                result.append(token)
            pos = match.end()
        return result
    return tokens(actual) == tokens(expected)

def unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate authorization JSON key')
        result[key] = value
    return result

def validate_authorization(raw, now):
    # Exact source/target equality is enforced by prepareReleaseInputs in Orchard,
    # NOT by comparing these values to themselves or inventing extra env inputs.
    fields = {'orgId', 'machineUserId', 'operationsOwnerId', 'artifactSha',
              'targetFingerprint', 'approvalReference', 'syntheticOnly',
              'writesQuiesced', 'expiresAt'}
    require(isinstance(raw, dict) and set(raw) == fields, 'Authorization must contain exactly the nine declared fields')
    for field, prefix in (('orgId', '00D'), ('machineUserId', '005'), ('operationsOwnerId', '005')):
        sfid(raw[field], prefix)
    for field, length in (('artifactSha', 40), ('targetFingerprint', 64)):
        require(isinstance(raw[field], str) and re.fullmatch('[0-9a-f]{' + str(length) + '}', raw[field]), 'Invalid authorization pin: ' + field)
    require(raw['syntheticOnly'] is True and raw['writesQuiesced'] is True, 'Explicit synthetic-only and write-quiescence authorization required')
    reference = raw['approvalReference']
    require(isinstance(reference, str) and reference.strip() and len(reference) <= 500, 'Human approval reference is required')
    expiry = parse_expiry(raw['expiresAt'])
    require(expiry > now, 'Release quiescence authorization expired')
    return dict(raw, expiresAt=expiry)

def verify_authorized_org(context, observed):
    require(isinstance(observed, dict) and observed.get('Id') == context['orgId'] and observed.get('IsSandbox') is True,
            'Target is not the authorized nonproduction org')

def verify_machine_actor(context, actor, owner, api_only):
    require(isinstance(actor, dict) and actor.get('Id') == context['machineUserId'], 'Machine identity differs from authorization')
    require(actor.get('IsActive') is True and actor.get('TimeZoneSidKey') == 'America/Los_Angeles', 'Machine must be active with America/Los_Angeles timezone')
    require(isinstance(owner, dict) and owner.get('Id') == context['operationsOwnerId'] and owner.get('IsActive') is True, 'Authorized operations owner must be active')
    require(api_only is True, 'Configured machine must have effective API-only access, never a human identity')

def load_release_inputs():
    path = os.environ.get('SALES_TARGET_RELEASE_CONTEXT')
    machine = os.environ.get('SALES_TARGET_MACHINE_ORG')
    require(isinstance(path, str) and os.path.isabs(path), 'Missing declared authorization file path')
    require(isinstance(machine, str) and machine.strip() == machine and machine and not machine.startswith('-') and not any(c.isspace() for c in machine), 'Missing declared authenticated machine username')
    # No secret token is read, logged or passed to a subprocess by this script.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'r', encoding='utf-8') as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600 and info.st_uid == os.geteuid(), 'Authorization file must be runner-owned regular mode 0600')
        text = stream.read(16385)
        require(len(text) <= 16384, 'Authorization file exceeds bounded size')
        raw = json.loads(text, object_pairs_hook=unique_json_object)
    return validate_authorization(raw, dt.datetime.now(dt.timezone.utc)), machine

STAGE_TWO_PROTECTION = 'OR(AND(NOT($Permission.Sales_Target_System_Write),OR(AND(ISNEW(),OR(NOT(ISBLANK(Actual_Amount__c)),NOT(ISBLANK(Won_Opportunity_Count__c)),NOT(ISBLANK(Last_Calculated_At__c)))),AND(NOT(ISNEW()),OR(ISCHANGED(Actual_Amount__c),ISCHANGED(Won_Opportunity_Count__c),ISCHANGED(Last_Calculated_At__c))))),ISBLANK(Target_Key__c),Target_Key__c<>(CASESAFEID(Sales_Rep__c)&"-"&TEXT(Fiscal_Year__c)&"-"&TEXT(Fiscal_Quarter__c)&"-"&BLANKVALUE(TEXT(Product_Line__c),"ALL")))'
PROTECTION_MESSAGE = 'Actuals and target keys can only be changed by the system.'

def apex(body, permission=True):
    check_window()
    prefix = 'System.assertEquals(' + quote(ORG) + ', String.valueOf(UserInfo.getOrganizationId()), \'Wrong org\');\n'
    prefix += 'System.assertEquals(' + quote(USER) + ', String.valueOf(UserInfo.getUserId()), \'Wrong machine\');\n'
    prefix += "System.assert([SELECT IsSandbox FROM Organization WITH SYSTEM_MODE LIMIT 1].IsSandbox, 'Nonproduction only');\n"
    if permission:
        prefix += "System.assert(FeatureManagement.checkPermission('Sales_Target_System_Write'), 'Missing machine permission');\n"
    expiry_ms = int(CONTEXT['expiresAt'].timestamp() * 1000)
    prefix += 'System.assert(Datetime.now().getTime() < ' + str(expiry_ms) + 'L, \'Release authorization expired\');\n'
    result = cli(['apex', 'run', '--file', '/dev/stdin'], MACHINE, prefix + body)
    require(result.get('compiled') is True and result.get('success') is True, 'Anonymous Apex compile/execution failed; no success inferred')
    messages = re.findall(r'\|USER_DEBUG\|\[\d+\]\|ERROR\|ST_PREFLIGHT:(.*)', result.get('logs', ''))
    require(len(messages) == 1, 'Missing/truncated/ambiguous Apex readback marker')
    return json.loads(messages[0])

def system_query(soql):
    # Approved system-mode audit is independent of the API user's business FLS/sharing.
    return apex('List<SObject> rows = Database.queryWithBinds(' + quote(soql) + ", new Map<String,Object>(), AccessLevel.SYSTEM_MODE);\nSystem.debug(LoggingLevel.ERROR, 'ST_PREFLIGHT:' + JSON.serialize(rows));")

def target_rows():
    rows, last = [], None
    while True:
        condition = ' WHERE Id > ' + quote(last) if last else ''
        page = system_query('SELECT Id,Sales_Rep__c,Fiscal_Year__c,Fiscal_Quarter__c,Product_Line__c,Target_Key__c,Period_Start__c,Period_End__c,SystemModstamp' + (',CurrencyIsoCode' if MULTI else '') + ' FROM Sales_Target__c' + condition + ' ORDER BY Id LIMIT 200')
        require(isinstance(page, list) and len(page) <= 200, 'Malformed target page')
        if not page:
            break
        ids = [sfid(r['Id']) for r in page]
        require(ids == sorted(set(ids)) and (last is None or ids[0] > last), 'Target pagination did not advance')
        rows.extend(page)
        last = ids[-1]
    return rows

def audit_currencies(rows, today):
    for row in rows:
        period(row)
        if MULTI:
            require(row.get('CurrencyIsoCode') == CORPORATE, 'Foreign target currency; no conversion or relabeling allowed')
    if not MULTI:
        return
    eligible = [r for r in rows if period(r)[0] <= today and period(r)[1] >= previous_quarter(today)]
    for offset in range(0, len(eligible), 25):
        all_conditions, line_conditions = [], []
        for row in eligible[offset:offset+25]:
            start, end = period(row)
            end = min(end, today - dt.timedelta(days=1))
            if start > end:
                continue
            def condition(prefix):
                return '(' + prefix + 'OwnerId = ' + quote(row['Sales_Rep__c']) + ' AND ' + prefix + 'IsWon = true AND ' + prefix + 'CloseDate >= ' + start.isoformat() + ' AND ' + prefix + 'CloseDate <= ' + end.isoformat() + ')'
            if not row.get('Product_Line__c'):
                all_conditions.append(condition(''))
            else:
                line_conditions.append('(' + condition('Opportunity.') + ' AND Product2.Product_Line__c = ' + quote(row['Product_Line__c']) + ')')
        if all_conditions:
            bad = system_query('SELECT Id FROM Opportunity WHERE (' + ' OR '.join(all_conditions) + ') AND CurrencyIsoCode != ' + quote(CORPORATE) + ' LIMIT 1')
            require(not bad, 'Foreign eligible opportunity currency; conversion is out of scope')
        if line_conditions:
            bad = system_query('SELECT Id FROM OpportunityLineItem WHERE (' + ' OR '.join(line_conditions) + ') AND (CurrencyIsoCode != ' + quote(CORPORATE) + ' OR Opportunity.CurrencyIsoCode != ' + quote(CORPORATE) + ') LIMIT 1')
            require(not bad, 'Foreign eligible opportunity/product-line currency; conversion is out of scope')

def verify_sales_rep_metadata(metadata, user_describe):
    require(isinstance(metadata, dict), 'Missing Sales Rep metadata')
    expected = {'type': 'Lookup', 'referenceTo': 'User', 'label': 'Sales Rep',
                'relationshipName': 'Sales_Quarterly_Targets',
                'relationshipLabel': 'Sales Quarterly Targets', 'required': False}
    for name, value in expected.items():
        require(name in metadata and type(metadata[name]) is type(value) and metadata[name] == value,
                'Sales Rep preservation contract differs or is unverified: ' + name)
    require(not metadata.get('lookupFilter'), 'Stage-1 main metadata is not installed: active-only filter must be removed before backfill')
    # Reconciled API67 User lookup: SetNull is serialized, but User cannot be
    # deleted. Never claim omitted deletion metadata proves Restrict.
    require(metadata.get('deleteConstraint') == 'SetNull', 'Sales Rep deletion constraint differs or is unverified')
    require(isinstance(user_describe, dict) and user_describe.get('name') == 'User' and user_describe.get('deletable') is False,
            'User non-deletability must be explicit')

def metadata_gates():
    entity = one(query("SELECT DurableId FROM EntityDefinition WHERE QualifiedApiName = 'Sales_Target__c'", True), 'target object')['DurableId']
    for name in ('System_Fields_Protected', 'Sales_Rep_Required', 'Active_Sales_Rep_On_Assignment'):
        rule = one(query('SELECT Id,Active FROM ValidationRule WHERE EntityDefinitionId = ' + quote(entity) + ' AND ValidationName = ' + quote(name), True), name)
        require(rule['Active'] is True, 'Required protection is inactive: ' + name)
        if name == 'System_Fields_Protected':
            detail = one(query('SELECT Metadata FROM ValidationRule WHERE Id = ' + quote(rule['Id']), True), 'protection rule metadata')['Metadata']
            require(formula_matches(detail.get('errorConditionFormula'), STAGE_TWO_PROTECTION), 'Stage-2 System_Fields_Protected formula differs from the pinned protection contract')
            require(detail.get('errorMessage') == PROTECTION_MESSAGE and not detail.get('errorDisplayField'), 'Protection rule message/location differs')
        if name == 'Sales_Rep_Required':
            detail = one(query('SELECT Metadata FROM ValidationRule WHERE Id = ' + quote(rule['Id']), True), 'required salesperson rule metadata')['Metadata']
            require(formula_matches(detail.get('errorConditionFormula'), 'ISBLANK(Sales_Rep__c)'), 'Sales Rep required rule differs')
            require(detail.get('errorDisplayField') == 'Sales_Rep__c' and detail.get('errorMessage') == 'Sales Rep is required.', 'Sales Rep required message/location differs')
        if name == 'Active_Sales_Rep_On_Assignment':
            detail = one(query('SELECT Metadata FROM ValidationRule WHERE Id = ' + quote(rule['Id']), True), 'assignment rule metadata')['Metadata']
            require(formula_matches(detail.get('errorConditionFormula'), 'AND(OR(ISNEW(),ISCHANGED(Sales_Rep__c)),NOT(Sales_Rep__r.IsActive))'), 'Assignment rule differs from approved formula')
            require(detail.get('errorDisplayField') == 'Sales_Rep__c' and detail.get('errorMessage') == 'Choose an active Sales Rep.', 'Assignment rule message/location differs')
    for name in ('Sales_Rep', 'Target_Key'):
        field = one(query('SELECT Id FROM CustomField WHERE TableEnumOrId = ' + quote(entity) + ' AND DeveloperName = ' + quote(name), True), name)
        metadata = one(query('SELECT Metadata FROM CustomField WHERE Id = ' + quote(field['Id']), True), name + ' metadata')['Metadata']
        if name == 'Sales_Rep':
            verify_sales_rep_metadata(metadata, cli(['sobject', 'describe', '--sobject', 'User']))
        else:
            require(metadata.get('type') == 'Text' and metadata.get('length') == 80 and metadata.get('unique') is True and metadata.get('caseSensitive') is False and metadata.get('externalId') is True, 'Unique key contract mismatch')

def verify_schedule(rows):
    job = one(rows, 'owned daily schedule')
    require(job.get('OwnerId') == USER, 'Schedule owner is not the authorized machine')
    require(job.get('TimeZoneSidKey') == 'America/Los_Angeles', 'Schedule timezone differs')
    require(job.get('CronExpression') == '0 0 2 * * ?', 'Schedule cron differs')
    require(job.get('State') == 'WAITING' and job.get('NextFireTime'), 'Schedule is not waiting with a next fire time')
    sfid(job.get('Id'), '08e')
    next_fire = dt.datetime.fromisoformat(job['NextFireTime'].replace('Z', '+00:00'))
    require(next_fire.tzinfo is not None and next_fire > dt.datetime.now(dt.timezone.utc), 'Next fire time is not a future zoned timestamp')
    return job

def schedule_rows():
    return query("SELECT Id,OwnerId,TimeZoneSidKey,CronExpression,NextFireTime,State FROM CronTrigger WHERE CronJobDetail.Name = 'Sales Target Daily Actuals' AND State NOT IN ('DELETED','COMPLETE')", org=MACHINE)

def verify_schedule_binding(job):
    # API67 AsyncApexJob.CronTriggerId was reconciled through org describe.
    bindings = query('SELECT Id,ApexClass.Name,CreatedById FROM AsyncApexJob WHERE JobType = \'ScheduledApex\' AND CronTriggerId = ' + quote(job['Id']), org=MACHINE)
    require(bindings and all(r.get('ApexClass', {}).get('Name') == 'SalesTargetActualsSchedulable' and r.get('CreatedById') == USER for r in bindings), 'Named schedule is not proven to be the owned scheduler class')
    verify_schedule_inventory(job['Id'])
    return [sfid(r['Id'], '707') for r in bindings]

def verify_schedule_inventory(expected_id=None):
    active = query("SELECT Id FROM CronTrigger WHERE State NOT IN ('DELETED','COMPLETE')", org=MACHINE)
    active_ids = {r['Id'] for r in active}
    own = query("SELECT Id,CronTriggerId FROM AsyncApexJob WHERE JobType='ScheduledApex' AND ApexClass.Name='SalesTargetActualsSchedulable'", org=MACHINE)
    expected = set() if expected_id is None else {expected_id}
    require({r.get('CronTriggerId') for r in own if r.get('CronTriggerId') in active_ids} == expected, 'Another active actuals schedule exists; preserve it and resolve ownership before activation')

def verify_active_flow():
    definition = one(query("SELECT Id,ActiveVersionId FROM FlowDefinition WHERE DeveloperName='Sales_Target_Set_Unique_Key' AND NamespacePrefix=null", True), 'key Flow definition')
    version = sfid(definition.get('ActiveVersionId'))
    metadata = one(query('SELECT Metadata FROM Flow WHERE Id = ' + quote(version), True), 'active key Flow metadata')['Metadata']
    require(metadata.get('status') == 'Active' and float(metadata.get('apiVersion', 0)) == 67.0, 'Key Flow is not the approved active API67 version')
    start = metadata.get('start') or {}
    require(start.get('object') == 'Sales_Target__c' and start.get('recordTriggerType') == 'CreateAndUpdate' and start.get('triggerType') == 'RecordBeforeSave', 'Key Flow trigger differs')
    formulas = metadata.get('formulas') or []
    canonical_formula = 'CASESAFEID({!$Record.Sales_Rep__c})&"-"&TEXT({!$Record.Fiscal_Year__c})&"-"&TEXT({!$Record.Fiscal_Quarter__c})&"-"&BLANKVALUE(TEXT({!$Record.Product_Line__c}),"ALL")'
    require(len(formulas) == 1 and formulas[0].get('name') == 'Canonical_Key' and formulas[0].get('expression') == canonical_formula, 'Active key Flow canonical formula differs')
    return version

try:
    CONTEXT, MACHINE = load_release_inputs()
    ORG, USER, owner = CONTEXT['orgId'], CONTEXT['machineUserId'], CONTEXT['operationsOwnerId']
    verify_authorized_org(CONTEXT, one(query('SELECT Id,IsSandbox FROM Organization'), 'deployment organization'))
    verify_authorized_org(CONTEXT, one(query('SELECT Id,IsSandbox FROM Organization', org=MACHINE), 'machine organization'))
    metadata_gates()
    flow_version = verify_active_flow()
    actor = one(query('SELECT Id,IsActive,TimeZoneSidKey,Profile.PermissionsApiOnlyUser FROM User WHERE Id = ' + quote(USER)), 'machine user')
    operations_owner = one(query('SELECT Id,IsActive FROM User WHERE Id = ' + quote(owner)), 'operations owner')
    api_only = actor['Profile']['PermissionsApiOnlyUser'] is True or bool(query('SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = ' + quote(USER) + ' AND PermissionSet.PermissionsApiOnlyUser = true LIMIT 1'))
    verify_machine_actor(CONTEXT, actor, operations_owner, api_only)
    one(query("SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = " + quote(USER) + " AND PermissionSet.Name = 'Sales_Target_System_Write_Access' AND PermissionSet.NamespacePrefix = null"), 'existing machine permission assignment')
    state = apex("Boolean multi = Sales_Target__c.SObjectType.getDescribe().fields.getMap().containsKey('CurrencyIsoCode'); String corporate; if (multi) { List<SObject> rows = Database.queryWithBinds('SELECT IsoCode FROM CurrencyType WHERE IsCorporate = true', new Map<String,Object>(), AccessLevel.SYSTEM_MODE); System.assertEquals(1,rows.size()); corporate=(String)rows[0].get('IsoCode'); } System.debug(LoggingLevel.ERROR, 'ST_PREFLIGHT:' + JSON.serialize(new Map<String,Object>{'multi'=>multi,'corporate'=>corporate,'today'=>Datetime.now().format('yyyy-MM-dd','America/Los_Angeles')}));")
    MULTI, CORPORATE = state['multi'], state['corporate']
    require(isinstance(MULTI, bool) and (not MULTI or re.fullmatch(r'[A-Z]{3}', CORPORATE or '')), 'Unverified currency configuration')
    today = dt.date.fromisoformat(state['today'])
    before = target_rows()
    require(not audit_keys(before), 'Activation requires zero blank, mismatched or duplicate keys')
    audit_currencies(before, today)
    existing = schedule_rows()
    if existing:
        verify_schedule_binding(verify_schedule(existing))
    else:
        verify_schedule_inventory()
        try:
            apex("Id jobId=SalesTargetActualsSchedulable.createOwnedSchedule(); System.debug(LoggingLevel.ERROR,'ST_PREFLIGHT:'+JSON.serialize(jobId));")
        except (GateError, subprocess.TimeoutExpired, ValueError):
            emit('schedule_uncertain_readback', schedules=schedule_rows())
            raise
    job = verify_schedule(schedule_rows())
    scheduled_apex_ids = verify_schedule_binding(job)
    after = target_rows()
    require({r['Id']:canonical(r) for r in before} == {r['Id']:canonical(r) for r in after} and not audit_keys(after), 'Targets changed during activation quiescence')
    audit_currencies(after, today)
    check_window()
    emit('activation_verified', orgId=ORG, artifactSha=CONTEXT['artifactSha'], targetFingerprint=CONTEXT['targetFingerprint'], machineUserId=USER, operationsOwnerId=owner, approvalReference=CONTEXT['approvalReference'], flowVersionId=flow_version, schedule=job, scheduledApexIds=scheduled_apex_ids, targets=len(after), blankKeys=0, mismatchedKeys=0, duplicateKeys=0, writesRemainQuiesced=True, resume='Authorized operations owner may now end the approved write-quiescence window; this action does not change access or maintenance controls.')
except (GateError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError, OSError) as exc:
    emit('blocked', reason=str(exc) if isinstance(exc, GateError) else type(exc).__name__, writesRemainQuiesced=True, retry='Do not replay uncertain scheduling. Read the exact owned job; preserve unrelated jobs and successful actuals. A separately approved rollback stops only the verified owned CronTrigger ID with SalesTargetActualsSchedulable.stopOwnedSchedule() under the machine identity. Recovery uses SalesTargetActualsSchedulable.launch().')
    sys.exit(1)
PY
