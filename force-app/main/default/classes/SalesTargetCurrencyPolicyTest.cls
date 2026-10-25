@IsTest
private class SalesTargetCurrencyPolicyTest {
    @TestSetup
    static void users() {
        List<User> users = new List<User>();
        for (String role : new List<String>{'human', 'machine', 'inactive'}) {
            users.add(new User(
                Alias = ('st' + role).left(8), LastName = 'ST fixture ' + role,
                Email = role + '@example.invalid',
                Username = 'st.' + role + '.' + UserInfo.getOrganizationId() + '.' + DateTime.now().getTime() + '@example.invalid',
                ProfileId = UserInfo.getProfileId(), TimeZoneSidKey = 'America/Los_Angeles',
                LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US',
                IsActive = role != 'inactive'
            ));
        }
        insert users;
        PermissionSet machine = [SELECT Id FROM PermissionSet WHERE Name = 'Sales_Target_System_Write_Access'];
        insert new PermissionSetAssignment(AssigneeId = users[1].Id, PermissionSetId = machine.Id);
    }
    private static User persona(String role) {
        String fixtureName = 'ST fixture ' + role;
        return [SELECT Id FROM User WHERE LastName = :fixtureName LIMIT 1];
    }
    private static Sales_Target__c target(Id rep, String quarter) {
        return new Sales_Target__c(Sales_Rep__c = rep, Fiscal_Year__c = 2026,
            Fiscal_Quarter__c = quarter, Target_Amount__c = 100000);
    }
    private static Sales_Target__c reload(Id recordId) {
        return [SELECT Actual_Amount__c, Won_Opportunity_Count__c, Last_Calculated_At__c,
            Target_Key__c, Period_Start__c, Period_End__c, Attainment__c, Attainment_Status__c,
            Target_Amount__c FROM Sales_Target__c WHERE Id = :recordId];
    }
    private static void blocked(Database.SaveResult result, String message) {
        Assert.isFalse(result.isSuccess(), 'Expected a rejected save');
        Boolean found = false;
        for (Database.Error err : result.getErrors()) {
            found = found || err.getMessage().contains(message);
        }
        Assert.isTrue(found, 'Expected error: ' + message + '; got ' + JSON.serialize(result.getErrors()));
    }

    @IsTest static void calendarDatesAndBlankActuals() {
        User human = persona('human');
        System.runAs(human) {
            List<Sales_Target__c> rows = new List<Sales_Target__c>();
            for (String quarter : new List<String>{'Q1','Q2','Q3','Q4'}) {
                rows.add(target(human.Id, quarter));
            }
            insert rows;
            List<Date> starts = new List<Date>{Date.newInstance(2026,1,1),Date.newInstance(2026,4,1),Date.newInstance(2026,7,1),Date.newInstance(2026,10,1)};
            List<Date> ends = new List<Date>{Date.newInstance(2026,3,31),Date.newInstance(2026,6,30),Date.newInstance(2026,9,30),Date.newInstance(2026,12,31)};
            for (Integer i=0; i<rows.size(); i++) {
                Sales_Target__c saved = reload(rows[i].Id);
                Assert.areEqual(starts[i], saved.Period_Start__c);
                Assert.areEqual(ends[i], saved.Period_End__c);
                Assert.areEqual(0, saved.Attainment__c);
                Assert.areEqual('Behind', saved.Attainment_Status__c);
                Assert.isNull(saved.Actual_Amount__c);
                Assert.isNull(saved.Target_Key__c);
                Assert.isNull(saved.Last_Calculated_At__c);
            }
            Sales_Target__c leap = target(human.Id,'Q1'); leap.Fiscal_Year__c = 2028; insert leap;
            Assert.areEqual(Date.newInstance(2028,3,31),reload(leap.Id).Period_End__c);
        }
    }

