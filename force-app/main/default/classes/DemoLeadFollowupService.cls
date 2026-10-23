/** Narrow system-mode implementation of the approved OD-1 duplicate check.
 * No remote/Invocable entry point. Caller verifies Lead access; lock and recheck before any write.
 * Elevation is necessary to see other owners' completed/archived Tasks, without exposing them.
 */
public without sharing class DemoLeadFollowupService {
    public static final String TASK_ERROR = '無法建立跟進任務，請確認名單擁有者可承接任務及必要設定後重新儲存';
    @TestVisible private static final String OWNER_ERROR = '請先將名單擁有者改為可承接任務的啟用使用者，再重新儲存';
    @TestVisible private static final String LOCK_ERROR = '資料正在更新，本次未儲存，請重新整理後再送出';
    @TestVisible private static final String SUBJECT = '餐會名單首次跟進';
    @TestVisible private static Datetime clockOverride;
    // Private test injection exercises actual DML rejection, never bypasses production validation.
    @TestVisible private static Set<Id> rejectTaskFor = new Set<Id>();
    @TestVisible private static List<TaskStatus> statusOverride;
    @TestVisible private static List<TaskPriority> priorityOverride;

    /** @param candidates Caller-visible transition candidates, never arbitrary Task fields.
     * @return Errors keyed by Lead; no Task IDs or internal exception content.
     */
    public static Map<Id, String> createFollowups(Map<Id, DemoLeadFollowupAction.Request> candidates) {
        Map<Id, String> errors = new Map<Id, String>();
        if (candidates == null || candidates.isEmpty()) return errors;
        Map<Id, Lead> leads;
        try {
            Set<Id> ids = candidates.keySet();
            leads = new Map<Id, Lead>([SELECT Id, OwnerId, IsConverted, Demo_Event_Code__c,
                Demo_Followup_Intent__c, Demo_Followup_Date__c FROM Lead WHERE Id IN :ids WITH SYSTEM_MODE FOR UPDATE]);
        } catch (QueryException error) {
            for (Id leadId : candidates.keySet()) errors.put(leadId, LOCK_ERROR);
            return errors;
        }
        Map<Id, Lead> eligible = new Map<Id, Lead>();
        for (Id leadId : candidates.keySet()) {
            Lead lead = leads.get(leadId);
            DemoLeadFollowupAction.Request request = candidates.get(leadId);
            if (lead == null) errors.put(leadId, TASK_ERROR);
            else if (qualifies(lead, request)) eligible.put(leadId, lead);
        }
        if (eligible.isEmpty()) return errors;
        try {
            validateOwners(eligible, errors);
            Set<Id> existing = findExisting(eligible.keySet());
            List<Lead> missing = new List<Lead>();
            for (Lead lead : eligible.values()) {
                if (!errors.containsKey(lead.Id) && !existing.contains(lead.Id)) missing.add(lead);
            }
            if (!missing.isEmpty()) insertTasks(missing, errors);
        } catch (Exception error) {
            // Flow Custom Error rolls back the parent and any child writes; do not swallow the failure.
            for (Id leadId : eligible.keySet()) if (!errors.containsKey(leadId)) errors.put(leadId, TASK_ERROR);
        }
        return errors;
    }
    @TestVisible private static Boolean qualifies(Lead lead, DemoLeadFollowupAction.Request request) {
        return request != null && request.isNew != null && !lead.IsConverted &&
            'CDO-BANQUET-DEMO'.equals(lead.Demo_Event_Code__c) && 'High'.equals(lead.Demo_Followup_Intent__c) &&
            (request.isNew || !'High'.equals(request.priorIntent));
    }
    private static void validateOwners(Map<Id, Lead> leads, Map<Id, String> errors) {
        Set<Id> userIds = new Set<Id>();
        for (Lead lead : leads.values()) {
            if (lead.OwnerId != null && lead.OwnerId.getSObjectType() == User.SObjectType) userIds.add(lead.OwnerId);
        }
        Map<Id, User> owners = new Map<Id, User>([SELECT Id, IsActive FROM User WHERE Id IN :userIds WITH SYSTEM_MODE]);
        for (Lead lead : leads.values()) {
            User owner = owners.get(lead.OwnerId);
            if (owner == null || !owner.IsActive) errors.put(lead.Id, OWNER_ERROR);
        }
    }
    private static Set<Id> findExisting(Set<Id> leadIds) {
        // ALL ROWS includes archived and completed Tasks; deleted Tasks explicitly do not count.
        List<Task> tasks = [SELECT WhoId, Subject, IsDeleted, IsArchived FROM Task WHERE WhoId IN :leadIds AND Subject = :SUBJECT
            AND IsDeleted = false WITH SYSTEM_MODE ALL ROWS];
        return existingLeadIds(tasks);
    }
    @TestVisible private static Set<Id> existingLeadIds(List<Task> tasks) {
        Set<Id> existing = new Set<Id>();
        for (Task task : tasks) if (!task.IsDeleted && SUBJECT.equals(task.Subject)) existing.add(task.WhoId);
        return existing;
    }
    private static void insertTasks(List<Lead> leads, Map<Id, String> errors) {
        List<TaskStatus> statuses = statusOverride == null ?
            [SELECT ApiName, IsDefault, IsClosed FROM TaskStatus WHERE IsDefault = true WITH SYSTEM_MODE] : statusOverride;
        List<TaskPriority> priorities = priorityOverride == null ?
            [SELECT ApiName, IsDefault FROM TaskPriority WHERE IsDefault = true WITH SYSTEM_MODE] : priorityOverride;
        List<String> defaults = resolveDefaults(statuses, priorities);
        Date tomorrow = taipeiTomorrow(clockOverride == null ? System.now() : clockOverride);
        List<Task> tasks = new List<Task>();
        for (Lead lead : leads) {
            Task task = new Task(WhoId=lead.Id, OwnerId=lead.OwnerId, Subject=SUBJECT,
                ActivityDate=lead.Demo_Followup_Date__c == null ? tomorrow : lead.Demo_Followup_Date__c,
                Status=defaults[0], Priority=defaults[1], IsReminderSet=false);
            Database.DMLOptions options = new Database.DMLOptions();
            options.EmailHeader.triggerUserEmail = false;
            options.EmailHeader.triggerOtherEmail = false;
            options.EmailHeader.triggerAutoResponseEmail = false;
            task.setOptions(options);
            if (rejectTaskFor.contains(lead.Id)) task.OwnerId = lead.Id; // invalid owner -> real SaveResult failure
            tasks.add(task);
        }
        List<Database.SaveResult> results = Database.insert(tasks, false, AccessLevel.SYSTEM_MODE);
        for (Integer index = 0; index < results.size(); index++) {
            if (!results[index].isSuccess()) {
                String message = TASK_ERROR;
                for (Database.Error error : results[index].getErrors()) {
                    if (error.getStatusCode() == StatusCode.UNABLE_TO_LOCK_ROW) message = LOCK_ERROR;
                }
                errors.put(leads[index].Id, message);
            }
        }
    }
    @TestVisible private static List<String> resolveDefaults(List<TaskStatus> statuses, List<TaskPriority> priorities) {
        if (statuses.size() != 1 || priorities.size() != 1 || !statuses[0].IsDefault || statuses[0].IsClosed ||
            !priorities[0].IsDefault || String.isBlank(statuses[0].ApiName) || String.isBlank(priorities[0].ApiName)) {
            throw new ConfigurationException(TASK_ERROR);
        }
        return new List<String>{statuses[0].ApiName, priorities[0].ApiName};
    }
    @TestVisible private static Date taipeiTomorrow(Datetime instant) {
        return Date.valueOf(instant.format('yyyy-MM-dd', 'Asia/Taipei')).addDays(1);
    }
    private class ConfigurationException extends Exception {}
}
