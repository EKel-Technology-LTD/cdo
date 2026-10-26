trigger RepairOrderValidation on Repair_Order__c (before insert, before update) {
    RepairOrderValidator.validate(Trigger.new);
}
