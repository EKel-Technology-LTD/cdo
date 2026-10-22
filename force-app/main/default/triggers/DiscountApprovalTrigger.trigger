trigger DiscountApprovalTrigger on Discount_Approval__c (before insert, before update, before delete, after undelete) {
    if (DiscountApprovalHandler.writingCycles != true && DiscountApprovalService.writingOutcome != true) {
        for (Discount_Approval__c cycle : (Trigger.isDelete ? Trigger.old : Trigger.new)) {
            cycle.addError('Approval records can only be changed through the Deal Desk approval panel.');
        }
    }
}
