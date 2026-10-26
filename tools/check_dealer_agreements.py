#!/usr/bin/env python3
"""Offline metadata contract checks; not Salesforce execution or persona acceptance."""
from pathlib import Path
from decimal import Decimal
import re
import xml.etree.ElementTree as ET

BASE = Path(__file__).resolve().parents[1] / 'force-app/main/default'
OBJ = 'Dealer_Agreement__c'
NS = {'m': 'http://soap.sforce.com/2006/04/metadata'}
checks = 0

def check(condition, message):
    global checks
    assert condition, message
    checks += 1

def read(path):
    return ET.parse(BASE / path).getroot()

def text(root, path):
    return root.findtext('/'.join('m:' + p for p in path.split('/')), namespaces=NS)

def items(root, path):
    return root.findall('/'.join('m:' + p for p in path.split('/')), NS)

obj = read(f'objects/{OBJ}/{OBJ}.object-meta.xml')
for tag, value in {'deploymentStatus':'Deployed', 'visibility':'Public', 'sharingModel':'ControlledByParent', 'externalSharingModel':'ControlledByParent', 'enableHistory':'true', 'enableActivities':'true', 'enableSearch':'true', 'enableReports':'true', 'nameField/type':'AutoNumber', 'nameField/displayFormat':'DA-{00000}', 'nameField/startingNumber':'1', 'nameField/label':'Agreement Number'}.items():
    check(text(obj, tag) == value, tag)
fields = {p.name.split('.')[0]: ET.parse(p).getroot() for p in (BASE / 'objects' / OBJ / 'fields').glob('*.xml')}
required = {'Dealer__c','Dealer_Tier__c','Start_Date__c','End_Date__c','Sales_Region__c','Authorized_Product_Lines__c','Annual_Target_Amount__c','Payment_Terms__c'}
optional = {'Dealer_Contact__c','Agreement_Status__c','Signed_Date__c','Rebate_Rate__c','Credit_Limit__c','Days_To_Expiry__c','Renewal_Opportunity__c','Termination_Reason__c','Notes__c'}
check(set(fields) == required | optional, 'exact field inventory')
check({f for f,r in fields.items() if text(r,'trackHistory') == 'true'} == {'Agreement_Status__c','Dealer_Tier__c','Rebate_Rate__c','Credit_Limit__c','End_Date__c'}, 'history')
for f,r in fields.items():
    if f != 'Dealer__c': check(text(r,'required') == str(f in required).lower(), f+' required')
for f,t in [('Start_Date__c','Date'),('End_Date__c','Date'),('Signed_Date__c','Date'),('Termination_Reason__c','TextArea'),('Notes__c','LongTextArea'),('Authorized_Product_Lines__c','MultiselectPicklist')]:check(text(fields[f],'type') == t, f+' type')
for f,prec,scale in [('Annual_Target_Amount__c','16','2'),('Credit_Limit__c','16','2'),('Rebate_Rate__c','3','1'),('Days_To_Expiry__c','18','0')]:
    check(text(fields[f],'precision') == prec and text(fields[f],'scale') == scale, f+' precision')
check(text(fields['Notes__c'],'length') == '32768', 'notes length')
check(text(fields['Days_To_Expiry__c'],'formula') == 'End_Date__c - TODAY()', 'expiry formula')
check(text(fields['Authorized_Product_Lines__c'],'valueSet/valueSetName') == 'Product_Line', 'dependency')
products=read('globalValueSets/Product_Line.globalValueSet-meta.xml')
check({'Air_Purifier','Dehumidifier'} <= {text(v,'fullName') for v in items(products,'customValue')}, 'fixture products')
for api,values in {'Agreement_Status__c':['Draft','In_Review','Active','Expired','Terminated'],'Dealer_Tier__c':['Gold','Silver','Bronze'],'Sales_Region__c':['North','Central','South','East'],'Payment_Terms__c':['Net_30','Net_60','COD','Prepaid']}.items():
    r=fields[api]; vs=items(r,'valueSet/valueSetDefinition/value')
    check([text(v,'fullName') for v in vs] == values, api+' values')
    check([text(v,'fullName') for v in vs if text(v,'default') == 'true'] == (['Draft'] if api=='Agreement_Status__c' else []), api+' defaults')
    check(text(r,'valueSet/restricted') == 'true', api+' restricted')
