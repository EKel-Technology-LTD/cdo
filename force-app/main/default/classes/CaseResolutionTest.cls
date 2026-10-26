@IsTest
private class CaseResolutionTest {
    private static final String CODE_ERROR = '結案前請選擇結案代碼。';
    private static final String SUMMARY_ERROR = '已維修、已換貨或已退貨的案件，結案前請填寫結案摘要。';
    private static final String PARENT_ERROR = '結案代碼為「重複案件」時，請在上層案件填入原案件。';

    private static Case sample(String status, String code, String summary) {
        return new Case(Subject = 'Synthetic CDO-56 regression', Origin = 'Phone',
            Status = status, Resolution_Code__c = code, Resolution_Summary__c = summary);
    }
    private static void expectError(Database.SaveResult result, String message) {
        Assert.isFalse(result.isSuccess(), 'Invalid case must not save');
        Boolean found = false;
        for (Database.Error error : result.getErrors()) {
            if (error.getMessage().contains(message)) { found = true; }
        }
        Assert.isTrue(found, 'Expected business error: ' + message + '; got ' + result.getErrors());
    }
    @IsTest static void openLifecycleAndOptionalFields() {
        Case c = sample('New', null, null);
        insert c;
        for (String status : new List<String>{'In Progress', 'Waiting on Customer'}) {
            c.Status = status;
            update c;
            Case saved = [SELECT Status, IsClosed, Product_Line__c, Resolution_Code__c,
                Resolution_Summary__c FROM Case WHERE Id = :c.Id];
            Assert.areEqual(status, saved.Status);
            Assert.isFalse(saved.IsClosed);
            Assert.isNull(saved.Product_Line__c);
            Assert.isNull(saved.Resolution_Code__c);
            Assert.isNull(saved.Resolution_Summary__c);
        }
    }
    @IsTest static void closureCodeOnCreateAndEveryUpdate() {
        expectError(Database.insert(sample('Closed', null, null), false), CODE_ERROR);
        Case c = sample('New', null, null);
        insert c;
        c.Status = 'Closed';
        expectError(Database.update(c, false), CODE_ERROR);
        c.Resolution_Code__c = 'Answered';
        update c;
        Assert.isTrue([SELECT IsClosed FROM Case WHERE Id = :c.Id].IsClosed);
        c.Subject = 'Synthetic already-closed edit';
        c.Resolution_Code__c = null;
        expectError(Database.update(c, false), CODE_ERROR);
    }
    @IsTest static void summaryForAllImportantOutcomesAndClosedEdits() {
        String longSummary = 'x'.repeat(4000);
        for (String code : new List<String>{'Repaired', 'Replaced', 'Refunded'}) {
            Case c = sample('Closed', code, null);
            expectError(Database.insert(c, false), SUMMARY_ERROR);
            c.Resolution_Summary__c = '';
            expectError(Database.insert(c, false), SUMMARY_ERROR);
            c.Resolution_Summary__c = longSummary;
            insert c;
            Case saved = [SELECT IsClosed, Resolution_Summary__c FROM Case WHERE Id = :c.Id];
            Assert.isTrue(saved.IsClosed);
            Assert.areEqual(longSummary, saved.Resolution_Summary__c);
            c.Resolution_Summary__c = null;
            expectError(Database.update(c, false), SUMMARY_ERROR);
        }
        for (String code : new List<String>{'Answered', 'Not_Reproducible', 'No_Customer_Response'}) {
            insert sample('Closed', code, null);
        }
    }
    @IsTest static void duplicateRequiresParentEvenWhenOpen() {
        Case originalCase = sample('New', null, null);
        insert originalCase;
        for (String status : new List<String>{'New', 'Closed'}) {
            Case duplicateCase = sample(status, 'Duplicate', null);
            expectError(Database.insert(duplicateCase, false), PARENT_ERROR);
            duplicateCase.ParentId = originalCase.Id;
            insert duplicateCase;
            Assert.areEqual(originalCase.Id, [SELECT ParentId FROM Case WHERE Id = :duplicateCase.Id].ParentId);
            duplicateCase.ParentId = null;
            expectError(Database.update(duplicateCase, false), PARENT_ERROR);
        }
    }
    @IsTest static void allSixProductLines() {
        List<Case> cases = new List<Case>();
        Set<String> expected = new Set<String>{'Air_Purifier', 'Dehumidifier', 'Vacuum_Cleaner',
            'Water_Purifier', 'Accessory', 'Service_Plan'};
        Set<String> actual = new Set<String>();
        for (Schema.PicklistEntry entry : Case.Product_Line__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) { actual.add(entry.getValue()); }
        }
        Assert.areEqual(expected, actual);
        for (String value : expected) {
            Case c = sample('New', null, null);
            c.Product_Line__c = value;
            cases.add(c);
        }
        insert cases;
        Assert.areEqual(6, [SELECT count() FROM Case WHERE Id IN :cases]);
    }
    @IsTest static void bulkClosedCases195SucceedFiveFail() {
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 200; i++) {
            cases.add(sample('Closed', i < 5 ? null : 'Answered', null));
        }
        Test.startTest();
        List<Database.SaveResult> results = Database.insert(cases, false);
        Test.stopTest();
        Integer successes = 0;
        for (Integer i = 0; i < results.size(); i++) {
            if (i < 5) { expectError(results[i], CODE_ERROR); }
            else { Assert.isTrue(results[i].isSuccess(), 'Valid row ' + i); successes++; }
        }
        Assert.areEqual(195, successes);
        Assert.areEqual(195, [SELECT count() FROM Case]);
    }
    @IsTest static void bulkMixedFlowErrorsRetainValidRows() {
        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 200; i++) {
            cases.add(sample('Closed', 'Replaced', i < 5 ? null : 'Synthetic replacement completed'));
        }
        Test.startTest();
        List<Database.SaveResult> results = Database.insert(cases, false);
        Test.stopTest();
        Integer successes = 0;
        for (Integer i = 0; i < results.size(); i++) {
            if (i < 5) { expectError(results[i], SUMMARY_ERROR); }
            else { Assert.isTrue(results[i].isSuccess(), 'Valid Flow row ' + i); successes++; }
        }
        Assert.areEqual(195, successes);
        Assert.areEqual(195, [SELECT count() FROM Case]);
    }
}
