#!/usr/bin/env python3
"""Offline metadata contract checks, not Salesforce runtime or persona evidence."""
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

BASE = Path(__file__).resolve().parents[1] / 'force-app/main/default'
NS = {'m': 'http://soap.sforce.com/2006/04/metadata'}
PUBLIC = {
    'Registered_Serial__c': ('產品序號', 'Text'),
    'Purchase_Channel__c': ('購買通路', 'Picklist'),
    'Selling_Dealer__c': ('購買經銷商', 'Lookup'),
    'Invoice_Number__c': ('發票號碼', 'Text'),
    'Extended_Warranty_Months__c': ('延長保固月數', 'Number'),
    'Warranty_End_Date__c': ('保固到期日', 'Date'),
    'Warranty_Status__c': ('保固狀態', 'Text'),
    'Registration_Source__c': ('登錄方式', 'Picklist'),
    'Registered_At__c': ('登錄時間', 'DateTime'),
    'Installation_Date__c': ('安裝日期', 'Date'),
}
MARKER = 'Warranty_Registration_Initialized__c'
FORMULAS = {'Warranty_End_Date__c', 'Warranty_Status__c'}
RULES = {
    'Serial_Format', 'Registered_Requires_Purchase_Info',
    'Dealer_Required_For_Dealer_Channel', 'Invoice_Number_Format',
    'Purchase_Date_Not_Future', 'Extended_Warranty_Range',
    'Registered_Requires_Warranty_Term', 'Registered_Requires_Person_Account',
}

def xml(path):
    return ET.parse(BASE / path).getroot()

def text(root, path):
    return root.findtext('/'.join('m:' + p for p in path.split('/')), namespaces=NS)

def field(name):
    return xml(f'objects/Asset/fields/{name}.field-meta.xml')

