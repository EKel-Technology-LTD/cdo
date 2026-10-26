#!/usr/bin/env python3
"""Offline CDO-56 metadata checks, not org/runtime or effective-access evidence."""
import hashlib
import json
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE / 'force-app/main/default'
NS = {'m': 'http://soap.sforce.com/2006/04/metadata'}
FIELDS = ['Product_Line__c', 'Resolution_Code__c', 'Resolution_Summary__c']
CODES = [('Answered', '已解答'), ('Repaired', '已維修'), ('Replaced', '已換貨'),
         ('Refunded', '已退貨退款'), ('Not_Reproducible', '無法重現'),
         ('No_Customer_Response', '顧客未回覆'), ('Duplicate', '重複案件')]

def xml(path):
    return ET.parse(ROOT / path).getroot()

def text(root, path):
    return root.findtext('/'.join('m:' + p for p in path.split('/')), namespaces=NS)

def field(name):
    return xml(f'objects/Case/fields/{name}.field-meta.xml')

class CaseResolutionContract(unittest.TestCase):
    def test_status_flags_and_order(self):
        root = xml('standardValueSets/CaseStatus.standardValueSet-meta.xml')
        values = root.findall('m:standardValue', NS)
        self.assertEqual([text(v, 'fullName') for v in values],
                         ['New', 'In Progress', 'Waiting on Customer', 'On Hold', 'Escalated', 'Closed'])
        self.assertEqual(text(root, 'sorted'), 'false')
        for v in values:
            name = text(v, 'fullName')
            self.assertEqual(text(v, 'label'), name)
            self.assertEqual(text(v, 'default'), str(name == 'New').lower())
            self.assertEqual(text(v, 'closed'), str(name == 'Closed').lower())

    def test_fields(self):
        for name, label, kind in zip(FIELDS, ['產品線', '結案代碼', '結案摘要'], ['Picklist', 'Picklist', 'LongTextArea']):
            root = field(name)
            self.assertEqual(text(root, 'fullName'), name)
            self.assertEqual(text(root, 'label'), label)
            self.assertEqual(text(root, 'type'), kind)
            self.assertIn(text(root, 'required'), [None, 'false'])
        self.assertEqual(text(field(FIELDS[0]), 'valueSet/valueSetName'), 'Product_Line')
        self.assertEqual(text(field(FIELDS[0]), 'valueSet/restricted'), 'true')
        code = field(FIELDS[1])
        self.assertEqual(text(code, 'valueSet/restricted'), 'true')
        self.assertEqual(text(code, 'valueSet/valueSetDefinition/sorted'), 'false')
        values = code.findall('m:valueSet/m:valueSetDefinition/m:value', NS)
        self.assertEqual([(text(v, 'fullName'), text(v, 'label')) for v in values], CODES)
        self.assertTrue(all(text(v, 'default') == 'false' for v in values))
        self.assertEqual(text(field(FIELDS[2]), 'length'), '4000')
        self.assertEqual(text(field(FIELDS[2]), 'visibleLines'), '5')

    def test_rules(self):
        specs = [
            ('Closed_Requires_Resolution_Code', 'AND(ISPICKVAL(Status,"Closed"), ISBLANK(TEXT(Resolution_Code__c)))',
             '結案前請選擇結案代碼。', 'Resolution_Code__c'),
            ('Duplicate_Requires_Parent', 'AND(ISPICKVAL(Resolution_Code__c,"Duplicate"), ISBLANK(ParentId))',
             '結案代碼為「重複案件」時，請在上層案件填入原案件。', None)]
        for name, formula, message, error_field in specs:
            root = xml(f'objects/Case/validationRules/{name}.validationRule-meta.xml')
            self.assertEqual(text(root, 'active'), 'true')
            self.assertEqual(text(root, 'errorConditionFormula'), formula)
            self.assertEqual(text(root, 'errorMessage'), message)
            self.assertEqual(text(root, 'errorDisplayField'), error_field)
        self.assertFalse((ROOT/'objects/Case/validationRules/Resolution_Summary_Required.validationRule-meta.xml').exists())

    def test_flow_boundary_and_logic(self):
        root = xml('flows/Case_Resolution_Summary_Required.flow-meta.xml')
        for path, expected in [('apiVersion', '67.0'), ('status', 'Active'),
            ('start/object', 'Case'), ('start/recordTriggerType', 'CreateAndUpdate'),
            ('start/triggerType', 'RecordBeforeSave'), ('start/doesRequireRecordChangedToMeetCriteria', 'false'),
            ('start/filters/field', 'Status'), ('start/filters/operator', 'EqualTo'),
            ('start/filters/value/stringValue', 'Closed'),
            ('decisions/rules/conditionLogic', '(1 OR 2 OR 3) AND (4 OR 5)'),
            ('customErrors/customErrorMessages/isFieldError', 'false'),
            ('customErrors/customErrorMessages/errorMessage', '已維修、已換貨或已退貨的案件，結案前請填寫結案摘要。')]:
            self.assertEqual(text(root, path), expected, path)
        conditions = root.findall('m:decisions/m:rules/m:conditions', NS)
        self.assertEqual(len(conditions), 5)
        for c, code in zip(conditions[:3], ['Repaired', 'Replaced', 'Refunded']):
            self.assertEqual(text(c, 'leftValueReference'), '$Record.Resolution_Code__c')
            self.assertEqual(text(c, 'operator'), 'EqualTo')
            self.assertEqual(text(c, 'rightValue/stringValue'), code)
        for c in conditions[3:]:
            self.assertEqual(text(c, 'leftValueReference'), '$Record.Resolution_Summary__c')
        self.assertEqual(text(conditions[3], 'operator'), 'IsNull')
        self.assertEqual(text(conditions[3], 'rightValue/booleanValue'), 'true')
        self.assertEqual(text(conditions[4], 'operator'), 'EqualTo')
        self.assertEqual(text(conditions[4], 'rightValue/stringValue'), '')
        for forbidden in ['recordUpdates', 'recordCreates', 'recordDeletes', 'recordLookups', 'loops',
                          'actionCalls', 'subflows', 'assignments', 'formulas']:
            self.assertIsNone(root.find('m:' + forbidden, NS))
        self.assertIsNone(root.find('m:decisions/m:defaultConnector', NS))
        self.assertEqual(text(root, 'start/connector/targetReference'), text(root, 'decisions/name'))
        self.assertEqual(text(root, 'decisions/rules/connector/targetReference'), text(root, 'customErrors/name'))

    def test_fls_only(self):
        for suffix, label, editable in [('Edit', '案件結案資訊編輯', 'true'), ('Read', '案件結案資訊檢視', 'false')]:
            name = 'Case_Resolution_' + suffix
            header = xml(f'permissionsets/{name}/{name}.permissionset-meta.xml')
            self.assertEqual(text(header, 'label'), label)
            root = xml(f'permissionsets/{name}/objectSettings/Case.objectSettings-meta.xml')
            self.assertEqual([c.tag for c in root], ['fieldPermissions'] * 3)
            self.assertEqual([p.findtext('field') for p in root], ['Case.'+f for f in FIELDS])
            for p in root:
                self.assertEqual(p.findtext('editable'), editable)
                self.assertEqual(p.findtext('readable'), 'true')
            self.assertEqual({c.tag.split('}')[-1] for c in header}, {'label', 'hasActivationRequired'})

    def test_layout_and_original_preservation(self):
        path = ROOT/'layouts/Case-Case Layout.layout-meta.xml'
        root = ET.parse(path).getroot()
        sections = root.findall('m:layoutSections', NS)
        section = next(s for s in sections if text(s, 'label') == '處理與結案')
        self.assertEqual(text(section, 'style'), 'OneColumn')
        self.assertEqual(text(section, 'detailHeading'), 'true')
        self.assertEqual(text(section, 'editHeading'), 'true')
        items = section.findall('m:layoutColumns/m:layoutItems', NS)
        self.assertEqual([text(i, 'field') for i in items], FIELDS)
        self.assertTrue(all(text(i, 'behavior') == 'Edit' for i in items))
        additional = next(s for s in sections if text(s, 'label') == 'Additional Information')
        self.assertEqual(len(additional.findall("m:layoutColumns/m:layoutItems[m:field='ParentId']", NS)), 1)
        # Remove exactly the two insertions and compare original bytes, including actions/feed/related lists.
        source = path.read_text()
        import re
        source, count = re.subn(r'    <layoutSections>\n(?:(?!    </layoutSections>).)*?<label>處理與結案</label>.*?    </layoutSections>\n', '', source, flags=re.S)
        self.assertEqual(count, 1)
        parent = '            <layoutItems>\n                <behavior>Edit</behavior>\n                <field>ParentId</field>\n            </layoutItems>\n'
        self.assertEqual(source.count(parent), 1)
        source = source.replace(parent, '')
        self.assertEqual(hashlib.sha256(source.encode()).hexdigest(),
                         '1f689b9bae83fc8fc5b14d24f7d8d60c21bd395c866ce0734d6b40ef1e6229f4')

    def test_api_and_shared_values(self):
        self.assertEqual(json.loads((BASE/'sfdx-project.json').read_text())['sourceApiVersion'], '67.0')
        root = xml('globalValueSets/Product_Line.globalValueSet-meta.xml')
        self.assertEqual([text(v, 'fullName') for v in root.findall('m:customValue', NS)],
                         ['Air_Purifier', 'Dehumidifier', 'Vacuum_Cleaner', 'Water_Purifier', 'Accessory', 'Service_Plan'])
        self.assertEqual(text(xml('classes/CaseResolutionTest.cls-meta.xml'), 'apiVersion'), '67.0')

if __name__ == '__main__':
    unittest.main(verbosity=2)
