/** System enforcement for all Opportunity writes, independent of UI and automation switches. */
public without sharing class DiscountApprovalHandler {
    public static Boolean writingCycles { get; private set; }
    private static final List<String> PROTECTED_FIELDS = new List<String>{
        'Discount_Approval_Status__c','Discount_Approval_Route__c','Discount_Approver__c',
        'Discount_Decided_By__c','Discount_Decided_At__c','Discount_Decision_Comment__c'};
    private static Set<String> wonStages;
    /** Only callable in the actual Opportunity trigger context; accepts no caller-supplied records. */
    public static void run() {
        if (!Trigger.isExecuting || Trigger.new == null || Trigger.new[0].getSObjectType() != Opportunity.SObjectType) {
            throw new HandlerException('Opportunity trigger context is required.');
        }
        List<Opportunity> records = (List<Opportunity>)Trigger.new;
        Map<Id,Opportunity> previous = Trigger.isInsert ? new Map<Id,Opportunity>() : (Map<Id,Opportunity>)Trigger.oldMap;
        if (Trigger.isBefore) beforeSave(records, previous);
        else afterSave(records, previous);
    }
    private static Boolean changed(Opportunity current, Opportunity previous, Boolean includeReason) {
        return previous == null || current.Discount_Percent__c != previous.Discount_Percent__c ||
            current.Amount != previous.Amount || current.CurrencyIsoCode != previous.CurrencyIsoCode ||
            current.OwnerId != previous.OwnerId || (includeReason && current.Discount_Reason__c != previous.Discount_Reason__c);
    }
    private static Boolean recalculate(Opportunity current, Opportunity previous) {
        return changed(current, previous, true) && !(previous != null &&
            previous.Discount_Approval_Status__c == 'Rejected' && !changed(current, previous, false));
    }
    private static Map<Id,User> owners(List<Opportunity> records) {
        Set<Id> ids = new Set<Id>();
        for (Opportunity record : records) ids.add(record.OwnerId);
        return new Map<Id,User>([SELECT Id,ManagerId FROM User WHERE Id IN :ids WITH SYSTEM_MODE]);
    }
    private static void beforeSave(List<Opportunity> records, Map<Id,Opportunity> previous) {
        Map<Id,User> users = owners(records);
        if (wonStages == null) {
            wonStages = new Set<String>();
            for (OpportunityStage stage : [SELECT ApiName FROM OpportunityStage WHERE IsWon = true WITH SYSTEM_MODE]) wonStages.add(stage.ApiName);
        }
        for (Opportunity record : records) {
            Opportunity old = previous.get(record.Id);
            if (record.Discount_Percent__c != null && record.Discount_Percent__c >= 10 && String.isBlank(record.Discount_Reason__c))
                record.Discount_Reason__c.addError('Enter a Discount Reason for a discount of 10% or more.');
            if (DiscountApprovalService.writingOutcome != true) {
                for (String field : PROTECTED_FIELDS) {
                    if (record.get(field) != (old == null ? null : old.get(field))) {
                        record.addError('Approval fields can only be changed through the Deal Desk approval panel.');
                        break;
                    }
                }
            }
            if (old != null && wonStages.contains(old.StageName) && changed(record,old,true)) {
                record.addError('Reopen the Opportunity before changing discount terms on a Closed Won deal.');
                // Do not replace the recovery instruction with the later pending-approval error.
                continue;
            }
            if (recalculate(record,old)) {
                String route = DiscountApprovalPolicy.route(record.Discount_Percent__c,DiscountApprovalPolicy.corporateAmount(record));
                Id manager = users.get(record.OwnerId)?.ManagerId;
                if (route != null && manager == null) record.addError('The Opportunity owner has no manager, so a discount of 10% or more cannot be submitted.');
                record.Discount_Approval_Status__c = route == null ? 'Not Required' : 'Pending';
                record.Discount_Approval_Route__c = route;
                record.Discount_Approver__c = route == 'Manager' ? manager : null;
                record.Discount_Decided_By__c = null;
                record.Discount_Decided_At__c = null;
                record.Discount_Decision_Comment__c = null;
            }
            if (wonStages.contains(record.StageName) && (record.Discount_Approval_Status__c == 'Pending' || record.Discount_Approval_Status__c == 'Rejected'))
                record.addError('Discount approval is pending or rejected; this deal cannot be Closed Won.');
        }
    }
    private static void afterSave(List<Opportunity> records, Map<Id,Opportunity> previous) {
        List<Opportunity> newCycles = new List<Opportunity>();
        Set<Id> invalidated = new Set<Id>();
        Set<Id> sharingIds = new Set<Id>();
        for (Opportunity record : records) {
            Opportunity old = previous.get(record.Id);
            if (recalculate(record,old)) {
                invalidated.add(record.Id);
                if (record.Discount_Approval_Status__c == 'Pending') newCycles.add(record);
            }
            if (old != null && old.OwnerId != record.OwnerId) sharingIds.add(record.Id);
        }
        writingCycles = true;
        try {
            List<Discount_Approval__c> superseded = [SELECT Id,Status__c,Manager_Task_Id__c FROM Discount_Approval__c
                WHERE Opportunity__c IN :invalidated AND Status__c IN ('Pending','Approved') WITH SYSTEM_MODE];
            List<Task> completed = new List<Task>();
            for (Discount_Approval__c cycle : superseded) {
                cycle.Status__c = 'Superseded';
                if (cycle.Manager_Task_Id__c != null) completed.add(new Task(Id=cycle.Manager_Task_Id__c,Status='Completed'));
            }
            if (!completed.isEmpty()) update as system completed;
            if (!superseded.isEmpty()) update as system superseded;
            createCycles(newCycles);
            for (Opportunity record : newCycles) sharingIds.add(record.Id);
            DiscountApprovalSharing.ensureShares(sharingIds);
        } finally { writingCycles = false; }
    }
    /** Creates cycles only for a verified handler or service operation. */
    public static void createCycles(List<Opportunity> records) {
        if (writingCycles != true && DiscountApprovalService.writingOutcome != true) throw new HandlerException('Approval service context is required.');
        if (records.isEmpty()) return;
        Map<Id,User> users = owners(records);
        List<Task> tasks = new List<Task>();
        List<Discount_Approval__c> cycles = new List<Discount_Approval__c>();
        for (Opportunity record : records) {
            tasks.add(new Task(OwnerId=users.get(record.OwnerId).ManagerId,WhatId=record.Id,
                Subject=('Approve discount: '+record.Name).left(255),Priority='High',Status='Not Started',ActivityDate=Date.today()));
            cycles.add(new Discount_Approval__c(Opportunity__c=record.Id,Route__c=record.Discount_Approval_Route__c,
                Status__c='Pending',Approver__c=record.Discount_Approver__c,Submitted_By__c=UserInfo.getUserId(),Submitted_At__c=System.now(),
                Discount_Percent__c=record.Discount_Percent__c,Amount__c=record.Amount,CurrencyIsoCode=record.CurrencyIsoCode,
                Routing_Amount_Corporate__c=DiscountApprovalPolicy.corporateAmount(record),Discount_Reason__c=record.Discount_Reason__c));
        }
        insert as system tasks;
        for (Integer i=0;i<cycles.size();i++) cycles[i].Manager_Task_Id__c = tasks[i].Id;
        insert as system cycles;
    }
    public class HandlerException extends Exception {}
}
