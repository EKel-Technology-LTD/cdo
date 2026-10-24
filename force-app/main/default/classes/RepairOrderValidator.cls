/**
 * Validation-only before-save guard for repair orders. No business-record reads or DML.
 * Corporate currency configuration is deliberately read in system mode so validation
 * does not depend on a technician's access to organization setup data.
 */
public with sharing class RepairOrderValidator {
    // A null cache means not yet loaded. An empty cache fails closed. Tests can supply
    // configuration rows without changing org currency settings or bypassing validation.
    @TestVisible private static List<CurrencyType> corporateConfiguration;
    // Counts actual query attempts, independently of governor counters reset by partial saves.
    // Observation only: never used to bypass validation or decide whether to load the cache.
    @TestVisible private static Integer corporateConfigQueryCount = 0;
    private static final String CONFIGURATION_ERROR =
        'Repair Order corporate currency configuration is unavailable. Contact your administrator.';

    /**
     * Validates every record on every invocation, including partial-save retries.
     * @param orders Full before-insert or before-update trigger batch.
     */
    public static void validate(List<Repair_Order__c> orders) {
        if (orders == null || orders.isEmpty()) {
            return;
        }
        String corporateCode = getCorporateCode();
        for (Repair_Order__c order : orders) {
            if (String.isBlank(order.Fault_Description__c)) {
                order.Fault_Description__c.addError('Please enter the fault description.');
            }
            if (String.isBlank(order.Repair_Status__c)) {
                order.Repair_Status__c.addError('Please select a repair status.');
            }
            if ((order.Repair_Status__c == 'Unrepairable' || order.Repair_Status__c == 'Cancelled')
                && String.isBlank(order.Diagnosis_Result__c)) {
                order.Diagnosis_Result__c.addError(
                    'When "Unrepairable" or "Cancelled", please state the reason in Diagnosis Result.');
            }
            if (String.isBlank(corporateCode)) {
                order.CurrencyIsoCode.addError(CONFIGURATION_ERROR);
            } else if (order.CurrencyIsoCode != corporateCode) {
                order.CurrencyIsoCode.addError('Select the organization\'s corporate currency for Repair Order.');
            }
        }
    }

    private static String getCorporateCode() {
        if (corporateConfiguration == null) {
            try {
                corporateConfigQueryCount++;
                corporateConfiguration = [
                    SELECT IsoCode FROM CurrencyType WHERE IsCorporate = true
                    WITH SYSTEM_MODE LIMIT 2
                ];
            } catch (QueryException configurationFailure) {
                // Fail closed; never disclose internal configuration or query details.
                corporateConfiguration = new List<CurrencyType>();
            }
        }
        return corporateConfiguration.size() == 1 ? corporateConfiguration[0].IsoCode : null;
    }
}
