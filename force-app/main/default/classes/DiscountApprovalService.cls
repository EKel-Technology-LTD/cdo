/** Sharing-aware entry point. Decision rights derive from captured manager/group membership, never FLS alone. */
public with sharing class DiscountApprovalService {
    public static Boolean writingOutcome { get; private set; }
    /** Returns only user-readable opportunity and cycle fields. */
    @AuraEnabled(cacheable=true)
    public static Map<String,Object> getPanel(Id opportunityId) {
        try {
            Map<String,Object> panel = new Map<String,Object>();
            Opportunity opportunity = readOpportunity(opportunityId);
            panel.put('opportunity',opportunity);
            List<Discount_Approval__c> history = [SELECT Id,Name,Opportunity__c,Route__c,Status__c,Approver__c,Submitted_By__c,Submitted_At__c,
                Discount_Reason__c,Decided_By__c,Decided_By__r.Name,Decided_At__c,Decision_Comment__c
                FROM Discount_Approval__c WHERE Opportunity__c=:opportunityId WITH USER_MODE ORDER BY CreatedDate DESC,Id DESC];
            panel.put('history',history);
            panel.put('canDecide',false);
            for (Discount_Approval__c cycle : history) {
                if (cycle.Status__c == 'Pending') {
                    panel.put('approvalId',cycle.Id);
                    panel.put('canDecide',permitted(cycle,opportunity));
                    break;
                }
            }
            panel.put('canResubmit',opportunity.OwnerId == UserInfo.getUserId() && opportunity.Discount_Approval_Status__c == 'Rejected');
            return panel;
        } catch (Exception error) { throw handled('Unable to load discount approval. Check your record and field access.'); }
    }
    private static Opportunity readOpportunity(Id opportunityId) {
        if (opportunityId == null) throw handled('An Opportunity is required.');
        return [SELECT Id,Name,OwnerId,Amount,CurrencyIsoCode,CloseDate,StageName,Discount_Percent__c,Discount_Reason__c,
            Amount_After_Discount__c,Discount_Approval_Status__c,Discount_Approval_Route__c,Discount_Approver__c,
            Discount_Required_Approver__c,Discount_Decided_By__c,Discount_Decided_At__c,Discount_Decision_Comment__c
            FROM Opportunity WHERE Id=:opportunityId WITH USER_MODE];
    }
    private static Boolean permitted(Discount_Approval__c cycle, Opportunity opportunity) {
        Id caller = UserInfo.getUserId();
        if (cycle.Status__c != 'Pending' || opportunity.Discount_Approval_Status__c != 'Pending' ||
            opportunity.OwnerId == caller || cycle.Submitted_By__c == caller) return false;
        if (cycle.Route__c == 'Manager') return cycle.Approver__c == caller;
        String developerName = cycle.Route__c == 'Deal Desk' ? 'Deal_Desk_Analysts' :
            (cycle.Route__c == 'Executive' ? 'Discount_Executive_Approvers' : null);
        if (developerName == null) return false;
        return [SELECT COUNT() FROM GroupMember WHERE Group.Type='Regular' AND Group.DeveloperName=:developerName
            AND UserOrGroupId=:caller WITH SYSTEM_MODE] > 0;
    }
    /** Atomically records an authorized decision and completes its manager task. */
    @AuraEnabled
    public static void decide(Id approvalId,String outcome,String comment) {
        if (String.isBlank(comment)) throw handled('Enter a comment to approve or reject.');
        if (comment.length() > 4000) throw handled('Decision Comment must be 4000 characters or fewer.');
        if (outcome != 'Approved' && outcome != 'Rejected') throw handled('Choose Approved or Rejected.');
        if (approvalId == null) throw handled('A pending approval is required.');
        Savepoint checkpoint = Database.setSavepoint();
        try {
            Discount_Approval__c visible = [SELECT Id,Opportunity__c FROM Discount_Approval__c WHERE Id=:approvalId WITH USER_MODE];
            readOpportunity(visible.Opportunity__c);
            // Always lock the parent before the child to serialize with Opportunity term edits.
            Opportunity opportunity = [SELECT Id,OwnerId,Discount_Approval_Status__c FROM Opportunity WHERE Id=:visible.Opportunity__c FOR UPDATE];
            Discount_Approval__c cycle = [SELECT Id,Opportunity__c,Route__c,Status__c,Approver__c,Submitted_By__c,Manager_Task_Id__c
                FROM Discount_Approval__c WHERE Id=:approvalId FOR UPDATE];
            if (!permitted(cycle,opportunity)) throw handled('You are not authorized to decide this pending approval.');
            writingOutcome = true;
            new Writer().decide(opportunity,cycle,outcome,comment.trim());
        } catch (AuraHandledException error) { Database.rollback(checkpoint); throw error;
        } catch (Exception error) { Database.rollback(checkpoint); throw handled('Unable to save the decision. Refresh and try again.');
        } finally { writingOutcome = false; }
    }
    /** Owner resubmission keeps the rejected audit record and requires a changed reason. */
    @AuraEnabled
    public static void resubmit(Id opportunityId) {
        Savepoint checkpoint = Database.setSavepoint();
        try {
            readOpportunity(opportunityId);
            Opportunity opportunity = [SELECT Id,Name,OwnerId,Amount,CurrencyIsoCode,CloseDate,Discount_Percent__c,Discount_Reason__c,
                Discount_Approval_Status__c,Discount_Approval_Route__c,Discount_Approver__c
                FROM Opportunity WHERE Id=:opportunityId FOR UPDATE];
            if (opportunity.OwnerId != UserInfo.getUserId() || opportunity.Discount_Approval_Status__c != 'Rejected')
                throw handled('Only the owner can resubmit a rejected discount.');
            Discount_Approval__c rejected = [SELECT Id,Discount_Reason__c FROM Discount_Approval__c
                WHERE Opportunity__c=:opportunityId AND Status__c='Rejected' ORDER BY CreatedDate DESC,Id DESC LIMIT 1];
            if (String.isBlank(opportunity.Discount_Reason__c) || opportunity.Discount_Reason__c == rejected.Discount_Reason__c)
                throw handled('Enter a different Discount Reason before resubmitting.');
            User owner = [SELECT ManagerId FROM User WHERE Id=:opportunity.OwnerId WITH SYSTEM_MODE];
            if (owner.ManagerId == null) throw handled('The Opportunity owner has no manager, so a discount of 10% or more cannot be submitted.');
            opportunity.Discount_Approval_Route__c = DiscountApprovalPolicy.route(opportunity.Discount_Percent__c,DiscountApprovalPolicy.corporateAmount(opportunity));
            opportunity.Discount_Approver__c = opportunity.Discount_Approval_Route__c == 'Manager' ? owner.ManagerId : null;
            writingOutcome = true;
            new Writer().resubmit(opportunity);
        } catch (AuraHandledException error) { Database.rollback(checkpoint); throw error;
        } catch (Exception error) { Database.rollback(checkpoint); throw handled('Unable to resubmit. Refresh and check your record access.');
        } finally { writingOutcome = false; }
    }
    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message); error.setMessage(message); return error;
    }
    /** Elevation is private and follows row/FLS visibility plus route authorization above. */
    private without sharing class Writer {
        void decide(Opportunity opportunity,Discount_Approval__c cycle,String outcome,String comment) {
            Datetime decidedAt = System.now();
            cycle.Status__c=outcome;cycle.Decided_By__c=UserInfo.getUserId();cycle.Decided_At__c=decidedAt;cycle.Decision_Comment__c=comment;
            update as system cycle;
            opportunity.Discount_Approval_Status__c=outcome;opportunity.Discount_Decided_By__c=UserInfo.getUserId();
            opportunity.Discount_Decided_At__c=decidedAt;opportunity.Discount_Decision_Comment__c=comment;
            update as system opportunity;
            if (cycle.Manager_Task_Id__c != null) {
                Task task = new Task(Id=cycle.Manager_Task_Id__c,Status='Completed'); update as system task;
            }
        }
        void resubmit(Opportunity opportunity) {
            opportunity.Discount_Approval_Status__c='Pending';opportunity.Discount_Decided_By__c=null;
            opportunity.Discount_Decided_At__c=null;opportunity.Discount_Decision_Comment__c=null;
            update as system opportunity;
            DiscountApprovalHandler.createCycles(new List<Opportunity>{opportunity});
            DiscountApprovalSharing.ensureShares(new Set<Id>{opportunity.Id});
        }
    }
}
