/** Synthetic-only save-contract tests. Persona effective-access/UI evidence belongs to QA. */
@IsTest
private with sharing class RepairOrderValidatorTest {
    private static final String FAULT_ERROR = 'Please enter the fault description.';
    private static final String REASON_ERROR =
        'When "Unrepairable" or "Cancelled", please state the reason in Diagnosis Result.';
    private static final String APPROVAL_ERROR =
        'Out-of-warranty or customer-damage repairs require the customer\'s recorded quote approval before changing to "In Repair".';

    // This fixture factory is local to this feature; the existing discount factory creates
    // unrelated roles, groups and opportunity automation and is intentionally not reused.
    private class Fixtures {
        Case serviceCase;
        Asset asset;
        String currency;
        Fixtures() {
            currency = [SELECT IsoCode FROM CurrencyType WHERE IsCorporate = true WITH SYSTEM_MODE LIMIT 1].IsoCode;
            Account account = new Account(Name='Synthetic Repair Customer');
            insert as system account;
            serviceCase = new Case(Subject='Synthetic appliance leakage', Status='New', Origin='Phone', AccountId=account.Id);
            insert as system serviceCase;
            asset = new Asset(Name='Synthetic Water Purifier', AccountId=account.Id);
            insert as system asset;
        }
        Repair_Order__c order() {
            return new Repair_Order__c(Case__c=serviceCase.Id, Asset__c=asset.Id,
                Intake_Method__c='Courier_Pickup', Fault_Category__c='Leakage',
                Fault_Description__c='Synthetic leak at the outlet', CurrencyIsoCode=currency);
        }
    }

    private static void assertError(Database.SaveResult result, String field, String message) {
        Assert.isFalse(result.isSuccess(), 'Invalid save must fail');
        Boolean found = false;
        for (Database.Error error : result.getErrors()) {
            if (error.getMessage() == message && error.getFields().contains(field)) {
                found = true;
            }
        }
        Assert.isTrue(found, 'Expected field error: '+field+' / '+message+'; actual '+result.getErrors());
    }
    private static void assertRequired(Database.SaveResult result, String field) {
        Assert.isFalse(result.isSuccess(), 'Missing '+field+' must fail');
        Boolean found = false;
        for (Database.Error error : result.getErrors()) {
            if (error.getStatusCode() == StatusCode.REQUIRED_FIELD_MISSING && error.getFields().contains(field)) {
                found = true;
            }
        }
        Assert.isTrue(found, 'Expected required field error for '+field+'; actual '+result.getErrors());
    }
    private static Repair_Order__c saved(Id recordId) {
        return [SELECT Name, Repair_Status__c, Total_Charge__c, Turnaround_Days__c, Is_Overdue__c,
            Received_Date__c, Diagnosis_Date__c, Quoted_Date__c, Repair_Completed_Date__c,
            Shipped_Back_Date__c, Overdue_Reminder_Sent__c, Customer_Approved_Quote__c,
            Case__c, Asset__c FROM Repair_Order__c WHERE Id=:recordId WITH SYSTEM_MODE];
    }

    @IsTest static void intakeDefaultsAndParentLinks() {
        Fixtures fixtures = new Fixtures();
        Repair_Order__c order = fixtures.order();
        Test.startTest();
        insert as system order;
        Test.stopTest();
        Repair_Order__c actual = saved(order.Id);
        Date today = Date.today();
        String month = today.month()<10 ? '0'+today.month() : String.valueOf(today.month());
        Assert.isTrue(Pattern.matches('RO-'+today.year()+month+'-[0-9]{4,}',actual.Name), 'Order number format');
        Assert.areEqual('Awaiting_Receipt',actual.Repair_Status__c,'Default status');
        Assert.areEqual(fixtures.serviceCase.Id,actual.Case__c,'Case relationship');
        Assert.areEqual(fixtures.asset.Id,actual.Asset__c,'Asset relationship');
        Assert.isFalse(actual.Customer_Approved_Quote__c,'Approval defaults false');
        Assert.isFalse(actual.Overdue_Reminder_Sent__c,'Reminder defaults false');
        Assert.areEqual(null,actual.Diagnosis_Date__c,'No automatic diagnosis date');
        Assert.areEqual(null,actual.Quoted_Date__c,'No automatic quote date');
        Assert.areEqual(null,actual.Repair_Completed_Date__c,'No automatic completion date');
        Assert.areEqual(null,actual.Shipped_Back_Date__c,'No automatic shipping date');
    }
    @IsTest static void requiredLookupsAndPicklists() {
        Fixtures fixtures = new Fixtures();
        List<String> fields = new List<String>{'Case__c','Asset__c','Fault_Category__c','Intake_Method__c'};
        List<Repair_Order__c> orders = new List<Repair_Order__c>();
        for (String field : fields) {
            Repair_Order__c order = fixtures.order(); order.put(field,null); orders.add(order);
        }
        Test.startTest();
        List<Database.SaveResult> results = Database.insert(orders,false,AccessLevel.SYSTEM_MODE);
        Test.stopTest();
        for (Integer i=0;i<fields.size();i++) { assertRequired(results[i],fields[i]); }
    }
    @IsTest static void missingDescriptionInsert() {
        Fixtures fixtures = new Fixtures(); Repair_Order__c order=fixtures.order(); order.Fault_Description__c=null;
        Test.startTest();
        Database.SaveResult result=Database.insert(order,false,AccessLevel.SYSTEM_MODE);
        Test.stopTest();
        assertError(result,'Fault_Description__c',FAULT_ERROR);
    }
    @IsTest static void whitespaceDescriptionUpdateRetainsPersistedValue() {
        Fixtures fixtures = new Fixtures(); Repair_Order__c order=fixtures.order(); insert as system order;
        String previous=order.Fault_Description__c; order.Fault_Description__c=' \t\n';
        Test.startTest();
        Database.SaveResult result=Database.update(order,false,AccessLevel.SYSTEM_MODE);
        Test.stopTest();
        assertError(result,'Fault_Description__c',FAULT_ERROR);
        Assert.areEqual(previous,[SELECT Fault_Description__c FROM Repair_Order__c WHERE Id=:order.Id WITH SYSTEM_MODE].Fault_Description__c,'Rejected save preserves value');
    }
    @IsTest static void explicitBlankStatusUpdate() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order(); insert as system order;
        order.Repair_Status__c=null;
        Test.startTest();
        Database.SaveResult result=Database.update(order,false,AccessLevel.SYSTEM_MODE);
        Test.stopTest();
        assertError(result,'Repair_Status__c','Please select a repair status.');
        Assert.areEqual('Awaiting_Receipt',saved(order.Id).Repair_Status__c,'Blank status never persisted');
    }
    @IsTest static void blankStatusGuardForUnsavedRecord() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order(); order.Repair_Status__c=null;
        Test.startTest(); RepairOrderValidator.validate(new List<Repair_Order__c>{order}); Test.stopTest();
        Assert.isTrue(order.hasErrors(),'Explicit blank input rejected by guard');
        Assert.areEqual('Please select a repair status.',order.getErrors()[0].getMessage(),'Blank status message');
    }
    @IsTest static void chargeableRepairNeedsApproval() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order(); insert as system order;
        order.Warranty_Coverage__c='Out_Of_Warranty'; order.Repair_Status__c='In_Repair';
        Test.startTest();
        Database.SaveResult denied=Database.update(order,false,AccessLevel.SYSTEM_MODE);
        order.Customer_Approved_Quote__c=true; order.Quote_Approved_Date__c=Date.today();
        Database.SaveResult allowed=Database.update(order,false,AccessLevel.SYSTEM_MODE);
        Test.stopTest();
        assertError(denied,'Repair_Status__c',APPROVAL_ERROR);
        Assert.isTrue(allowed.isSuccess(),'Dated approval allows repair');
        Assert.areEqual('In_Repair',saved(order.Id).Repair_Status__c,'Approved status persists');
    }
    @IsTest static void approvalCannotBeRevokedWhileInRepair() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order();
        order.Warranty_Coverage__c='Out_Of_Warranty'; order.Repair_Status__c='In_Repair';
        order.Customer_Approved_Quote__c=true; order.Quote_Approved_Date__c=Date.today(); insert as system order;
        order.Customer_Approved_Quote__c=false;
        Test.startTest(); Database.SaveResult result=Database.update(order,false,AccessLevel.SYSTEM_MODE); Test.stopTest();
        assertError(result,'Repair_Status__c',APPROVAL_ERROR);
        Assert.isTrue(saved(order.Id).Customer_Approved_Quote__c,'Every-save approval guard preserves approval');
    }
    @IsTest static void customerDamageNeedsApprovalOnInsert() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order();
        order.Warranty_Coverage__c='Customer_Damage'; order.Repair_Status__c='In_Repair';
        Test.startTest(); Database.SaveResult result=Database.insert(order,false,AccessLevel.SYSTEM_MODE); Test.stopTest();
        assertError(result,'Repair_Status__c',APPROVAL_ERROR);
    }
    @IsTest static void inWarrantyAndUndeterminedAllowRepair() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c warranty=fixtures.order(); Repair_Order__c undetermined=fixtures.order();
        warranty.Repair_Status__c='In_Repair'; warranty.Warranty_Coverage__c='In_Warranty'; undetermined.Repair_Status__c='In_Repair';
        Test.startTest(); List<Database.SaveResult> results=Database.insert(new List<Repair_Order__c>{warranty,undetermined},false,AccessLevel.SYSTEM_MODE); Test.stopTest();
        for(Database.SaveResult result:results) { Assert.isTrue(result.isSuccess(),'Only chargeable determinations need approval'); }
    }
    @IsTest static void approvalRequiresDate() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order(); order.Customer_Approved_Quote__c=true;
        Test.startTest(); Database.SaveResult result=Database.insert(order,false,AccessLevel.SYSTEM_MODE); Test.stopTest();
        assertError(result,'Quote_Approved_Date__c','Please enter the quote approval date.');
    }
    @IsTest static void chargeFormulaReflectsWarranty() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order();
        order.Parts_Cost__c=45; order.Labor_Cost__c=30; order.Warranty_Coverage__c='Out_Of_Warranty';
        Test.startTest(); insert as system order; Decimal charge=saved(order.Id).Total_Charge__c;
        order.Warranty_Coverage__c='In_Warranty'; update as system order; Test.stopTest();
        Assert.areEqual(75,charge,'Parts plus labor'); Assert.areEqual(0,saved(order.Id).Total_Charge__c,'In warranty is free');
    }
    @IsTest static void blankCostsAreZero() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order(); order.Labor_Cost__c=30;
        Test.startTest(); insert as system order; Test.stopTest();
        Assert.areEqual(30,saved(order.Id).Total_Charge__c,'Blank parts count as zero');
    }
    @IsTest static void shippingRequiresTrackingExceptOnsite() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order(); insert as system order; order.Repair_Status__c='Shipped_Back';
        Test.startTest(); Database.SaveResult denied=Database.update(order,false,AccessLevel.SYSTEM_MODE);
        order.Return_Tracking_Number__c='SYNTHETIC-TRACK-001'; Database.SaveResult tracked=Database.update(order,false,AccessLevel.SYSTEM_MODE);
        order.Intake_Method__c='Onsite'; order.Return_Tracking_Number__c=null; Database.SaveResult onsite=Database.update(order,false,AccessLevel.SYSTEM_MODE); Test.stopTest();
        assertError(denied,'Return_Tracking_Number__c','Please enter the tracking number when shipping back.');
        Assert.isTrue(tracked.isSuccess(),'Tracking permits courier return'); Assert.isTrue(onsite.isSuccess(),'Onsite requires no tracking');
    }
    @IsTest static void terminalReasonsRequired() {
        Fixtures fixtures=new Fixtures(); List<Repair_Order__c> orders=new List<Repair_Order__c>();
        for(String status:new List<String>{'Unrepairable','Cancelled'}) {
            Repair_Order__c order=fixtures.order(); order.Repair_Status__c=status; order.Diagnosis_Result__c=' \n'; orders.add(order);
        }
        Test.startTest(); List<Database.SaveResult> denied=Database.insert(orders,false,AccessLevel.SYSTEM_MODE);
        for(Repair_Order__c order:orders) {order.Diagnosis_Result__c='Synthetic terminal reason';}
        List<Database.SaveResult> allowed=Database.insert(orders,false,AccessLevel.SYSTEM_MODE); Test.stopTest();
        for(Database.SaveResult result:denied) {assertError(result,'Diagnosis_Result__c',REASON_ERROR);}
        for(Database.SaveResult result:allowed) {Assert.isTrue(result.isSuccess(),'Reason allows terminal status');}
    }
    @IsTest static void terminalReasonCannotBeCleared() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order(); order.Repair_Status__c='Unrepairable'; order.Diagnosis_Result__c='Synthetic damage'; insert as system order;
        order.Diagnosis_Result__c=null;
        Test.startTest(); Database.SaveResult result=Database.update(order,false,AccessLevel.SYSTEM_MODE); Test.stopTest();
        assertError(result,'Diagnosis_Result__c',REASON_ERROR);
    }
    @IsTest static void completionCannotPrecedeReceipt() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order(); order.Received_Date__c=Date.today(); order.Repair_Completed_Date__c=Date.today().addDays(-1);
        Test.startTest(); Database.SaveResult result=Database.insert(order,false,AccessLevel.SYSTEM_MODE); Test.stopTest();
        assertError(result,'Repair_Completed_Date__c','Completed Date cannot be earlier than Received Date.');
    }
    @IsTest static void overdueAndTurnaroundBoundaries() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order(); order.Received_Date__c=Date.today().addDays(-8); order.Repair_Status__c='Diagnosing';
        Test.startTest(); insert as system order; Repair_Order__c open=saved(order.Id);
        order.Repair_Status__c='Repaired'; order.Repair_Completed_Date__c=Date.today(); update as system order; Test.stopTest();
        Assert.isTrue(open.Is_Overdue__c,'Eight days open is overdue'); Assert.areEqual(null,open.Turnaround_Days__c,'Blank completion means blank turnaround');
        Repair_Order__c closed=saved(order.Id); Assert.isFalse(closed.Is_Overdue__c,'Repaired closes overdue'); Assert.areEqual(8,closed.Turnaround_Days__c,'Exact date difference');
    }
    @IsTest static void sevenDaysAndMissingReceiptAreNotOverdue() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c seven=fixtures.order(); seven.Received_Date__c=Date.today().addDays(-7); Repair_Order__c missing=fixtures.order();
        Test.startTest(); insert as system new List<Repair_Order__c>{seven,missing}; Test.stopTest();
        Assert.isFalse(saved(seven.Id).Is_Overdue__c,'Seven days is not over seven'); Assert.isFalse(saved(missing.Id).Is_Overdue__c,'Missing receipt is not overdue');
    }
    @IsTest static void allClosedStatusesNotOverdue() {
        Fixtures fixtures=new Fixtures(); List<Repair_Order__c> orders=new List<Repair_Order__c>();
        for(String status:new List<String>{'Repaired','Shipped_Back','Unrepairable','Cancelled'}) {
            Repair_Order__c order=fixtures.order(); order.Repair_Status__c=status; order.Received_Date__c=Date.today().addDays(-8); order.Intake_Method__c='Onsite'; order.Diagnosis_Result__c='Synthetic reason'; orders.add(order);
        }
        Test.startTest(); insert as system orders; Test.stopTest();
        for(Repair_Order__c order:[SELECT Is_Overdue__c FROM Repair_Order__c WITH SYSTEM_MODE]) {Assert.isFalse(order.Is_Overdue__c,'Every closed status stops overdue');}
    }
    @IsTest static void corporateMismatchFailsWithoutConversion() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order(); order.Repair_Status__c='Received'; order.CurrencyIsoCode='ZZZ';
        Test.startTest(); RepairOrderValidator.validate(new List<Repair_Order__c>{order}); Test.stopTest();
        Assert.isTrue(order.hasErrors(),'Noncorporate currency rejected');
        Assert.areEqual('Select the organization\'s corporate currency for Repair Order.',order.getErrors()[0].getMessage(),'Exact currency message');
        Assert.areEqual('ZZZ',order.CurrencyIsoCode,'No conversion or mutation');
    }
    @IsTest static void missingCorporateConfigurationFailsClosed() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order();
        RepairOrderValidator.corporateConfiguration=new List<CurrencyType>();
        Test.startTest(); Database.SaveResult result=Database.insert(order,false,AccessLevel.SYSTEM_MODE); Test.stopTest();
        assertError(result,'CurrencyIsoCode','Repair Order corporate currency configuration is unavailable. Contact your administrator.');
    }
    @IsTest static void corporateMismatchBlocksUpdate() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order(); insert as system order;
        RepairOrderValidator.corporateConfiguration=new List<CurrencyType>{new CurrencyType(IsoCode='ZZZ')};
        Test.startTest(); Database.SaveResult result=Database.update(order,false,AccessLevel.SYSTEM_MODE); Test.stopTest();
        assertError(result,'CurrencyIsoCode','Select the organization\'s corporate currency for Repair Order.');
    }
    @IsTest static void bulkImport200Has195SuccessesAnd5DescriptionFailures() {
        Fixtures fixtures=new Fixtures(); List<Repair_Order__c> orders=new List<Repair_Order__c>();
        for(Integer i=0;i<200;i++) {Repair_Order__c order=fixtures.order(); if(i<5) {order.Fault_Description__c=null;} orders.add(order);}
        Test.startTest(); List<Database.SaveResult> results=Database.insert(orders,false,AccessLevel.SYSTEM_MODE); Integer queries=Limits.getQueries(); Test.stopTest();
        Integer successes=0; Integer failures=0;
        for(Integer i=0;i<results.size();i++) {
            if(i<5) {assertError(results[i],'Fault_Description__c',FAULT_ERROR); failures++;}
            else {Assert.isTrue(results[i].isSuccess(),'Valid import row '+i+' must save'); successes++;}
        }
        Assert.areEqual(195,successes,'Exact successful rows'); Assert.areEqual(5,failures,'Exact rejected rows');
        Assert.areEqual(195,[SELECT COUNT() FROM Repair_Order__c WITH SYSTEM_MODE],'Persisted count');
        Assert.areEqual(1,queries,'Corporate config queried once, even for partial-save retry');
    }
    @IsTest static void bulk251InsertAndUpdateValidateAcrossChunks() {
        Fixtures fixtures=new Fixtures(); List<Repair_Order__c> orders=new List<Repair_Order__c>();
        for(Integer i=0;i<251;i++) {orders.add(fixtures.order());}
        Test.startTest(); insert as system orders;
        for(Repair_Order__c order:orders) {order.Fault_Description__c=' ';}
        List<Database.SaveResult> results=Database.update(orders,false,AccessLevel.SYSTEM_MODE); Integer queries=Limits.getQueries(); Test.stopTest();
        Assert.areEqual(251,results.size(),'Every row across chunks validated');
        for(Database.SaveResult result:results) {assertError(result,'Fault_Description__c',FAULT_ERROR);}
        Assert.areEqual(1,queries,'One configuration query across chunks and operations');
    }
    @IsTest static void caseDeletionRestricted() {
        Fixtures fixtures=new Fixtures(); Repair_Order__c order=fixtures.order(); insert as system order;
        Test.startTest(); Database.DeleteResult result=Database.delete(fixtures.serviceCase,false,AccessLevel.SYSTEM_MODE); Test.stopTest();
        Assert.isFalse(result.isSuccess(),'A case with repair orders cannot be deleted');
        Assert.areEqual(fixtures.serviceCase.Id,saved(order.Id).Case__c,'Required link remains');
    }
    @IsTest static void emptyBatchIsSafe() {
        Test.startTest(); RepairOrderValidator.validate(new List<Repair_Order__c>()); Test.stopTest();
        Assert.areEqual(null,RepairOrderValidator.corporateConfiguration,'Empty batch does not query configuration');
    }
    @IsTest static void nullBatchIsSafe() {
        Test.startTest(); RepairOrderValidator.validate(null); Test.stopTest();
        Assert.areEqual(null,RepairOrderValidator.corporateConfiguration,'Null batch does not query configuration');
    }
}