for api,target,filterfield,valuekey,value in [('Dealer__c','Account','Account.IsPersonAccount','value','false'),('Dealer_Contact__c','Contact','Contact.AccountId','valueField','$Source.Dealer__c')]:
    r=fields[api]
    for k,v in {'referenceTo':target,'relationshipName':'Dealer_Agreements','lookupFilter/active':'true','lookupFilter/isOptional':'false','lookupFilter/filterItems/field':filterfield,'lookupFilter/filterItems/operation':'equals','lookupFilter/filterItems/'+valuekey:value}.items():check(text(r,k)==v,api+' '+k)
check(text(fields['Dealer__c'],'reparentableMasterDetail')=='true' and text(fields['Dealer__c'],'writeRequiresMasterRead')=='true','agreement writes require only parent Read access')
for api in ['Dealer_Contact__c','Renewal_Opportunity__c']:check(text(fields[api],'deleteConstraint')=='SetNull',api+' delete')
rules={p.name.split('.')[0]:ET.parse(p).getroot() for p in (BASE/'objects'/OBJ/'validationRules').glob('*.xml')}
expected={
'End_After_Start':('End_Date__c <= Start_Date__c','End date must be later than start date.'),
'Rebate_Within_Tier_Cap':('AND(NOT(ISBLANK(Rebate_Rate__c)),OR(AND(ISPICKVAL(Dealer_Tier__c,"Gold"),Rebate_Rate__c>0.08),AND(ISPICKVAL(Dealer_Tier__c,"Silver"),Rebate_Rate__c>0.05),AND(ISPICKVAL(Dealer_Tier__c,"Bronze"),Rebate_Rate__c>0.03)))','Rebate rate exceeds the cap for this dealer tier (Gold 8%, Silver 5%, Bronze 3%).'),
'Active_Requires_Signed_Date':('AND(ISPICKVAL(Agreement_Status__c,"Active"),ISBLANK(Signed_Date__c))','A signing date must be entered before the agreement becomes active.'),
'Termination_Reason_Required':('AND(ISPICKVAL(Agreement_Status__c,"Terminated"),ISBLANK(TRIM(Termination_Reason__c)))','Please enter a termination reason when terminating the agreement.'),
'Agreement_Status_Required':('ISBLANK(TEXT(Agreement_Status__c))','Agreement Status is required.'),
'Sales_Draft_Only':('AND(NOT($Permission.Manage_Dealer_Agreements),OR(NOT(ISPICKVAL(Agreement_Status__c,"Draft")),AND(NOT(ISNEW()),NOT(ISPICKVAL(PRIORVALUE(Agreement_Status__c),"Draft")))))','Sales representatives can create and edit Draft agreements only.'),
'Manager_Only_Financial_Terms':('AND(NOT($Permission.Manage_Dealer_Agreements),IF(ISNEW(),OR(NOT(ISBLANK(Rebate_Rate__c)),NOT(ISBLANK(Credit_Limit__c))),OR(ISCHANGED(Rebate_Rate__c),ISCHANGED(Credit_Limit__c))))','Only channel managers and sales directors can change Rebate Rate or Credit Limit.')}
check(set(rules)==set(expected),'exact rules')
for name,(formula,msg) in expected.items():
    r=rules[name]
    check(text(r,'errorConditionFormula')==formula,name+' formula')
    check(text(r,'errorMessage')==msg,name+' message')
    check(text(r,'active')=='true',name+' active')
