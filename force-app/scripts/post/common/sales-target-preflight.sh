#!/usr/bin/env bash
# Orchard action runner only. Data effects: scoped machine permission assignment and
# canonical Target_Key__c backfill. NEVER deploys metadata or disables protections.
# Post-baseline migration only: stage 1 metadata must already be installed.
# Never register as a pre-deployment review prerequisite. Stage 2 requires its receipt.
# Not registered for execution. Formal target-bound releaseInputs and machine
# execution binding must be published and verified before this adapter is enabled.
# Legacy environment variables are NOT an authorization or execution contract.
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
    line = row.get('Product_Line__c') or 'ALL'
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
    require(isinstance(value, str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)', value), 'Release expiry must be an explicit UTC ISO8601 timestamp')
    return dt.datetime.fromisoformat(value.replace('Z', '+00:00'))

def check_window():
    require(CONTEXT['expiresAt'] > dt.datetime.now(dt.timezone.utc), 'Release quiescence authorization expired')

def formula_matches(actual, expected):
    # The pinned formulas contain no string literals; ignore formatting only.
    def compact(value):
        require(isinstance(value, str), 'Missing protection formula')
        return re.sub(r'\s+', '', value)
    return compact(actual) == compact(expected)

STAGE_ONE_PROTECTION = 'AND(NOT($Permission.Sales_Target_System_Write),OR(AND(ISNEW(),OR(NOT(ISBLANK(Actual_Amount__c)),NOT(ISBLANK(Won_Opportunity_Count__c)),NOT(ISBLANK(Last_Calculated_At__c)),NOT(ISBLANK(Target_Key__c)))),AND(NOT(ISNEW()),OR(ISCHANGED(Actual_Amount__c),ISCHANGED(Won_Opportunity_Count__c),ISCHANGED(Last_Calculated_At__c),ISCHANGED(Target_Key__c)))))'
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

def verify_sales_rep_metadata(metadata):
    require(isinstance(metadata, dict), 'Missing Sales Rep metadata')
    expected = {'type': 'Lookup', 'referenceTo': 'User', 'label': 'Sales Rep',
                'relationshipName': 'Sales_Quarterly_Targets',
                'relationshipLabel': 'Sales Quarterly Targets', 'required': False}
    for name, value in expected.items():
        require(name in metadata and type(metadata[name]) is type(value) and metadata[name] == value,
                'Sales Rep preservation contract differs or is unverified: ' + name)
    require(not metadata.get('lookupFilter'), 'Stage-1 main metadata is not installed: active-only filter must be removed before backfill')
    # An omitted attribute is NOT evidence of Restrict. Preserve the existing field;
    # resolve this prerequisite evidence gap, never add a constraint speculatively.
    require(metadata.get('deleteConstraint') == 'Restrict',
            'Sales Rep deletion restriction is unverified or incompatible; prerequisite evidence required before migration')

def metadata_gates():
    entity = one(query("SELECT DurableId FROM EntityDefinition WHERE QualifiedApiName = 'Sales_Target__c'", True), 'target object')['DurableId']
    for name in ('System_Fields_Protected', 'Sales_Rep_Required', 'Active_Sales_Rep_On_Assignment'):
        rule = one(query('SELECT Id,Active FROM ValidationRule WHERE EntityDefinitionId = ' + quote(entity) + ' AND ValidationName = ' + quote(name), True), name)
        require(rule['Active'] is True, 'Required protection is inactive: ' + name)
        if name == 'System_Fields_Protected':
            detail = one(query('SELECT Metadata FROM ValidationRule WHERE Id = ' + quote(rule['Id']), True), 'protection rule metadata')['Metadata']
            require(formula_matches(detail.get('errorConditionFormula'), STAGE_ONE_PROTECTION), 'Stage-1 System_Fields_Protected formula differs from the pinned protection contract')
            require(detail.get('errorMessage') == PROTECTION_MESSAGE and not detail.get('errorDisplayField'), 'Protection rule message/location differs')
        if name == 'Sales_Rep_Required':
            detail = one(query('SELECT Metadata FROM ValidationRule WHERE Id = ' + quote(rule['Id']), True), 'required salesperson rule metadata')['Metadata']
            require(formula_matches(detail.get('errorConditionFormula'), 'ISBLANK(Sales_Rep__c)'), 'Sales Rep required rule differs')
            require(detail.get('errorDisplayField') == 'Sales_Rep__c' and detail.get('errorMessage') == 'Sales Rep is required.', 'Sales Rep required message/location differs')
        if name == 'Active_Sales_Rep_On_Assignment':
            detail = one(query('SELECT Metadata FROM ValidationRule WHERE Id = ' + quote(rule['Id']), True), 'assignment rule metadata')['Metadata']
            normalized = re.sub(r'\s+', '', detail.get('errorConditionFormula', '')).casefold()
            require(normalized == 'and(or(isnew(),ischanged(sales_rep__c)),not(sales_rep__r.isactive))', 'Assignment rule differs from approved formula')
            require(detail.get('errorDisplayField') == 'Sales_Rep__c' and detail.get('errorMessage') == 'Choose an active Sales Rep.', 'Assignment rule message/location differs')
    for name in ('Sales_Rep', 'Target_Key'):
        field = one(query('SELECT Id FROM CustomField WHERE TableEnumOrId = ' + quote(entity) + ' AND DeveloperName = ' + quote(name), True), name)
        metadata = one(query('SELECT Metadata FROM CustomField WHERE Id = ' + quote(field['Id']), True), name + ' metadata')['Metadata']
        if name == 'Sales_Rep':
            verify_sales_rep_metadata(metadata)
        else:
            require(metadata.get('type') == 'Text' and metadata.get('length') == 80 and metadata.get('unique') is True and metadata.get('caseSensitive') is False and metadata.get('externalId') is True, 'Unique key contract mismatch')

def backfill(chunk):
    # Expected dimensions + timestamp prevent overwriting edits since the audit.
    expected = [{k: r.get(k) for k in ('Id','Sales_Rep__c','Fiscal_Year__c','Fiscal_Quarter__c','Product_Line__c','Target_Key__c','SystemModstamp')} for r in chunk]
    body = '''
List<Sales_Target__c> expected = (List<Sales_Target__c>)JSON.deserialize(PAYLOAD, List<Sales_Target__c>.class);
Map<Id,Sales_Target__c> expectedById = new Map<Id,Sales_Target__c>(expected);
Set<Id> ids = expectedById.keySet();
List<Sales_Target__c> locked = [SELECT Id,Sales_Rep__c,Fiscal_Year__c,Fiscal_Quarter__c,Product_Line__c,Target_Key__c,SystemModstamp FROM Sales_Target__c WHERE Id IN :ids WITH SYSTEM_MODE FOR UPDATE];
System.assertEquals(expected.size(), locked.size(), 'Target disappeared during quiescence');
List<Sales_Target__c> updates = new List<Sales_Target__c>();
for (Sales_Target__c row : locked) {
    Sales_Target__c prior = expectedById.get(row.Id);
    System.assertEquals(prior.SystemModstamp, row.SystemModstamp, 'Concurrent target edit');
    System.assertEquals(prior.Sales_Rep__c, row.Sales_Rep__c);
    System.assertEquals(prior.Fiscal_Year__c, row.Fiscal_Year__c);
    System.assertEquals(prior.Fiscal_Quarter__c, row.Fiscal_Quarter__c);
    System.assertEquals(prior.Product_Line__c, row.Product_Line__c);
    System.assertEquals(prior.Target_Key__c, row.Target_Key__c);
    String key = String.valueOf(row.Sales_Rep__c) + '-' + String.valueOf(row.Fiscal_Year__c.intValue()) + '-' + row.Fiscal_Quarter__c + '-' + (String.isBlank(row.Product_Line__c) ? 'ALL' : row.Product_Line__c);
    updates.add(new Sales_Target__c(Id=row.Id, Target_Key__c=key));
}
System.assert(Datetime.now().getTime() < EXPIRY_MS, 'Release authorization expired before backfill DML');
Database.update(updates, true, AccessLevel.SYSTEM_MODE);
List<Sales_Target__c> saved = [SELECT Id,Target_Key__c FROM Sales_Target__c WHERE Id IN :ids WITH SYSTEM_MODE];
System.debug(LoggingLevel.ERROR, 'ST_PREFLIGHT:' + JSON.serialize(saved));
'''.replace('PAYLOAD', quote(json.dumps(expected, separators=(',', ':')))).replace('EXPIRY_MS', str(int(CONTEXT['expiresAt'].timestamp() * 1000)) + 'L')
    result = apex(body)
    expected_keys = {r['Id']: canonical(r) for r in chunk}
    require(len(result) == len(chunk) and {r['Id']:r.get('Target_Key__c') for r in result} == expected_keys, 'Chunk readback did not match canonical keys')
    emit('chunk_verified', count=len(chunk), idsHash=hashlib.sha256(json.dumps(sorted(expected_keys)).encode()).hexdigest())

try:
    # Deliberate fail-closed barrier, not a configurable override. Replace only after
    # the published platform binding is verified; legacy inputs cannot unlock it.
    raise GateError('Formal target-bound releaseInputs and machine execution binding are not verified; migration is disabled')
    org = one(query('SELECT Id,IsSandbox FROM Organization'), 'organization')
    require(org['Id'] == ORG and org['IsSandbox'] is True, 'Target is not the authorized nonproduction org')
    metadata_gates()
    actor = one(query('SELECT Id,IsActive,TimeZoneSidKey,Profile.PermissionsApiOnlyUser FROM User WHERE Id = ' + quote(USER)), 'machine user')
    require(actor['IsActive'] is True and actor['TimeZoneSidKey'] == 'America/Los_Angeles', 'Machine must be active with America/Los_Angeles timezone')
    require(one(query('SELECT Id,IsActive FROM User WHERE Id = ' + quote(owner)), 'operations owner')['IsActive'] is True, 'Operations owner must be active')
    api_only = actor['Profile']['PermissionsApiOnlyUser'] is True or bool(query('SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = ' + quote(USER) + ' AND PermissionSet.PermissionsApiOnlyUser = true LIMIT 1'))
    require(api_only, 'Configured machine must have effective API-only access, never a human identity')
    # Proves the authenticated identity and supported anonymous execution BEFORE granting anything.
    apex("System.debug(LoggingLevel.ERROR, 'ST_PREFLIGHT:true');", permission=False)
    permission = one(query("SELECT Id FROM PermissionSet WHERE Name = 'Sales_Target_System_Write_Access' AND NamespacePrefix = null"), 'existing machine permission set')['Id']
    assignment_query = 'SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = ' + quote(USER) + ' AND PermissionSetId = ' + quote(permission)
    if not query(assignment_query):
        try:
            cli(['data','create','record','--sobject','PermissionSetAssignment','--values',f'AssigneeId={USER} PermissionSetId={permission}'])
        except (GateError, subprocess.TimeoutExpired, ValueError):
            emit('assignment_uncertain_readback', present=bool(query(assignment_query)))
            raise
    one(query(assignment_query), 'machine assignment readback')
    state = apex("Boolean multi = Sales_Target__c.SObjectType.getDescribe().fields.getMap().containsKey('CurrencyIsoCode'); String corporate; if (multi) { List<SObject> rows = Database.queryWithBinds('SELECT IsoCode FROM CurrencyType WHERE IsCorporate = true', new Map<String,Object>(), AccessLevel.SYSTEM_MODE); System.assertEquals(1,rows.size()); corporate=(String)rows[0].get('IsoCode'); } System.debug(LoggingLevel.ERROR, 'ST_PREFLIGHT:' + JSON.serialize(new Map<String,Object>{'multi'=>multi,'corporate'=>corporate,'today'=>Datetime.now().format('yyyy-MM-dd','America/Los_Angeles')}));")
    MULTI, CORPORATE = state['multi'], state['corporate']
    require(isinstance(MULTI, bool) and (not MULTI or re.fullmatch(r'[A-Z]{3}', CORPORATE or '')), 'Unverified currency configuration')
    today = dt.date.fromisoformat(state['today'])
    before = target_rows()
    changes = audit_keys(before)
    audit_currencies(before, today)
    emit('audit_passed', orgId=ORG, artifactSha=CONTEXT['artifactSha'], targets=len(before), keysToBackfill=len(changes), approvalReference=CONTEXT['approvalReference'])
    for offset in range(0, len(changes), 100):
        chunk = changes[offset:offset+100]
        try:
            backfill(chunk)
        except (GateError, subprocess.TimeoutExpired, ValueError):
            # Read exact target state once; never replay an uncertain transaction.
            ids = ','.join(quote(r['Id']) for r in chunk)
            observed = system_query('SELECT Id,Target_Key__c FROM Sales_Target__c WHERE Id IN (' + ids + ') ORDER BY Id')
            emit('backfill_uncertain_readback', rows=len(observed), canonicalMatches=sum(r.get('Target_Key__c') == canonical(next(x for x in chunk if x['Id']==r['Id'])) for r in observed))
            raise
    after = target_rows()
    require({r['Id']:canonical(r) for r in before} == {r['Id']:canonical(r) for r in after}, 'Targets changed during quiescence')
    require(not audit_keys(after), 'Final audit has blank or mismatched keys')
    audit_currencies(after, today)
    check_window()
    emit('backfill_verified', orgId=ORG, artifactSha=CONTEXT['artifactSha'], targets=len(after), blankKeys=0, mismatchedKeys=0, duplicateKeys=0, writesRemainQuiesced=True, keyDigest=hashlib.sha256(json.dumps(sorted((r['Id'],r['Target_Key__c']) for r in after)).encode()).hexdigest())
except (GateError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError, OSError) as exc:
    emit('blocked', reason=str(exc) if isinstance(exc, GateError) else type(exc).__name__, writesRemainQuiesced=True, retry='Do not replay uncertain writes. Inspect current assignment/keys and obtain a fresh release window; rerun performs a new full audit.')
    sys.exit(1)
PY
