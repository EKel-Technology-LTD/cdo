#!/usr/bin/env bash
set -euo pipefail
# Verify the deployed application keeps the committed Case page assignment.
# Retrieve inside the project: Salesforce CLI rejects external output directories.
# Orchard runs this in a bare project that holds only this script, so the expected values live here.
# tools/test_case_summary_verify.py fails when they drift from the committed application.
[[ $# -eq 1 && -n "${ORCHARD_TARGET_ORG:-}" && "$1" == "$ORCHARD_TARGET_ORG" ]] || { echo 'Target mismatch' >&2; exit 1; }
python3 - "$1" <<'PY'
import json, pathlib, subprocess, sys, tempfile, xml.etree.ElementTree as ET
NS={'m':'http://soap.sforce.com/2006/04/metadata'}
EXPECTED_OVERRIDE={
    'actionName':'View',
    'content':'Case_Record_Page',
    'formFactor':'Large',
    'pageOrSobjectType':'Case',
    'skipRecordTypeSelect':'false',
    'type':'Flexipage',
}

def check_page(root):
    # Other overrides, profiles and settings belong to the org; check only the assignment this delivery owns.
    overrides=[{child.tag.split('}')[1]:(child.text or '').strip() for child in override}
               for override in root.findall('m:actionOverrides',NS)]
    if EXPECTED_OVERRIDE not in overrides: raise RuntimeError('Case page activation readback mismatch')

def sf(org,*args):
    p=subprocess.run(['sf',*args,'--target-org',org,'--json'],capture_output=True,text=True,timeout=180)
    try: result=json.loads(p.stdout)
    except (ValueError,TypeError): raise RuntimeError('Salesforce returned no valid receipt')
    if p.returncode or result.get('status')!=0: raise RuntimeError('Salesforce action failed; inspect the Orchard receipt')
    return result['result']

def main(org):
    records=sf(org,'data','query','--query','SELECT Id,IsSandbox FROM Organization')['records']
    if len(records)!=1 or records[0]['IsSandbox'] is not True: raise RuntimeError('Nonproduction only')
    with tempfile.TemporaryDirectory(prefix='case-summary-page-readback-', dir='.') as temp:
        folder=pathlib.Path(temp)/'application'
        # Retrieve into the isolated output directory; never overwrite committed source.
        receipt=sf(org,'project','retrieve','start','--metadata','CustomApplication:standard__LightningService','--output-dir',str(folder),'--ignore-conflicts','--wait','2','--api-version','67.0')
        apps=list(folder.rglob('standard__LightningService.app-meta.xml'))
        if len(apps)!=1: raise RuntimeError('Application readback is incomplete')
        check_page(ET.parse(apps[0]).getroot())
        print(json.dumps({'applicationRetrieveId':receipt.get('id'),'orgId':records[0]['Id'],'application':'standard__LightningService','page':'Case_Record_Page','verified':True}))

if __name__=='__main__':
    try: main(sys.argv[1])
    except Exception as error:
        print('Case summary page verification blocked: '+str(error),file=sys.stderr)
        sys.exit(1)
PY
