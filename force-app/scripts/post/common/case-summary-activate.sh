#!/usr/bin/env bash
set -euo pipefail
# The committed generated active-version identifier makes the page deployable in one batch.
# Verify that exact version after deployment without changing the target.
[[ $# -eq 1 && -n "${ORCHARD_TARGET_ORG:-}" && "$1" == "$ORCHARD_TARGET_ORG" ]] || { echo 'Target mismatch' >&2; exit 1; }
python3 - "$1" <<'PY'
import json, pathlib, subprocess, sys, tempfile, xml.etree.ElementTree as ET
org=sys.argv[1]
ns={'m':'http://soap.sforce.com/2006/04/metadata'}

def sf(*args):
    p=subprocess.run(['sf',*args,'--target-org',org,'--json'],capture_output=True,text=True,timeout=180)
    try: result=json.loads(p.stdout)
    except (ValueError,TypeError): raise RuntimeError('Salesforce returned no valid receipt')
    if p.returncode or result.get('status')!=0: raise RuntimeError('Salesforce action failed; inspect the Orchard receipt')
    return result['result']

def retrieve(folder):
    # The isolated output directory preserves source even when tracking reports drift.
    receipt=sf('project','retrieve','start','--metadata','GenAiPromptTemplate:Case_Resolution_Summary','--output-dir',str(folder),'--ignore-conflicts','--wait','2','--api-version','67.0')
    paths=list(folder.rglob('Case_Resolution_Summary.genAiPromptTemplate-meta.xml'))
    if len(paths)!=1: raise RuntimeError('Expected exactly one retrieved template')
    return paths[0],ET.parse(paths[0]).getroot(),receipt

try:
    records=sf('data','query','--query','SELECT Id,IsSandbox FROM Organization')['records']
    if len(records)!=1 or records[0]['IsSandbox'] is not True: raise RuntimeError('Nonproduction only')
    source=ET.parse('force-app/main/default/genAiPromptTemplates/Case_Resolution_Summary.genAiPromptTemplate-meta.xml').getroot()
    with tempfile.TemporaryDirectory(prefix='.case-summary-activation-', dir='.') as temp:
        folder=pathlib.Path(temp)
        _,root,receipt=retrieve(folder/'readback')
        for field in ('developerName','relatedEntity','relatedField','type'):
            if root.findtext('m:'+field,namespaces=ns)!=source.findtext('m:'+field,namespaces=ns): raise RuntimeError('Template identity or field binding mismatch')
        expected_version=source.find('m:templateVersions',ns)
        def satisfies(actual,wanted):
            if (wanted.text or '').strip()!=(actual.text or '').strip(): return False
            for child_tag in {c.tag for c in wanted}:
                wanted_children=wanted.findall(child_tag)
                actual_children=actual.findall(child_tag)
                if len(wanted_children)!=len(actual_children): return False
                if not all(satisfies(a,w) for a,w in zip(actual_children,wanted_children)): return False
            return True
        matches=[v for v in root.findall('m:templateVersions',ns) if satisfies(v,expected_version)]
        active_identifier=root.findtext('m:activeVersionIdentifier',namespaces=ns)
        active_matches=[v for v in matches if v.findtext('m:versionIdentifier',namespaces=ns)==active_identifier]
        # A repeated identical delivery reuses its already-active generated version.
        if len(active_matches)==1: matches=active_matches
        if len(matches)!=1: raise RuntimeError('Published source version is missing or ambiguous; do not guess')
        version=matches[0].findtext('m:versionIdentifier',namespaces=ns)

        if not version: raise RuntimeError('Salesforce has not generated a version identifier')
        if active_identifier!=version: raise RuntimeError('Pinned source version is not active; inspect the deployment receipt')
        print(json.dumps({'orgId':records[0]['Id'],'template':'Case_Resolution_Summary','activeVersionIdentifier':version,'retrieveId':receipt.get('id'),'verified':True}))
except Exception as error:
    print('Case summary activation blocked: '+str(error),file=sys.stderr)
    sys.exit(1)
PY
