"""Offline regression checks for the portable active-template deployment contract.

These inspect the pinned action sources; they do not execute release actions,
contact Salesforce, or establish deployment/runtime acceptance.
"""
import ast
import contextlib
import io
import json
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
COMMON = ROOT / 'force-app/scripts/post/common'
BASE = 'force-app/main/default/'
NS = {'m': 'http://soap.sforce.com/2006/04/metadata'}


def embedded_python(name):
    return (COMMON / name).read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]


class CaseSummaryDeploymentContractTest(unittest.TestCase):
    def setUp(self):
        self.actions = json.loads((COMMON / 'orchard-run.json').read_text())['actions']
        self.by_id = {action['id']: action for action in self.actions}

    def test_template_pins_a_generated_active_version_for_atomic_build(self):
        template = ET.parse(ROOT / (BASE + 'genAiPromptTemplates/Case_Resolution_Summary.genAiPromptTemplate-meta.xml'))
        versions = template.findall('m:templateVersions', NS)
        self.assertEqual(1, len(versions))
        identifier = versions[0].findtext('m:versionIdentifier', namespaces=NS)
        self.assertTrue(identifier, 'Retrieve the actual Salesforce-generated version before binding the page')
        self.assertEqual(identifier, template.findtext('m:activeVersionIdentifier', namespaces=NS))
        self.assertEqual('Published', versions[0].findtext('m:status', namespaces=NS))

    def test_activation_is_ordinary_post_verification_not_a_build_dependency(self):
        action = self.by_id['activate-case-summary']
        self.assertEqual('none', action['deploymentEffect'])
        self.assertNotIn('metadataBoundary', action)
        self.assertNotIn('reviewPrerequisite', action)

    def test_readback_is_an_ordinary_post_action_before_assignments(self):
        action = self.by_id['verify-case-summary-page']
        self.assertNotIn('metadataBoundary', action)
        self.assertEqual('none', action['deploymentEffect'])
        self.assertLess(self.actions.index(action), self.actions.index(self.by_id['assign-case-summary-access']))
        activation = embedded_python('case-summary-activate.sh')
        self.assertNotIn('CustomApplication:', activation)
        verification = embedded_python(action['file'])
        self.assertIn('CustomApplication:standard__LightningService', verification)
        self.assertIn('semantic(expected_app)!=semantic(actual_app)', verification)
        self.assertNotIn("'deploy'", verification)
        self.assertNotIn("'create'", verification)

    def test_template_verification_uses_retrieved_version_without_mutation(self):
        source = embedded_python('case-summary-activate.sh')
        self.assertIn("version=matches[0].findtext('m:versionIdentifier'", source)
        self.assertNotIn("'deploy'", source)
        self.assertNotIn("'create'", source)
        self.assertIn('satisfies(v,expected_version)', source)

    def test_inactive_template_fails_without_an_activation_write(self):
        calls = []
        def fake_sf(args, **kwargs):
            calls.append(args)
            if args[1:3] == ['data', 'query']:
                result = {'records': [{'Id': '00D000000000001EAA', 'IsSandbox': True}]}
            elif args[1:4] == ['project', 'retrieve', 'start']:
                folder = Path(args[args.index('--output-dir') + 1])
                folder.mkdir(parents=True, exist_ok=True)
                tree = ET.parse(ROOT / (BASE + 'genAiPromptTemplates/Case_Resolution_Summary.genAiPromptTemplate-meta.xml'))
                tree.find('m:activeVersionIdentifier', NS).text = 'synthetic-different-version'
                tree.write(folder / 'Case_Resolution_Summary.genAiPromptTemplate-meta.xml')
                result = {'id': 'synthetic-read-receipt'}
            else:
                return SimpleNamespace(returncode=1, stdout=json.dumps({'status': 1}))
            return SimpleNamespace(returncode=0, stdout=json.dumps({'status': 0, 'result': result}))
        old_cwd = Path.cwd()
        try:
            os.chdir(ROOT)
            with patch('subprocess.run', side_effect=fake_sf), patch('sys.argv', ['-', 'synthetic-org']), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    exec(compile(embedded_python('case-summary-activate.sh'), 'template-verification', 'exec'), {})
            self.assertEqual(1, error.exception.code)
            self.assertFalse(any(args[1:3] == ['project', 'deploy'] for args in calls))
        finally:
            os.chdir(old_cwd)

    def test_native_binding_and_mutually_exclusive_permission_gate_remain(self):
        page = ET.parse(ROOT / (BASE + 'flexipages/Case_Record_Page.flexipage-meta.xml'))
        fields = page.findall('.//m:fieldInstance', NS)
        bound = [f for f in fields if any(p.findtext('m:name', namespaces=NS) == 'generativePromptTemplate'
                 for p in f.findall('m:fieldInstanceProperties', NS))]
        self.assertEqual(1, len(bound))
        prop = next(p for p in bound[0].findall('m:fieldInstanceProperties', NS)
                    if p.findtext('m:name', namespaces=NS) == 'generativePromptTemplate')
        self.assertEqual('Case_Resolution_Summary', prop.findtext('m:value', namespaces=NS))
        self.assertEqual({'true', 'false'}, {f.findtext('m:visibilityRule/m:criteria/m:rightValue', namespaces=NS) for f in fields})
        for field in fields:
            self.assertEqual('Record.Resolution_Summary__c', field.findtext('m:fieldItem', namespaces=NS))
            self.assertEqual('{!$Permission.CustomPermission.Case_Summary_Generation}', field.findtext('m:visibilityRule/m:criteria/m:leftValue', namespaces=NS))

    def test_registered_scripts_parse_and_remain_target_guarded(self):
        self.assertEqual(len(self.actions), len(self.by_id))
        for action in self.actions:
            path = COMMON / action['file']
            self.assertTrue(path.is_file())
            source = path.read_text()
            self.assertIn('"$1" == "$ORCHARD_TARGET_ORG"', source)
            code = embedded_python(action['file'])
            ast.parse(code)
            self.assertIn('IsSandbox', code)

    def test_readback_scripts_keep_cli_output_inside_project(self):
        # Reproduce Salesforce CLI's OutputDirOutsideProjectError, then execute
        # the real embedded scripts against synthetic retrieve receipts.
        def fake_sf(args, **kwargs):
            if args[1:3] == ['data', 'query']:
                result = {'records': [{'Id': '00D000000000001EAA', 'IsSandbox': True}]}
            else:
                self.assertEqual(['project', 'retrieve', 'start'], args[1:4])
                folder = Path(args[args.index('--output-dir') + 1]).resolve()
                if not folder.is_relative_to(ROOT):
                    return SimpleNamespace(returncode=1, stdout=json.dumps({'status': 1, 'name': 'OutputDirOutsideProjectError'}))
                metadata = args[args.index('--metadata') + 1]
                if metadata.startswith('GenAiPromptTemplate:'):
                    path = 'genAiPromptTemplates/Case_Resolution_Summary.genAiPromptTemplate-meta.xml'
                    tree = ET.parse(ROOT / (BASE + path))
                    version = tree.find('m:templateVersions', NS)
                    identifier = version.find('m:versionIdentifier', NS)
                    if identifier is None:
                        identifier = ET.SubElement(version, '{' + NS['m'] + '}versionIdentifier')
                        identifier.text = 'synthetic-test-version'
                    active = tree.find('m:activeVersionIdentifier', NS)
                    if active is None:
                        active = ET.SubElement(tree.getroot(), '{' + NS['m'] + '}activeVersionIdentifier')
                    active.text = identifier.text
                else:
                    self.assertEqual('CustomApplication:standard__LightningService', metadata)
                    path = 'applications/standard__LightningService.app-meta.xml'
                    tree = ET.parse(ROOT / (BASE + path))
                destination = folder / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                tree.write(destination)
                result = {'id': 'synthetic-read-receipt'}
            return SimpleNamespace(returncode=0, stdout=json.dumps({'status': 0, 'result': result}))

        old_cwd = Path.cwd()
        try:
            os.chdir(ROOT)
            for name in ('case-summary-activate.sh', 'case-summary-verify-page.sh'):
                with self.subTest(script=name), patch('subprocess.run', side_effect=fake_sf), patch('sys.argv', ['-', 'synthetic-org']):
                    out, err = io.StringIO(), io.StringIO()
                    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                        try:
                            exec(compile(embedded_python(name), name, 'exec'), {})
                        except SystemExit as error:
                            self.fail(f'{name} exited {error.code}: {err.getvalue()}')
                    self.assertIn('orgId', json.loads(out.getvalue()))
        finally:
            os.chdir(old_cwd)


if __name__ == '__main__':
    unittest.main()
