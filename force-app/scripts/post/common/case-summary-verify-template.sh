#!/usr/bin/env bash
set -euo pipefail
# The committed generated active-version identifier makes the page deployable in one batch.
# Verify that exact version after deployment without changing the target.
# Orchard runs this in a bare project that holds only this script, so the expected values live here.
# tools/test_case_summary_verify.py fails when they drift from the committed template.
[[ $# -eq 1 && -n "${ORCHARD_TARGET_ORG:-}" && "$1" == "$ORCHARD_TARGET_ORG" ]] || { echo 'Target mismatch' >&2; exit 1; }
python3 - "$1" <<'PY'
import json, pathlib, subprocess, sys, tempfile, xml.etree.ElementTree as ET
NS={'m':'http://soap.sforce.com/2006/04/metadata'}
EXPECTED_TEMPLATE={
    'developerName':'Case_Resolution_Summary',
    'relatedEntity':'Case',
    'relatedField':'Case.Resolution_Summary__c',
    'type':'einstein_gpt__fieldCompletion',
    'activeVersionIdentifier':'sdEF8q15nKwoMf+RgukBR/k89gpCfpiWWyhT+dYA+Gc=_1',
}

def check_template(root):
    for field in ('developerName','relatedEntity','relatedField','type'):
        if root.findtext('m:'+field,namespaces=NS)!=EXPECTED_TEMPLATE[field]: raise RuntimeError('Template identity or field binding mismatch')
    pinned=EXPECTED_TEMPLATE['activeVersionIdentifier']
    matches=[v for v in root.findall('m:templateVersions',NS) if v.findtext('m:versionIdentifier',namespaces=NS)==pinned]
    if len(matches)!=1: raise RuntimeError('Pinned source version is missing or ambiguous; do not guess')
    if matches[0].findtext('m:status',namespaces=NS)!='Published': raise RuntimeError('Pinned source version is not published')
    if root.findtext('m:activeVersionIdentifier',namespaces=NS)!=pinned: raise RuntimeError('Pinned source version is not active; inspect the deployment receipt')
    return pinned

def sf(org,*args):
    p=subprocess.run(['sf',*args,'--target-org',org,'--json'],capture_output=True,text=True,timeout=180)
    try: result=json.loads(p.stdout)
    except (ValueError,TypeError): raise RuntimeError('Salesforce returned no valid receipt')
    if p.returncode or result.get('status')!=0: raise RuntimeError('Salesforce action failed; inspect the Orchard receipt')
    return result['result']

def main(org):
    records=sf(org,'data','query','--query','SELECT Id,IsSandbox FROM Organization')['records']
    if len(records)!=1 or records[0]['IsSandbox'] is not True: raise RuntimeError('Nonproduction only')
    with tempfile.TemporaryDirectory(prefix='case-summary-template-readback-', dir='.') as temp:
        folder=pathlib.Path(temp)/'readback'
        # The isolated output directory preserves source even when tracking reports drift.
        receipt=sf(org,'project','retrieve','start','--metadata','GenAiPromptTemplate:Case_Resolution_Summary','--output-dir',str(folder),'--ignore-conflicts','--wait','2','--api-version','67.0')
        paths=list(folder.rglob('Case_Resolution_Summary.genAiPromptTemplate-meta.xml'))
        if len(paths)!=1: raise RuntimeError('Expected exactly one retrieved template')
        version=check_template(ET.parse(paths[0]).getroot())
        print(json.dumps({'orgId':records[0]['Id'],'template':'Case_Resolution_Summary','activeVersionIdentifier':version,'retrieveId':receipt.get('id'),'verified':True}))

if __name__=='__main__':
    try: main(sys.argv[1])
    except Exception as error:
        print('Case summary template verification blocked: '+str(error),file=sys.stderr)
        sys.exit(1)
PY
