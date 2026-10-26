#!/usr/bin/env python3
"""Offline source contracts. Salesforce execution and persona acceptance remain separate."""
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

BASE = Path(__file__).resolve().parents[1] / 'force-app/main/default'
NS = {'m': 'http://soap.sforce.com/2006/04/metadata'}
FIELDS = {
    'Sales_Rep__c': ('Sales Rep', 'Lookup'),
    'Fiscal_Year__c': ('Year', 'Number'),
    'Fiscal_Quarter__c': ('Quarter', 'Picklist'),
    'Product_Line__c': ('Product Line', 'Picklist'),
    'Target_Amount__c': ('Target Amount', 'Currency'),
    'Actual_Amount__c': ('Actual Won Amount', 'Currency'),
    'Won_Opportunity_Count__c': ('Won Opportunity Count', 'Number'),
    'Last_Calculated_At__c': ('Last Calculated At', 'DateTime'),
    'Period_Start__c': ('Period Start', 'Date'),
    'Period_End__c': ('Period End', 'Date'),
    'Attainment__c': ('Attainment Rate', 'Percent'),
    'Attainment_Status__c': ('Attainment Status', 'Text'),
    'Target_Key__c': ('Target Unique Key', 'Text'),
    'Notes__c': ('Notes', 'TextArea'),
}
REQUIRED = { 'Fiscal_Year__c', 'Fiscal_Quarter__c', 'Target_Amount__c'}
SYSTEM = ['Actual_Amount__c', 'Won_Opportunity_Count__c', 'Last_Calculated_At__c', 'Target_Key__c']
FORMULAS = {
    'Period_Start__c': 'DATE(Fiscal_Year__c,CASE(TEXT(Fiscal_Quarter__c),"Q1",1,"Q2",4,"Q3",7,"Q4",10,1),1)',
    'Period_End__c': 'ADDMONTHS(Period_Start__c,3)-1',
    'Attainment__c': 'IF(Target_Amount__c > 0,BLANKVALUE(Actual_Amount__c,0)/Target_Amount__c,0)',
    'Attainment_Status__c': 'IF(Attainment__c >= 1,"Achieved",IF(Attainment__c >= 0.8,"Near Target","Behind"))',
}
def xml(path):
    return ET.parse(BASE / path).getroot()
def text(root, path):
    return root.findtext('/'.join('m:' + item for item in path.split('/')), namespaces=NS)
def field(name):
    return xml(f'objects/Sales_Target__c/fields/{name}.field-meta.xml')
def rule(name):
    return xml(f'objects/Sales_Target__c/validationRules/{name}.validationRule-meta.xml')

