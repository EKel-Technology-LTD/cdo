"""Reproducible source contract checks; not a replacement for Salesforce/Jest execution."""
from pathlib import Path
import xml.etree.ElementTree as E
B=Path('force-app/main/default'); ns={'m':'http://soap.sforce.com/2006/04/metadata'}
def read(p):return E.parse(B/p).getroot()
def value(r,path):return r.findtext('/'.join('m:'+part for part in path.split('/')),namespaces=ns)
checks=[]
def check(name,condition):
 assert condition,name
 checks.append(name)
r=read('objects/Opportunity/Opportunity.object-meta.xml')
check('Private sharing preserved',value(r,'sharingModel')=='Private' and value(r,'externalSharingModel')=='Private')
check('Sales org default wired',value(r,'actionOverrides/content')=='Opportunity_Sales_Record_Page')
for obj in ['Opportunity','Discount_Approval__c']:
 for p in (B/'objects'/obj).rglob('*.xml'):E.parse(p)
check('Object XML parses',True)
for permission,editable in [('Discount_Sales_User',{'Opportunity.Discount_Percent__c','Opportunity.Discount_Reason__c'}),('Deal_Desk_Analyst',set())]:
 found=set()
 for p in (B/'permissionsets'/permission).rglob('*.xml'):
  r=E.parse(p).getroot()
  for entry in r.findall('m:fieldPermissions',ns):
   if value(entry,'editable')=='true':found.add(value(entry,'field'))
  for entry in r.findall('m:objectPermissions',ns):
   check(permission+' '+value(entry,'object')+' is read-only',all(value(entry,k)=='false' for k in ['allowCreate','allowDelete','allowEdit','modifyAllRecords','viewAllRecords']) and value(entry,'allowRead')=='true')
 check(permission+' exact editable discount fields',found==editable)
for group in ['Deal_Desk_Analysts','Discount_Executive_Approvers']:
 check(group+' excludes hierarchy bosses',value(read('groups/'+group+'.group-meta.xml'),'doesIncludeBosses')=='false')
for p in (B/'classes').glob('Discount*.cls'):
 check(p.name+' metadata paired',Path(str(p)+'-meta.xml').exists())
 check(p.name+' sharing declared','with sharing class' in p.read_text() or 'without sharing class' in p.read_text())
for p in (B/'triggers').glob('*Discount*.trigger'):check(p.name+' metadata paired',Path(str(p)+'-meta.xml').exists())
tests=(B/'classes/DiscountApprovalTest.cls').read_text()
check('200 and 251 bulk test fixtures present','bulkOpportunities(200)' in tests and 'bulkOpportunities(251)' in tests)
service=(B/'classes/DiscountApprovalService.cls').read_text()
check('Owner and submitter checks present','opportunity.OwnerId == caller || cycle.Submitted_By__c == caller' in service)
check('UI read uses user-mode security','WITH USER_MODE' in service)
check('Decision context setter is private','writingOutcome { get; private set; }' in service)
check('Atomic decision rollback present','Database.rollback(checkpoint)' in service)
check('Mandatory server comment check','String.isBlank(comment)' in service)
check('No automation kill-switch bypass',all('xDO_Tool_ProcessAutomationSwitch' not in p.read_text() for p in (B/'classes').glob('Discount*.cls')))
check('LWC Jest tests included',(B/'lwc/discountApprovalPanel/__tests__/discountApprovalPanel.test.js').exists())
for name in ['Opportunity_Sales_Record_Page','Deal_Desk_Opportunity_Record_Page']:
 p=B/'flexipages'/f'{name}.flexipage-meta.xml';E.parse(p);check(name+' contains approval panel','c:discountApprovalPanel' in p.read_text())
check('Deal Desk app assignment',value(read('applications/Deal_Desk.app-meta.xml'),'actionOverrides/content')=='Deal_Desk_Opportunity_Record_Page')
handler=(B/'classes/DiscountApprovalHandler.cls').read_text()
changed=handler.split('private static Boolean changed(',1)[1].split('private static Boolean requiresApproval',1)[0]
check('CloseDate invalidates approval in shared before/after predicate','current.CloseDate != previous.CloseDate' in changed)
check('Closed Won guard checks both old and new approval threshold','(requiresApproval(old) || requiresApproval(record)) && changed(record,old,true)' in handler)
check('Threshold is null safe and inclusive at ten','record.Discount_Percent__c != null && record.Discount_Percent__c >= 10' in handler)
check('Conversion skipped below threshold','String route = requiresApproval(record)\n                    ? DiscountApprovalPolicy.route(record.Discount_Percent__c,DiscountApprovalPolicy.corporateAmount(record)) : null;' in handler)
check('Both trigger phases use same invalidation predicate',handler.count('if (recalculate(record,old))')==2)
check('Pending and approved cycles superseded',"Status__c IN ('Pending','Approved')" in handler and "cycle.Status__c = 'Superseded'" in handler)
for method in ['closedBlankDiscountStaysEditable','closedBelowTenStaysEditable','closedDiscountCannotCrossThreshold','closedApprovedDiscountCannotDropBelowTen','closeDateInvalidatesPending','closeDateInvalidatesApproved']:
 check(method+' regression delivered','@IsTest static void '+method+'()' in tests)
print('\n'.join('PASS '+name for name in checks));print(f'{len(checks)} source contract checks passed. Runtime acceptance NOT verified.')
