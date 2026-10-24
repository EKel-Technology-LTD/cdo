#!/usr/bin/env python3
"""Offline catalog metadata contract tests; not Salesforce acceptance evidence.
Run: python3 tools/check_product_catalog.py
"""
from pathlib import Path
import hashlib
import re
import unittest
import xml.etree.ElementTree as ET

BASE = Path(__file__).resolve().parents[1] / 'force-app/main/default'
NS = {'m': 'http://soap.sforce.com/2006/04/metadata'}
FIELDS = {
    'Model_Number__c': ('產品型號', 'Text'),
    'Product_Line__c': ('產品線', 'Picklist'),
    'Warranty_Months__c': ('保固月數', 'Number'),
    'Energy_Efficiency_Grade__c': ('能源效率等級', 'Picklist'),
    'Requires_Installation__c': ('需要安裝', 'Checkbox'),
    'Replacement_Cycle_Months__c': ('建議更換週期（月）', 'Number'),
    'Dealer_Exclusive__c': ('經銷限定', 'Checkbox'),
    'Spec_Sheet_URL__c': ('產品規格頁', 'Url'),
    'Accessory_Classification__c': ('配件分類', 'Picklist'),
}
STANDARD = {'AvailabilityDate', 'DiscontinuedDate'}
LINE_VALUES = list(zip(
    ['Air_Purifier', 'Dehumidifier', 'Vacuum_Cleaner', 'Water_Purifier', 'Accessory', 'Service_Plan'],
    ['空氣清淨機', '除濕機', '吸塵器', '淨水器', '耗材與配件', '服務方案']))

def xml(path):
    return ET.parse(BASE / path).getroot()

def text(root, path):
    return root.findtext('/'.join('m:' + p for p in path.split('/')), namespaces=NS)

def field(name):
    return xml(f'objects/Product2/fields/{name}.field-meta.xml')

def rule(name):
    return xml(f'objects/Product2/validationRules/{name}.validationRule-meta.xml')

def compact(s):
    return re.sub(r'\s+', '', s)

