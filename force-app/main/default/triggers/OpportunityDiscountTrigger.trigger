trigger OpportunityDiscountTrigger on Opportunity (before insert, before update, after insert, after update) {
    DiscountApprovalHandler.run();
}
