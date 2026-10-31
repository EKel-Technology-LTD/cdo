"""Offline regression checks for the activation-before-page deployment contract.

These inspect the pinned action sources; they do not execute release actions,
contact Salesforce, or establish deployment/runtime acceptance.
"""
import ast
import json
from pathlib import Path
import unittest
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

    def test_boundary_deploys_grounding_and_template_before_activation(self):
        action = self.by_id['activate-case-summary']
        self.assertEqual('metadata', action['deploymentEffect'])
        early = set(action['metadataBoundary']['after'])
        for path in (
            'classes/CaseResolutionSummaryGrounding.cls',
            'classes/CaseResolutionSummaryGroundingTest.cls',
            'customPermissions/Case_Summary_Generation.customPermission-meta.xml',
            'genAiPromptTemplates/Case_Resolution_Summary.genAiPromptTemplate-meta.xml',
        ):
            self.assertIn(BASE + path, early)
        self.assertNotIn('reviewPrerequisite', action)

    def test_page_and_app_follow_activation(self):
        boundary = self.by_id['activate-case-summary']['metadataBoundary']
        self.assertEqual({BASE + 'flexipages/Case_Record_Page.flexipage-meta.xml',
                          BASE + 'applications/standard__LightningService.app-meta.xml'},
                         set(boundary['before']))
        self.assertFalse(set(boundary['after']) & set(boundary['before']))
        for path in boundary['after'] + boundary['before']:
            self.assertTrue((ROOT / path).is_file(), path)

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

    def test_activation_uses_retrieved_version_and_relevant_tests(self):
        source = embedded_python('case-summary-activate.sh')
        self.assertIn("version=matches[0].findtext('m:versionIdentifier'", source)
        self.assertIn('if previous!=version:', source)
        self.assertIn("'--test-level','RunRelevantTests'", source)
        self.assertIn("verified.findtext('m:activeVersionIdentifier',namespaces=ns)!=version", source)
        self.assertIn('satisfies(v,expected_version)', source)

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


if __name__ == '__main__':
    unittest.main()
