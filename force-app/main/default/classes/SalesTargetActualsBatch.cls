/**
 * Replaces two-quarter actuals through yesterday in Los Angeles.
 * Deliberately without sharing: the designated machine aggregates across owners.
 * Every transaction checks the machine custom permission and captured identity;
 * all reads/writes explicitly use system mode. No interactive entry point.
 */
public without sharing class SalesTargetActualsBatch implements Database.Batchable<SObject> {
  @TestVisible
  private static Date testToday;
  private Date runToday;
  private Date cutoff;
  private Date previousStart;
  private Id machineId;
  public class ActualsException extends Exception {
  }

  /** Captures one business date and identity, retained across batch transactions. */
  public SalesTargetActualsBatch() {
    requirePermission();
    machineId = UserInfo.getUserId();
    runToday = testToday == null
      ? Date.valueOf(Datetime.now().format('yyyy-MM-dd', 'America/Los_Angeles'))
      : testToday;
    cutoff = runToday.addDays(-1);
    previousStart = Date.newInstance(
        runToday.year(),
        1 + 3 * ((runToday.month() - 1) / 3),
        1
      )
      .addMonths(-3);
  }
  /** Only the separately authorized machine may call this service. */
  public static void requirePermission() {
    if (!FeatureManagement.checkPermission('Sales_Target_System_Write')) {
      throw new ActualsException(
        'Sales target machine permission is required.'
      );
    }
  }
  private void guard() {
    requirePermission();
    if (machineId != UserInfo.getUserId()) {
      throw new ActualsException('Sales target execution identity changed.');
    }
  }
  private static Boolean multiCurrency() {
    return Sales_Target__c.SObjectType.getDescribe()
      .fields.getMap()
      .containsKey('CurrencyIsoCode');
  }
  private static String corporateCurrency() {
    if (!multiCurrency())
      return null;
    List<SObject> currencies = Database.queryWithBinds(
      'SELECT IsoCode FROM CurrencyType WHERE IsCorporate=true AND IsActive=true LIMIT 2',
      new Map<String, Object>(),
      AccessLevel.SYSTEM_MODE
    );
    if (currencies.size() != 1)
      throw new ActualsException('Corporate currency is unresolved.');
    String result = (String) currencies[0].get('IsoCode');
    if (String.isBlank(result))
      throw new ActualsException('Corporate currency is unresolved.');
    return result;
  }
  @TestVisible
  private static void checkCurrency(String actual, String corporate) {
    if (corporate != null && actual != corporate) {
      throw new ActualsException(
        'Foreign eligible currency; conversion is out of scope.'
      );
    }
  }
  /** QueryLocator selects only current and previous calendar quarters. */
  public Database.QueryLocator start(Database.BatchableContext context) {
    guard();
    String corporate = corporateCurrency();
    Map<String, Object> binds = new Map<String, Object>{
      'today' => runToday,
      'previous' => previousStart,
      'corporate' => corporate
    };
    if (
      corporate != null &&
      !Database.queryWithBinds(
          'SELECT Id FROM Sales_Target__c WHERE Period_Start__c <= :today AND Period_End__c >= :previous AND CurrencyIsoCode != :corporate LIMIT 1',
          binds,
          AccessLevel.SYSTEM_MODE
        )
        .isEmpty()
    ) {
      throw new ActualsException(
        'Foreign target currency; conversion is out of scope.'
      );
    }
    return Database.getQueryLocatorWithBinds(
      'SELECT Id FROM Sales_Target__c WHERE Period_Start__c <= :today AND Period_End__c >= :previous',
      binds,
      AccessLevel.SYSTEM_MODE
    );
  }
  private class Totals {
    Decimal amount = 0;
    Set<Id> opportunityIds = new Set<Id>();
  }
  private static String dimension(Id owner, Date dateValue, String line) {
    return String.valueOf(owner) +
      ':' +
      dateValue.year() +
      ':' +
      ((dateValue.month() - 1) / 3) +
      ':' +
      (String.isBlank(line) ? 'ALL' : line);
  }
  private static void add(
    Map<String, Totals> sums,
    String key,
    Id opportunityId,
    Decimal amount
  ) {
    if (!sums.containsKey(key))
      sums.put(key, new Totals());
    Totals total = sums.get(key);
    total.amount += amount == null ? 0 : amount;
    total.opportunityIds.add(opportunityId);
  }
  /** Locks and re-reads dimensions, then performs one all-or-none scope update. */
  public void execute(Database.BatchableContext context, List<SObject> scope) {
    guard();
    if (scope == null || scope.isEmpty())
      return;
    if (scope.size() > 25)
      throw new ActualsException('Sales target scope must not exceed 25.');
    String corporate = corporateCurrency();
    Set<Id> ids = new Map<Id, SObject>(scope).keySet();
    Map<String, Object> binds = new Map<String, Object>{ 'ids' => ids };
    List<Sales_Target__c> targets = new List<Sales_Target__c>();
    Set<Id> owners = new Set<Id>();
    Set<String> lines = new Set<String>();
    Map<String, Totals> sums = new Map<String, Totals>();
    Set<String> wanted = new Set<String>();
    Date earliest;
    Date latest;
    String currencyColumn = corporate == null ? '' : ',CurrencyIsoCode';
    for (
      SObject raw : Database.queryWithBinds(
        'SELECT Id,Sales_Rep__c,Product_Line__c,Period_Start__c,Period_End__c' +
          currencyColumn +
          ' FROM Sales_Target__c WHERE Id IN :ids FOR UPDATE',
        binds,
        AccessLevel.SYSTEM_MODE
      )
    ) {
      Sales_Target__c row = (Sales_Target__c) raw;
      if (row.Period_Start__c > runToday || row.Period_End__c < previousStart)
        continue;
      if (corporate != null)
        checkCurrency((String) raw.get('CurrencyIsoCode'), corporate);
      if (
        row.Sales_Rep__c == null ||
        row.Period_Start__c == null ||
        row.Period_End__c == null
      ) {
        throw new ActualsException('Invalid target dimensions.');
      }
      targets.add(row);
      owners.add(row.Sales_Rep__c);
      if (!String.isBlank(row.Product_Line__c))
        lines.add(row.Product_Line__c);
      wanted.add(
        dimension(row.Sales_Rep__c, row.Period_Start__c, row.Product_Line__c)
      );
      Date endDate = row.Period_End__c < cutoff ? row.Period_End__c : cutoff;
      if (earliest == null || row.Period_Start__c < earliest)
        earliest = row.Period_Start__c;
      if (latest == null || endDate > latest)
        latest = endDate;
    }
    if (targets.isEmpty())
      return;
    binds = new Map<String, Object>{
      'owners' => owners,
      'earliest' => earliest,
      'latest' => latest,
      'lines' => lines
    };
    // Dynamic columns support single- and multi-currency without conversion.
    // SOQL-for loops consume minimal source columns, not nested relationship lists.
    for (
      SObject raw : Database.queryWithBinds(
        'SELECT Id,OwnerId,CloseDate,Amount' +
          currencyColumn +
          ' FROM Opportunity WHERE OwnerId IN :owners AND IsWon=true AND CloseDate >= :earliest AND CloseDate <= :latest',
        binds,
        AccessLevel.SYSTEM_MODE
      )
    ) {
      Opportunity row = (Opportunity) raw;
      String key = dimension(row.OwnerId, row.CloseDate, null);
      if (!wanted.contains(key))
        continue;
      if (corporate != null)
        checkCurrency((String) raw.get('CurrencyIsoCode'), corporate);
      add(sums, key, row.Id, row.Amount);
    }
    if (!lines.isEmpty()) {
      for (
        SObject raw : Database.queryWithBinds(
          'SELECT OpportunityId,Opportunity.OwnerId,Opportunity.CloseDate,Product2.Product_Line__c,TotalPrice' +
            (corporate == null
              ? ''
              : ',CurrencyIsoCode,Opportunity.CurrencyIsoCode') +
            ' FROM OpportunityLineItem WHERE Opportunity.OwnerId IN :owners AND Opportunity.IsWon=true' +
            ' AND Opportunity.CloseDate >= :earliest AND Opportunity.CloseDate <= :latest AND Product2.Product_Line__c IN :lines',
          binds,
          AccessLevel.SYSTEM_MODE
        )
      ) {
        OpportunityLineItem row = (OpportunityLineItem) raw;
        String key = dimension(
          row.Opportunity.OwnerId,
          row.Opportunity.CloseDate,
          row.Product2.Product_Line__c
        );
        if (!wanted.contains(key))
          continue;
        if (corporate != null) {
          checkCurrency((String) raw.get('CurrencyIsoCode'), corporate);
          checkCurrency(
            (String) raw.getSObject('Opportunity').get('CurrencyIsoCode'),
            corporate
          );
        }
        add(sums, key, row.OpportunityId, row.TotalPrice);
      }
    }
    Datetime calculatedAt = Datetime.now();
    List<Sales_Target__c> updates = new List<Sales_Target__c>();
    for (Sales_Target__c row : targets) {
      Totals total = sums.get(
        dimension(row.Sales_Rep__c, row.Period_Start__c, row.Product_Line__c)
      );
      updates.add(
        new Sales_Target__c(
          Id = row.Id,
          Actual_Amount__c = total == null ? 0 : total.amount,
          Won_Opportunity_Count__c = total == null
            ? 0
            : total.opportunityIds.size(),
          Last_Calculated_At__c = calculatedAt
        )
      );
    }
    // Never swallow failures or advance freshness for a failed scope.
    Database.update(updates, true, AccessLevel.SYSTEM_MODE);
  }
  /** Failed scopes remain visible in AsyncApexJob; no success masking or automatic retry. */
  public void finish(Database.BatchableContext context) {
    guard();
  }
}
