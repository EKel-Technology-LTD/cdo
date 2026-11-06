// QA activation prerequisite (AC-12). Read all rows, disclose only pass/fail,
// and stop before the Flow is installed if existing data needs remediation.
without sharing class QaExistingTargetKeys {
    void verify() {
        Schema.SObjectType objectType = Schema.getGlobalDescribe().get('Sales_Target__c');
        Schema.SObjectField keyField = objectType.getDescribe().fields.getMap().get('Target_Key__c');
        System.assert(keyField != null && keyField.getDescribe().isUnique() && !keyField.getDescribe().isCaseSensitive(),
            'QA activation requires a case-insensitive unique target key field.');

        Id lastId;
        while (true) {
            String soql = 'SELECT Id, Sales_Rep__c, Fiscal_Year__c, Fiscal_Quarter__c, Product_Line__c, Target_Key__c FROM Sales_Target__c'
                + (lastId == null ? '' : ' WHERE Id > :lastId') + ' ORDER BY Id LIMIT 1000';
            List<SObject> page = Database.queryWithBinds(soql, new Map<String,Object>{'lastId' => lastId}, AccessLevel.SYSTEM_MODE);
            for (SObject target : page) {
                Id rep = (Id)target.get('Sales_Rep__c');
                Decimal year = (Decimal)target.get('Fiscal_Year__c');
                String quarter = (String)target.get('Fiscal_Quarter__c');
                String product = (String)target.get('Product_Line__c');
                System.assert(rep != null && year != null && !String.isBlank(quarter), 'Existing target lacks required key fields.');
                String expected = String.valueOf(rep) + '-' + year.intValue() + '-' + quarter + '-' + (String.isBlank(product) ? 'ALL' : product);
                System.assert(expected.equals((String)target.get('Target_Key__c')),
                    'QA activation blocked: existing target keys need approved cleanup or backfill.');
                lastId = (Id)target.get('Id');
            }
            if (page.size() < 1000) break;
        }
    }
}
new QaExistingTargetKeys().verify();
