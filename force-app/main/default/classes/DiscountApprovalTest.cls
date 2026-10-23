/** Acceptance and adversarial tests for the complete approval lifecycle. */
@IsTest(testFor='ApexClass:DiscountApprovalHandler,ApexClass:DiscountApprovalPolicy,ApexClass:DiscountApprovalService,ApexClass:DiscountApprovalSharing,ApexTrigger:DiscountApprovalTrigger,ApexTrigger:OpportunityDiscountTrigger')
private with sharing class DiscountApprovalTest {
    // System-mode fixtures exercise trigger invariants; service calls below retain persona CRUD/FLS and sharing.
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
        Test.startTest(); insert as system deal; Test.stopTest();
        deal=[SELECT Discount_Approval_Status__c,Amount_After_Discount__c FROM Opportunity WHERE Id=:deal.Id WITH SYSTEM_MODE];
        Assert.areEqual('Not Required',deal.Discount_Approval_Status__c,'5% bypasses approval');
        Assert.areEqual(95000,deal.Amount_After_Discount__c,'Percent formula uses fraction');
        Assert.areEqual(0,[SELECT COUNT() FROM Task WHERE WhatId=:deal.Id WITH SYSTEM_MODE],'No task below 10');
    }
    @IsTest static void missingReasonRejected() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);deal.Discount_Reason__c=null;
        Test.startTest(); Database.SaveResult result=Database.insert(deal,false,AccessLevel.SYSTEM_MODE); Test.stopTest();
        Assert.isFalse(result.isSuccess(),'Reason must be required');
        Assert.isTrue(result.getErrors()[0].getMessage().contains('Discount Reason'),'Reason message');
    }
    @IsTest static void managerTask() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);
        Test.startTest();insert as system deal;Test.stopTest();
        Discount_Approval__c cycle=DiscountApprovalTestDataFactory.pending(deal.Id);
        Assert.areEqual('Manager',cycle.Route__c,'15 route');
        List<Task> tasks=[SELECT OwnerId,Priority,Status FROM Task WHERE WhatId=:deal.Id WITH SYSTEM_MODE];
        Assert.areEqual(1,tasks.size(),'One task per cycle');
        Assert.areEqual(DiscountApprovalTestDataFactory.persona('manager').Id,tasks[0].OwnerId,'Manager task');
        Assert.areEqual('High',tasks[0].Priority,'High priority');
        Assert.areEqual('Not Started',tasks[0].Status,'Open task');
    }
    @IsTest static void routesAndShares() {
        List<Opportunity> deals=new List<Opportunity>{DiscountApprovalTestDataFactory.opportunity(25,100000),DiscountApprovalTestDataFactory.opportunity(25,600000),DiscountApprovalTestDataFactory.opportunity(40,100)};
        Test.startTest();insert as system deals;Test.stopTest();
        Assert.areEqual('Deal Desk',DiscountApprovalTestDataFactory.pending(deals[0].Id).Route__c,'Normal Deal Desk');
        Assert.areEqual('Executive',DiscountApprovalTestDataFactory.pending(deals[1].Id).Route__c,'Large Executive');
        Assert.areEqual('Executive',DiscountApprovalTestDataFactory.pending(deals[2].Id).Route__c,'High discount Executive');
        Set<Id> ids=new Map<Id,Opportunity>(deals).keySet();
        Assert.areEqual(3,[SELECT COUNT() FROM OpportunityShare WHERE OpportunityId IN :ids AND RowCause='Manual' WITH SYSTEM_MODE],'One group share per deal');
    }
    @IsTest static void managerApprovalAllowsWon() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert as system deal;
        Discount_Approval__c cycle=DiscountApprovalTestDataFactory.pending(deal.Id);
        Test.startTest();
        System.runAs(DiscountApprovalTestDataFactory.persona('manager')) { DiscountApprovalService.decide(cycle.Id,'Approved','Acceptable margin'); }
        deal.StageName='Closed Won';update as system deal;
        Test.stopTest();
        deal=[SELECT Discount_Approval_Status__c,Discount_Decided_By__c,Discount_Decided_At__c,Discount_Decision_Comment__c FROM Opportunity WHERE Id=:deal.Id WITH SYSTEM_MODE];
        Assert.areEqual('Approved',deal.Discount_Approval_Status__c,'Approved can close');
        Assert.areEqual(DiscountApprovalTestDataFactory.persona('manager').Id,deal.Discount_Decided_By__c,'Decision identity');
        Assert.isNotNull(deal.Discount_Decided_At__c,'Decision timestamp');
        Assert.areEqual('Acceptable margin',deal.Discount_Decision_Comment__c,'Decision comment');
        Assert.areEqual('Completed',[SELECT Status FROM Task WHERE Id=:cycle.Manager_Task_Id__c WITH SYSTEM_MODE].Status,'Task completed');
    }
    @IsTest static void pendingCannotClose() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);insert as system deal;deal.StageName='Closed Won';
        Test.startTest();Database.SaveResult result=Database.update(deal,false,AccessLevel.SYSTEM_MODE);Test.stopTest();
        Assert.isFalse(result.isSuccess(),'Pending cannot close');
        Assert.isTrue(result.getErrors()[0].getMessage().contains('cannot be Closed Won'),'Won guard');
    }
    @IsTest static void analystRejectAndOwnerResubmit() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);insert as system deal;
        Id cycleId=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
        Test.startTest();
        System.runAs(DiscountApprovalTestDataFactory.persona('analyst')) {
            Assert.isTrue((Boolean)DiscountApprovalService.getPanel(deal.Id).get('canDecide'),'Analyst controls visible');
            DiscountApprovalService.decide(cycleId,'Rejected','Margin below floor');
        }
        deal.StageName='Closed Won';Assert.isFalse(Database.update(deal,false,AccessLevel.SYSTEM_MODE).isSuccess(),'Rejected cannot close');
        deal.StageName='Qualification';deal.Discount_Reason__c='Revised multi-year agreement';update as system deal;
        Assert.areEqual('Rejected',[SELECT Discount_Approval_Status__c FROM Opportunity WHERE Id=:deal.Id WITH SYSTEM_MODE].Discount_Approval_Status__c,'Reason only does not resubmit');
        System.runAs(DiscountApprovalTestDataFactory.persona('rep')) {
            Assert.isTrue((Boolean)DiscountApprovalService.getPanel(deal.Id).get('canResubmit'),'Owner resubmit shown');
            DiscountApprovalService.resubmit(deal.Id);
        }
        Test.stopTest();
        Assert.areEqual('Rejected',[SELECT Status__c FROM Discount_Approval__c WHERE Id=:cycleId WITH SYSTEM_MODE].Status__c,'Rejected history preserved');
        Assert.areEqual(1,[SELECT COUNT() FROM Discount_Approval__c WHERE Opportunity__c=:deal.Id AND Status__c='Pending' WITH SYSTEM_MODE],'One new cycle');
        Assert.areEqual(2,[SELECT COUNT() FROM Task WHERE WhatId=:deal.Id WITH SYSTEM_MODE],'Two total tasks');
    }
    @IsTest static void executiveApproval() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(40,100000);insert as system deal;Id cycleId=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
        Test.startTest();System.runAs(DiscountApprovalTestDataFactory.persona('executive')) { DiscountApprovalService.decide(cycleId,'Approved','Strategic'); }Test.stopTest();
        Assert.areEqual('Approved',[SELECT Status__c FROM Discount_Approval__c WHERE Id=:cycleId WITH SYSTEM_MODE].Status__c,'Executive decision');
    }
    @IsTest static void ownerCannotApproveEvenInGroup() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);insert as system deal;Id cycleId=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
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
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);insert as system deal;
        Test.startTest();System.runAs(DiscountApprovalTestDataFactory.persona('analyst')) {
            try { DiscountApprovalService.decide(DiscountApprovalTestDataFactory.pending(deal.Id).Id,'Approved','  ');Assert.fail('Comment mandatory'); }
            catch (AuraHandledException error) { Assert.areEqual('Enter a comment to approve or reject.',error.getMessage(),'Comment message'); }
        }Test.stopTest();
    }
    @IsTest static void unchangedReasonCannotResubmit() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert as system deal;
        System.runAs(DiscountApprovalTestDataFactory.persona('manager')) { DiscountApprovalService.decide(DiscountApprovalTestDataFactory.pending(deal.Id).Id,'Rejected','Revise'); }
        Test.startTest();System.runAs(DiscountApprovalTestDataFactory.persona('rep')) {
            try { DiscountApprovalService.resubmit(deal.Id);Assert.fail('Changed reason required'); }
            catch (AuraHandledException error) { Assert.isTrue(error.getMessage().contains('different Discount Reason'),'Reason unchanged'); }
        }Test.stopTest();
    }
    @IsTest static void approvedDiscountChangeInvalidates() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert as system deal;Id cycleId=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
        System.runAs(DiscountApprovalTestDataFactory.persona('manager')) { DiscountApprovalService.decide(cycleId,'Approved','OK'); }
        Test.startTest();deal.Discount_Percent__c=16;update as system deal;Test.stopTest();
        Assert.areEqual('Superseded',[SELECT Status__c FROM Discount_Approval__c WHERE Id=:cycleId WITH SYSTEM_MODE].Status__c,'Old approval invalid');
        Assert.isNotNull(DiscountApprovalTestDataFactory.pending(deal.Id),'Pending again');
    }
    @IsTest static void amountAndReasonInvalidate() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);insert as system deal;
        Test.startTest();deal.Amount=600000;update as system deal;
        Assert.areEqual('Executive',DiscountApprovalTestDataFactory.pending(deal.Id).Route__c,'Amount reroutes');
        deal.Discount_Reason__c='Changed terms';update as system deal;Test.stopTest();
        Assert.areEqual(3,[SELECT COUNT() FROM Discount_Approval__c WHERE Opportunity__c=:deal.Id WITH SYSTEM_MODE],'Three cycles');
        Assert.areEqual(1,[SELECT COUNT() FROM Task WHERE WhatId=:deal.Id AND Status!='Completed' WITH SYSTEM_MODE],'Only current task open');
    }
    @IsTest static void ownerChangeRetainsHistoricShares() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);insert as system deal;
        deal.Amount=600000;update as system deal;
        Test.startTest();deal.OwnerId=DiscountApprovalTestDataFactory.persona('newowner').Id;update as system deal;Test.stopTest();
        Assert.areEqual(2,[SELECT COUNT() FROM OpportunityShare WHERE OpportunityId=:deal.Id AND RowCause='Manual' WITH SYSTEM_MODE],'Both historical groups shared');
    }
    @IsTest static void belowTenResets() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);insert as system deal;
        Test.startTest();deal.Discount_Percent__c=5;update as system deal;Test.stopTest();
        Assert.areEqual('Not Required',[SELECT Discount_Approval_Status__c FROM Opportunity WHERE Id=:deal.Id WITH SYSTEM_MODE].Discount_Approval_Status__c,'Reset');
        Assert.areEqual(0,[SELECT COUNT() FROM Task WHERE WhatId=:deal.Id AND Status!='Completed' WITH SYSTEM_MODE],'No open task');
    }
    @IsTest static void closedTermsCannotChange() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert as system deal;
        System.runAs(DiscountApprovalTestDataFactory.persona('manager')) { DiscountApprovalService.decide(DiscountApprovalTestDataFactory.pending(deal.Id).Id,'Approved','OK'); }
        deal.StageName='Closed Won';update as system deal;
        Test.startTest();deal.Discount_Percent__c=16;
        assertValidation(Database.update(deal,false,AccessLevel.SYSTEM_MODE),'Reopen the Opportunity before changing discount terms on a Closed Won deal.');
        deal.StageName='Qualification';
        assertValidation(Database.update(deal,false,AccessLevel.SYSTEM_MODE),'Reopen the Opportunity before changing discount terms on a Closed Won deal.');
        update as system new Opportunity(Id=deal.Id,StageName='Qualification');
        update as system deal;
        Test.stopTest();
        Assert.areEqual('Pending',[SELECT Discount_Approval_Status__c FROM Opportunity WHERE Id=:deal.Id WITH SYSTEM_MODE].Discount_Approval_Status__c,'Separate reopen permits terms change and requires approval');
    }
    @IsTest static void closedBlankDiscountStaysEditable() { assertClosedLowDiscountEditable(null); }
    @IsTest static void closedBelowTenStaysEditable() { assertClosedLowDiscountEditable(9.99); }
    private static void assertClosedLowDiscountEditable(Decimal discount) {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(discount,50000);
        deal.StageName='Closed Won';insert as system deal;
        Test.startTest();
        deal.Amount=60000;deal.OwnerId=DiscountApprovalTestDataFactory.persona('newowner').Id;
        deal.CloseDate=deal.CloseDate.addDays(1);update as system deal;
        Test.stopTest();
        Opportunity saved=[SELECT Amount,OwnerId,Discount_Approval_Status__c FROM Opportunity WHERE Id=:deal.Id WITH SYSTEM_MODE];
        Assert.areEqual(60000,saved.Amount,'Closed low discount amount remains editable');
        Assert.areEqual(deal.OwnerId,saved.OwnerId,'Closed low discount owner remains editable');
        Assert.areEqual('Not Required',saved.Discount_Approval_Status__c,'No approval required');
        Assert.areEqual(0,[SELECT COUNT() FROM Discount_Approval__c WHERE Opportunity__c=:deal.Id WITH SYSTEM_MODE],'No audit cycle');
    }
    @IsTest static void closedDiscountCannotCrossThreshold() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(9.99,50000);
        deal.StageName='Closed Won';insert as system deal;
        Test.startTest();deal.Discount_Percent__c=10;deal.Discount_Reason__c='New terms';
        assertValidation(Database.update(deal,false,AccessLevel.SYSTEM_MODE),'Reopen the Opportunity before changing discount terms on a Closed Won deal.');
        Test.stopTest();
    }
    @IsTest static void closedApprovedDiscountCannotDropBelowTen() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(10,50000);insert as system deal;
        System.runAs(DiscountApprovalTestDataFactory.persona('manager')) { DiscountApprovalService.decide(DiscountApprovalTestDataFactory.pending(deal.Id).Id,'Approved','OK'); }
        deal.StageName='Closed Won';update as system deal;
        Test.startTest();deal.Discount_Percent__c=null;
        assertValidation(Database.update(deal,false,AccessLevel.SYSTEM_MODE),'Reopen the Opportunity before changing discount terms on a Closed Won deal.');
        Test.stopTest();
    }
    @IsTest static void closeDateInvalidatesPending() { assertCloseDateReroutes(false); }
    @IsTest static void closeDateInvalidatesApproved() { assertCloseDateReroutes(true); }
    private static void assertCloseDateReroutes(Boolean approveFirst) {
        seedCurrencyRates();
        // Keep the existing USD fixture; inject transaction-local non-corporate dated rates.
        DiscountApprovalPolicy.corporate='EUR';
        DiscountApprovalPolicy.datedRates.put('USD',new List<SObject>{
            datedRate('2026-07-01',null,1),datedRate('2026-01-01','2026-07-01',2)});
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,600000);
        deal.CloseDate=Date.newInstance(2026,6,30);insert as system deal;
        Discount_Approval__c prior=DiscountApprovalTestDataFactory.pending(deal.Id);
        Assert.areEqual('Deal Desk',prior.Route__c,'300000 corporate before boundary');
        if (approveFirst) {
            System.runAs(DiscountApprovalTestDataFactory.persona('analyst')) { DiscountApprovalService.decide(prior.Id,'Approved','OK'); }
        }
        Test.startTest();deal.CloseDate=Date.newInstance(2026,7,1);update as system deal;Test.stopTest();
        Discount_Approval__c current=DiscountApprovalTestDataFactory.pending(deal.Id);
        Assert.areEqual('Executive',current.Route__c,'600000 corporate after boundary');
        Assert.areEqual('Superseded',[SELECT Status__c FROM Discount_Approval__c WHERE Id=:prior.Id WITH SYSTEM_MODE].Status__c,'Prior cycle invalidated');
        Assert.areEqual('Completed',[SELECT Status FROM Task WHERE Id=:prior.Manager_Task_Id__c WITH SYSTEM_MODE].Status,'Prior task closed');
        Assert.areEqual(600000,[SELECT Routing_Amount_Corporate__c FROM Discount_Approval__c WHERE Id=:current.Id WITH SYSTEM_MODE].Routing_Amount_Corporate__c,'New rate snapshot');
        Assert.areEqual(1,[SELECT COUNT() FROM Task WHERE WhatId=:deal.Id AND Status='Not Started' WITH SYSTEM_MODE],'One current task');
    }
    @IsTest static void protectedOutcomeDenied() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert as system deal;
        Test.startTest();deal.Discount_Approval_Status__c='Approved';Database.SaveResult result=Database.update(deal,false,AccessLevel.SYSTEM_MODE);Test.stopTest();
        assertValidation(result,'Approval fields can only be changed through the Deal Desk approval panel.');
    }
    @IsTest static void cycleTamperingDenied() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert as system deal;Discount_Approval__c cycle=DiscountApprovalTestDataFactory.pending(deal.Id);
        Test.startTest();cycle.Status__c='Approved';assertValidation(Database.update(cycle,false,AccessLevel.SYSTEM_MODE),'Approval records can only be changed through the Deal Desk approval panel.');
        Database.DeleteResult deleted=Database.delete(cycle,false,AccessLevel.SYSTEM_MODE);
        Assert.isFalse(deleted.isSuccess(),'Cycle delete denied');
        Assert.areEqual(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION,deleted.getErrors()[0].getStatusCode(),'Trigger rejected deletion');
        Assert.areEqual('Approval records can only be changed through the Deal Desk approval panel.',deleted.getErrors()[0].getMessage(),'Delete guard');
        assertValidation(Database.insert(new Discount_Approval__c(Opportunity__c=deal.Id,Status__c='Approved'),false,AccessLevel.SYSTEM_MODE),'Approval records can only be changed through the Deal Desk approval panel.');Test.stopTest();
    }
    @IsTest static void missingManagerDenied() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);deal.OwnerId=DiscountApprovalTestDataFactory.persona('manager').Id;
        Test.startTest();Database.SaveResult result=Database.insert(deal,false,AccessLevel.SYSTEM_MODE);Test.stopTest();
        Assert.isFalse(result.isSuccess(),'Missing manager denied');
        Assert.isTrue(result.getErrors()[0].getMessage().contains('has no manager'),'Missing manager message');
    }

    @IsTest static void wrongRouteCannotDecide() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert as system deal;
        Id cycleId=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
        Id analystId=DiscountApprovalTestDataFactory.persona('analyst').Id;
        insert as system new OpportunityShare(OpportunityId=deal.Id,UserOrGroupId=analystId,OpportunityAccessLevel='Read',RowCause='Manual');
        Test.startTest();System.runAs(new User(Id=analystId)) {
            try { DiscountApprovalService.decide(cycleId,'Approved','Wrong route');Assert.fail('Group membership cannot approve manager route'); }
            catch (AuraHandledException error) { Assert.isTrue(error.getMessage().contains('not authorized'),'Wrong route denied'); }
        }Test.stopTest();
    }
    @IsTest static void decisionCannotBeRepeated() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert as system deal;
        Id cycleId=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
        Test.startTest();System.runAs(DiscountApprovalTestDataFactory.persona('manager')) {
            DiscountApprovalService.decide(cycleId,'Approved','First');
            try { DiscountApprovalService.decide(cycleId,'Rejected','Second');Assert.fail('A cycle can be decided only once'); }
            catch (AuraHandledException error) { Assert.isTrue(error.getMessage().contains('not authorized'),'Not pending'); }
        }Test.stopTest();
        Assert.areEqual('Approved',[SELECT Status__c FROM Discount_Approval__c WHERE Id=:cycleId WITH SYSTEM_MODE].Status__c,'First decision retained');
    }
    @IsTest static void invalidOutcomeRejected() {
        Test.startTest();
        try { DiscountApprovalService.decide(null,'Superseded','Not a decision');Assert.fail('Outcome allowlist'); }
        catch (AuraHandledException error) { Assert.areEqual('Choose Approved or Rejected.',error.getMessage(),'Invalid outcome message'); }
        Test.stopTest();
    }
    @IsTest static void invalidPercentRejected() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(101,100000);
        Test.startTest();Database.SaveResult result=Database.insert(deal,false,AccessLevel.SYSTEM_MODE);Test.stopTest();
        assertValidation(result,'Discount % must be between 0% and 100%.');
    }
    @IsTest static void negativePercentRejected() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(-1,100000);
        Test.startTest();Database.SaveResult result=Database.insert(deal,false,AccessLevel.SYSTEM_MODE);Test.stopTest();
        assertValidation(result,'Discount % must be between 0% and 100%.');
    }
    @IsTest static void approvedReasonChangeInvalidates() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert as system deal;
        System.runAs(DiscountApprovalTestDataFactory.persona('manager')) { DiscountApprovalService.decide(DiscountApprovalTestDataFactory.pending(deal.Id).Id,'Approved','OK'); }
        Test.startTest();deal.Discount_Reason__c='New commercial reason';update as system deal;Test.stopTest();
        Assert.areEqual('Pending',[SELECT Discount_Approval_Status__c FROM Opportunity WHERE Id=:deal.Id WITH SYSTEM_MODE].Discount_Approval_Status__c,'Approved reason changes invalidate');
    }

    @IsTest static void currencyConversionWhenAvailable() {
        List<CurrencyType> currencies=[SELECT IsoCode,ConversionRate FROM CurrencyType WHERE IsActive=true AND IsCorporate=false WITH SYSTEM_MODE];
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(25,100000);
        Test.startTest();
        Assert.areEqual(100000,DiscountApprovalPolicy.corporateAmount(deal),'Corporate currency pass-through');
        if (!currencies.isEmpty()) {
            deal.CurrencyIsoCode=currencies[0].IsoCode;
            insert as system deal;
            Id prior=DiscountApprovalTestDataFactory.pending(deal.Id).Id;
            deal.CurrencyIsoCode='USD';update as system deal;
            Assert.areEqual('Superseded',[SELECT Status__c FROM Discount_Approval__c WHERE Id=:prior WITH SYSTEM_MODE].Status__c,'Currency change invalidates');
        }
        Test.stopTest();
    }
    @IsTest static void currencyRatesUseCloseDate() {
        seedCurrencyRates();
        DiscountApprovalPolicy.datedRates.put('EUR',new List<SObject>{
            datedRate('2026-07-01',null,4),datedRate('2026-01-01','2026-07-01',2)});
        Opportunity deal=new Opportunity(Amount=100000,CurrencyIsoCode='EUR',CloseDate=Date.newInstance(2026,6,30));
        Test.startTest();
        Assert.areEqual(50000,DiscountApprovalPolicy.corporateAmount(deal),'Uses historical rate before next start');
        deal.CloseDate=Date.newInstance(2026,7,1);
        Assert.areEqual(25000,DiscountApprovalPolicy.corporateAmount(deal),'Next start is exclusive; new start inclusive');
        deal.CloseDate=Date.newInstance(2027,1,1);
        Assert.areEqual(25000,DiscountApprovalPolicy.corporateAmount(deal),'Open-ended current interval');
        deal.CurrencyIsoCode=null;
        Assert.areEqual(100000,DiscountApprovalPolicy.corporateAmount(deal),'Blank currency defaults to corporate');
        deal.Amount=null;
        Assert.areEqual(0,DiscountApprovalPolicy.corporateAmount(deal),'Blank amount');
        Test.stopTest();
    }
    @IsTest static void currencyRateGapsFailClosed() {
        seedCurrencyRates();
        Opportunity deal=new Opportunity(Amount=100000,CurrencyIsoCode='EUR',CloseDate=Date.newInstance(2026,1,1));
        Test.startTest();
        Assert.areEqual(50000,DiscountApprovalPolicy.corporateAmount(deal),'Current rate when no dated configuration exists');
        DiscountApprovalPolicy.datedRates.put('EUR',new List<SObject>{datedRate('2026-07-01',null,4)});
        assertMissingRate(deal);
        deal.CurrencyIsoCode='GBP';
        assertMissingRate(deal);
        DiscountApprovalPolicy.datedRates.clear();
        DiscountApprovalPolicy.rates.put('GBP',0);
        assertMissingRate(deal);
        Test.stopTest();
    }
    private static void seedCurrencyRates() {
        // Transaction-local inputs only; never enable currencies or ACM in the sandbox.
        DiscountApprovalPolicy.rates=new Map<String,Decimal>{'USD'=>1,'EUR'=>2,'GBP'=>3};
        DiscountApprovalPolicy.corporate='USD';
        DiscountApprovalPolicy.datedRates=new Map<String,List<SObject>>();
    }
    private static SObject datedRate(String startDate,String nextStartDate,Decimal rate) {
        return (SObject)JSON.deserialize(JSON.serialize(new Map<String,Object>{
            'attributes'=>new Map<String,String>{'type'=>'DatedConversionRate'},'IsoCode'=>'EUR',
            'StartDate'=>startDate,'NextStartDate'=>nextStartDate,'ConversionRate'=>rate}),SObject.class);
    }
    private static void assertMissingRate(Opportunity deal) {
        try { DiscountApprovalPolicy.corporateAmount(deal);Assert.fail('Missing or invalid rate must fail closed'); }
        catch (DiscountApprovalPolicy.PolicyException error) {
            Assert.areEqual('A valid currency conversion rate is required.',error.getMessage(),'Rate validation');
        }
    }
    @IsTest static void noRecordAccessCannotReadPanel() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);insert as system deal;
        Test.startTest();System.runAs(DiscountApprovalTestDataFactory.persona('outsider')) {
            try { DiscountApprovalService.getPanel(deal.Id);Assert.fail('Private record must not leak'); }
            catch (AuraHandledException error) { Assert.isTrue(error.getMessage().contains('record and field access'),'No data leakage'); }
        }Test.stopTest();
    }
    @IsTest static void repCanSubmitInUserMode() {
        Opportunity deal=DiscountApprovalTestDataFactory.opportunity(15,100000);
        Test.startTest();System.runAs(DiscountApprovalTestDataFactory.persona('rep')) {
            insert as user deal;
            Opportunity pending=[SELECT Discount_Approval_Status__c FROM Opportunity WHERE Id=:deal.Id WITH USER_MODE];
            Assert.areEqual('Pending',pending.Discount_Approval_Status__c,'Rep can submit with assigned permissions');
        }Test.stopTest();
        Assert.isNotNull(DiscountApprovalTestDataFactory.pending(deal.Id),'Approval cycle created');
    }
    private static void assertValidation(Database.SaveResult result,String message) {
        Assert.isFalse(result.isSuccess(),'Invalid mutation must fail');
        Assert.areEqual(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION,result.getErrors()[0].getStatusCode(),'Business validation, not fixture permissions');
        Assert.areEqual(message,result.getErrors()[0].getMessage(),'Expected business rule');
    }
    @IsTest static void bulk200InsertAndUpdate() { bulkOpportunities(200); }
    @IsTest static void bulk251AcrossTriggerChunks() { bulkOpportunities(251); }
    private static void bulkOpportunities(Integer count) {
        Opportunity seed=DiscountApprovalTestDataFactory.opportunity(25,100000);List<Opportunity> deals=new List<Opportunity>();
        for (Integer i=0;i<count;i++) { Opportunity deal=seed.clone(false,true,false,false);deal.Name='Bulk '+i;deals.add(deal); }
        Test.startTest();insert as system deals;
        for (Opportunity deal : deals) deal.Discount_Percent__c=26;
        update as system deals;Integer queries=Limits.getQueries();Integer statements=Limits.getDmlStatements();Test.stopTest();
        Set<Id> ids=new Map<Id,Opportunity>(deals).keySet();
        Assert.areEqual(count,[SELECT COUNT() FROM Discount_Approval__c WHERE Opportunity__c IN :ids AND Status__c='Pending' WITH SYSTEM_MODE],'One current cycle each');
        Assert.areEqual(count,[SELECT COUNT() FROM Discount_Approval__c WHERE Opportunity__c IN :ids AND Status__c='Superseded' WITH SYSTEM_MODE],'One historical cycle each');
        Assert.areEqual(count,[SELECT COUNT() FROM Task WHERE WhatId IN :ids AND Status='Not Started' WITH SYSTEM_MODE],'One current task each');
        Assert.isTrue(queries<100,'Within SOQL limit');Assert.isTrue(statements<150,'Within DML limit');
    }
}
