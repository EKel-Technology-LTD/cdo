/** Routing and currency conversion. Percent values in Apex use percentage points. */
public with sharing class DiscountApprovalPolicy {
    private static Map<String, Decimal> rates;
    private static String corporate;
    private static Map<String,List<SObject>> datedRates;
    /** Determines the approved route from percentage points and corporate amount. */
    public static String route(Decimal discount, Decimal amount) {
        if (discount == null || discount < 10) return null;
        if (discount >= 35 || (discount >= 20 && amount != null && amount > 500000)) return 'Executive';
        return discount >= 20 ? 'Deal Desk' : 'Manager';
    }
    /** Loads current and, when available, effective-dated conversion rates once per transaction. */
    public static Decimal corporateAmount(Opportunity opportunity) {
        if (opportunity.Amount == null) return 0;
        if (rates == null) {
            rates = new Map<String, Decimal>();
            for (CurrencyType currency : [SELECT IsoCode, ConversionRate, IsCorporate FROM CurrencyType WITH SYSTEM_MODE]) {
                rates.put(currency.IsoCode, currency.ConversionRate);
                if (currency.IsCorporate) corporate = currency.IsoCode;
            }
        }
        if (datedRates == null) {
            datedRates = new Map<String,List<SObject>>();
            // DatedConversionRate is feature-dependent. Empty dated configuration uses current rates.
            if (Schema.getGlobalDescribe().containsKey('DatedConversionRate')) {
                Set<String> isoCodes = rates.keySet();
                for (SObject dated : Database.query('SELECT IsoCode,ConversionRate,StartDate,NextStartDate FROM DatedConversionRate WHERE IsoCode IN :isoCodes WITH SYSTEM_MODE ORDER BY StartDate DESC')) {
                    String code = (String)dated.get('IsoCode');
                    if (!datedRates.containsKey(code)) datedRates.put(code,new List<SObject>());
                    datedRates.get(code).add(dated);
                }
            }
        }
        String iso = opportunity.CurrencyIsoCode == null ? corporate : opportunity.CurrencyIsoCode;
        Decimal rate = rates.get(iso);
        if (iso != corporate && !datedRates.isEmpty()) {
            rate = null;
            List<SObject> effectiveRates = datedRates.get(iso);
            if (effectiveRates != null) {
                for (SObject dated : effectiveRates) {
                    Date startDate = (Date)dated.get('StartDate');
                    Date nextStartDate = (Date)dated.get('NextStartDate');
                    if (opportunity.CloseDate >= startDate && (nextStartDate == null || opportunity.CloseDate < nextStartDate)) {
                        rate = (Decimal)dated.get('ConversionRate'); break;
                    }
                }
            }
        }
        if (rate == null || rate <= 0) throw new PolicyException('A valid currency conversion rate is required.');
        return opportunity.Amount / rate;
    }
    public class PolicyException extends Exception {}
}
