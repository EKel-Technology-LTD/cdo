/** Synthetic, isolated regression tests. Real UI, archived-record visibility and concurrent
 * transactions require the separately recorded QA scenarios; mocks are not their verdicts.
 */
@IsTest
private with sharing class DemoLeadFollowupServiceTest {
    private static Lead fixture(Integer number, String intent) {
        return new Lead(LastName='合成餐會測試'+number, Company='Synthetic Banquet '+number,
            OwnerId=UserInfo.getUserId(), Demo_Event_Code__c='CDO-BANQUET-DEMO', Demo_Followup_Intent__c=intent);
    }
    private static DemoLeadFollowupAction.Request request(Id leadId, String prior, Boolean isNew) {
        DemoLeadFollowupAction.Request input = new DemoLeadFollowupAction.Request();
        input.leadId=leadId; input.priorIntent=prior; input.isNew=isNew;
        return input;
    }
    private static List<Task> tasksFor(Set<Id> ids) {
        return [SELECT Id, WhoId, OwnerId, Subject, ActivityDate, Status, Priority, WhatId, IsReminderSet, IsClosed
            FROM Task WHERE WhoId IN :ids AND Subject = :DemoLeadFollowupService.SUBJECT WITH SYSTEM_MODE ALL ROWS];
    }
    @IsTest static void mediumToHighCopiesDate() {
        Lead lead=fixture(1,'Medium'); lead.Demo_Followup_Date__c=Date.newInstance(2030,1,2); insert lead;
        Test.startTest(); lead.Demo_Followup_Intent__c='High'; update lead; Test.stopTest();
        List<Task> tasks=tasksFor(new Set<Id>{lead.Id});
        Assert.areEqual(1,tasks.size(),'一筆正確關聯的任務');
        Task task=tasks[0];
        Assert.areEqual(lead.Id,task.WhoId,'WhoId 必須為名單');
        Assert.areEqual(lead.OwnerId,task.OwnerId,'保留啟用使用者擁有者');
        Assert.areEqual(lead.Demo_Followup_Date__c,task.ActivityDate,'直接複製指定日期');
        Assert.areEqual(null,task.WhatId,'不設定 WhatId');
        Assert.areEqual(false,task.IsReminderSet,'不得設定提醒');
        Assert.areEqual(false,task.IsClosed,'預設狀態未完成');
        Assert.areEqual([SELECT ApiName FROM TaskStatus WHERE IsDefault=true].ApiName,task.Status,'採用 API 預設狀態');
        Assert.areEqual([SELECT ApiName FROM TaskPriority WHERE IsDefault=true].ApiName,task.Priority,'採用 API 預設優先順序');
    }
    @IsTest static void newHighUsesTaipeiTomorrow() {
        DemoLeadFollowupService.clockOverride=Datetime.newInstanceGmt(2030,1,1,16,0,0);
        Lead lead=fixture(2,'High');
        Test.startTest(); insert lead; Test.stopTest();
        List<Task> tasks=tasksFor(new Set<Id>{lead.Id});
        Assert.areEqual(1,tasks.size(),'新增 High 建立一次');
        Assert.areEqual(Date.newInstance(2030,1,3),tasks[0].ActivityDate,'台北瞬間日期加一天');
        Assert.areEqual(0,Limits.getEmailInvocations(),'沒有 Apex 寄信');
    }
    @IsTest static void taipeiMidnightBoundary() {
        Test.startTest();
        Date beforeMidnight=DemoLeadFollowupService.taipeiTomorrow(Datetime.newInstanceGmt(2030,1,1,15,59,59));
        Date atMidnight=DemoLeadFollowupService.taipeiTomorrow(Datetime.newInstanceGmt(2030,1,1,16,0,0));
        Test.stopTest();
        Assert.areEqual(Date.newInstance(2030,1,2),beforeMidnight,'台北午夜前');
        Assert.areEqual(Date.newInstance(2030,1,3),atMidnight,'台北午夜起');
    }
    @IsTest static void repeatedAndCompletedNeverDuplicate() {
        Lead lead=fixture(3,'High'); insert lead;
        List<Task> original=tasksFor(new Set<Id>{lead.Id});
        String closed=[SELECT ApiName FROM TaskStatus WHERE IsClosed=true LIMIT 1].ApiName;
        Test.startTest();
        update lead;
        lead.Demo_Followup_Intent__c='Low'; update lead;
        lead.Demo_Followup_Intent__c='High'; update lead;
        original[0].Status=closed; update original;
        update lead;
        lead.Demo_Followup_Intent__c='Medium'; update lead;
        lead.Demo_Followup_Intent__c='High'; update lead;
        Test.stopTest();
        List<Task> actual=tasksFor(new Set<Id>{lead.Id});
        Assert.areEqual(1,actual.size(),'重存／降低再升高／完成後仍僅一筆');
        Assert.areEqual(original[0].Id,actual[0].Id,'不得取代既有任務');
        Assert.areEqual(closed,actual[0].Status,'不得修改既有任務');
    }
    @IsTest static void manualTaskPreventsCreation() {
        Lead lead=fixture(4,'Medium'); insert lead;
        Task manual=new Task(WhoId=lead.Id,OwnerId=lead.OwnerId,Subject=DemoLeadFollowupService.SUBJECT,
            ActivityDate=Date.newInstance(2031,2,3)); insert manual;
        Test.startTest(); lead.Demo_Followup_Intent__c='High'; update lead; Test.stopTest();
        List<Task> actual=tasksFor(new Set<Id>{lead.Id});
        Assert.areEqual(1,actual.size(),'人工同名任務亦防重');
        Assert.areEqual(manual.Id,actual[0].Id,'保留人工任務');
        Assert.areEqual(manual.ActivityDate,actual[0].ActivityDate,'保留原期限');
    }
    @IsTest static void deletedTaskDoesNotCount() {
        Lead lead=fixture(5,'High'); insert lead;
        delete tasksFor(new Set<Id>{lead.Id});
        lead.Demo_Followup_Intent__c='Low'; update lead;
        Test.startTest(); lead.Demo_Followup_Intent__c='High'; update lead; Test.stopTest();
        Assert.areEqual(1,[SELECT COUNT() FROM Task WHERE WhoId=:lead.Id AND IsDeleted=false],'已刪除任務不算現存');
    }
    @IsTest static void otherEventExcluded() {
        Lead lead=fixture(6,'High'); lead.Demo_Event_Code__c='OTHER';
        Test.startTest(); insert lead; Test.stopTest();
        Assert.areEqual(0,tasksFor(new Set<Id>{lead.Id}).size(),'其他活動不建立');
    }
    @IsTest static void eventMustMatchExactly() {
        Lead lead=fixture(7,'High'); lead.Demo_Event_Code__c='cdo-banquet-demo';
        Test.startTest(); insert lead; Test.stopTest();
        Assert.areEqual(0,tasksFor(new Set<Id>{lead.Id}).size(),'活動大小寫須完全符合');
    }
    @IsTest static void nonHighExcluded() {
        Lead lead=fixture(8,'Medium');
        Test.startTest(); insert lead; update lead; Test.stopTest();
        Assert.areEqual(0,tasksFor(new Set<Id>{lead.Id}).size(),'非高意圖不建立');
    }
    @IsTest static void eventChangeDoesNotBackfill() {
        Lead lead=fixture(9,'High'); lead.Demo_Event_Code__c='OTHER'; insert lead;
        Test.startTest(); lead.Demo_Event_Code__c='CDO-BANQUET-DEMO'; update lead; update lead; Test.stopTest();
        Assert.areEqual(0,tasksFor(new Set<Id>{lead.Id}).size(),'只改活動／既有 High 不回填');
    }
    @IsTest static void nullIntentTransitionsToHigh() {
        Lead lead=fixture(10,null); insert lead;
        Test.startTest(); lead.Demo_Followup_Intent__c='High'; update lead; Test.stopTest();
        Assert.areEqual(1,tasksFor(new Set<Id>{lead.Id}).size(),'空白亦為非 High');
    }
    @IsTest static void convertedGuardRejectsInMemoryRecord() {
        Lead converted=(Lead)JSON.deserialize('{"IsConverted":true,"Demo_Event_Code__c":"CDO-BANQUET-DEMO","Demo_Followup_Intent__c":"High"}',Lead.class);
        Test.startTest(); Boolean eligible=DemoLeadFollowupService.qualifies(converted,request(null,'Medium',false)); Test.stopTest();
        Assert.isFalse(eligible,'服務重驗已轉換狀態；此測試不冒充真實轉換 UI 證據');
    }
    @IsTest static void convertingMediumCreatesNoTask() {
        Lead lead=fixture(11,'Medium'); insert lead;
        Database.LeadConvert conversion=new Database.LeadConvert();
        conversion.setLeadId(lead.Id); conversion.setDoNotCreateOpportunity(true);
        conversion.setConvertedStatus([SELECT MasterLabel FROM LeadStatus WHERE IsConverted=true LIMIT 1].MasterLabel);
        conversion.setSendNotificationEmail(false);
        Test.startTest(); Database.LeadConvertResult result=Database.convertLead(conversion); Test.stopTest();
        Assert.isTrue(result.isSuccess(),'合成名單轉換成功');
        Assert.areEqual(0,tasksFor(new Set<Id>{lead.Id}).size(),'轉換不新增跟進');
    }
    private static void verifyBulk(Integer size) {
        List<Lead> leads=new List<Lead>();
        for (Integer index=0;index<size;index++) {
            Lead lead=fixture(1000+index,'Medium');
            if (Math.mod(index,2)==0) lead.Demo_Followup_Date__c=Date.newInstance(2030,6,1);
            leads.add(lead);
        }
        insert leads;
        DemoLeadFollowupService.clockOverride=Datetime.newInstanceGmt(2030,5,1,16,0,0);
        for (Lead lead : leads) lead.Demo_Followup_Intent__c='High';
        Test.startTest(); update leads; Test.stopTest();
        Map<Id,Lead> expected=new Map<Id,Lead>(leads);
        List<Task> actual=tasksFor(expected.keySet());
        Assert.areEqual(size,actual.size(),'每筆合成名單恰有一任務');
        Set<Id> seen=new Set<Id>();
        for (Task task : actual) {
            Assert.isFalse(seen.contains(task.WhoId),'不得重複 WhoId'); seen.add(task.WhoId);
            Lead lead=expected.get(task.WhoId);
            Assert.areEqual(lead.OwnerId,task.OwnerId,'逐筆 owner');
            Assert.areEqual(lead.Demo_Followup_Date__c==null ? Date.newInstance(2030,5,3) : lead.Demo_Followup_Date__c,
                task.ActivityDate,'逐筆期限');
            Assert.areEqual(false,task.IsReminderSet,'逐筆無提醒');
        }
        Assert.areEqual(expected.keySet(),seen,'逐筆完整對照');
    }
    @IsTest static void batch20() { verifyBulk(20); }
    @IsTest static void batch200() { verifyBulk(200); }
    @IsTest static void batch251CrossesTriggerBoundary() { verifyBulk(251); }
    @IsTest static void taskFailureRollsBackLead() {
        Lead lead=fixture(20,'Medium'); insert lead;
        DemoLeadFollowupService.rejectTaskFor.add(lead.Id);
        Test.startTest();
        lead.Demo_Followup_Intent__c='High';
        Database.SaveResult result=Database.update(lead,false);
        Test.stopTest();
        Assert.isFalse(result.isSuccess(),'Task 拒絕必須使名單儲存失敗');
        Assert.areEqual('Medium',[SELECT Demo_Followup_Intent__c FROM Lead WHERE Id=:lead.Id].Demo_Followup_Intent__c,'名單回復');
        Assert.areEqual(0,tasksFor(new Set<Id>{lead.Id}).size(),'無殘留任務');
        Assert.isTrue(result.getErrors()[0].getMessage().contains(DemoLeadFollowupService.TASK_ERROR),'安全繁體中文錯誤');
    }
    @IsTest static void allOrNoneRollsBackBatch() {
        List<Lead> leads=new List<Lead>{fixture(21,'Medium'),fixture(22,'Medium')}; insert leads;
        DemoLeadFollowupService.rejectTaskFor.add(leads[1].Id);
        for (Lead lead : leads) lead.Demo_Followup_Intent__c='High';
        Test.startTest();
        try { update leads; Assert.fail('allOrNone 必須失敗'); } catch (DmlException expected) {
            Assert.isTrue(expected.getMessage().contains(DemoLeadFollowupService.TASK_ERROR),'回傳安全錯誤');
        }
        Test.stopTest();
        Set<Id> ids=new Map<Id,Lead>(leads).keySet();
        Assert.areEqual(0,tasksFor(ids).size(),'整批 Task 回復');
        Assert.areEqual(2,[SELECT COUNT() FROM Lead WHERE Id IN :ids AND Demo_Followup_Intent__c='Medium'],'整批名單回復');
    }
    @IsTest static void partialResultsThenManualResubmit() {
        List<Lead> leads=new List<Lead>{fixture(23,'Medium'),fixture(24,'Medium')}; insert leads;
        DemoLeadFollowupService.rejectTaskFor.add(leads[1].Id);
        for (Lead lead : leads) lead.Demo_Followup_Intent__c='High';
        Test.startTest();
        List<Database.SaveResult> results=Database.update(leads,false);
        Assert.isFalse(results[1].isSuccess(),'被拒絕筆不能成功');
        Set<Id> ids=new Map<Id,Lead>(leads).keySet();
        Map<Id,Lead> saved=new Map<Id,Lead>([SELECT Id,Demo_Followup_Intent__c FROM Lead WHERE Id IN :ids]);
        for (Integer index=0;index<results.size();index++) {
            Assert.areEqual(results[index].isSuccess() ? 'High' : 'Medium',saved.get(leads[index].Id).Demo_Followup_Intent__c,'逐筆 SaveResult 對照實際提交');
        }
        DemoLeadFollowupService.rejectTaskFor.clear();
        update leads; // explicit human-equivalent resubmit; no production retry loop
        Test.stopTest();
        List<Task> actual=tasksFor(ids);
        Assert.areEqual(leads.size(),actual.size(),'重送後每 Lead 一筆，不依賴 static 已處理旗標');
        Set<Id> seen=new Set<Id>(); for (Task task : actual) seen.add(task.WhoId);
        Assert.areEqual(ids,seen,'重送結果完整');
    }
    private static Group queueFixture() {
        Group queue=new Group(Name='Synthetic banquet queue',DeveloperName='Synthetic_Banquet_Queue',Type='Queue'); insert queue;
        insert new QueueSobject(QueueId=queue.Id,SobjectType='Lead');
        return queue;
    }
    @IsTest static void queueOwnerBlockedEvenWithTask() {
        Group queue=queueFixture();
        System.runAs(new User(Id=UserInfo.getUserId())) {
            Lead lead=fixture(30,'Medium'); lead.OwnerId=queue.Id; insert lead;
            insert new Task(WhoId=lead.Id,OwnerId=UserInfo.getUserId(),Subject=DemoLeadFollowupService.SUBJECT);
            Test.startTest(); lead.Demo_Followup_Intent__c='High'; Database.SaveResult result=Database.update(lead,false); Test.stopTest();
            Assert.isFalse(result.isSuccess(),'已有同名任務仍須驗證 Queue owner');
            Assert.isTrue(result.getErrors()[0].getMessage().contains(DemoLeadFollowupService.OWNER_ERROR),'Queue 提示');
            Assert.areEqual(1,tasksFor(new Set<Id>{lead.Id}).size(),'不得修改既有任務');
        }
    }
    private static User userFixture(Id profileId) {
        String token=EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        return new User(Alias='syntest',Email='synthetic@example.invalid',EmailEncodingKey='UTF-8',LastName='合成測試',
            LanguageLocaleKey='en_US',LocaleSidKey='en_US',TimeZoneSidKey='America/Los_Angeles',ProfileId=profileId,
            Username='synthetic.'+token+'@example.invalid');
    }
    @IsTest static void inactiveOwnerBlockedEvenWithTask() {
        User owner=userFixture(UserInfo.getProfileId()); insert owner;
        System.runAs(new User(Id=UserInfo.getUserId())) {
            Lead lead=fixture(31,'Medium'); lead.OwnerId=owner.Id; insert lead;
            insert new Task(WhoId=lead.Id,OwnerId=UserInfo.getUserId(),Subject=DemoLeadFollowupService.SUBJECT);
            owner.IsActive=false; update owner;
            Test.startTest(); lead.Demo_Followup_Intent__c='High'; Database.SaveResult result=Database.update(lead,false); Test.stopTest();
            Assert.isFalse(result.isSuccess(),'停用 owner 必須阻擋');
            Assert.isTrue(result.getErrors()[0].getMessage().contains(DemoLeadFollowupService.OWNER_ERROR),'停用 owner 提示');
        }
    }
    @IsTest static void responsesPreserveOrderAndDuplicates() {
        Lead lead=fixture(40,'High'); insert lead;
        List<DemoLeadFollowupAction.Request> requests=new List<DemoLeadFollowupAction.Request>{
            request(lead.Id,'Medium',false),null,request(lead.Id,'Low',false),request(lead.Id,'High',false)};
        Test.startTest(); List<DemoLeadFollowupAction.Response> results=DemoLeadFollowupAction.followUp(requests); Test.stopTest();
        Assert.areEqual(requests.size(),results.size(),'回傳長度相同');
        Assert.isTrue(results[0].isSuccess,'第一筆'); Assert.isFalse(results[1].isSuccess,'第二筆錯誤');
        Assert.isTrue(results[2].isSuccess,'重複 ID 對應'); Assert.isTrue(results[3].isSuccess,'非轉換無動作');
        Assert.areEqual(1,tasksFor(new Set<Id>{lead.Id}).size(),'同批重複 ID 不重複新增');
    }
    @IsTest static void nullRequestsReturnsEmpty() {
        Test.startTest(); List<DemoLeadFollowupAction.Response> results=DemoLeadFollowupAction.followUp(null); Test.stopTest();
        Assert.areEqual(0,results.size(),'null 輸入');
    }
    @IsTest static void emptyRequestsReturnsEmpty() {
        Test.startTest(); List<DemoLeadFollowupAction.Response> results=DemoLeadFollowupAction.followUp(new List<DemoLeadFollowupAction.Request>()); Test.stopTest();
        Assert.areEqual(0,results.size(),'空輸入');
    }
    @IsTest static void inaccessibleLeadRejectedByUserMode() {
        Profile minimal=[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' LIMIT 1];
        User actor=userFixture(minimal.Id); insert actor;
        System.runAs(new User(Id=UserInfo.getUserId())) {
            Lead lead=fixture(41,'Medium'); insert lead;
            System.runAs(actor) {
                Test.startTest();
                List<DemoLeadFollowupAction.Response> results=DemoLeadFollowupAction.followUp(new List<DemoLeadFollowupAction.Request>{request(lead.Id,'Medium',false)});
                Test.stopTest();
                Assert.isFalse(results[0].isSuccess,'缺少 Lead 存取不能透過動作提權');
                Assert.areEqual(DemoLeadFollowupService.TASK_ERROR,results[0].errorMessage,'不洩露內部例外');
            }
        }
    }
    @IsTest static void missingDefaultsRollBack() {
        Lead lead=fixture(50,'Medium'); insert lead;
        DemoLeadFollowupService.statusOverride=new List<TaskStatus>();
        Test.startTest(); lead.Demo_Followup_Intent__c='High'; Database.SaveResult result=Database.update(lead,false); Test.stopTest();
        Assert.isFalse(result.isSuccess(),'缺少預設值必須失敗');
        Assert.areEqual('Medium',[SELECT Demo_Followup_Intent__c FROM Lead WHERE Id=:lead.Id].Demo_Followup_Intent__c,'不得提交名單');
    }
    @IsTest static void ambiguousDefaultsRollBack() {
        Lead lead=fixture(51,'Medium'); insert lead;
        TaskPriority priority=[SELECT ApiName,IsDefault FROM TaskPriority WHERE IsDefault=true];
        DemoLeadFollowupService.priorityOverride=new List<TaskPriority>{priority,priority};
        Test.startTest(); lead.Demo_Followup_Intent__c='High'; Database.SaveResult result=Database.update(lead,false); Test.stopTest();
        Assert.isFalse(result.isSuccess(),'歧義預設值必須失敗');
        Assert.areEqual(0,tasksFor(new Set<Id>{lead.Id}).size(),'無殘留任務');
    }
    @IsTest static void closedDefaultRejected() {
        Lead lead=fixture(52,'Medium'); insert lead;
        TaskStatus closed=(TaskStatus)JSON.deserialize('{"ApiName":"Synthetic Closed","IsDefault":true,"IsClosed":true}',TaskStatus.class);
        DemoLeadFollowupService.statusOverride=new List<TaskStatus>{closed};
        Test.startTest(); lead.Demo_Followup_Intent__c='High'; Database.SaveResult result=Database.update(lead,false); Test.stopTest();
        Assert.isFalse(result.isSuccess(),'已完成預設狀態必須拒絕');
    }
    @IsTest static void archivedTaskPredicateIncludesUndeletedOnly() {
        Lead lead=fixture(60,'Medium'); insert lead;
        // Pure predicate fixture only: Salesforce archival itself is a separate real-org QA test.
        Task archived=(Task)JSON.deserialize(JSON.serialize(new Map<String,Object>{
            'WhoId'=>lead.Id,'Subject'=>DemoLeadFollowupService.SUBJECT,'IsDeleted'=>false,'IsArchived'=>true}),Task.class);
        Task deleted=(Task)JSON.deserialize(JSON.serialize(new Map<String,Object>{
            'WhoId'=>lead.Id,'Subject'=>DemoLeadFollowupService.SUBJECT,'IsDeleted'=>true,'IsArchived'=>true}),Task.class);
        Test.startTest();
        Set<Id> archivedIds=DemoLeadFollowupService.existingLeadIds(new List<Task>{archived});
        Set<Id> deletedIds=DemoLeadFollowupService.existingLeadIds(new List<Task>{deleted});
        Test.stopTest();
        Assert.areEqual(new Set<Id>{lead.Id},archivedIds,'封存但未刪除的同名任務必須計入');
        Assert.areEqual(new Set<Id>(),deletedIds,'刪除任務排除');
    }
    @IsTest static void nonExactSubjectDoesNotSuppress() {
        Lead lead=fixture(61,'Medium'); insert lead;
        insert new Task(WhoId=lead.Id,Subject=DemoLeadFollowupService.SUBJECT+'（其他）');
        Test.startTest(); lead.Demo_Followup_Intent__c='High'; update lead; Test.stopTest();
        Assert.areEqual(1,tasksFor(new Set<Id>{lead.Id}).size(),'必須完整相同主旨才防重');
        Assert.areEqual(2,[SELECT COUNT() FROM Task WHERE WhoId=:lead.Id],'保留其他任務');
    }
    @IsTest static void serviceRechecksCurrentEntry() {
        Lead lead=fixture(62,'Medium'); insert lead;
        Test.startTest();
        List<DemoLeadFollowupAction.Response> responses=DemoLeadFollowupAction.followUp(
            new List<DemoLeadFollowupAction.Request>{request(lead.Id,null,true)});
        Test.stopTest();
        Assert.isTrue(responses[0].isSuccess,'不符合入口為無動作');
        Assert.areEqual(0,tasksFor(new Set<Id>{lead.Id}).size(),'不得信任呼叫端宣稱新增即 High');
    }
    @IsTest static void batchResponseMapsTaskFailureByLead() {
        List<Lead> leads=new List<Lead>{fixture(63,'High'),fixture(64,'High')}; insert leads;
        Set<Id> ids=new Map<Id,Lead>(leads).keySet(); delete tasksFor(ids);
        DemoLeadFollowupService.rejectTaskFor.add(leads[0].Id);
        Test.startTest();
        List<DemoLeadFollowupAction.Response> responses=DemoLeadFollowupAction.followUp(
            new List<DemoLeadFollowupAction.Request>{request(leads[1].Id,'Low',false),request(leads[0].Id,'Medium',false)});
        Test.stopTest();
        Assert.isTrue(responses[0].isSuccess,'輸入第一筆映射成功');
        Assert.isFalse(responses[1].isSuccess,'輸入第二筆映射 Task 拒絕');
        Assert.areEqual(DemoLeadFollowupService.TASK_ERROR,responses[1].errorMessage,'只回安全錯誤');
        // Direct service contract only; taskFailureRollsBackLead tests Flow transaction rollback.
    }

    @IsTest static void invisibleTaskStillPreventsDuplicate() {
        Profile minimal=[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' WITH SYSTEM_MODE LIMIT 1];
        User actor=userFixture(minimal.Id); insert actor;
        // Isolated setup fixture grants Lead read only, never Task read or product Apex access.
        PermissionSet leadRead=new PermissionSet(Name='SyntheticLeadRead'+EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0,8),Label='Synthetic Lead Read');
        insert leadRead;
        insert new ObjectPermissions(ParentId=leadRead.Id,SobjectType='Lead',PermissionsRead=true,
            PermissionsCreate=false,PermissionsEdit=false,PermissionsDelete=false,PermissionsViewAllRecords=false,PermissionsModifyAllRecords=false);
        insert new PermissionSetAssignment(AssigneeId=actor.Id,PermissionSetId=leadRead.Id);
        System.runAs(new User(Id=UserInfo.getUserId())) {
            Lead lead=fixture(65,'Medium'); lead.OwnerId=actor.Id; insert lead;
            Task manual=new Task(WhoId=lead.Id,OwnerId=UserInfo.getUserId(),Subject=DemoLeadFollowupService.SUBJECT); insert manual;
            lead.Demo_Followup_Intent__c='High'; update lead;
            System.runAs(actor) {
                Test.startTest();
                try {
                    List<Task> unreadable=[SELECT Id FROM Task WHERE Id=:manual.Id WITH USER_MODE];
                    Assert.areEqual(0,unreadable.size(),'前置條件：操作者不可見任務');
                } catch (QueryException expected) {
                    Assert.isNotNull(expected,'前置條件：Task CRUD 拒絕亦不可見');
                }
                List<DemoLeadFollowupAction.Response> results=DemoLeadFollowupAction.followUp(
                    new List<DemoLeadFollowupAction.Request>{request(lead.Id,'Medium',false)});
                Test.stopTest();
                Assert.isTrue(results[0].isSuccess,'Lead 可讀、Task 不可見仍應防重成功');
                Assert.areEqual(null,results[0].errorMessage,'不得洩露任務內容');
            }
            List<Task> actual=tasksFor(new Set<Id>{lead.Id});
            Assert.areEqual(1,actual.size(),'系統模式防重不可見任務');
            Assert.areEqual(manual.Id,actual[0].Id,'保留既有人工任務');
        }
    }

}
