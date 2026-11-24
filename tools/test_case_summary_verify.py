"""Offline tests for the Case summary verify actions. Never invoke the action runner, sf, or an org.

Failure modes, written before the fix:
1. A script reads committed source at run time. Orchard runs a bash action in a bare project that holds
   only the script, so any force-app/main/default read fails before it verifies anything.
2. The expected values embedded in a script drift from the committed metadata they stand for.
3. The template check accepts a wrong binding, a missing or unpublished version, or an inactive pin.
4. The page check misses a removed or changed Case page assignment, or rejects an org whose application
   carries other, unrelated settings.
"""
import ast
import copy
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'force-app/scripts/post/common'
TEMPLATE_SOURCE = ROOT / 'force-app/main/default/genAiPromptTemplates/Case_Resolution_Summary.genAiPromptTemplate-meta.xml'
APP_SOURCE = ROOT / 'force-app/main/default/applications/standard__LightningService.app-meta.xml'
NS = {'m': 'http://soap.sforce.com/2006/04/metadata'}


def python_body(name):
    return (SCRIPTS / name).read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]


def load(name, names):
    """Load only the declarations the pure tests need, not the action's execution block."""
    parsed = ast.parse(python_body(name))
    nodes = [n for n in parsed.body if (isinstance(n, (ast.FunctionDef, ast.ClassDef)) and n.name in names)
             or (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in names for t in n.targets))]
    ns = {'ET': ET}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), name, 'exec'), ns)
    return ns


template = load('case-summary-verify-template.sh', {'NS', 'EXPECTED_TEMPLATE', 'check_template'})
page = load('case-summary-verify-page.sh', {'NS', 'EXPECTED_OVERRIDE', 'check_page'})


class SelfContained(unittest.TestCase):
    def test_scripts_do_not_read_committed_source(self):
        for name in ('case-summary-verify-template.sh', 'case-summary-verify-page.sh'):
            self.assertNotIn('force-app/main/default', python_body(name), name)

    def test_template_expectation_matches_committed_template(self):
        root = ET.parse(TEMPLATE_SOURCE).getroot()
        expected = template['EXPECTED_TEMPLATE']
        for field in ('developerName', 'relatedEntity', 'relatedField', 'type', 'activeVersionIdentifier'):
            self.assertEqual(expected[field], root.findtext('m:' + field, namespaces=NS), field)

    def test_page_expectation_matches_committed_application(self):
        root = ET.parse(APP_SOURCE).getroot()
        committed = [{child.tag.split('}')[1]: (child.text or '').strip() for child in override}
                     for override in root.findall('m:actionOverrides', NS)]
        self.assertIn(page['EXPECTED_OVERRIDE'], committed)


class TemplateCheck(unittest.TestCase):
    def setUp(self):
        # The committed template is what a correct deployment retrieves.
        self.root = ET.parse(TEMPLATE_SOURCE).getroot()

    def test_accepts_the_published_active_pinned_version(self):
        self.assertEqual(template['check_template'](self.root), template['EXPECTED_TEMPLATE']['activeVersionIdentifier'])

    def test_rejects_a_changed_binding(self):
        self.root.find('m:relatedField', NS).text = 'Case.Description'
        with self.assertRaises(RuntimeError):
            template['check_template'](self.root)

    def test_rejects_an_inactive_pin(self):
        self.root.find('m:activeVersionIdentifier', NS).text = 'other_2'
        with self.assertRaises(RuntimeError):
            template['check_template'](self.root)

    def test_rejects_a_missing_or_unpublished_version(self):
        missing = copy.deepcopy(self.root)
        for version in missing.findall('m:templateVersions', NS):
            missing.remove(version)
        with self.assertRaises(RuntimeError):
            template['check_template'](missing)
        self.root.find('m:templateVersions/m:status', NS).text = 'Draft'
        with self.assertRaises(RuntimeError):
            template['check_template'](self.root)


class PageCheck(unittest.TestCase):
    def setUp(self):
        self.root = ET.parse(APP_SOURCE).getroot()

    def test_accepts_the_committed_assignment_among_other_settings(self):
        extra = ET.SubElement(self.root, '{%s}actionOverrides' % NS['m'])
        for tag, text in (('actionName', 'View'), ('content', 'Account_Record_Page'), ('formFactor', 'Large'),
                          ('pageOrSobjectType', 'Account'), ('type', 'Flexipage')):
            ET.SubElement(extra, '{%s}%s' % (NS['m'], tag)).text = text
        page['check_page'](self.root)

    def test_rejects_a_missing_or_changed_assignment(self):
        changed = copy.deepcopy(self.root)
        changed.find('m:actionOverrides/m:content', NS).text = 'Case_Record_Page_Old'
        with self.assertRaises(RuntimeError):
            page['check_page'](changed)
        for override in self.root.findall('m:actionOverrides', NS):
            self.root.remove(override)
        with self.assertRaises(RuntimeError):
            page['check_page'](self.root)


if __name__ == '__main__':
    unittest.main()