class SalesTargetContract(unittest.TestCase):
    def test_object_and_sharing(self):
        r = xml('objects/Sales_Target__c/Sales_Target__c.object-meta.xml')
        expected = {'label':'Sales Quarterly Target','pluralLabel':'Sales Quarterly Targets',
                    'deploymentStatus':'Deployed','enableHistory':'true','enableReports':'true',
                    'enableSearch':'true','enableSharing':'true','enableBulkApi':'true','enableStreamingApi':'true','sharingModel':'Read',
                    'externalSharingModel':'Private','enableActivities':'false','enableFeeds':'false',
                    'nameField/type':'AutoNumber','nameField/label':'Target Number',
                    'nameField/displayFormat':'ST-{00000}','nameField/startingNumber':'1'}
        for path, value in expected.items(): self.assertEqual(text(r,path),value,path)
    def test_field_inventory_and_precision(self):
        names = {p.name.removesuffix('.field-meta.xml') for p in (BASE/'objects/Sales_Target__c/fields').glob('*.xml')}
        self.assertEqual(names, set(FIELDS))
        for name,(label,kind) in FIELDS.items():
            r=field(name)
            self.assertEqual(text(r,'fullName'),name)
            self.assertEqual(text(r,'label'),label)
            self.assertEqual(text(r,'type'),kind)
            self.assertEqual(text(r,'required')=='true',name in REQUIRED)
            self.assertIsNone(text(r,'defaultValue'))
        for name, precision, scale in [('Target_Amount__c','16','2'),('Actual_Amount__c','16','2'),('Fiscal_Year__c','4','0'),('Won_Opportunity_Count__c','6','0'),('Attainment__c','5','1')]:
            self.assertEqual(text(field(name),'precision'),precision)
            self.assertEqual(text(field(name),'scale'),scale)
        self.assertEqual(text(field('Target_Amount__c'),'trackHistory'),'true')
        self.assertIsNone(text(field('Notes__c'),'length'), 'TextArea has a fixed 255-character limit; explicit length is rejected')
    def test_lookup_and_picklists(self):
        r=field('Sales_Rep__c')
        for path,value in {'referenceTo':'User','relationshipName':'Sales_Quarterly_Targets','lookupFilter/active':'true','lookupFilter/isOptional':'false','lookupFilter/filterItems/field':'User.IsActive','lookupFilter/filterItems/operation':'equals','lookupFilter/filterItems/value':'true'}.items(): self.assertEqual(text(r,path),value)
        self.assertIsNone(text(r,'deleteConstraint'), 'User lookups cannot declare a delete constraint')
        self.assertEqual(text(r,'required'),'false')
        r=field('Fiscal_Quarter__c')
        self.assertEqual(text(r,'valueSet/restricted'),'true')
        values=r.findall('m:valueSet/m:valueSetDefinition/m:value',NS)
        self.assertEqual([(text(v,'fullName'),text(v,'label'),text(v,'default')) for v in values],[(f'Q{i}',label,'false') for i,label in enumerate(['First Quarter','Second Quarter','Third Quarter','Fourth Quarter'],1)])
        r=field('Product_Line__c')
        self.assertEqual(text(r,'valueSet/valueSetName'),'Product_Line')
        self.assertEqual(text(r,'valueSet/restricted'),'true')
        self.assertIsNone(r.find('m:valueSet/m:valueSetDefinition',NS))
    def test_formula_contract(self):
        for name,formula in FORMULAS.items(): self.assertEqual(text(field(name),'formula'),formula)
    def test_validations_and_system_boundary(self):
        self.assertEqual(text(rule('Target_Amount_Positive'),'errorConditionFormula'),'Target_Amount__c <= 0')
        self.assertEqual(text(rule('Fiscal_Year_Range'),'errorConditionFormula'),'OR(Fiscal_Year__c < 2025,Fiscal_Year__c > 2030)')
        required=rule('Sales_Rep_Required')
        self.assertEqual(text(required,'errorConditionFormula'),'ISBLANK(Sales_Rep__c)')
        self.assertEqual(text(required,'errorDisplayField'),'Sales_Rep__c')
        self.assertEqual(text(required,'errorMessage'),'Sales Rep is required.')
        self.assertEqual(text(required,'active'),'true')
        expected='AND(NOT($Permission.Sales_Target_System_Write),OR(AND(ISNEW(),OR('+','.join(f'NOT(ISBLANK({f}))' for f in SYSTEM)+')),AND(NOT(ISNEW()),OR('+','.join(f'ISCHANGED({f})' for f in SYSTEM)+'))))'
        r=rule('System_Fields_Protected')
        self.assertEqual(text(r,'errorConditionFormula'),expected)
        self.assertEqual(text(r,'errorMessage'),'Actuals and target keys can only be changed by the system.')
        self.assertIsNone(text(r,'errorDisplayField'))
        self.assertEqual(expected.count('('),expected.count(')'))
        for name in ['Target_Amount_Positive','Fiscal_Year_Range','System_Fields_Protected']: self.assertEqual(text(rule(name),'active'),'true')
    def test_unique_key_without_generation(self):
        r=field('Target_Key__c')
        for path,value in {'length':'80','unique':'true','externalId':'true','caseSensitive':'false','required':'false'}.items(): self.assertEqual(text(r,path),value)
        policy=(BASE/'classes/SalesTargetCurrencyPolicy.cls').read_text()
        self.assertNotIn('Target_Key__c',policy)
        self.assertNotIn('Actual_Amount__c',policy)
    def test_permission_boundaries(self):
        for name,manage in [('Sales_Target_Manage',True),('Sales_Target_Read',False)]:
            p=BASE/f'permissionsets/{name}/objectSettings/Sales_Target__c.objectSettings-meta.xml'
            r=ET.parse(p).getroot()  # decomposed fragments intentionally have no namespace
            grants=r.findall('fieldPermissions')
            self.assertEqual({g.findtext('field') for g in grants},{'Sales_Target__c.'+f for f in set(FIELDS)-REQUIRED})
            for grant in grants:
                f=grant.findtext('field').split('.')[1]
                self.assertEqual(grant.findtext('readable'),'true')
                self.assertEqual(grant.findtext('editable'),'true' if manage and f in ['Product_Line__c','Notes__c','Sales_Rep__c'] else 'false')
            for flag in ['allowCreate','allowEdit','allowDelete']: self.assertEqual(r.findtext('objectPermissions/'+flag),str(manage).lower())
            self.assertEqual(r.findtext('objectPermissions/allowRead'),'true')
            for flag in ['modifyAllRecords','viewAllRecords','viewAllFields']: self.assertEqual(r.findtext('objectPermissions/'+flag),'false')
            self.assertEqual(r.findtext('tabSettings/visibility'),'Available')
            self.assertIsNone(xml(f'permissionsets/{name}/{name}.permissionset-meta.xml').find('m:customPermissions',NS))
        r=xml('permissionsets/Sales_Target_System_Write_Access/Sales_Target_System_Write_Access.permissionset-meta.xml')
        self.assertEqual(text(r,'customPermissions/name'),'Sales_Target_System_Write')
        self.assertEqual(text(r,'customPermissions/enabled'),'true')
        for tag in ['objectPermissions','fieldPermissions','userPermissions','tabSettings','classAccesses']: self.assertIsNone(r.find('m:'+tag,NS))
    def test_layout_and_tab(self):
        r=xml('layouts/Sales_Target__c-Sales Quarterly Target Layout.layout-meta.xml')
        sections={text(s,'label'):s for s in r.findall('m:layoutSections',NS)}
        setup=sections['Target Setup'].findall('.//m:layoutItems',NS)
        self.assertEqual([text(i,'field') for i in setup],['Sales_Rep__c','Fiscal_Year__c','Fiscal_Quarter__c','Product_Line__c','Target_Amount__c','Notes__c'])
        self.assertEqual(text(setup[0],'behavior'),'Required')
        readonly=[]
        for section in ['Attainment','System']:
            for item in sections[section].findall('.//m:layoutItems',NS):
                self.assertEqual(text(item,'behavior'),'Readonly'); readonly.append(text(item,'field'))
        self.assertTrue(set(SYSTEM)|set(FORMULAS) <= set(readonly))
        self.assertEqual([item.text for item in r.findall('m:excludeButtons',NS)], ['Sharing'])
        self.assertNotIn('OwnerId', [item.text for item in r.findall('.//m:field',NS)])
        self.assertEqual(text(r,'relatedLists/relatedList'),'RelatedEntityHistoryList')
        self.assertEqual([text(i,'actionName') for i in r.findall('m:platformActionList/m:platformActionListItems',NS)],['Edit','Delete'])
        self.assertEqual(text(xml('tabs/Sales_Target__c.tab-meta.xml'),'customObject'),'true')
    def test_apex_scope_and_regression_inventory(self):
        policy=(BASE/'classes/SalesTargetCurrencyPolicy.cls').read_text()
        trigger=(BASE/'triggers/SalesTargetBeforeSave.trigger').read_text()
        self.assertEqual(trigger.count('SalesTargetCurrencyPolicy.beforeSave('),1)
        self.assertIn('before insert, before update',trigger)
        self.assertIn("containsKey('CurrencyIsoCode')",policy)
        self.assertEqual(policy.count('Database.query('),1)
        self.assertNotRegex(policy,r'\b(insert|update|delete|upsert)\s+\w+;')
        self.assertNotIn('Opportunity',policy)
        test=(BASE/'classes/SalesTargetCurrencyPolicyTest.cls').read_text()
        self.assertEqual(len(re.findall(r'@IsTest static void',test)),5)
        self.assertNotIn('SeeAllData',test)
        self.assertIn('Assert.areEqual(198, successes)',test)
        for name in ['SalesTargetCurrencyPolicy','SalesTargetCurrencyPolicyTest']:
            self.assertEqual(text(xml(f'classes/{name}.cls-meta.xml'),'apiVersion'),'67.0')

if __name__=='__main__': unittest.main(verbosity=2)