for persona in ['Manage','Edit','Read']:
    name='Dealer_Agreement_'+persona
    root=read(f'permissionsets/{name}/{name}.permissionset-meta.xml')
    ps=read(f'permissionsets/{name}/objectSettings/{OBJ}.objectSettings-meta.xml')
    grants={text(v,'field').split('.')[1]:text(v,'editable') for v in items(ps,'fieldPermissions')}
    check(set(grants)==optional,persona+' FLS inventory')
    for f,value in grants.items():
        edit=persona!='Read' and f not in {'Days_To_Expiry__c','Renewal_Opportunity__c'} and not (persona=='Edit' and f in {'Agreement_Status__c','Rebate_Rate__c','Credit_Limit__c'})
        check(value==str(edit).lower(),persona+' '+f)
    check(all(text(v,'readable')=='true' for v in items(ps,'fieldPermissions')),persona+' read fields')
    for k,v in {'allowRead':True,'allowCreate':persona!='Read','allowEdit':persona!='Read','allowDelete':False,'modifyAllRecords':False,'viewAllRecords':False}.items():check(text(ps,'objectPermissions/'+k)==str(v).lower(),persona+' '+k)
    check(len(items(ps,'objectPermissions'))==1 and text(ps,'objectPermissions/object')==OBJ,persona+' agreement object grant')
    # Owner-approved 2026-10-25 exceptions: Account and Contact Read only.
    check({p.name for p in (BASE/f'permissionsets/{name}/objectSettings').glob('*.xml')} == {f'{OBJ}.objectSettings-meta.xml','Account.objectSettings-meta.xml','Contact.objectSettings-meta.xml'},persona+' exact object scope')
    for parent in ['Account','Contact']:
        parent_ps=read(f'permissionsets/{name}/objectSettings/{parent}.objectSettings-meta.xml')
        check([v.tag.split('}')[-1] for v in parent_ps] == ['objectPermissions'],persona+' no '+parent+' field or other grants')
        expected_parent={'allowCreate':'false','allowDelete':'false','allowEdit':'false','allowRead':'true','modifyAllRecords':'false','object':parent,'viewAllFields':'false','viewAllRecords':'false'}
        check({v.tag.split('}')[-1]:v.text for v in items(parent_ps,'objectPermissions')[0]} == expected_parent,persona+' '+parent+' Read only')
    check([text(v,'name') for v in items(root,'customPermissions')]==(['Manage_Dealer_Agreements'] if persona=='Manage' else []),persona+' custom permission')
    check(text(root,'tabSettings/tab')==OBJ and text(root,'tabSettings/visibility')=='Visible',persona+' tab')
layout=read(f'layouts/{OBJ}-Dealer Agreement Layout.layout-meta.xml')
check([text(v,'label') for v in items(layout,'layoutSections')]==['Basic Agreement Information','Commercial Terms','Renewal and Termination','System Information'],'layout sections')
li=items(layout,'layoutSections/layoutColumns/layoutItems')
check({text(v,'field') for v in li}==set(fields)|{'Name','CreatedById','LastModifiedById'},'layout field inventory')
for v in li:
    f=text(v,'field'); b=text(v,'behavior')
    expect='Readonly' if f in {'Name','CreatedById','LastModifiedById','Days_To_Expiry__c','Renewal_Opportunity__c'} else 'Required' if f in required|{'Agreement_Status__c'} else 'Edit'
    check(b==expect,f+' layout behavior')
check({text(v,'relatedList') for v in items(layout,'relatedLists')}=={'RelatedActivityList','RelatedHistoryList','RelatedEntityHistoryList'},'activity/history lists')
account=read('layouts/Account-Account Layout.layout-meta.xml')
related=[v for v in items(account,'relatedLists') if text(v,'relatedList')==OBJ+'.Dealer__c']
check(len(related)==1,'account list once')
check([v.text for v in items(related[0],'fields')]==['NAME','Agreement_Status__c','Dealer_Tier__c','End_Date__c','Days_To_Expiry__c'],'account columns')
check(text(read(f'tabs/{OBJ}.tab-meta.xml'),'motif')=='Custom18: Form','tab motif')
print(f'PASS: {checks} offline metadata contract assertions. Salesforce deployment, formula execution, UI, personas and 200-row import are NOT verified by this checker.')
