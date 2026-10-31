#!/usr/bin/env bash
set -euo pipefail
# Orchard runs this read-only post action after the remaining page/application metadata.
# Keep application preservation readback out of the earlier template-activation boundary.
[[ $# -eq 1 && -n "${ORCHARD_TARGET_ORG:-}" && "$1" == "$ORCHARD_TARGET_ORG" ]] || { echo 'Target mismatch' >&2; exit 1; }
python3 - "$1" <<'PY'
import json, pathlib, subprocess, sys, tempfile, xml.etree.ElementTree as ET
org=sys.argv[1]
ns={'m':'http://soap.sforce.com/2006/04/metadata'}
ET.register_namespace('',ns['m'])
q=lambda name:'{'+ns['m']+'}'+name

def sf(*args):
    p=subprocess.run(['sf',*args,'--target-org',org,'--json'],capture_output=True,text=True,timeout=180)
    try: result=json.loads(p.stdout)
    except (ValueError,TypeError): raise RuntimeError('Salesforce returned no valid receipt')
    if p.returncode or result.get('status')!=0: raise RuntimeError('Salesforce action failed; inspect the Orchard receipt')
    return result['result']

try:
    records=sf('data','query','--query','SELECT Id,IsSandbox FROM Organization')['records']
    if len(records)!=1 or records[0]['IsSandbox'] is not True: raise RuntimeError('Nonproduction only')
    with tempfile.TemporaryDirectory(prefix='case-summary-page-readback-') as temp:
        folder=pathlib.Path(temp)
        app_receipt=sf('project','retrieve','start','--metadata','CustomApplication:standard__LightningService','--output-dir',str(folder/'application'),'--wait','2','--api-version','67.0')
        apps=list((folder/'application').rglob('standard__LightningService.app-meta.xml'))
        if len(apps)!=1: raise RuntimeError('Application readback is incomplete')
        def semantic(element):
            children={}
            for child in element:
                children.setdefault(child.tag,[]).append(semantic(child))
            return element.tag,(element.text or '').strip(),children
        expected_app=ET.parse('force-app/main/default/applications/standard__LightningService.app-meta.xml').getroot()
        actual_app=ET.parse(apps[0]).getroot()
        if semantic(expected_app)!=semantic(actual_app): raise RuntimeError('Application settings or Case page activation readback mismatch')
        print(json.dumps({'applicationRetrieveId':app_receipt.get('id'),'orgId':records[0]['Id'],'application':'standard__LightningService','page':'Case_Record_Page','verified':True}))
except Exception as error:
    print('Case summary page verification blocked: '+str(error),file=sys.stderr)
    sys.exit(1)
PY
