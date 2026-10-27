/** Corporate denomination policy only; never calculates or converts monetary values. */
public with sharing class SalesTargetCurrencyPolicy {
    private static Boolean corporateResolved = false;
    private static String corporateIso;
    private static final String ERROR_MESSAGE = 'Sales targets must use the corporate currency.';

    public static void beforeSave(List<Sales_Target__c> records, Map<Id, Sales_Target__c> oldRecords) {
        Boolean hasCurrency = Sales_Target__c.SObjectType.getDescribe().fields.getMap().containsKey('CurrencyIsoCode');
        if (!hasCurrency) {
            return;
        }
        List<SObject> rows = new List<SObject>();
        Map<Id, SObject> prior = oldRecords == null ? null : new Map<Id, SObject>();
        for (Sales_Target__c record : records) {
            rows.add(record);
        }
        if (prior != null) {
            for (Id recordId : oldRecords.keySet()) {
                prior.put(recordId, oldRecords.get(recordId));
            }
        }
        applyPolicy(rows, prior, 'CurrencyIsoCode', resolveCorporateIso());
    }

    private static String resolveCorporateIso() {
        if (!corporateResolved) {
            corporateResolved = true;
            try {
                List<SObject> currencies = Database.query('SELECT IsoCode FROM CurrencyType WHERE IsCorporate = true LIMIT 2');
                if (currencies.size() == 1) {
                    String candidate = (String) currencies[0].get('IsoCode');
                    if (!String.isBlank(candidate) && candidate.length() == 3) {
                        corporateIso = candidate;
                    }
                }
            } catch (QueryException ex) {
                // Fail closed rather than labeling money with an unknown denomination.
                corporateIso = null;
            }
        }
        return corporateIso;
    }

    // An isolated field-name seam exercises both currency modes without changing org settings.
    @TestVisible
    private static void applyPolicy(List<SObject> rows, Map<Id, SObject> prior, String currencyField, String corporate) {
        if (currencyField == null) {
            return;
        }
        for (SObject row : rows) {
            if (String.isBlank(corporate)) {
                row.addError(ERROR_MESSAGE);
            } else if (prior == null) {
                row.put(currencyField, corporate);
            } else {
                SObject oldRow = prior.get((Id) row.get('Id'));
                String current = (String) row.get(currencyField);
                if (oldRow == null || current != corporate || current != (String) oldRow.get(currencyField)) {
                    row.addError(ERROR_MESSAGE);
                }
            }
        }
    }
}
