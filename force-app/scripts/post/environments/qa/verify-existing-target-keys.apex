// QA activation prerequisite (AC-12). Read all rows, disclose only pass/fail,
// and stop before the Flow is installed if existing data needs remediation.
without sharing class QaExistingTargetKeys {
    void verify() {
        for (Sales_Target__c target : [
            SELECT Sales_Rep__c, Fiscal_Year__c, Fiscal_Quarter__c, Product_Line__c, Target_Key__c
            FROM Sales_Target__c WITH SYSTEM_MODE
        ]) {
            System.assert(target.Sales_Rep__c != null && target.Fiscal_Year__c != null
                && !String.isBlank(target.Fiscal_Quarter__c), 'Existing target lacks required key fields.');
            String line = String.isBlank(target.Product_Line__c) ? 'ALL' : target.Product_Line__c;
            String expected = String.valueOf(target.Sales_Rep__c) + '-' + target.Fiscal_Year__c.intValue()
                + '-' + target.Fiscal_Quarter__c + '-' + line;
            System.assert(expected.equals(target.Target_Key__c),
                'QA activation blocked: existing target keys need approved cleanup or backfill.');
        }
        // Matching all rows to the canonical key proves business uniqueness only
        // when Salesforce enforces uniqueness on the stored key.
        System.assert(Sales_Target__c.Target_Key__c.getDescribe().isUnique(),
            'QA activation requires the unique target key field.');
    }
}
new QaExistingTargetKeys().verify();
