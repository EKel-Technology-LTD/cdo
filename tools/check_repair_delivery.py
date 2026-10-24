#!/usr/bin/env python3
"""Offline repair-order contract checks. Not a substitute for Salesforce/QA execution."""
from pathlib import Path
import hashlib
import re
import unittest
import xml.etree.ElementTree as ET

BASE = Path(__file__).resolve().parents[1] / 'force-app/main/default'
NS = {'m': 'http://soap.sforce.com/2006/04/metadata'}
OBJECT = BASE / 'objects/Repair_Order__c'
REQUIRED = {'Case__c', 'Asset__c', 'Intake_Method__c', 'Fault_Category__c'}
READONLY = {'Total_Charge__c', 'Turnaround_Days__c', 'Is_Overdue__c', 'Overdue_Reminder_Sent__c'}
AGENT = {'Case__c', 'Asset__c', 'Intake_Method__c', 'Fault_Category__c', 'Fault_Description__c',
         'Customer_Approved_Quote__c', 'Quote_Approved_Date__c', 'CurrencyIsoCode'}

def text(root, path):
    return root.findtext('/'.join('m:' + part for part in path.split('/')), namespaces=NS)

def read(path):
    return ET.parse(path).getroot()

class RepairContract(unittest.TestCase):
    def test_schema_and_history(self):
        root = read(OBJECT / 'Repair_Order__c.object-meta.xml')
        expected = {'deploymentStatus': 'Deployed', 'sharingModel': 'ReadWrite',
                    'externalSharingModel': 'Private', 'nameField/displayFormat': 'RO-{YYYY}{MM}-{0000}',
                    'nameField/type': 'AutoNumber', 'nameField/label': 'Order Number'}
        expected.update({key: 'true' for key in ['enableActivities', 'enableHistory', 'enableReports', 'enableSearch']})
        for key, value in expected.items():
            self.assertEqual(value, text(root, key), key)
        fields = {p.name.split('.')[0]: read(p) for p in (OBJECT / 'fields').glob('*.xml')}
        self.assertEqual(23, len(fields))
        self.assertEqual(REQUIRED, {f for f, r in fields.items() if text(r, 'required') == 'true'})
        self.assertEqual({'Repair_Status__c','Warranty_Coverage__c','Parts_Cost__c','Labor_Cost__c','Customer_Approved_Quote__c'},
                         {f for f, r in fields.items() if text(r,'trackHistory') == 'true'})
        for field in ['Case__c', 'Asset__c']:
            self.assertEqual('Restrict', text(fields[field], 'deleteConstraint'))
            self.assertEqual('Repair_Orders', text(fields[field], 'relationshipName'))
        for field in ['Fault_Description__c','Diagnosis_Result__c','Technician_Notes__c']:
            self.assertEqual('LongTextArea',text(fields[field],'type'))
            self.assertEqual('4000',text(fields[field],'length'))
        for field in ['Parts_Cost__c','Labor_Cost__c']:
            self.assertEqual('10',text(fields[field],'precision'))
            self.assertEqual('2',text(fields[field],'scale'))
        self.assertEqual('30',text(fields['Return_Tracking_Number__c'],'length'))

    def test_picklists(self):
        expected = {
            'Repair_Status__c': 'Awaiting_Receipt|Received|Diagnosing|Awaiting_Approval|Awaiting_Parts|In_Repair|Repaired|Shipped_Back|Unrepairable|Cancelled',
            'Intake_Method__c': 'Store_Dropoff|Courier_Pickup|Onsite',
            'Fault_Category__c': 'No_Power|Abnormal_Noise|Odor|Leakage|Sensor_Error|Poor_Performance|Physical_Damage|Other',
            'Warranty_Coverage__c': 'In_Warranty|Out_Of_Warranty|Customer_Damage'}
        for field, values in expected.items():
            root=read(OBJECT/'fields'/f'{field}.field-meta.xml')
            self.assertEqual('true',text(root,'valueSet/restricted'))
            rows=root.findall('m:valueSet/m:valueSetDefinition/m:value',NS)
            self.assertEqual(values.split('|'),[text(row,'fullName') for row in rows])
            self.assertEqual(['Awaiting_Receipt'] if field=='Repair_Status__c' else [],
                             [text(row,'fullName') for row in rows if text(row,'default')=='true'])

    def test_formula_and_validation_contracts(self):
        total=read(OBJECT/'fields/Total_Charge__c.field-meta.xml')
        self.assertEqual('IF(ISPICKVAL(Warranty_Coverage__c,"In_Warranty"),0,BLANKVALUE(Parts_Cost__c,0)+BLANKVALUE(Labor_Cost__c,0))',text(total,'formula'))
        turnaround=read(OBJECT/'fields/Turnaround_Days__c.field-meta.xml')
        self.assertEqual('IF(OR(ISBLANK(Repair_Completed_Date__c),ISBLANK(Received_Date__c)),NULL,Repair_Completed_Date__c-Received_Date__c)',text(turnaround,'formula'))
        overdue=read(OBJECT/'fields/Is_Overdue__c.field-meta.xml')
        formula=text(overdue,'formula')
        self.assertIn('TODAY()-Received_Date__c>7',formula)
        self.assertEqual(['Repaired','Shipped_Back','Unrepairable','Cancelled'],re.findall(r'ISPICKVAL\(Repair_Status__c,"(.*?)"\)',formula))
        rules=list((OBJECT/'validationRules').glob('*.xml'))
        self.assertEqual(4,len(rules))
        for path in rules:
            root=read(path)
            self.assertEqual('true',text(root,'active'))
            self.assertNotIn('Diagnosis_Result__c',text(root,'errorConditionFormula'))
            self.assertNotIn('Fault_Description__c',text(root,'errorConditionFormula'))

    def test_permission_boundaries(self):
        custom={p.name.split('.')[0] for p in (OBJECT/'fields').glob('*.xml')}
        for persona in ['Technician','Agent','Read']:
            name='Repair_Order_'+persona
            root=read(BASE/'permissionsets'/name/'objectSettings/Repair_Order__c.objectSettings-meta.xml')
            permissions={text(row,'field').split('.')[1]:row for row in root.findall('m:fieldPermissions',NS)}
            expected=(custom|{'CurrencyIsoCode'})-REQUIRED
            if persona!='Technician': expected.remove('Technician_Notes__c')
            self.assertEqual(expected,set(permissions))
            edits={field for field,row in permissions.items() if text(row,'editable')=='true'}
            self.assertEqual(expected-READONLY if persona=='Technician' else AGENT-REQUIRED if persona=='Agent' else set(),edits)
            for row in permissions.values():self.assertEqual('true',text(row,'readable'))
            for right in ['allowDelete','modifyAllRecords','viewAllRecords']:
                self.assertEqual('false',text(root,'objectPermissions/'+right))
            self.assertEqual('true',text(root,'objectPermissions/allowRead'))
            for right in ['allowCreate','allowEdit']:
                self.assertEqual('false' if persona=='Read' else 'true',text(root,'objectPermissions/'+right))
            master=read(BASE/'permissionsets'/name/(name+'.permissionset-meta.xml'))
            self.assertEqual('Available',text(master,'tabSettings/visibility'))

    def test_parent_layout_preservation(self):
        hashes={'Case':'1f689b9bae83fc8fc5b14d24f7d8d60c21bd395c866ce0734d6b40ef1e6229f4',
                'Asset':'484937ac4b9ba52b41009b510173ddd9c791cdbce9f09dcfd7d3d2277b9d5cd0'}
        for obj, expected in hashes.items():
            source=(BASE/'layouts'/f'{obj}-{obj} Layout.layout-meta.xml').read_text()
            addition='    <relatedLists>\n'+''.join(f'        <fields>{field}</fields>\n' for field in ['NAME','Repair_Status__c','Received_Date__c','Is_Overdue__c'])+f'        <relatedList>Repair_Order__c.{obj}__c</relatedList>\n    </relatedLists>\n'
            self.assertEqual(1,source.count(addition))
            self.assertEqual(expected,hashlib.sha256(source.replace(addition,'',1).encode()).hexdigest())

    def test_repair_layout(self):
        root=read(BASE/'layouts/Repair_Order__c-Repair Order Layout.layout-meta.xml')
        sections=root.findall('m:layoutSections',NS)
        self.assertEqual(['Intake Information','Diagnosis and Quote','Repair and Shipping','Internal'],[text(s,'label') for s in sections])
        items=root.findall('m:layoutSections/m:layoutColumns/m:layoutItems',NS)
        fields={text(i,'field'):text(i,'behavior') for i in items}
        custom={p.name.split('.')[0] for p in (OBJECT/'fields').glob('*.xml')}
        self.assertEqual(custom|{'Name','CurrencyIsoCode','CreatedById','LastModifiedById'},set(fields))
        for field in REQUIRED|{'Fault_Description__c','CurrencyIsoCode'}:self.assertEqual('Required',fields[field])
        for field in READONLY|{'Name','CreatedById','LastModifiedById'}:self.assertEqual('Readonly',fields[field])
        self.assertEqual('Edit',fields['Repair_Status__c'])

    def test_apex_contract_and_test_inventory(self):
        validator=(BASE/'classes/RepairOrderValidator.cls').read_text()
        trigger=(BASE/'triggers/RepairOrderValidation.trigger').read_text()
        tests=(BASE/'classes/RepairOrderValidatorTest.cls').read_text()
        self.assertIn('before insert, before update',trigger)
        self.assertIn('RepairOrderValidator.validate(Trigger.new)',trigger)
        self.assertEqual(1,validator.count('SELECT '))
        self.assertIn('WITH SYSTEM_MODE LIMIT 2',validator)
        self.assertNotRegex(validator,r'(?i)\b(insert|update|delete)\s+(as\s+system|orders)')
        self.assertNotIn('SeeAllData=true',tests)
        self.assertIn('bulkImport200Has195SuccessesAnd5DescriptionFailures',tests)
        self.assertIn('bulk251InsertAndUpdateValidateAcrossChunks',tests)
        self.assertEqual(28,len(re.findall(r'@IsTest static void ',tests)))
        for path in ['classes/RepairOrderValidator.cls-meta.xml','classes/RepairOrderValidatorTest.cls-meta.xml','triggers/RepairOrderValidation.trigger-meta.xml']:
            self.assertEqual('67.0',text(read(BASE/path),'apiVersion'))

if __name__=='__main__':
    unittest.main(verbosity=2)
