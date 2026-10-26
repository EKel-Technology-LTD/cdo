"""CDO-48 metadata contract tests; not a substitute for sandbox persona E2E."""
import unittest
from pathlib import Path
import xml.etree.ElementTree as ET
B=Path(__file__).resolve().parents[1]/'force-app/main/default'
NS={'m':'http://soap.sforce.com/2006/04/metadata'}
def read(p): return ET.parse(B/p).getroot()
def all(e,p): return e.findall(p,NS)
def text(e,p): return e.findtext(p,namespaces=NS)
FIELDS={'Demo_Inquiry_Topic__c','Demo_Impact__c','Demo_Response_Stage__c'}
class Contract(unittest.TestCase):
 def setUp(self): self.f=read('flows/Banquet_Case_Classify.flow-meta.xml')
 def test_context_and_scope(self):
  self.assertEqual(text(self.f,'m:apiVersion'),'67.0')
  self.assertEqual(text(self.f,'m:runInMode'),'DefaultMode')
  self.assertEqual(text(self.f,'m:isAdditionalPermissionRequiredToRun'),'true')
  self.assertEqual([text(v,'m:name') for v in all(self.f,'m:variables') if text(v,'m:isInput')=='true'],['recordId'])
  for tag in ['actionCalls','subflows','loops','recordCreates','recordDeletes','waits']:
   self.assertFalse(all(self.f,'m:'+tag))
  self.assertNotIn('Subject',ET.tostring(self.f,encoding='unicode'))
 def test_single_constrained_write(self):
  updates=all(self.f,'m:recordUpdates'); self.assertEqual(len(updates),1)
  u=updates[0]; self.assertEqual(text(u,'m:object'),'Case'); self.assertEqual(text(u,'m:filterLogic'),'and')
  self.assertEqual({text(a,'m:field') for a in all(u,'m:inputAssignments')},FIELDS)
  self.assertEqual({text(x,'m:field'):text(x,'m:value/m:elementReference') or text(x,'m:value/m:stringValue') for x in all(u,'m:filters')},{'Id':'recordId','Demo_Event_Code__c':'CDO-BANQUET-DEMO'})
  self.assertIsNone(u.find('m:inputReference',NS))
  self.assertEqual(text(u,'m:connector/m:targetReference'),'Read_Back')
 def test_faults_and_read_fields(self):
  for r in all(self.f,'m:recordLookups'):
   self.assertEqual(text(r,'m:object'),'Case'); self.assertIsNotNone(r.find('m:faultConnector',NS))
   self.assertEqual({x.text for x in all(r,'m:queriedFields')},FIELDS|{'Id','Demo_Event_Code__c'})
  self.assertIsNotNone(self.f.find('m:recordUpdates/m:faultConnector',NS))
 def test_screens_and_graph(self):
  nodes={text(n,'m:name'):n for n in self.f if n.find('m:locationX',NS) is not None and text(n,'m:name')}
  for t in all(self.f,'.//m:targetReference'): self.assertIn(t.text,nodes)
  for s in all(self.f,'m:screens'):
   self.assertEqual(text(s,'m:allowPause'),'false')
   if text(s,'m:name')!='Confirm_Summary': self.assertEqual(text(s,'m:allowBack'),'false')
  self.assertEqual(text(nodes['Edit_Classification'],'m:connector/m:targetReference'),'Confirm_Summary')
  self.assertEqual(text(nodes['Confirm_Summary'],'m:connector/m:targetReference'),'Recheck_Case')
  self.assertEqual(text(nodes['Confirm_Summary'],'m:nextOrFinishButtonLabel'),'儲存')
  self.assertEqual(text(nodes['Read_Back'],'m:faultConnector/m:targetReference'),'Unconfirmed')
  self.assertEqual(text(nodes['Verify_Result'],'m:defaultConnector/m:targetReference'),'Unconfirmed')
 def test_save_requires_confirmation_and_no_retry(self):
  nodes={text(n,'m:name'):n for n in self.f if n.find('m:locationX',NS) is not None and text(n,'m:name')}
  graph={name:[t.text for t in all(n,'.//m:targetReference')] for name,n in nodes.items()}
  def paths(name,trail=()):
   self.assertNotIn(name,trail, 'forward graph must not loop or retry writes')
   trail=trail+(name,)
   if name=='Save_Classification':
    self.assertIn('Confirm_Summary',trail)
    self.assertIn('Recheck_Case',trail)
    self.assertIn('Check_Before_Save',trail)
   if name=='Saved':
    self.assertIn('Save_Classification',trail)
    self.assertIn('Read_Back',trail)
    self.assertIn('Verify_Result',trail)
   for target in graph[name]: paths(target,trail)
  paths('Validate_Record_Id')
  for name in ['Read_Error','Outside_Event','Write_Error','Unconfirmed','Saved']:
   self.assertEqual(graph[name],[])
 def test_choice_sets(self):
  self.assertEqual({text(c,'m:picklistField') for c in all(self.f,'m:dynamicChoiceSets')},FIELDS)
  self.assertFalse(all(self.f,'m:choices'))
 def test_picklist_choice_set_schema_regression(self):
  # 0AfAu00000iLMDtKAO: even an empty object element conflicts with picklistObject.
  choices=all(self.f,'m:dynamicChoiceSets')
  self.assertEqual(len(choices),3)
  for choice in choices:
   with self.subTest(choice=text(choice,'m:name')):
    self.assertEqual(text(choice,'m:dataType'),'Picklist')
    self.assertEqual(text(choice,'m:picklistObject'),'Case')
    self.assertIn(text(choice,'m:picklistField'),FIELDS)
    self.assertEqual({child.tag.split('}')[-1] for child in choice},
                     {'name','dataType','picklistField','picklistObject'},
                     'Picklist choice sets must omit record-choice object/displayField, even when empty')
 def test_entry_and_minimal_permission(self):
  a=read('quickActions/Case.Organize_Banquet_Inquiry.quickAction-meta.xml')
  self.assertEqual(text(a,'m:type'),'Flow'); self.assertEqual(text(a,'m:flowDefinition'),'Banquet_Case_Classify')
  p=read('permissionsets/Banquet_Case_Flow_Run/Banquet_Case_Flow_Run.permissionset-meta.xml')
  self.assertEqual({x.tag.split('}')[-1] for x in p},{'description','hasActivationRequired','label'})
  grant=ET.parse(B/'permissionsets/Banquet_Case_Flow_Run/Banquet_Case_Flow_Run.flowAccess-meta.xml').getroot()
  self.assertEqual(grant.findtext('flowAccesses/flow'),'Banquet_Case_Classify')
  self.assertEqual(grant.findtext('flowAccesses/enabled'),'true')
  self.assertEqual([x.tag for x in grant],['flowAccesses'])
  l=read('layouts/Case-Case Layout.layout-meta.xml')
  actions=[text(a,'m:actionName') for a in all(l,'m:platformActionList/m:platformActionListItems')]
  self.assertEqual(actions.count('Case.Organize_Banquet_Inquiry'),1)
  self.assertEqual(actions[:6],['FeedItem.TextPost','Case.LogACall','Case.CaseComment','Case.ChangeStatus','FeedItem.ContentPost','FeedItem.LinkPost'])
if __name__=='__main__': unittest.main(verbosity=2)