    @IsTest static void validationAndPartialBulkImport() {
        User human = persona('human');
        System.runAs(human) {
            List<Sales_Target__c> rows = new List<Sales_Target__c>();
            for (Integer i=0; i<200; i++) {
                Sales_Target__c row = target(human.Id,'Q4');
                if (i<2) row.Target_Amount__c = 0;
                rows.add(row);
            }
            Test.startTest();
            List<Database.SaveResult> results = Database.insert(rows,false);
            Integer queries = Limits.getQueries();
            Test.stopTest();
            Integer successes = 0;
            for (Integer i=0; i<results.size(); i++) {
                if (i<2) blocked(results[i], 'Target amount must be greater than 0.');
                else { Assert.isTrue(results[i].isSuccess()); successes++; }
            }
            Assert.areEqual(198, successes);
            Assert.isTrue(queries <= 2, 'Bulk policy must not query per record, including partial-save retries');
            Sales_Target__c invalidYear = target(human.Id,'Q4'); invalidYear.Fiscal_Year__c = 2031;
            blocked(Database.insert(invalidYear,false),'Year must be between 2025 and 2030.');
            invalidYear = target(human.Id,'Q4'); invalidYear.Fiscal_Year__c = 2024;
            blocked(Database.insert(invalidYear,false),'Year must be between 2025 and 2030.');
            Sales_Target__c negative = target(human.Id,'Q4'); negative.Target_Amount__c = -1;
            blocked(Database.insert(negative,false),'Target amount must be greater than 0.');
            Sales_Target__c inactive = target(persona('inactive').Id,'Q4');
            Database.SaveResult inactiveResult = Database.insert(inactive,false);
            Assert.isFalse(inactiveResult.isSuccess(), 'Required active-user filter must reject inactive reps');
        }
    }

    @IsTest static void protectedFieldsAndMachineAttainment() {
        User human = persona('human'); User machine = persona('machine');
        List<String> fields = new List<String>{'Actual_Amount__c','Won_Opportunity_Count__c','Last_Calculated_At__c','Target_Key__c'};
        List<Object> values = new List<Object>{Decimal.valueOf('0'),Decimal.valueOf('0'),DateTime.newInstance(2026,10,1,0,0,0),'synthetic-test-only'};
        Sales_Target__c saved;
        System.runAs(human) {
            Assert.isFalse(FeatureManagement.checkPermission('Sales_Target_System_Write'));
            for (Integer i=0; i<fields.size(); i++) {
                Sales_Target__c row = target(human.Id,'Q4'); row.put(fields[i],values[i]);
                blocked(Database.insert(row,false),'Actuals and target keys can only be changed by the system.');
            }
            saved = target(human.Id,'Q4'); insert saved;
            for (Integer i=0; i<fields.size(); i++) {
                Sales_Target__c change = new Sales_Target__c(Id=saved.Id); change.put(fields[i],values[i]);
                blocked(Database.update(change,false),'Actuals and target keys can only be changed by the system.');
            }
        }
        System.runAs(machine) {
            Assert.isTrue(FeatureManagement.checkPermission('Sales_Target_System_Write'));
            Sales_Target__c machineInsert = target(human.Id,'Q4');
            machineInsert.Actual_Amount__c = 85000;
            insert machineInsert;
            Assert.areEqual('Near Target',reload(machineInsert.Id).Attainment_Status__c);
            Assert.isNull(reload(machineInsert.Id).Target_Key__c);
            update new Sales_Target__c(Id=saved.Id,Actual_Amount__c=85000,Won_Opportunity_Count__c=1,
                Last_Calculated_At__c=DateTime.newInstance(2026,10,1,0,0,0),Target_Key__c='synthetic-test-only');
            Assert.areEqual('Near Target',reload(saved.Id).Attainment_Status__c);
            Assert.areEqual(Decimal.valueOf('0.85'),reload(saved.Id).Attainment__c);
            update new Sales_Target__c(Id=saved.Id,Actual_Amount__c=100000);
            Assert.areEqual('Achieved',reload(saved.Id).Attainment_Status__c);
            Assert.areEqual(Decimal.valueOf('1'),reload(saved.Id).Attainment__c);
            update new Sales_Target__c(Id=saved.Id,Actual_Amount__c=79999);
            Assert.areEqual('Behind',reload(saved.Id).Attainment_Status__c);
            update new Sales_Target__c(Id=saved.Id,Actual_Amount__c=80000);
            Assert.areEqual('Near Target',reload(saved.Id).Attainment_Status__c);
        }
        System.runAs(human) {
            for (String field : fields) {
                Sales_Target__c clear = new Sales_Target__c(Id=saved.Id); clear.put(field,null);
                blocked(Database.update(clear,false),'Actuals and target keys can only be changed by the system.');
            }
            update new Sales_Target__c(Id=saved.Id,Notes__c='Allowed setup change');
        }
        System.runAs(machine) {
            update new Sales_Target__c(Id=saved.Id,Actual_Amount__c=null,Won_Opportunity_Count__c=null,
                Last_Calculated_At__c=null,Target_Key__c=null);
            Assert.isNull(reload(saved.Id).Target_Key__c);
        }
    }

