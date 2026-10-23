/** Synchronous Flow boundary: verifies caller visibility and returns only safe outcomes. */
public with sharing class DemoLeadFollowupAction {
    public class Request {
        @InvocableVariable(label='名單 ID' required=true)
        public Id leadId;
        @InvocableVariable(label='儲存前意圖')
        public String priorIntent;
        @InvocableVariable(label='新增名單' required=true)
        public Boolean isNew;
    }
    public class Response {
        @InvocableVariable(label='成功')
        public Boolean isSuccess;
        @InvocableVariable(label='安全錯誤訊息')
        public String errorMessage;
        public Response() { isSuccess = true; }
    }
    /** @param requests One request per Flow interview; results preserve size and order.
     * @return Safe results; Flow MUST route every failure to Custom Error in this transaction.
     */
    @InvocableMethod(label='建立餐會首次跟進任務' description='同步驗證並防止重複；失敗必須回復名單儲存' category='餐會示範')
    public static List<Response> followUp(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null) return responses;
        Set<Id> ids = new Set<Id>();
        for (Request request : requests) {
            responses.add(new Response());
            if (request != null && request.leadId != null && request.leadId.getSObjectType() == Lead.SObjectType) ids.add(request.leadId);
        }
        Map<Id, Lead> visible;
        try {
            // Only Id is needed for caller record access. Entry fields are rechecked under the parent lock.
            visible = new Map<Id, Lead>([SELECT Id FROM Lead WHERE Id IN :ids WITH USER_MODE]);
        } catch (Exception error) {
            for (Response response : responses) fail(response, DemoLeadFollowupService.TASK_ERROR);
            return responses;
        }
        Map<Id, List<Integer>> positions = new Map<Id, List<Integer>>();
        Map<Id, Request> candidates = new Map<Id, Request>();
        for (Integer index = 0; index < requests.size(); index++) {
            Request request = requests[index];
            if (request == null || request.isNew == null || !visible.containsKey(request.leadId)) {
                fail(responses[index], DemoLeadFollowupService.TASK_ERROR);
            } else if (request.isNew || !'High'.equals(request.priorIntent)) {
                candidates.put(request.leadId, request);
                if (!positions.containsKey(request.leadId)) positions.put(request.leadId, new List<Integer>());
                positions.get(request.leadId).add(index);
            }
        }
        Map<Id, String> errors = DemoLeadFollowupService.createFollowups(candidates);
        for (Id leadId : errors.keySet()) {
            for (Integer index : positions.get(leadId)) fail(responses[index], errors.get(leadId));
        }
        return responses;
    }
    private static void fail(Response response, String message) {
        response.isSuccess = false;
        response.errorMessage = message;
    }
}