class WarrantyContract(unittest.TestCase):
    def test_field_inventory(self):
        paths = (BASE / 'objects/Asset/fields').glob('*.xml')
        self.assertEqual({p.name.removesuffix('.field-meta.xml') for p in paths}, set(PUBLIC) | {MARKER})
        for name, (label, kind) in PUBLIC.items():
            root = field(name)
            self.assertEqual(text(root, 'fullName'), name)
            self.assertEqual(text(root, 'label'), label)
            self.assertEqual(text(root, 'type'), kind)
            self.assertEqual(text(root, 'required'), 'false')
        self.assertEqual(text(field(MARKER), 'defaultValue'), 'false')
        self.assertEqual(text(field(MARKER), 'type'), 'Checkbox')
        for name in ['Registered_At__c', 'Registration_Source__c']:
            self.assertIsNone(text(field(name), 'defaultValue'))
        self.assertEqual(text(field('Extended_Warranty_Months__c'), 'defaultValue'), '0')
        self.assertEqual(text(field('Extended_Warranty_Months__c'), 'precision'), '2')
        self.assertEqual(text(field('Extended_Warranty_Months__c'), 'scale'), '0')
        self.assertEqual(text(field('Invoice_Number__c'), 'length'), '10')

    def test_unique_serial_and_patterns(self):
        serial = field('Registered_Serial__c')
        for key, value in {'length': '30', 'unique': 'true', 'caseSensitive': 'false', 'externalId': 'true'}.items():
            self.assertEqual(text(serial, key), value)
        for name, regex, good, bad in [
            ('Serial_Format', '^[A-Z0-9-]{8,30}$', ['ABCD-123', 'A'*30], ['abcD-123', 'A'*7, 'A'*31, 'ＡBCD-123', 'AB CD123']),
            ('Invoice_Number_Format', '^[A-Z]{2}[0-9]{8}$', ['AB12345678'], ['ab12345678', 'AB1234567'])]:
            root = xml(f'objects/Asset/validationRules/{name}.validationRule-meta.xml')
            formula = text(root, 'errorConditionFormula')
            self.assertIn('NOT(ISBLANK(', formula)
            self.assertIn('"' + regex + '"', formula)
            for value in good: self.assertIsNotNone(re.fullmatch(regex, value))
            for value in bad: self.assertIsNone(re.fullmatch(regex, value))

    def test_picklists(self):
        expected = {
            'Purchase_Channel__c': [('Official_Store', '官方網路商店'), ('Dealer', '經銷商門市'), ('Marketplace', '電商平台'), ('Retail_Chain', '量販通路')],
            'Registration_Source__c': [('Agent', '客服代為登錄'), ('Web_Self_Service', '官網自助登錄'), ('Agentforce', 'AI 客服代理登錄'), ('Import', '批次匯入')],
        }
        for name, pairs in expected.items():
            root = field(name)
            self.assertEqual(text(root, 'valueSet/restricted'), 'true')
            values = root.findall('m:valueSet/m:valueSetDefinition/m:value', NS)
            self.assertEqual([(text(v, 'fullName'), text(v, 'label')) for v in values], pairs)
            self.assertTrue(all(text(v, 'default') == 'false' for v in values))

    def test_dealer_filter(self):
        root = field('Selling_Dealer__c')
        self.assertEqual(text(root, 'referenceTo'), 'Account')
        for path, expected in {'active':'true', 'isOptional':'false', 'filterItems/field':'Account.IsPersonAccount', 'filterItems/operation':'equals', 'filterItems/value':'false'}.items():
            self.assertEqual(text(root, 'lookupFilter/' + path), expected)

    def test_formula_contract(self):
        self.assertEqual(text(field('Warranty_End_Date__c'), 'formula'), 'IF(OR(ISBLANK(PurchaseDate),ISBLANK(Product2Id),ISBLANK(Product2.Warranty_Months__c)),NULL,ADDMONTHS(PurchaseDate,Product2.Warranty_Months__c+BLANKVALUE(Extended_Warranty_Months__c,0))-1)')
        self.assertEqual(text(field('Warranty_Status__c'), 'formula'), 'IF(ISBLANK(PurchaseDate),"未登錄",IF(ISBLANK(Warranty_End_Date__c),"",IF(Warranty_End_Date__c<TODAY(),"已過保",IF(Warranty_End_Date__c<=TODAY()+30,"30 天內到期","保固中"))))')
        for name in FORMULAS:
            self.assertEqual(text(field(name), 'formulaTreatBlanksAs'), 'BlankAsBlank')
        dependency = xml('objects/Product2/fields/Warranty_Months__c.field-meta.xml')
        self.assertEqual(text(dependency, 'type'), 'Number')

    def test_validation_inventory(self):
        paths = list((BASE / 'objects/Asset/validationRules').glob('*.xml'))
        self.assertEqual({p.name.removesuffix('.validationRule-meta.xml') for p in paths}, RULES)
        for p in paths:
            root = ET.parse(p).getroot()
            self.assertEqual(text(root, 'active'), 'true')
            self.assertTrue(text(root, 'errorConditionFormula'))
            self.assertTrue(text(root, 'errorMessage'))
            self.assertIsNone(text(root, 'errorDisplayField'))

    def test_before_save_flow(self):
        root = xml('flows/Asset_Warranty_First_Registration.flow-meta.xml')
        for key, val in {'apiVersion':'67.0', 'status':'Active', 'start/object':'Asset', 'start/triggerType':'RecordBeforeSave', 'start/recordTriggerType':'CreateAndUpdate'}.items():
            self.assertEqual(text(root, key), val)
        self.assertEqual(text(root, 'start/filterFormula'), 'AND(ISPICKVAL({!$Record.Status},"Registered"),NOT({!$Record.Warranty_Registration_Initialized__c}),OR(ISNEW(),NOT(ISPICKVAL({!$Record__Prior.Status},"Registered"))))')
        for forbidden in ['recordLookups', 'recordUpdates', 'recordCreates', 'recordDeletes', 'loops', 'actionCalls', 'scheduledPaths', 'subflows']:
            self.assertEqual(root.findall('.//m:' + forbidden, NS), [])
        items = root.findall('m:assignments/m:assignmentItems', NS)
        self.assertEqual({text(x, 'assignToReference') for x in items}, {'$Record.Registered_At__c', '$Record.Registration_Source__c', '$Record.' + MARKER})
        self.assertEqual(text(items[-1], 'value/booleanValue'), 'true')
        formulas = {text(x, 'name'):text(x, 'expression') for x in root.findall('m:formulas', NS)}
        self.assertEqual(formulas['Initial_Registered_At'], 'IF(ISBLANK({!$Record.Registered_At__c}),{!$Flow.CurrentDateTime},{!$Record.Registered_At__c})')
        self.assertEqual(formulas['Initial_Registration_Source'], 'IF(ISBLANK(TEXT({!$Record.Registration_Source__c})),"Agent",TEXT({!$Record.Registration_Source__c}))')

    def test_layout_preservation(self):
        root = xml('layouts/Asset-Asset Layout.layout-meta.xml')
        sections = root.findall('m:layoutSections', NS)
        warranty = [s for s in sections if text(s, 'label') == '保固資訊']
        self.assertEqual(len(warranty), 1)
        self.assertEqual(len(warranty[0].findall('m:layoutColumns', NS)), 2)
        items = warranty[0].findall('m:layoutColumns/m:layoutItems', NS)
        self.assertEqual({text(i, 'field') for i in items}, set(PUBLIC) | {'PurchaseDate'})
        for i in items:
            self.assertEqual(text(i, 'behavior'), 'Readonly' if text(i, 'field') in FORMULAS else 'Edit')
        all_fields = [e.text for e in root.findall('.//m:field', NS)]
        self.assertEqual(all_fields.count('PurchaseDate'), 1)
        self.assertNotIn(MARKER, all_fields)
        self.assertIn('SerialNumber', all_fields)
        self.assertIn('InstallDate', all_fields)
        self.assertEqual([text(x, 'relatedList') for x in root.findall('m:relatedLists', NS)], ['RelatedCaseList','RelatedActivityList','RelatedHistoryList','RelatedNoteList'])
        self.assertEqual(text(root, 'excludeButtons'), 'Submit')
        original = sections[0].findall('m:layoutColumns/m:layoutItems', NS)
        for name in ['Name', 'CurrencyIsoCode']:
            self.assertEqual([text(i, 'behavior') for i in original if text(i, 'field') == name], ['Required'])
        self.assertIsNone(root.find('m:platformActionList', NS))
        self.assertEqual(len(sections), 6)

    def test_list_view_contract(self):
        for name, label, f, value, trailing in [
            ('Warranty_Expiring_30_Days','保固 30 天內到期','Warranty_Status__c','30 天內到期',['Warranty_End_Date__c','Purchase_Channel__c']),
            ('Registered_This_Month','本月新登錄','Registered_At__c','THIS_MONTH',['Registered_At__c','Registration_Source__c'])]:
            root = xml(f'objects/Asset/listViews/{name}.listView-meta.xml')
            self.assertEqual(text(root, 'label'), label)
            self.assertEqual(text(root, 'filterScope'), 'Everything')
            self.assertEqual(text(root, 'sharedTo/allInternalUsers'), 'true')
            self.assertEqual(text(root, 'filters/field'), f)
            self.assertEqual(text(root, 'filters/operation'), 'equals')
            self.assertEqual(text(root, 'filters/value'), value)
            self.assertEqual([x.text for x in root.findall('m:columns', NS)], ['ASSET.NAME','ACCOUNT.NAME','Registered_Serial__c'] + trailing)

    def test_permission_boundary(self):
        for mode in ['Read', 'Edit']:
            directory = BASE / f'permissionsets/Asset_Warranty_{mode}'
            self.assertEqual({p.name for p in (directory / 'objectSettings').glob('*.xml')},
                {f'{obj}.objectSettings-meta.xml' for obj in ['Asset', 'Account', 'Contact', 'Product2']})
            for obj in ['Asset', 'Account', 'Contact', 'Product2']:
                root = ET.parse(directory / f'objectSettings/{obj}.objectSettings-meta.xml').getroot()
                grants = root.find('objectPermissions')
                self.assertEqual(grants.findtext('allowRead'), 'true')
                for privilege in ['allowDelete','modifyAllRecords','viewAllRecords','viewAllFields']:
                    self.assertEqual(grants.findtext(privilege), 'false')
                for privilege in ['allowEdit','allowCreate']:
                    self.assertEqual(grants.findtext(privilege), str(mode == 'Edit' and obj == 'Asset').lower())
                fields = {x.findtext('field'):x for x in root.findall('fieldPermissions')}
                if obj == 'Asset':
                    expected = set(PUBLIC) | {'AccountId','Product2Id','Status','PurchaseDate'}
                    self.assertEqual(set(fields), {'Asset.' + f for f in expected})
                elif obj == 'Product2': self.assertEqual(set(fields), {'Product2.Warranty_Months__c'})
                else: self.assertEqual(fields, {})
                for name, grant in fields.items():
                    self.assertNotIn(MARKER, name)
                    self.assertEqual(grant.findtext('readable'), 'true')
                    self.assertEqual(grant.findtext('editable'), str(mode == 'Edit' and obj == 'Asset' and name.split('.')[1] not in FORMULAS).lower())
            self.assertFalse(list(directory.glob('*.userPermission-meta.xml')))
        self.assertFalse((BASE.parents[1] / 'scripts/post/common/asset-warranty-access.sh').exists())

if __name__ == '__main__':
    unittest.main(verbosity=2)
