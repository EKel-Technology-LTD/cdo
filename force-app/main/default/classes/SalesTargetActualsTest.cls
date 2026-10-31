/** Isolated synthetic acceptance tests; no live migration or schedule activation. */
@IsTest(testFor='ApexClass:SalesTargetActualsBatch,ApexClass:SalesTargetActualsSchedulable')
private with sharing class SalesTargetActualsTest {
  private static final Date TODAY = Date.newInstance(2026, 10, 28);
  @TestSetup
  static void setup() {
    createFixtures();
  }
  private static void createFixtures() {
    List<User> users = new List<User>();
    for (Integer i = 0; i < 26; i++) {
      users.add(
        new User(
          Alias = 'st60' + i,
          LastName = 'ST60 ' + i,
          Email = 'st60-' + i + '@example.invalid',
          Username = 'st60-' +
            i +
            '-' +
            UserInfo.getOrganizationId() +
            '-' +
            Datetime.now().getTime() +
            '@example.invalid',
          ProfileId = UserInfo.getProfileId(),
          TimeZoneSidKey = 'America/Los_Angeles',
          LocaleSidKey = 'en_US',
          EmailEncodingKey = 'UTF-8',
          LanguageLocaleKey = 'en_US'
        )
      );
    }
    insert users;
    PermissionSet permission = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = 'Sales_Target_System_Write_Access'
    ];
    insert new PermissionSetAssignment(
      AssigneeId = users[25].Id,
      PermissionSetId = permission.Id
    );
  }
  /** Synthetic transaction-local mutex only; all test records roll back. */
  private static void createMutex(Id machine) {
    Database.insert(
      new Sales_Target_Mutex__c(
        Lock_Key__c = 'DAILY_ACTUALS',
        Machine_User__c = machine
      ),
      AccessLevel.SYSTEM_MODE
    );
  }
  private static User person(Integer i) {
    String lastName = 'ST60 ' + i;
    return [SELECT Id, IsActive FROM User WHERE LastName = :lastName LIMIT 1];
  }
  private static Sales_Target__c target(
    Id rep,
    Integer year,
    String quarter,
    String line
  ) {
    return new Sales_Target__c(
      Sales_Rep__c = rep,
      Fiscal_Year__c = year,
      Fiscal_Quarter__c = quarter,
      Product_Line__c = line,
      Target_Amount__c = 100000
    );
  }
  private static Opportunity opportunity(
    Id rep,
    Date closeDate,
    Decimal amount,
    String stage
  ) {
    return new Opportunity(
      Name = 'ST60 synthetic',
      OwnerId = rep,
      CloseDate = closeDate,
      Amount = amount,
      StageName = stage,
      Discount_Percent__c = 0
    );
  }
  private static Sales_Target__c stored(Id recordId) {
    return [
      SELECT
        Id,
        Actual_Amount__c,
        Won_Opportunity_Count__c,
        Last_Calculated_At__c,
        Attainment__c,
        Attainment_Status__c,
        Target_Key__c
      FROM Sales_Target__c
      WHERE Id = :recordId
    ];
  }
  private static SalesTargetActualsBatch batch(Date today) {
    SalesTargetActualsBatch.testToday = today;
    return new SalesTargetActualsBatch();
  }
  private static List<SObject> scope(List<Sales_Target__c> targets) {
    List<SObject> result = new List<SObject>();
    for (Sales_Target__c row : targets)
      result.add(new Sales_Target__c(Id = row.Id));
    return result;
  }
  private static void actual(Id targetId, Decimal amount, Integer count) {
    Sales_Target__c result = stored(targetId);
    Assert.areEqual(amount, result.Actual_Amount__c, 'Replaced actual amount');
    Assert.areEqual(
      Decimal.valueOf(String.valueOf(count)),
      result.Won_Opportunity_Count__c,
      'Distinct opportunity count'
    );
    Assert.isNotNull(
      result.Last_Calculated_At__c,
      'Successful scope has freshness'
    );
  }
  @IsTest
  static void allLinesOwnerQuarterAndAttainment() {
    User rep = person(0), other = person(1), machine = person(25);
    List<Sales_Target__c> targets = new List<Sales_Target__c>{
      target(rep.Id, 2026, 'Q4', null),
      target(rep.Id, 2026, 'Q3', null),
      target(rep.Id, 2027, 'Q2', null)
    };
    insert targets;
    insert new List<Opportunity>{
      opportunity(rep.Id, Date.newInstance(2026, 10, 1), 30000, 'Closed Won'),
      opportunity(rep.Id, TODAY.addDays(-1), 25000, 'Closed Won'),
      opportunity(rep.Id, Date.newInstance(2026, 10, 5), 40000, 'Closed Won'),
      opportunity(rep.Id, Date.newInstance(2026, 10, 5), 50000, 'Negotiation'),
      opportunity(rep.Id, Date.newInstance(2026, 9, 30), 7000, 'Closed Won'),
      opportunity(other.Id, Date.newInstance(2026, 10, 5), 9000, 'Closed Won'),
      opportunity(rep.Id, TODAY, 11000, 'Closed Won')
    };
    System.runAs(machine) {
      Test.startTest();
      Id job = Database.executeBatch(batch(TODAY), 25);
      Test.stopTest();
      AsyncApexJob receipt = [
        SELECT Status, NumberOfErrors
        FROM AsyncApexJob
        WHERE Id = :job
      ];
      Assert.areEqual(
        'Completed',
        receipt.Status,
        'Actual async batch completes'
      );
      Assert.areEqual(0, receipt.NumberOfErrors, 'No failed scopes');
    }
    actual(targets[0].Id, 95000, 3);
    actual(targets[1].Id, 7000, 1);
    Assert.areEqual(
      Decimal.valueOf('95'),
      stored(targets[0].Id).Attainment__c,
      '95 percent'
    );
    Assert.areEqual(
      'Near Target',
      stored(targets[0].Id).Attainment_Status__c,
      'Preserve approved CDO-55 label'
    );
    Assert.isNull(
      stored(targets[2].Id).Actual_Amount__c,
      'Future remains blank'
    );
    Assert.isNull(
      stored(targets[2].Id).Last_Calculated_At__c,
      'Future has no timestamp'
    );
  }
  @IsTest
  static void lineAmountsCountDistinctAndDoNotUseOpportunityAmount() {
    User rep = person(0), machine = person(25);
    List<Sales_Target__c> targets = new List<Sales_Target__c>{
      target(rep.Id, 2026, 'Q4', 'Water_Purifier'),
      target(rep.Id, 2026, 'Q4', 'Air_Purifier')
    };
    targets[0].Target_Amount__c = 20000;
    insert targets;
    List<Product2> products = new List<Product2>{
      new Product2(
        Name = 'ST60 WP-RO600',
        Model_Number__c = 'ST60-WP-RO600',
        Product_Line__c = 'Water_Purifier',
        IsActive = true
      ),
      new Product2(
        Name = 'ST60 AP-500',
        Model_Number__c = 'ST60-AP-500',
        Product_Line__c = 'Air_Purifier',
        Energy_Efficiency_Grade__c = 'Grade_1',
        IsActive = true
      )
    };
    insert products;
    Id book = Test.getStandardPricebookId();
    List<PricebookEntry> prices = new List<PricebookEntry>{
      new PricebookEntry(
        Pricebook2Id = book,
        Product2Id = products[0].Id,
        UnitPrice = 640,
        IsActive = true
      ),
      new PricebookEntry(
        Pricebook2Id = book,
        Product2Id = products[1].Id,
        UnitPrice = 360,
        IsActive = true
      )
    };
    insert prices;
    Opportunity win = opportunity(
      rep.Id,
      TODAY.addDays(-1),
      9999,
      'Closed Won'
    );
    win.Pricebook2Id = book;
    insert win;
    insert new List<OpportunityLineItem>{
      new OpportunityLineItem(
        OpportunityId = win.Id,
        PricebookEntryId = prices[0].Id,
        Quantity = 2,
        UnitPrice = 640
      ),
      new OpportunityLineItem(
        OpportunityId = win.Id,
        PricebookEntryId = prices[1].Id,
        Quantity = 1,
        UnitPrice = 360
      )
    };
    System.runAs(machine) {
      Test.startTest();
      SalesTargetActualsBatch work = batch(TODAY);
      work.execute(null, scope(targets));
      actual(targets[0].Id, 1280, 1);
      actual(targets[1].Id, 360, 1);
      insert new OpportunityLineItem(
        OpportunityId = win.Id,
        PricebookEntryId = prices[0].Id,
        Quantity = 1,
        UnitPrice = 640
      );
      work.execute(null, scope(targets));
      Test.stopTest();
    }
    actual(targets[0].Id, 1920, 1);
  }
  @IsTest
  static void reopenReallocateAndEmptyReset() {
    User rep = person(0), machine = person(25);
    List<Sales_Target__c> targets = new List<Sales_Target__c>{
      target(rep.Id, 2026, 'Q4', null),
      target(rep.Id, 2026, 'Q3', null)
    };
    insert targets;
    Opportunity win = opportunity(
      rep.Id,
      Date.newInstance(2026, 10, 2),
      30000,
      'Closed Won'
    );
    insert win;
    System.runAs(machine) {
      Test.startTest();
      SalesTargetActualsBatch work = batch(TODAY);
      work.execute(null, scope(targets));
      actual(targets[0].Id, 30000, 1);
      update new Opportunity(Id = win.Id, StageName = 'Negotiation');
      work.execute(null, scope(targets));
      actual(targets[0].Id, 0, 0);
      update new Opportunity(
        Id = win.Id,
        StageName = 'Closed Won',
        CloseDate = Date.newInstance(2026, 9, 30)
      );
      work.execute(null, scope(targets));
      Test.stopTest();
    }
    actual(targets[0].Id, 0, 0);
    actual(targets[1].Id, 30000, 1);
  }
  @IsTest
  static void nullAmountCountsAsZero() {
    User rep = person(0), machine = person(25);
    Sales_Target__c row = target(rep.Id, 2026, 'Q4', null);
    insert row;
    insert opportunity(rep.Id, TODAY.addDays(-1), null, 'Closed Won');
    System.runAs(machine) {
      Test.startTest();
      batch(TODAY).execute(null, new List<SObject>{ row });
      Test.stopTest();
    }
    actual(row.Id, 0, 1);
  }
  @IsTest
  static void yearRolloverCutoffAndFreshDimensions() {
    User rep = person(0), machine = person(25);
    List<Sales_Target__c> targets = new List<Sales_Target__c>{
      target(rep.Id, 2026, 'Q4', null),
      target(rep.Id, 2027, 'Q1', null),
      target(rep.Id, 2026, 'Q3', null)
    };
    insert targets;
    insert new List<Opportunity>{
      opportunity(rep.Id, Date.newInstance(2026, 12, 31), 12, 'Closed Won'),
      opportunity(rep.Id, Date.newInstance(2027, 1, 1), 15, 'Closed Won')
    };
    System.runAs(machine) {
      Test.startTest();
      SalesTargetActualsBatch work = batch(Date.newInstance(2027, 1, 1));
      Database.QueryLocatorIterator selected = work.start(null).iterator();
      Integer count = 0;
      while (selected.hasNext()) {
        selected.next();
        count++;
      }
      Assert.areEqual(2, count, 'Year rollover selects Q4 and Q1, excludes Q3');
      work.execute(null, scope(targets));
      actual(targets[0].Id, 12, 1);
      actual(targets[1].Id, 0, 0);
      update new Sales_Target__c(
        Id = targets[0].Id,
        Fiscal_Year__c = 2027,
        Fiscal_Quarter__c = 'Q2'
      );
      work.execute(null, new List<SObject>{ targets[0] });
      Test.stopTest();
    }
    actual(targets[0].Id, 12, 1); // Out-of-scope edits retain previously stored results, not newly calculated.
    Assert.isNull(
      stored(targets[2].Id).Last_Calculated_At__c,
      'Older target untouched'
    );
  }
  @IsTest
  static void unauthorizedPathsFailBeforeWrites() {
    System.runAs(person(0)) {
      Test.startTest();
      try {
        new SalesTargetActualsBatch();
        Assert.fail('Human constructor must fail');
      } catch (SalesTargetActualsBatch.ActualsException ex) {
        Assert.isTrue(ex.getMessage().contains('permission'));
      }
      try {
        SalesTargetActualsSchedulable.launch();
        Assert.fail('Human recovery must fail');
      } catch (SalesTargetActualsBatch.ActualsException ex) {
        Assert.isTrue(ex.getMessage().contains('permission'));
      }
      try {
        new SalesTargetActualsSchedulable();
        Assert.fail('Human scheduler must fail');
      } catch (SalesTargetActualsBatch.ActualsException ex) {
        Assert.isTrue(ex.getMessage().contains('permission'));
      }
      Test.stopTest();
    }
  }
  @IsTest
  static void permissionIsRecheckedEveryTransaction() {
    SalesTargetActualsBatch work;
    System.runAs(person(25)) {
      work = batch(TODAY);
    }
    System.runAs(person(0)) {
      Test.startTest();
      try {
        work.start(null);
        Assert.fail('Start must guard');
      } catch (SalesTargetActualsBatch.ActualsException ex) {
        Assert.isTrue(ex.getMessage().contains('permission'));
      }
      try {
        work.execute(null, new List<SObject>());
        Assert.fail('Execute must guard');
      } catch (SalesTargetActualsBatch.ActualsException ex) {
        Assert.isTrue(ex.getMessage().contains('permission'));
      }
      try {
        work.finish(null);
        Assert.fail('Finish must guard');
      } catch (SalesTargetActualsBatch.ActualsException ex) {
        Assert.isTrue(ex.getMessage().contains('permission'));
      }
      Test.stopTest();
    }
  }
  @IsTest
  static void inactiveRepStillCalculatesAndReassignmentFails() {
    User rep = person(0), machine = person(25);
    Sales_Target__c row = target(rep.Id, 2026, 'Q4', null);
    insert row;
    insert opportunity(rep.Id, TODAY.addDays(-1), 420, 'Closed Won');
    System.runAs(machine) {
      update new User(Id = rep.Id, IsActive = false);
    }
    System.runAs(machine) {
      Test.startTest();
      batch(TODAY).execute(null, new List<SObject>{ row });
      Database.SaveResult rejected = Database.insert(
        target(rep.Id, 2026, 'Q3', null),
        false
      );
      Assert.isFalse(
        rejected.isSuccess(),
        'New inactive assignment blocked, including machine'
      );
      Test.stopTest();
    }
    actual(row.Id, 420, 1);
  }
  @IsTest
  static void currencyFailsClosedWithoutConversion() {
    Test.startTest();
    SalesTargetActualsBatch.checkCurrency(null, null);
    SalesTargetActualsBatch.checkCurrency('USD', 'USD');
    try {
      SalesTargetActualsBatch.checkCurrency('EUR', 'USD');
      Assert.fail('Foreign currency must fail');
    } catch (SalesTargetActualsBatch.ActualsException ex) {
      Assert.isTrue(ex.getMessage().contains('Foreign'));
    }
    try {
      SalesTargetActualsBatch.checkCurrency(null, 'USD');
      Assert.fail('Unknown currency must fail');
    } catch (SalesTargetActualsBatch.ActualsException ex) {
      Assert.isTrue(ex.getMessage().contains('Foreign'));
    }
    Test.stopTest();
  }
  @IsTest
  static void failedScopeKeepsOldValuesAndCanRetry() {
    User rep = person(0), machine = person(25);
    List<Sales_Target__c> targets = new List<Sales_Target__c>{
      target(rep.Id, 2026, 'Q4', null),
      target(rep.Id, 2026, 'Q3', null)
    };
    insert targets;
    // Existing Number(6,0) cannot hold one million; a real DML failure tests all-or-none.
    // Use Currency(16,2) overflow instead to avoid fabricating one million opportunities.
    List<Opportunity> wins = new List<Opportunity>{
      opportunity(rep.Id, TODAY.addDays(-1), 90000000000000L, 'Closed Won'),
      opportunity(rep.Id, TODAY.addDays(-1), 90000000000000L, 'Closed Won')
    };
    insert wins;
    System.runAs(machine) {
      Test.startTest();
      SalesTargetActualsBatch work = batch(TODAY);
      try {
        work.execute(null, scope(targets));
        Assert.fail('Overflow must fail the entire scope');
      } catch (DmlException ex) {
        Assert.isTrue(ex.getNumDml() > 0, 'DML failure visible');
      }
      Assert.isNull(
        stored(targets[0].Id).Last_Calculated_At__c,
        'Failed scope stays stale'
      );
      Assert.isNull(
        stored(targets[1].Id).Last_Calculated_At__c,
        'Other scope row rolls back too'
      );
      for (Opportunity win : wins)
        win.Amount = 10;
      update wins;
      work.execute(null, scope(targets));
      Test.stopTest();
    }
    actual(targets[0].Id, 20, 2);
    actual(targets[1].Id, 0, 0);
  }
  @IsTest
  static void launchSerializesRecoveryAndSkipsOverlap() {
    System.runAs(person(25)) {
      createMutex(UserInfo.getUserId());
      SalesTargetActualsBatch.testToday = TODAY;
      Test.startTest();
      Id first = SalesTargetActualsSchedulable.launch();
      Id second = SalesTargetActualsSchedulable.launch();
      Assert.areEqual(first, second, 'Queued/running job is reused');
      new SalesTargetActualsSchedulable().execute(null);
      Test.stopTest();
      Assert.areEqual(
        1,
        [
          SELECT COUNT()
          FROM AsyncApexJob
          WHERE
            ApexClass.Name = 'SalesTargetActualsBatch'
            AND JobType = 'BatchApex'
        ],
        'Only one actuals job'
      );
    }
  }
  @IsTest
  static void dailyCronIsOwnedAndLosAngeles() {
    User machine = person(25);
    System.runAs(machine) {
      createMutex(machine.Id);
      Test.startTest();
      Id job = SalesTargetActualsSchedulable.createOwnedSchedule();
      try {
        SalesTargetActualsSchedulable.createOwnedSchedule();
        Assert.fail('Duplicate schedule creation must fail closed');
      } catch (SalesTargetActualsBatch.ActualsException ex) {
        Assert.isTrue(
          ex.getMessage().contains('already exists'),
          'Readback required'
        );
      }
      CronTrigger cron = [
        SELECT OwnerId, CronExpression, TimeZoneSidKey, NextFireTime
        FROM CronTrigger
        WHERE Id = :job
      ];
      Assert.areEqual(machine.Id, cron.OwnerId, 'Synthetic machine owns cron');
      Assert.areEqual('0 0 2 * * ?', cron.CronExpression, 'Daily 02:00');
      Assert.areEqual(
        'America/Los_Angeles',
        cron.TimeZoneSidKey,
        'DST-aware timezone'
      );
      Assert.isNotNull(cron.NextFireTime, 'Next fire recorded');
      Assert.areEqual(
        job,
        SalesTargetActualsSchedulable.stopOwnedSchedule(),
        'Stop only the verified owned scheduler'
      );
      Assert.isNull(
        SalesTargetActualsSchedulable.stopOwnedSchedule(),
        'Rollback is idempotent'
      );
      Test.stopTest();
    }
  }
  @IsTest
  static void volume250Targets6000ClosedOpportunities() {
    List<User> reps = [
      SELECT Id
      FROM User
      WHERE LastName LIKE 'ST60 %' AND LastName != 'ST60 25'
      ORDER BY Id
    ];
    User machine = person(25);
    List<String> lines = new List<String>{
      null,
      'Air_Purifier',
      'Dehumidifier',
      'Vacuum_Cleaner',
      'Water_Purifier',
      'Accessory',
      'Service_Plan'
    };
    List<Sales_Target__c> targets = new List<Sales_Target__c>();
    for (User rep : reps) {
      for (Integer i = 0; i < 10; i++)
        targets.add(
          target(rep.Id, 2026, i < 7 ? 'Q4' : 'Q3', lines[Math.mod(i, 7)])
        );
    }
    insert targets;
    List<Opportunity> wins = new List<Opportunity>();
    for (Integer i = 0; i < 6000; i++)
      wins.add(
        opportunity(
          reps[Math.mod(i, 25)].Id,
          TODAY.addDays(-1),
          10,
          'Closed Won'
        )
      );
    insert wins;
    wins = null;
    System.runAs(machine) {
      SalesTargetActualsBatch work = batch(TODAY);
      Test.startTest();
      Database.QueryLocatorIterator selected = work.start(null).iterator();
      Integer selectedCount = 0;
      while (selected.hasNext()) {
        selected.next();
        selectedCount++;
      }
      Assert.areEqual(
        250,
        selectedCount,
        'Complete two-quarter target selection'
      );
      // Apex tests cannot execute multiple asynchronous batch scopes. Exercise all
      // ten production-size scopes directly; separate QA must prove the full job.
      for (Integer offset = 0; offset < 250; offset += 25) {
        List<SObject> chunk = new List<SObject>();
        for (Integer i = offset; i < offset + 25; i++)
          chunk.add(new Sales_Target__c(Id = targets[i].Id));
        work.execute(null, chunk);
      }
      Integer rows = Limits.getQueryRows(),
        queries = Limits.getQueries(),
        dml = Limits.getDmlStatements();
      Integer cpu = Limits.getCpuTime(), heap = Limits.getHeapSize();
      Assert.isTrue(
        rows < 50000,
        'No source truncation to fit queried-row limit'
      );
      Assert.isTrue(queries < 100, 'Includes target trigger and Flow lookups');
      Assert.areEqual(10, dml, 'One result write per production-size scope');
      Assert.isTrue(
        cpu < 10000,
        'Even the combined synchronous scopes fit CPU limit'
      );
      Assert.isTrue(heap < 6000000, 'Do not depend on Winter27 heap increases');
      System.debug(
        LoggingLevel.ERROR,
        'ST60_LIMITS:' +
        JSON.serialize(
          new Map<String, Object>{
            'targets' => 250,
            'opportunities' => 6000,
            'lineItems' => 0,
            'scopes' => 10,
            'queryRows' => rows,
            'queries' => queries,
            'dml' => dml,
            'cpuMs' => cpu,
            'heapBytes' => heap
          }
        )
      );
      Test.stopTest();
    }
    List<Sales_Target__c> results = [
      SELECT
        Actual_Amount__c,
        Won_Opportunity_Count__c,
        Last_Calculated_At__c,
        Fiscal_Quarter__c,
        Product_Line__c
      FROM Sales_Target__c
    ];
    Assert.areEqual(250, results.size(), 'Every target survives');
    for (Sales_Target__c row : results) {
      Boolean allCurrent =
        row.Fiscal_Quarter__c == 'Q4' &&
        row.Product_Line__c == null;
      Assert.areEqual(
        Decimal.valueOf(allCurrent ? '2400' : '0'),
        row.Actual_Amount__c,
        'Exact volume actual'
      );
      Assert.areEqual(
        Decimal.valueOf(allCurrent ? '240' : '0'),
        row.Won_Opportunity_Count__c,
        'Exact volume count'
      );
      Assert.isNotNull(row.Last_Calculated_At__c, 'Each scope fresh');
    }
  }
  @IsTest
  static void emptyScopeDoesNotWrite() {
    System.runAs(person(25)) {
      Test.startTest();
      SalesTargetActualsBatch work = batch(TODAY);
      work.execute(null, new List<SObject>());
      Assert.areEqual(
        0,
        Limits.getDmlStatements(),
        'Empty scope performs no write'
      );
      Test.stopTest();
    }
  }
  @IsTest
  static void oversizedScopeFailsBeforeQuery() {
    List<SObject> rows = new List<SObject>();
    for (Integer i = 0; i < 26; i++)
      rows.add(new Sales_Target__c());
    System.runAs(person(25)) {
      Test.startTest();
      try {
        batch(TODAY).execute(null, rows);
        Assert.fail('Scope over 25 must fail');
      } catch (SalesTargetActualsBatch.ActualsException ex) {
        Assert.isTrue(ex.getMessage().contains('25'));
      }
      Assert.areEqual(
        0,
        Limits.getQueries(),
        'Invalid scope rejected before source access'
      );
      Assert.areEqual(0, Limits.getDmlStatements(), 'No invalid-scope writes');
      Test.stopTest();
    }
  }
  @IsTest
  static void wrongTimezoneRejectsLaunch() {
    User machine = person(25);
    update new User(Id = machine.Id, TimeZoneSidKey = 'GMT');
    System.runAs(machine) {
      createMutex(machine.Id);
      Test.startTest();
      try {
        SalesTargetActualsSchedulable.launch();
        Assert.fail('Wrong timezone must fail');
      } catch (SalesTargetActualsBatch.ActualsException ex) {
        Assert.isTrue(ex.getMessage().contains('America/Los_Angeles'));
      }
      Assert.areEqual(
        0,
        [
          SELECT COUNT()
          FROM AsyncApexJob
          WHERE ApexClass.Name = 'SalesTargetActualsBatch'
        ],
        'No batch dispatched'
      );
      Test.stopTest();
    }
  }
  /** A private singleton owned by a different principal must still serialize. */
  private static User provisionSeparatelyOwnedMutex() {
    User machine = person(25);
    Profile restricted = [
      SELECT Id
      FROM Profile
      WHERE
        UserType = 'Standard'
        AND PermissionsModifyAllData = FALSE
        AND PermissionsViewAllData = FALSE
        AND UserLicense.Name = 'Salesforce'
      LIMIT 1
    ];
    update new User(Id = machine.Id, ProfileId = restricted.Id);
    User provisioner = person(24);
    PermissionSet permission = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = 'Sales_Target_System_Write_Access'
    ];
    insert new PermissionSetAssignment(
      AssigneeId = provisioner.Id,
      PermissionSetId = permission.Id
    );
    System.runAs(provisioner) {
      createMutex(machine.Id);
      Assert.areEqual(
        provisioner.Id,
        [SELECT OwnerId FROM Sales_Target_Mutex__c WITH SYSTEM_MODE].OwnerId,
        'Separate synthetic provisioner owns the private singleton'
      );
    }
    return machine;
  }
  @IsTest
  static void separatelyOwnedMutexAllowsLaunchAndRecovery() {
    User machine = provisionSeparatelyOwnedMutex();
    System.runAs(machine) {
      Assert.areEqual(
        0,
        [SELECT COUNT() FROM Sales_Target_Mutex__c WITH SYSTEM_MODE],
        'With-sharing caller cannot see the separately owned private row'
      );
      Test.startTest();
      Id first = SalesTargetActualsSchedulable.launch();
      Assert.isNotNull(first, 'Bound machine acquires the shared singleton');
      Assert.areEqual(
        first,
        SalesTargetActualsSchedulable.launch(),
        'Recovery reuses the queued job'
      );
      new SalesTargetActualsSchedulable().execute(null);
      Test.stopTest();
    }
  }
  @IsTest
  static void separatelyOwnedMutexAllowsScheduleAndStop() {
    User machine = provisionSeparatelyOwnedMutex();
    System.runAs(machine) {
      Assert.areEqual(
        0,
        [SELECT COUNT() FROM Sales_Target_Mutex__c WITH SYSTEM_MODE],
        'Machine has no record sharing access to the singleton'
      );
      Test.startTest();
      Id job = SalesTargetActualsSchedulable.createOwnedSchedule();
      Assert.isNotNull(job, 'Bound machine can schedule using the shared lock');
      Assert.areEqual(
        job,
        SalesTargetActualsSchedulable.stopOwnedSchedule(),
        'Owned schedule stop uses the same shared singleton'
      );
      Assert.isNull(
        SalesTargetActualsSchedulable.stopOwnedSchedule(),
        'Repeated stop remains idempotent'
      );
      Test.stopTest();
    }
  }
  @IsTest
  static void missingMutexBlocksEveryEntryWithoutProvisioning() {
    System.runAs(person(25)) {
      Test.startTest();
      assertMutexEntriesFail();
      Assert.areEqual(
        0,
        [SELECT COUNT() FROM Sales_Target_Mutex__c WITH SYSTEM_MODE],
        'Runtime must not create a fallback singleton'
      );
      Assert.areEqual(0, Limits.getDmlStatements(), 'No runtime provisioning');
      Test.stopTest();
    }
  }
  @IsTest
  static void anotherMachineBindingBlocksEveryEntry() {
    User other = person(0);
    System.runAs(person(25)) {
      createMutex(other.Id);
      Test.startTest();
      assertMutexEntriesFail();
      Test.stopTest();
    }
  }
  private static void assertMutexEntriesFail() {
    try {
      SalesTargetActualsSchedulable.launch();
      Assert.fail('Launch needs the bound singleton');
    } catch (SalesTargetActualsBatch.ActualsException ex) {
      Assert.isTrue(
        ex.getMessage().contains('mutex'),
        'Mutex failure is explicit'
      );
    }
    try {
      SalesTargetActualsSchedulable.createOwnedSchedule();
      Assert.fail('Creation needs the bound singleton');
    } catch (SalesTargetActualsBatch.ActualsException ex) {
      Assert.isTrue(
        ex.getMessage().contains('mutex'),
        'Mutex failure is explicit'
      );
    }
    try {
      SalesTargetActualsSchedulable.stopOwnedSchedule();
      Assert.fail(
        'Stop needs the bound singleton even when no schedule exists'
      );
    } catch (SalesTargetActualsBatch.ActualsException ex) {
      Assert.isTrue(
        ex.getMessage().contains('mutex'),
        'Mutex failure is explicit'
      );
    }
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM AsyncApexJob
        WHERE
          ApexClass.Name IN (
            'SalesTargetActualsBatch',
            'SalesTargetActualsSchedulable'
          )
        WITH SYSTEM_MODE
      ],
      'No jobs created on rejected paths'
    );
  }
  @IsTest
  static void singletonKeyRejectsDuplicateAndInvalidRows() {
    System.runAs(person(25)) {
      createMutex(UserInfo.getUserId());
      Test.startTest();
      Database.SaveResult duplicate = Database.insert(
        new Sales_Target_Mutex__c(
          Lock_Key__c = 'DAILY_ACTUALS',
          Machine_User__c = UserInfo.getUserId()
        ),
        false,
        AccessLevel.SYSTEM_MODE
      );
      Assert.isFalse(duplicate.isSuccess(), 'Unique key prevents two locks');
      Assert.areEqual(
        StatusCode.DUPLICATE_VALUE,
        duplicate.getErrors()[0].getStatusCode(),
        'Atomic uniqueness is the race safeguard'
      );
      Database.SaveResult invalid = Database.insert(
        new Sales_Target_Mutex__c(
          Lock_Key__c = 'OTHER',
          Machine_User__c = UserInfo.getUserId()
        ),
        false,
        AccessLevel.SYSTEM_MODE
      );
      Assert.isFalse(invalid.isSuccess(), 'Only the singleton key is valid');
      Assert.areEqual(
        StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION,
        invalid.getErrors()[0].getStatusCode(),
        'Invalid key is blocked'
      );
      Test.stopTest();
    }
  }
  @IsTest
  static void unauthorizedScheduleCreationAndStopFailBeforeLockRead() {
    System.runAs(person(0)) {
      Test.startTest();
      try {
        SalesTargetActualsSchedulable.createOwnedSchedule();
        Assert.fail('Human schedule creation must fail');
      } catch (SalesTargetActualsBatch.ActualsException ex) {
        Assert.isTrue(
          ex.getMessage().contains('permission'),
          'Permission checked first'
        );
      }
      try {
        SalesTargetActualsSchedulable.stopOwnedSchedule();
        Assert.fail('Human stop must fail');
      } catch (SalesTargetActualsBatch.ActualsException ex) {
        Assert.isTrue(
          ex.getMessage().contains('permission'),
          'Permission checked first'
        );
      }
      Assert.areEqual(
        0,
        Limits.getQueries(),
        'No mutex or job reads for unauthorized callers'
      );
      Test.stopTest();
    }
  }
}
