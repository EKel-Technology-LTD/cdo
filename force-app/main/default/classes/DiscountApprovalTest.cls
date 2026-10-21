/** Acceptance and adversarial tests for the complete approval lifecycle. */
@IsTest(testFor='ApexClass:DiscountApprovalHandler,ApexClass:DiscountApprovalPolicy,ApexClass:DiscountApprovalService,ApexClass:DiscountApprovalSharing,ApexTrigger:DiscountApprovalTrigger,ApexTrigger:OpportunityDiscountTrigger')
private with sharing class DiscountApprovalTest {
    @TestSetup static void setup() { DiscountApprovalTestDataFactory.createPersonas(); }
    @IsTest static void boundaries() {
        Test.startTest();
        Assert.isNull(DiscountApprovalPolicy.route(9.99,600000),'Below threshold');
        Assert.areEqual('Manager',DiscountApprovalPolicy.route(10,600000),'10 boundary');
        Assert.areEqual('Manager',DiscountApprovalPolicy.route(19.99,600000),'19.99 boundary');
        Assert.areEqual('Deal Desk',DiscountApprovalPolicy.route(20,500000),'20 boundary');
        Assert.areEqual('Deal Desk',DiscountApprovalPolicy.route(34.99,500000),'34.99 boundary');
        Assert.areEqual('Executive',DiscountApprovalPolicy.route(35,1),'35 boundary');
        Assert.areEqual('Executive',DiscountApprovalPolicy.route(20,500000.01),'Corporate amount strict boundary');
        Assert.isNull(DiscountApprovalPolicy.route(null,100),'Blank discount');
        Test.stopTest();
    }
    @IsTest static void lowDiscountNoTask() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(5,100000);
        Test.startTest(); insert deal; Test.stopTest();
        deal=[SELECT Discount_Approval_Status__c,Amount_After_Discount__c FROM Opportunity WHERE Id=:deal.Id];
        Assert.areEqual('Not Required',deal.Discount_Approval_Status__c,'5% bypasses approval');
        Assert.areEqual(95000,deal.Amount_After_Discount__c,'Percent formula uses fraction');
        Assert.areEqual(0,[SELECT COUNT() FROM Task WHERE WhatId=:deal.Id],'No task below 10');
    }
    @IsTest static void missingReasonRejected() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);deal.Discount_Reason__c=null;
        Test.startTest(); Database.SaveResult result=Database.insert(deal,false); Test.stopTest();
        Assert.isFalse(result.isSuccess(),'Reason must be required');
        Assert.isTrue(result.getErrors()[0].getMessage().contains('Discount Reason'),'Reason message');
    }
    @IsTest static void managerTask() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);
        Test.startTest();insert deal;Test.stopTest();
        Discount_Approval__c cycle=DiscountApprovalTestDataFactory.pending(deal.Id);
        Assert.areEqual('Manager',cycle.Route__c,'15 route');
        List<Task> tasks=[SELECT OwnerId,Priority,Status FROM Task WHERE WhatId=:deal.Id];
        Assert.areEqual(1,tasks.size(),'One task per cycle');
        Assert.areEqual(DiscountApprovalTestDataFactory.persona('manager').Id,tasks[0].OwnerId,'Manager task');
        Assert.areEqual('High',tasks[0].Priority,'High priority');
        Assert.areEqual('Not Started',tasks[0].Status,'Open task');
    }
    @IsTest static void routesAndShares() {
        List<Opportunity> deals=new List<Opportunity>{DiscountApprovalTestDataFactory.opportunity(25,100000),DiscountApprovalTestDataFactory.opportunity(25,600000),DiscountApprovalTestDataFactory.opportunity(40,100)};
        Test.startTest();insert deals;Test.stopTest();
        Assert.areEqual('Deal Desk',DiscountApprovalTestDataFactory.pending(deals[0].Id).Route__c,'Normal Deal Desk');
        Assert.areEqual('Executive',DiscountApprovalTestDataFactory.pending(deals[1].Id).Route__c,'Large Executive');
        Assert.areEqual('Executive',DiscountApprovalTestDataFactory.pending(deals[2].Id).Route__c,'High discount Executive');
        Set<Id> ids=new Map<Id,Opportunity>(deals).keySet();
        Assert.areEqual(3,[SELECT COUNT() FROM OpportunityShare WHERE OpportunityId IN :ids AND RowCause='Manual'],'One group share per deal');
    }
    @IsTest static void managerApprovalAllowsWon() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert deal;
        Discount_Approval__c cycle=DiscountApprovalTestDataFactory.pending(deal.Id);
        Test.startTest();
        System.runAs(DiscountApprovalTestDataFactory.persona('manager')) { DiscountApprovalService.decide(cycle.Id,'Approved','Acceptable margin'); }
        deal.StageName='Closed Won';update deal;
        Test.stopTest();
        deal=[SELECT Discount_Approval_Status__c,Discount_Decided_By__c,Discount_Decided_At__c,Discount_Decision_Comment__c FROM Opportunity WHERE Id=:deal.Id];
        Assert.areEqual('Approved',deal.Discount_Approval_Status__c,'Approved can close');
        Assert.areEqual(DiscountApprovalTestDataFactory.persona('manager').Id,deal.Discount_Decided_By__c,'Decision identity');
        Assert.isNotNull(deal.Discount_Decided_At__c,'Decision timestamp');
        Assert.areEqual('Acceptable margin',deal.Discount_Decision_Comment__c,'Decision comment');
        Assert.areEqual('Completed',[SELECT Status FROM Task WHERE Id=:cycle.Manager_Task_Id__c].Status,'Task completed');
    }
    @IsTest static void pendingCannotClose() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);insert deal;deal.StageName='Closed Won';
        Test.startTest();Database.SaveResult result=Database.update(deal,false);Test.stopTest();
        Assert.isFalse(result.isSuccess(),'Pending cannot close');
        Assert.isTrue(result.getErrors()[0].getMessage().contains('cannot be Closed Won'),'Won guard');
    }
    @IsTest static void analystRejectAndOwnerResubmit() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);insert deal;
        Id cycleId=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
        Test.startTest();
        System.runAs(DiscountApprovalTestDataFactory.persona('analyst')) {
            Assert.isTrue((Boolean)DiscountApprovalService.getPanel(deal.Id).get('canDecide'),'Analyst controls visible');
            DiscountApprovalService.decide(cycleId,'Rejected','Margin below floor');
        }
        deal.StageName='Closed Won';Assert.isFalse(Database.update(deal,false).isSuccess(),'Rejected cannot close');
        deal.StageName='Qualification';deal.Discount_Reason__c='Revised multi-year agreement';update deal;
        Assert.areEqual('Rejected',[SELECT Discount_Approval_Status__c FROM Opportunity WHERE Id=:deal.Id].Discount_Approval_Status__c,'Reason only does not resubmit');
        System.runAs(DiscountApprovalTestDataFactory.persona('rep')) {
            Assert.isTrue((Boolean)DiscountApprovalService.getPanel(deal.Id).get('canResubmit'),'Owner resubmit shown');
            DiscountApprovalService.resubmit(deal.Id);
        }
        Test.stopTest();
        Assert.areEqual('Rejected',[SELECT Status__c FROM Discount_Approval__c WHERE Id=:cycleId].Status__c,'Rejected history preserved');
        Assert.areEqual(1,[SELECT COUNT() FROM Discount_Approval__c WHERE Opportunity__c=:deal.Id AND Status__c='Pending'],'One new cycle');
        Assert.areEqual(2,[SELECT COUNT() FROM Task WHERE WhatId=:deal.Id],'Two total tasks');
    }
    @IsTest static void executiveApproval() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(40,100000);insert deal;Id cycleId=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
        Test.startTest();System.runAs(DiscountApprovalTestDataFactory.persona('executive')) { DiscountApprovalService.decide(cycleId,'Approved','Strategic'); }Test.stopTest();
        Assert.areEqual('Approved',[SELECT Status__c FROM Discount_Approval__c WHERE Id=:cycleId].Status__c,'Executive decision');
    }
    @IsTest static void ownerCannotApproveEvenInGroup() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);insert deal;Id cycleId=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
        Test.startTest();System.runAs(DiscountApprovalTestDataFactory.persona('rep')) {
            Assert.isFalse((Boolean)DiscountApprovalService.getPanel(deal.Id).get('canDecide'),'Self-decision hidden');
            try { DiscountApprovalService.decide(cycleId,'Approved','Self');Assert.fail('Self approval must fail'); }
            catch (AuraHandledException error) { Assert.isTrue(error.getMessage().contains('not authorized'),'Authorization error'); }
        }Test.stopTest();
    }
    @IsTest static void submitterCannotApprove() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);
        Test.startTest();System.runAs(DiscountApprovalTestDataFactory.persona('analyst')) {
            insert as system deal;Id cycleId=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
            try { DiscountApprovalService.decide(cycleId,'Approved','Self submitted');Assert.fail('Submitter approval must fail'); }
            catch (AuraHandledException error) { Assert.isTrue(error.getMessage().contains('not authorized'),'Submitter denied'); }
        }Test.stopTest();
    }
    @IsTest static void commentRequired() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);insert deal;
        Test.startTest();System.runAs(DiscountApprovalTestDataFactory.persona('analyst')) {
            try { DiscountApprovalService.decide(DiscountApprovalTestDataFactory.pending(deal.Id).Id,'Approved','  ');Assert.fail('Comment mandatory'); }
            catch (AuraHandledException error) { Assert.areEqual('Enter a comment to approve or reject.',error.getMessage(),'Comment message'); }
        }Test.stopTest();
    }
    @IsTest static void unchangedReasonCannotResubmit() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert deal;
        System.runAs(DiscountApprovalTestDataFactory.persona('manager')) { DiscountApprovalService.decide(DiscountApprovalTestDataFactory.pending(deal.Id).Id,'Rejected','Revise'); }
        Test.startTest();System.runAs(DiscountApprovalTestDataFactory.persona('rep')) {
            try { DiscountApprovalService.resubmit(deal.Id);Assert.fail('Changed reason required'); }
            catch (AuraHandledException error) { Assert.isTrue(error.getMessage().contains('different Discount Reason'),'Reason unchanged'); }
        }Test.stopTest();
    }
    @IsTest static void approvedDiscountChangeInvalidates() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert deal;Id cycleId=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
        System.runAs(DiscountApprovalTestDataFactory.persona('manager')) { DiscountApprovalService.decide(cycleId,'Approved','OK'); }
        Test.startTest();deal.Discount_Percent__c=16;update deal;Test.stopTest();
        Assert.areEqual('Superseded',[SELECT Status__c FROM Discount_Approval__c WHERE Id=:cycleId].Status__c,'Old approval invalid');
        Assert.isNotNull(DiscountApprovalTestDataFactory.pending(deal.Id),'Pending again');
    }
    @IsTest static void amountAndReasonInvalidate() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);insert deal;
        Test.startTest();deal.Amount=600000;update deal;
        Assert.areEqual('Executive',DiscountApprovalTestDataFactory.pending(deal.Id).Route__c,'Amount reroutes');
        deal.Discount_Reason__c='Changed terms';update deal;Test.stopTest();
        Assert.areEqual(3,[SELECT COUNT() FROM Discount_Approval__c WHERE Opportunity__c=:deal.Id],'Three cycles');
        Assert.areEqual(1,[SELECT COUNT() FROM Task WHERE WhatId=:deal.Id AND Status!='Completed'],'Only current task open');
    }
    @IsTest static void ownerChangeRetainsHistoricShares() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);insert deal;
        deal.Amount=600000;update deal;
        Test.startTest();deal.OwnerId=DiscountApprovalTestDataFactory.persona('newowner').Id;update deal;Test.stopTest();
        Assert.areEqual(2,[SELECT COUNT() FROM OpportunityShare WHERE OpportunityId=:deal.Id AND RowCause='Manual'],'Both historical groups shared');
    }
    @IsTest static void belowTenResets() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);insert deal;
        Test.startTest();deal.Discount_Percent__c=5;update deal;Test.stopTest();
        Assert.areEqual('Not Required',[SELECT Discount_Approval_Status__c FROM Opportunity WHERE Id=:deal.Id].Discount_Approval_Status__c,'Reset');
        Assert.areEqual(0,[SELECT COUNT() FROM Task WHERE WhatId=:deal.Id AND Status!='Completed'],'No open task');
    }
    @IsTest static void closedTermsCannotChange() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert deal;
        System.runAs(DiscountApprovalTestDataFactory.persona('manager')) { DiscountApprovalService.decide(DiscountApprovalTestDataFactory.pending(deal.Id).Id,'Approved','OK'); }
        deal.StageName='Closed Won';update deal;
        Test.startTest();deal.Discount_Percent__c=16;Database.SaveResult result=Database.update(deal,false);Test.stopTest();
        Assert.isFalse(result.isSuccess(),'Closed terms locked');
        Assert.isTrue(result.getErrors()[0].getMessage().contains('Reopen'),'Reopen first');
    }
    @IsTest static void protectedOutcomeDenied() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert deal;
        Test.startTest();deal.Discount_Approval_Status__c='Approved';Database.SaveResult result=Database.update(deal,false);Test.stopTest();
        Assert.isFalse(result.isSuccess(),'Direct outcome write denied even as admin');
    }
    @IsTest static void cycleTamperingDenied() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert deal;Discount_Approval__c cycle=DiscountApprovalTestDataFactory.pending(deal.Id);
        Test.startTest();cycle.Status__c='Approved';Assert.isFalse(Database.update(cycle,false).isSuccess(),'Cycle update denied');
        Assert.isFalse(Database.delete(cycle,false).isSuccess(),'Cycle delete denied');
        Assert.isFalse(Database.insert(new Discount_Approval__c(Opportunity__c=deal.Id,Status__c='Approved'),false).isSuccess(),'Cycle insert denied');Test.stopTest();
    }
    @IsTest static void missingManagerDenied() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);deal.OwnerId=DiscountApprovalTestDataFactory.persona('manager').Id;
        Test.startTest();Database.SaveResult result=Database.insert(deal,false);Test.stopTest();
        Assert.isFalse(result.isSuccess(),'Missing manager denied');
        Assert.isTrue(result.getErrors()[0].getMessage().contains('has no manager'),'Missing manager message');
    }

    @IsTest static void wrongRouteCannotDecide() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert deal;
        Id cycleId=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
        Id analystId=DiscountApprovalTestDataFactory.persona('analyst').Id;
        insert new OpportunityShare(OpportunityId=deal.Id,UserOrGroupId=analystId,OpportunityAccessLevel='Read',RowCause='Manual');
        Test.startTest();System.runAs(new User(Id=analystId)) {
            try { DiscountApprovalService.decide(cycleId,'Approved','Wrong route');Assert.fail('Group membership cannot approve manager route'); }
            catch (AuraHandledException error) { Assert.isTrue(error.getMessage().contains('not authorized'),'Wrong route denied'); }
        }Test.stopTest();
    }
    @IsTest static void decisionCannotBeRepeated() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert deal;
        Id cycleId=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
        Test.startTest();System.runAs(DiscountApprovalTestDataFactory.persona('manager')) {
            DiscountApprovalService.decide(cycleId,'Approved','First');
            try { DiscountApprovalService.decide(cycleId,'Rejected','Second');Assert.fail('A cycle can be decided only once'); }
            catch (AuraHandledException error) { Assert.isTrue(error.getMessage().contains('not authorized'),'Not pending'); }
        }Test.stopTest();
        Assert.areEqual('Approved',[SELECT Status__c FROM Discount_Approval__c WHERE Id=:cycleId].Status__c,'First decision retained');
    }
    @IsTest static void invalidOutcomeRejected() {
        Test.startTest();
        try { DiscountApprovalService.decide(null,'Superseded','Not a decision');Assert.fail('Outcome allowlist'); }
        catch (AuraHandledException error) { Assert.areEqual('Choose Approved or Rejected.',error.getMessage(),'Invalid outcome message'); }
        Test.stopTest();
    }
    @IsTest static void invalidPercentRejected() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(101,100000);
        Test.startTest();Assert.isFalse(Database.insert(deal,false).isSuccess(),'Over 100 denied');Test.stopTest();
    }
    @IsTest static void negativePercentRejected() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(-1,100000);
        Test.startTest();Assert.isFalse(Database.insert(deal,false).isSuccess(),'Below zero denied');Test.stopTest();
    }
    @IsTest static void approvedReasonChangeInvalidates() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert deal;
        System.runAs(DiscountApprovalTestDataFactory.persona('manager')) { DiscountApprovalService.decide(DiscountApprovalTestDataFactory.pending(deal.Id).Id,'Approved','OK'); }
        Test.startTest();deal.Discount_Reason__c='New commercial reason';update deal;Test.stopTest();
        Assert.areEqual('Pending',[SELECT Discount_Approval_Status__c FROM Opportunity WHERE Id=:deal.Id].Discount_Approval_Status__c,'Approved reason changes invalidate');
    }

    @IsTest static void currencyConversionWhenAvailable() {
        List<CurrencyType> currencies=[SELECT IsoCode,ConversionRate FROM CurrencyType WHERE IsActive=true AND IsCorporate=false];
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);
        Test.startTest();
        Assert.areEqual(100000,DiscountApprovalPolicy.corporateAmount(deal),'Corporate currency pass-through');
        if (!currencies.isEmpty()) {
            deal.CurrencyIsoCode=currencies[0].IsoCode;
            insert deal;
            Id prior=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
            deal.CurrencyIsoCode='USD';update deal;
            Assert.areEqual('Superseded',[SELECT Status__c FROM Discount_Approval__c WHERE Id=:prior].Status__c,'Currency change invalidates');
        }
        Test.stopTest();
    }
    @IsTest static void noRecordAccessCannotReadPanel() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert deal;
        Test.startTest();System.runAs(DiscountApprovalTestDataFactory.persona('outsider')) {
            try { DiscountApprovalService.getPanel(deal.Id);Assert.fail('Private record must not leak'); }
            catch (AuraHandledException error) { Assert.isTrue(error.getMessage().contains('record and field access'),'No data leakage'); }
        }Test.stopTest();
    }
    @IsTest static void bulk200InsertAndUpdate() { bulkOpportunities(200); }
    @IsTest static void bulk251AcrossTriggerChunks() { bulkOpportunities(251); }
    private static void bulkOpportunities(Integer count) {
        Opportunity seed=DiscountApprovalTestDataFactory.opportunity(25,100000);List<Opportunity> deals=new List<Opportunity>();
        for (Integer i=0;i<count;i++) { Opportunity deal=seed.clone(false,true,false,false);deal.Name='Bulk '+i;deals.add(deal); }
        Test.startTest();insert deals;
        for (Opportunity deal : deals) deal.Discount_Percent__c=26;
        update deals;Integer queries=Limits.getQueries();Integer statements=Limits.getDmlStatements();Test.stopTest();
        Set<Id> ids=new Map<Id,Opportunity>(deals).keySet();
        Assert.areEqual(count,[SELECT COUNT() FROM Discount_Approval__c WHERE Opportunity__c IN :ids AND Status__c='Pending'],'One current cycle each');
        Assert.areEqual(count,[SELECT COUNT() FROM Discount_Approval__c WHERE Opportunity__c IN :ids AND Status__c='Superseded'],'One historical cycle each');
        Assert.areEqual(count,[SELECT COUNT() FROM Task WHERE WhatId IN :ids AND Status='Not Started'],'One current task each');
        Assert.isTrue(queries<100,'Within SOQL limit');Assert.isTrue(statements<150,'Within DML limit');
    }
}
