trigger SalesTargetBeforeSave on Sales_Target__c (before insert, before update) {
    SalesTargetCurrencyPolicy.beforeSave(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}