class CatalogContract(unittest.TestCase):
    def test_exact_field_inventory_and_types(self):
        found = {p.name.removesuffix('.field-meta.xml') for p in (BASE/'objects/Product2/fields').glob('*.xml')}
        self.assertEqual(found, set(FIELDS))
        for name, (label, kind) in FIELDS.items():
            root = field(name)
            self.assertEqual(text(root, 'fullName'), name)
            self.assertEqual(text(root, 'label'), label)
            self.assertEqual(text(root, 'type'), kind)
            if kind != 'Checkbox':
                self.assertEqual(text(root, 'required'), 'false')
        self.assertIsNone(text(field('Spec_Sheet_URL__c'), 'length'))

    def test_model_index_and_format(self):
        root = field('Model_Number__c')
        for key, value in {'length': '40', 'caseSensitive': 'false', 'unique': 'true', 'externalId': 'true'}.items():
            self.assertEqual(text(root, key), value)
        pattern = re.search(r'"([^\"]+)"', text(rule('Model_Number_Format'), 'errorConditionFormula')).group(1)
        for value in ['AP-500', 'AP-800PRO', 'ABC', 'A'*40, '---']:
            self.assertIsNotNone(re.fullmatch(pattern, value))
        for value in ['ap-500', 'AP 500', 'AB', 'A'*41, 'ＡＰ-500']:
            self.assertIsNone(re.fullmatch(pattern, value))

    def test_defaults_and_no_backfill_flag(self):
        for name in FIELDS:
            expected = '12' if name == 'Warranty_Months__c' else 'false' if FIELDS[name][1] == 'Checkbox' else None
            self.assertEqual(text(field(name), 'defaultValue'), expected)
            if expected is not None:
                self.assertEqual(text(field(name), 'populateExistingRows'), 'false')
        for name in ['Warranty_Months__c', 'Replacement_Cycle_Months__c']:
            self.assertEqual(text(field(name), 'precision'), '3')
            self.assertEqual(text(field(name), 'scale'), '0')

    def test_shared_vocabulary(self):
        root = xml('globalValueSets/Product_Line.globalValueSet-meta.xml')
        self.assertEqual(text(root, 'masterLabel'), '產品線')
        self.assertEqual(text(root, 'sorted'), 'false')
        vals = root.findall('m:customValue', NS)
        self.assertEqual([(text(v, 'fullName'), text(v, 'label')) for v in vals], LINE_VALUES)
        self.assertTrue(all(text(v, 'default') == 'false' for v in vals))
        root = field('Product_Line__c')
        self.assertEqual(text(root, 'valueSet/valueSetName'), 'Product_Line')
        self.assertEqual(text(root, 'valueSet/restricted'), 'true')

    def test_local_picklists(self):
        for name, expected in [
            ('Energy_Efficiency_Grade__c', [(f'Grade_{i}', f'第 {i} 級') for i in range(1, 6)] + [('Not_Applicable', '不適用')]),
            ('Accessory_Classification__c', [('Consumable', '耗材'), ('Durable_Accessory', '耐用配件')]),
        ]:
            root = field(name)
            self.assertEqual(text(root, 'valueSet/restricted'), 'true')
            self.assertEqual(text(root, 'valueSet/valueSetDefinition/sorted'), 'false')
            vals = root.findall('m:valueSet/m:valueSetDefinition/m:value', NS)
            self.assertEqual([(text(v, 'fullName'), text(v, 'label')) for v in vals], expected)
            self.assertTrue(all(text(v, 'default') == 'false' for v in vals))

    def test_exact_validation_contract(self):
        expected = {
            'Active_Requires_Model_And_Line': ('AND(IsActive, OR(ISBLANK(Model_Number__c), ISBLANK(TEXT(Product_Line__c))))', None, '啟用中的產品必須填寫產品型號與產品線。'),
            'Model_Number_Format': ('AND(NOT(ISBLANK(Model_Number__c)), NOT(REGEX(Model_Number__c, "^[A-Z0-9-]{3,40}$")))', 'Model_Number__c', '產品型號只能使用大寫英文、數字與連字號（3–40 碼）。'),
            'Warranty_Months_Range': ('AND(NOT(ISBLANK(Warranty_Months__c)), OR(Warranty_Months__c < 0, Warranty_Months__c > 60))', 'Warranty_Months__c', '保固月數必須介於 0 到 60 個月。'),
            'End_Of_Sale_After_Launch': ('AND(NOT(ISBLANK(AvailabilityDate)), NOT(ISBLANK(DiscontinuedDate)), DiscontinuedDate < AvailabilityDate)', 'DiscontinuedDate', '停售日期不可早於上市日期。'),
            'Active_Requires_Energy_Grade': ('AND(IsActive, OR(ISPICKVAL(Product_Line__c,"Air_Purifier"),ISPICKVAL(Product_Line__c,"Dehumidifier")), NOT(OR(ISPICKVAL(Energy_Efficiency_Grade__c,"Grade_1"),ISPICKVAL(Energy_Efficiency_Grade__c,"Grade_2"),ISPICKVAL(Energy_Efficiency_Grade__c,"Grade_3"),ISPICKVAL(Energy_Efficiency_Grade__c,"Grade_4"),ISPICKVAL(Energy_Efficiency_Grade__c,"Grade_5"))))', 'Energy_Efficiency_Grade__c', '啟用中的空氣清淨機與除濕機必須填寫第 1 級至第 5 級能源效率等級。'),
            'Active_Accessory_Requires_Classification': ('AND(IsActive,ISPICKVAL(Product_Line__c,"Accessory"),ISBLANK(TEXT(Accessory_Classification__c)))', 'Accessory_Classification__c', '啟用中的耗材與配件必須填寫配件分類。'),
            'Active_Consumable_Requires_Cycle': ('AND(IsActive,ISPICKVAL(Product_Line__c,"Accessory"),ISPICKVAL(Accessory_Classification__c,"Consumable"),ISBLANK(Replacement_Cycle_Months__c))', 'Replacement_Cycle_Months__c', '啟用中的耗材必須填寫建議更換週期（月）。'),
        }
        found = {p.name.removesuffix('.validationRule-meta.xml') for p in (BASE/'objects/Product2/validationRules').glob('*.xml')}
        self.assertEqual(found, set(expected))
        for name, (formula, location, message) in expected.items():
            root = rule(name)
            self.assertEqual(text(root, 'active'), 'true')
            self.assertEqual(compact(text(root, 'errorConditionFormula')), compact(formula))
            self.assertEqual(text(root, 'errorDisplayField'), location)
            self.assertEqual(text(root, 'errorMessage'), message)

    def test_layout_and_preservation(self):
        path = BASE/'layouts/Product2-Product Layout.layout-meta.xml'
        root = ET.parse(path).getroot()
        sections = [s for s in root.findall('m:layoutSections', NS) if text(s, 'label') == '規格與保固']
        self.assertEqual(len(sections), 1)
        section = sections[0]
        for key in ['customLabel', 'detailHeading', 'editHeading']:
            self.assertEqual(text(section, key), 'true')
        self.assertEqual(text(section, 'style'), 'TwoColumnsTopToBottom')
        expected = [
            ['Model_Number__c', 'Product_Line__c', 'Warranty_Months__c', 'Energy_Efficiency_Grade__c', 'Requires_Installation__c', 'Accessory_Classification__c'],
            ['AvailabilityDate', 'DiscontinuedDate', 'Replacement_Cycle_Months__c', 'Dealer_Exclusive__c', 'Spec_Sheet_URL__c'],
        ]
        self.assertEqual([[text(i, 'field') for i in col.findall('m:layoutItems', NS)] for col in section.findall('m:layoutColumns', NS)], expected)
        self.assertTrue(all(text(i, 'behavior') == 'Edit' for i in section.findall('m:layoutColumns/m:layoutItems', NS)))
        content = path.read_text()
        baseline = re.sub(r'    <layoutSections>\n(?:(?!    </layoutSections>)[\s\S])*?<label>規格與保固</label>[\s\S]*?    </layoutSections>\n', '', content)
        self.assertEqual(hashlib.sha256(baseline.encode()).hexdigest(), '14c18e20ea805f36ffc468a0d1c3945f8c60d22ffd3e3af9251f8d2483ec69e4')

    def test_permission_boundaries(self):
        for name, label, edit in [('Product_Catalog_Manage', '產品主檔管理', 'true'), ('Product_Catalog_Read', '產品主檔檢視', 'false')]:
            parent = xml(f'permissionsets/{name}/{name}.permissionset-meta.xml')
            self.assertEqual(text(parent, 'label'), label)
            self.assertEqual({c.tag.split('}')[-1] for c in parent}, {'hasActivationRequired', 'label'})
            root = xml(f'permissionsets/{name}/objectSettings/Product2.objectSettings-meta.xml')
            self.assertEqual({c.tag for c in root}, {'fieldPermissions', 'objectPermissions'})
            perms = root.findall('fieldPermissions')
            self.assertEqual(len(perms), 11)
            self.assertEqual({p.findtext('field') for p in perms}, {'Product2.' + f for f in set(FIELDS) | STANDARD})
            for p in perms:
                self.assertEqual(p.findtext('editable'), edit)
                self.assertEqual(p.findtext('readable'), 'true')
            obj = root.find('objectPermissions')
            self.assertEqual({c.tag: c.text for c in obj}, dict(allowCreate=edit, allowDelete='false', allowEdit=edit, allowRead='true', modifyAllRecords='false', object='Product2', viewAllFields='false', viewAllRecords='false'))

    def test_list_view_contract(self):
        for name, label, columns, filter_field, value in [
            ('Active_Products', '上市中產品', ['PRODUCT2.NAME', 'Model_Number__c', 'Product_Line__c', 'Warranty_Months__c', 'Energy_Efficiency_Grade__c'], 'PRODUCT2.ACTIVE', '1'),
            ('Ending_Sale_90_Days', '90 天內停售', ['PRODUCT2.NAME', 'Model_Number__c', 'Product_Line__c', 'PRODUCT2.DISCONTINUED_DATE'], 'PRODUCT2.DISCONTINUED_DATE', 'NEXT_N_DAYS:90'),
        ]:
            root = xml(f'objects/Product2/listViews/{name}.listView-meta.xml')
            self.assertEqual(text(root, 'label'), label)
            self.assertEqual(text(root, 'filterScope'), 'Everything')
            self.assertEqual([c.text for c in root.findall('m:columns', NS)], columns)
            self.assertEqual(len(root.findall('m:filters', NS)), 1)
            self.assertEqual(text(root, 'filters/field'), filter_field)
            self.assertEqual(text(root, 'filters/value'), value)
            self.assertEqual(text(root, 'filters/operation'), 'equals')
            self.assertIsNone(root.find('m:sharedTo', NS))

    def test_all_scoped_xml_and_api(self):
        for p in (BASE/'objects/Product2').rglob('*.xml'):
            ET.parse(p)
        import json
        config = json.loads((BASE.parents[2]/'sfdx-project.json').read_text())
        self.assertEqual(config['sourceApiVersion'], '67.0')
        self.assertIn('decomposePermissionSetBeta2', config['sourceBehaviorOptions'])

if __name__ == '__main__':
    unittest.main(verbosity=2)