    @IsTest static void destinationCurrencyAndQueryCache() {
        User human = persona('human');
        System.runAs(human) {
            Sales_Target__c row = target(human.Id,'Q4');
            Boolean multi = Sales_Target__c.SObjectType.getDescribe().fields.getMap().containsKey('CurrencyIsoCode');
            String corporate;
            if (multi) {
                corporate = (String)Database.query('SELECT IsoCode FROM CurrencyType WHERE IsCorporate=true LIMIT 1')[0].get('IsoCode');
                row.put('CurrencyIsoCode',corporate);
            }
            Test.startTest(); insert row;
            Integer afterInsert = Limits.getQueries();
            update new Sales_Target__c(Id=row.Id,Notes__c='No currency or amount change');
            Assert.areEqual(afterInsert,Limits.getQueries(),'Corporate currency is cached for the transaction');
            Test.stopTest();
            Assert.areEqual(100000,reload(row.Id).Target_Amount__c);
            if (multi) {
                Id recordId = row.Id;
                SObject stored = Database.query('SELECT CurrencyIsoCode FROM Sales_Target__c WHERE Id = :recordId')[0];
                Assert.areEqual(corporate,stored.get('CurrencyIsoCode'));
            }
        }
    }

    @IsTest static void isolatedCurrencyBranchesAndBulk() {
        // Name represents the currency slot only for in-memory policy tests (no DML).
        List<SObject> rows = new List<SObject>();
        for (Integer i=0; i<200; i++) rows.add(new Account(Name='EUR',AnnualRevenue=100000));
        SalesTargetCurrencyPolicy.applyPolicy(rows,null,'Name','USD');
        for (SObject row : rows) {
            Assert.areEqual('USD',row.get('Name')); Assert.areEqual(100000,row.get('AnnualRevenue'));
            Assert.isFalse(row.hasErrors());
        }
        Account single = new Account(Name='EUR',AnnualRevenue=100000);
        SalesTargetCurrencyPolicy.applyPolicy(new List<SObject>{single},null,null,null);
        Assert.areEqual('EUR',single.Name); Assert.isFalse(single.hasErrors());
        List<SObject> unresolved = new List<SObject>();
        for (Integer i=0;i<200;i++) unresolved.add(new Account(Name='EUR',AnnualRevenue=100000));
        SalesTargetCurrencyPolicy.applyPolicy(unresolved,null,'Name',null);
        for (SObject row : unresolved) { Assert.isTrue(row.hasErrors()); Assert.areEqual('EUR',row.get('Name')); }
        Id id1 = '001000000000001'; Id id2 = '001000000000002'; Id id3 = '001000000000003';
        Map<Id,SObject> oldRows = new Map<Id,SObject>{
            id1 => new Account(Id=id1,Name='USD'), id2 => new Account(Id=id2,Name='EUR'), id3 => new Account(Id=id3,Name='USD')};
        Account changed = new Account(Id=id1,Name='EUR',AnnualRevenue=100000);
        Account relabeled = new Account(Id=id2,Name='USD',AnnualRevenue=100000);
        Account unchanged = new Account(Id=id3,Name='USD',AnnualRevenue=100000);
        SalesTargetCurrencyPolicy.applyPolicy(new List<SObject>{changed,relabeled,unchanged},oldRows,'Name','USD');
        Assert.isTrue(changed.hasErrors()); Assert.isTrue(relabeled.hasErrors()); Assert.isFalse(unchanged.hasErrors());
        Assert.areEqual('Sales targets must use the corporate currency.',changed.getErrors()[0].getMessage());
        Assert.areEqual(100000,changed.AnnualRevenue); Assert.areEqual('EUR',changed.Name);
        Assert.areEqual(100000,relabeled.AnnualRevenue);
    }
}
