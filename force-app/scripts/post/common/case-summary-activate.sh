#!/usr/bin/env bash
set -euo pipefail
# Orchard alone executes this action, against the authenticated target supplied twice.
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

def retrieve(folder):
    receipt=sf('project','retrieve','start','--metadata','GenAiPromptTemplate:Case_Resolution_Summary','--output-dir',str(folder),'--wait','2','--api-version','67.0')
    paths=list(folder.rglob('Case_Resolution_Summary.genAiPromptTemplate-meta.xml'))
    if len(paths)!=1: raise RuntimeError('Expected exactly one retrieved template')
    return paths[0],ET.parse(paths[0]).getroot(),receipt

try:
    records=sf('data','query','--query','SELECT Id,IsSandbox FROM Organization')['records']
    if len(records)!=1 or records[0]['IsSandbox'] is not True: raise RuntimeError('Nonproduction only')
    source=ET.parse('force-app/main/default/genAiPromptTemplates/Case_Resolution_Summary.genAiPromptTemplate-meta.xml').getroot()
    expected=source.find('m:templateVersions/m:content',ns).text
    with tempfile.TemporaryDirectory(prefix='case-summary-activation-') as temp:
        folder=pathlib.Path(temp)
        path,root,before=retrieve(folder/'before')
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
        active=root.find('m:activeVersionIdentifier',ns)
        previous=None if active is None else active.text
        deployment=None
        if previous!=version:
            if active is None: active=ET.Element(q('activeVersionIdentifier'));root.insert(0,active)
            active.text=version
            ET.ElementTree(root).write(path,encoding='UTF-8',xml_declaration=True)
            deployment=sf('project','deploy','start','--source-dir',str(path),'--wait','2','--api-version','67.0')
            if deployment.get('success') is not True or deployment.get('status')!='Succeeded': raise RuntimeError('Activation deployment is not verified; do not replay')
        _,verified,after=retrieve(folder/'after')
        if verified.findtext('m:activeVersionIdentifier',namespaces=ns)!=version: raise RuntimeError('Activation readback mismatch')
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
        print(json.dumps({'applicationRetrieveId':app_receipt.get('id'),'orgId':records[0]['Id'],'template':'Case_Resolution_Summary','previousActiveVersionIdentifier':previous,'activeVersionIdentifier':version,'retrieveId':after.get('id'),'deploymentId':None if deployment is None else deployment.get('id')}))
except Exception as error:
    print('Case summary activation blocked: '+str(error),file=sys.stderr)
    sys.exit(1)
PY
