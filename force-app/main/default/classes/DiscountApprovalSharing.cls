/** System-only historical sharing required by the approved approval policy. */
public without sharing class DiscountApprovalSharing {
    /** Preserves group read access across route and owner changes; never grants edit. */
    public static void ensureShares(Set<Id> opportunityIds) {
        if (DiscountApprovalHandler.writingCycles != true && DiscountApprovalService.writingOutcome != true)
            throw new SharingException('Approval service context is required.');
        if (opportunityIds.isEmpty()) return;
        Map<String,Id> groups = new Map<String,Id>();
        for (Group groupRecord : [SELECT Id,DeveloperName FROM Group WHERE Type='Regular' AND DeveloperName IN
            ('Deal_Desk_Analysts','Discount_Executive_Approvers') WITH SYSTEM_MODE]) groups.put(groupRecord.DeveloperName,groupRecord.Id);
        Set<String> existing = new Set<String>();
        for (OpportunityShare share : [SELECT OpportunityId,UserOrGroupId FROM OpportunityShare WHERE OpportunityId IN :opportunityIds WITH SYSTEM_MODE])
            existing.add(share.OpportunityId+':'+share.UserOrGroupId);
        List<OpportunityShare> shares = new List<OpportunityShare>();
        for (AggregateResult route : [SELECT Opportunity__c opportunityId,Route__c route FROM Discount_Approval__c
            WHERE Opportunity__c IN :opportunityIds AND Route__c IN ('Deal Desk','Executive') WITH SYSTEM_MODE GROUP BY Opportunity__c,Route__c]) {
            Id opportunityId = (Id)route.get('opportunityId');
            Id groupId = groups.get((String)route.get('route') == 'Deal Desk' ? 'Deal_Desk_Analysts' : 'Discount_Executive_Approvers');
            if (groupId == null) throw new SharingException('The discount approval public groups must be deployed.');
            String key = opportunityId+':'+groupId;
            if (!existing.contains(key)) {
                shares.add(new OpportunityShare(OpportunityId=opportunityId,UserOrGroupId=groupId,OpportunityAccessLevel='Read',RowCause='Manual'));
                existing.add(key);
            }
        }
        if (!shares.isEmpty()) insert as system shares;
    }
    public class SharingException extends Exception {}
}
