/** Isolated least-privilege personas and opportunity fixtures. */
@IsTest
public with sharing class DiscountApprovalTestDataFactory {
    public static void createPersonas() {
        Id profileId = [SELECT Id FROM Profile WHERE Name='Standard User' LIMIT 1].Id;
        UserRole managerRole = new UserRole(Name='Discount Test Manager'); insert managerRole;
        UserRole repRole = new UserRole(Name='Discount Test Rep',ParentRoleId=managerRole.Id); insert repRole;
        User manager = user('manager',profileId,managerRole.Id); insert manager;
        List<User> users = new List<User>{user('rep',profileId,repRole.Id),user('analyst',profileId,null),user('executive',profileId,null),user('outsider',profileId,null),user('newowner',profileId,repRole.Id)};
        for (User record : users) record.ManagerId=manager.Id;
        insert users;
        users.add(manager);
        Map<String,Id> permissions = new Map<String,Id>();
        for (PermissionSet permission : [SELECT Id,Name FROM PermissionSet WHERE Name IN ('Discount_Sales_User','Deal_Desk_Analyst')]) permissions.put(permission.Name,permission.Id);
        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
        for (User record : users) assignments.add(new PermissionSetAssignment(AssigneeId=record.Id,
            PermissionSetId=permissions.get(record.LastName=='dd_analyst' ? 'Deal_Desk_Analyst' : 'Discount_Sales_User')));
        insert assignments;
        Map<String,Id> groups = new Map<String,Id>();
        for (Group record : [SELECT Id,DeveloperName FROM Group WHERE DeveloperName IN ('Deal_Desk_Analysts','Discount_Executive_Approvers')]) groups.put(record.DeveloperName,record.Id);
        List<Group> missing = new List<Group>();
        for (String name : new List<String>{'Deal_Desk_Analysts','Discount_Executive_Approvers'})
            if (!groups.containsKey(name)) missing.add(new Group(Name=name,DeveloperName=name,Type='Regular',DoesIncludeBosses=false));
        if (!missing.isEmpty()) insert missing;
        for (Group record : missing) groups.put(record.DeveloperName,record.Id);
        insert new List<GroupMember>{new GroupMember(GroupId=groups.get('Deal_Desk_Analysts'),UserOrGroupId=users[0].Id),
            new GroupMember(GroupId=groups.get('Deal_Desk_Analysts'),UserOrGroupId=users[1].Id),
            new GroupMember(GroupId=groups.get('Discount_Executive_Approvers'),UserOrGroupId=users[2].Id)};
    }
    private static User user(String name,Id profileId,Id roleId) {
        return new User(Alias=name.left(8),LastName='dd_'+name,Email='discount-'+name+'@example.invalid',
            Username='discount-'+name+'-'+UserInfo.getOrganizationId()+'-'+System.now().getTime()+'@example.invalid',
            ProfileId=profileId,UserRoleId=roleId,TimeZoneSidKey='America/Los_Angeles',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');
    }
    public static User persona(String name) { return [SELECT Id,ManagerId FROM User WHERE LastName=:('dd_'+name) LIMIT 1]; }
    public static Opportunity opportunity(Decimal discount,Decimal amount) {
        return new Opportunity(Name='Discount test',OwnerId=persona('rep').Id,StageName='Qualification',CloseDate=Date.today().addDays(30),
            Amount=amount,CurrencyIsoCode='USD',Discount_Percent__c=discount,Discount_Reason__c=discount>=10 ? 'Multi-year agreement' : null);
    }
    public static Discount_Approval__c pending(Id opportunityId) {
        return [SELECT Id,Status__c,Manager_Task_Id__c,Route__c FROM Discount_Approval__c WHERE Opportunity__c=:opportunityId AND Status__c='Pending'];
    }
}
