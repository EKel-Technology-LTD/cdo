#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 1 && -n "${ORCHARD_TARGET_ORG:-}" && "$1" == "$ORCHARD_TARGET_ORG" ]] || { echo 'Target mismatch' >&2; exit 1; }
# No inferred recipients. The client administrator supplies an explicit target-bound roster.
# CASE_SUMMARY_APPROVED_ROSTER_JSON: {"orgId":"...","approvalReference":"...","userIds":["..."]}
python3 - "$1" <<'PY'
import json, os, re, subprocess, sys
org=sys.argv[1]
def sf(*args):
    p=subprocess.run(['sf',*args,'--target-org',org,'--json'],capture_output=True,text=True,timeout=120)
    try: response=json.loads(p.stdout)
    except (ValueError,TypeError): raise RuntimeError('Invalid Salesforce receipt')
    if p.returncode or response.get('status')!=0: raise RuntimeError('Assignment operation failed; inspect Orchard receipt before retry')
    return response['result']
def query(soql):
    result=sf('data','query','--query',soql)
    if result.get('done') is not True or result.get('totalSize')!=len(result.get('records',[])): raise RuntimeError('Incomplete inventory')
    return result['records']
def valid_id(value,prefix):
    if not isinstance(value,str) or not re.fullmatch(prefix+r'[A-Za-z0-9]{15}',value): return False
    chars='ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'
    suffix=''.join(chars[sum(1<<j for j,c in enumerate(value[i:i+5]) if c.isupper())] for i in (0,5,10))
    return value[15:]==suffix
try:
    roster=json.loads(os.environ.get('CASE_SUMMARY_APPROVED_ROSTER_JSON','null'))
    if not isinstance(roster,dict) or set(roster)!={'orgId','approvalReference','userIds'}: raise RuntimeError('Approved target-bound roster is required; no assignments attempted')
    ids=roster['userIds']
    if not valid_id(roster['orgId'],'00D') or not isinstance(roster['approvalReference'],str) or not roster['approvalReference'].strip(): raise RuntimeError('Invalid roster authorization')
    if not isinstance(ids,list) or not ids or len(ids)>200 or len(set(ids))!=len(ids) or not all(valid_id(v,'005') for v in ids): raise RuntimeError('Invalid roster IDs')
    organization=query('SELECT Id,IsSandbox FROM Organization')
    if len(organization)!=1 or organization[0]['IsSandbox'] is not True or organization[0]['Id']!=roster['orgId']: raise RuntimeError('Unauthorized target; nonproduction only')
    clause=','.join("'"+value+"'" for value in ids)
    users=query('SELECT Id,IsActive FROM User WHERE Id IN ('+clause+')')
    if {u['Id'] for u in users}!=set(ids) or not all(u['IsActive'] for u in users): raise RuntimeError('All approved recipients must be active')
    licenses=query("SELECT Id,MasterLabel,Status,TotalLicenses,UsedLicenses FROM PermissionSetLicense WHERE MasterLabel = 'Agentforce (Default)'")
    if len(licenses)!=1 or licenses[0]['Status']!='Active': raise RuntimeError('Agentforce (Default) entitlement is unavailable or ambiguous')
    license_id=licenses[0]['Id']
    sets=query("SELECT Id FROM PermissionSet WHERE Name = 'Case_Summary_Generation' AND IsOwnedByProfile = false")
    if len(sets)!=1: raise RuntimeError('Generation permission set is unavailable or ambiguous')
    psid=sets[0]['Id']
    entitled={r['AssigneeId'] for r in query("SELECT AssigneeId FROM PermissionSetLicenseAssign WHERE PermissionSetLicenseId = '"+license_id+"' AND AssigneeId IN ("+clause+")")}
    granted={r['AssigneeId'] for r in query("SELECT AssigneeId FROM PermissionSetAssignment WHERE PermissionSetId = '"+psid+"' AND AssigneeId IN ("+clause+")")}
    if licenses[0]['TotalLicenses']-licenses[0]['UsedLicenses']<len(set(ids)-entitled): raise RuntimeError('Insufficient license capacity; no writes attempted')
    for uid in ids:
        if uid not in entitled: sf('data','create','record','--sobject','PermissionSetLicenseAssign','--values','AssigneeId='+uid+' PermissionSetLicenseId='+license_id)
        if uid not in granted: sf('data','create','record','--sobject','PermissionSetAssignment','--values','AssigneeId='+uid+' PermissionSetId='+psid)
    verified_licenses={r['AssigneeId'] for r in query("SELECT AssigneeId FROM PermissionSetLicenseAssign WHERE PermissionSetLicenseId = '"+license_id+"' AND AssigneeId IN ("+clause+")")}
    verified_sets={r['AssigneeId'] for r in query("SELECT AssigneeId FROM PermissionSetAssignment WHERE PermissionSetId = '"+psid+"' AND AssigneeId IN ("+clause+")")}
    if verified_licenses!=set(ids) or verified_sets!=set(ids): raise RuntimeError('Assignment readback mismatch')
    print(json.dumps({'orgId':organization[0]['Id'],'verifiedRecipients':len(ids),'permissionSet':'Case_Summary_Generation','entitlement':'Agentforce (Default)'}))
except Exception as error:
    print('Case summary access blocked: '+str(error),file=sys.stderr);sys.exit(1)
PY
