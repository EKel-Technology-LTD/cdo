@IsTest
private class AssetWarrantyRegistrationTest {
    @TestSetup
    static void fixtures() {
        Id personType = [SELECT Id FROM RecordType WHERE SobjectType = 'Account' AND IsPersonType = true AND IsActive = true LIMIT 1].Id;
        insert new Account(LastName = 'Synthetic Warranty Customer', RecordTypeId = personType);
        insert new Account(Name = 'Synthetic Warranty Dealer');
        // Inactive models avoid unrelated active-product completeness requirements.
        insert new List<Product2>{
            new Product2(Name = 'Synthetic AP-500', Warranty_Months__c = 24, IsActive = false),
            new Product2(Name = 'Synthetic Unknown Term', Warranty_Months__c = null, IsActive = false),
            new Product2(Name = 'Synthetic Zero Term', Warranty_Months__c = 0, IsActive = false)
        };
    }
    private static Asset registration(String serial) {
        return new Asset(Name = 'Synthetic ' + serial,
            AccountId = [SELECT Id FROM Account WHERE IsPersonAccount = true LIMIT 1].Id,
            Product2Id = [SELECT Id FROM Product2 WHERE Name = 'Synthetic AP-500' LIMIT 1].Id,
            Status = 'Registered', PurchaseDate = Date.newInstance(2026, 1, 10),
            Registered_Serial__c = serial, Purchase_Channel__c = 'Official_Store',
            Invoice_Number__c = 'AB12345678', Extended_Warranty_Months__c = 0);
    }
    private static Asset reload(Id id) {
        return [SELECT Status, PurchaseDate, Warranty_End_Date__c, Warranty_Status__c,
            Registered_At__c, Registration_Source__c, Warranty_Registration_Initialized__c
            FROM Asset WHERE Id = :id];
    }
    private static void rejected(Asset a, String message) {
        Database.SaveResult result = Database.insert(a, false);
        Assert.isFalse(result.isSuccess(), 'Expected rejection: ' + message);
        Boolean found = false;
        for (Database.Error e : result.getErrors()) {
            if (e.getMessage().contains(message)) found = true;
        }
        Assert.isTrue(found, 'Expected message ' + message + ': ' + JSON.serialize(result.getErrors()));
    }
    @IsTest static void originalAndExtendedWarranty() {
        Asset a = registration('TEST-00001');
        insert a;
        Assert.areEqual(Date.newInstance(2028, 1, 9), reload(a.Id).Warranty_End_Date__c);
        if (Date.today() < Date.newInstance(2027, 12, 10)) {
            Assert.areEqual('保固中', reload(a.Id).Warranty_Status__c);
        }
        a.Extended_Warranty_Months__c = 12;
        update a;
        Assert.areEqual(Date.newInstance(2029, 1, 9), reload(a.Id).Warranty_End_Date__c);
        a.Extended_Warranty_Months__c = null;
        update a;
        Assert.areEqual(Date.newInstance(2028, 1, 9), reload(a.Id).Warranty_End_Date__c);
    }
    @IsTest static void relativeDatesAndInclusiveBoundaries() {
        Date today = Date.today();
        Id zeroProductId = [SELECT Id FROM Product2 WHERE Name = 'Synthetic Zero Term' LIMIT 1].Id;
        List<Asset> rows = new List<Asset>();
        for (Integer i = 0; i < 5; i++) {
            Asset a = registration('RELATIVE-000' + i);
            if (i == 0) a.PurchaseDate = today.addMonths(-23).addDays(-10);
            if (i == 1) a.PurchaseDate = today.addYears(-3);
            // Use a zero-month product and extension for exact boundary fixtures.
            if (i >= 2) {
                a.Product2Id = zeroProductId;
                a.PurchaseDate = today;
                a.Extended_Warranty_Months__c = 0;
            }
            rows.add(a);
        }
        insert rows;
        Assert.areEqual('30 天內到期', reload(rows[0].Id).Warranty_Status__c);
        Assert.areEqual('已過保', reload(rows[1].Id).Warranty_Status__c);
        Assert.areEqual(today.addDays(-1), reload(rows[2].Id).Warranty_End_Date__c);
        // Product warranty term is live. A term of one month checks calendar arithmetic.
        Product2 zero = [SELECT Id, Warranty_Months__c FROM Product2 WHERE Name = 'Synthetic Zero Term' LIMIT 1];
        zero.Warranty_Months__c = 1;
        update zero;
        Date expected = calendarAdd(today, 1).addDays(-1);
        Assert.areEqual(expected, reload(rows[2].Id).Warranty_End_Date__c);
        Assert.areEqual(expected <= today.addDays(30) ? '30 天內到期' : '保固中', reload(rows[2].Id).Warranty_Status__c);
        // Find calendar purchase dates whose 24-month terms end exactly on each boundary.
        List<Asset> boundaries = new List<Asset>();
        List<Integer> offsets = new List<Integer>{-1, 0, 30, 31};
        for (Integer offset : offsets) {
            Date desired = today.addDays(offset);
            Date purchase;
            for (Integer delta = -3; delta <= 3; delta++) {
                Date candidate = desired.addDays(1).addMonths(-24).addDays(delta);
                // Salesforce ADDMONTHS preserves last-day-of-month semantics.
                Date end = calendarAdd(candidate, 24).addDays(-1);
                if (end == desired) purchase = candidate;
            }
            if (purchase != null) {
                Asset a = registration('BOUNDARY-' + String.valueOf(offset).replace('-', 'N'));
                a.PurchaseDate = purchase;
                boundaries.add(a);
            }
        }
        insert boundaries;
        for (Asset a : boundaries) {
            Asset saved = reload(a.Id);
            Date end = saved.Warranty_End_Date__c;
            Assert.areEqual(end < today ? '已過保' : (end <= today.addDays(30) ? '30 天內到期' : '保固中'), saved.Warranty_Status__c);
        }
    }
    private static Date calendarAdd(Date value, Integer months) {
        Date result = value.addMonths(months);
        if (value.day() == Date.daysInMonth(value.year(), value.month())) {
            result = Date.newInstance(result.year(), result.month(), Date.daysInMonth(result.year(), result.month()));
        }
        return result;
    }
    @IsTest static void monthEndAndLeapYearArithmetic() {
        Asset monthEnd = registration('MONTHEND-01');
        monthEnd.PurchaseDate = Date.newInstance(2025, 2, 28);
        monthEnd.Extended_Warranty_Months__c = 1;
        insert monthEnd;
        Assert.areEqual(Date.newInstance(2027, 3, 30), reload(monthEnd.Id).Warranty_End_Date__c);
        Asset leap = registration('LEAPYEAR-01');
        leap.PurchaseDate = Date.newInstance(2024, 2, 29);
        insert leap;
        Assert.areEqual(Date.newInstance(2026, 2, 27), reload(leap.Id).Warranty_End_Date__c);
    }
    @IsTest static void serialAndInvoiceValidation() {
        Asset original = registration('DUPLICATE-01');
        insert original;
        Database.SaveResult dup = Database.insert(registration('DUPLICATE-01'), false);
        Assert.isFalse(dup.isSuccess());
        Assert.areEqual(StatusCode.DUPLICATE_VALUE, dup.getErrors()[0].getStatusCode());
        // Lowercase fails format too; schema evidence independently proves insensitive uniqueness.
        Schema.DescribeFieldResult serial = Asset.Registered_Serial__c.getDescribe();
        Assert.isTrue(serial.isUnique());
        Assert.isTrue(serial.isExternalId());
        Assert.isFalse(serial.isCaseSensitive());
        Assert.areEqual(30, serial.getLength());
        rejected(registration('duplicate-01'), '產品序號只能使用');
        rejected(registration('SHORT'), '產品序號只能使用');
        rejected(registration('BAD SPACE'), '產品序號只能使用');
        Asset lower = registration('INVOICE-001'); lower.Invoice_Number__c = 'ab12345678';
        rejected(lower, '發票號碼格式');
        Asset shortInvoice = registration('INVOICE-002'); shortInvoice.Invoice_Number__c = 'AB1234567';
        rejected(shortInvoice, '發票號碼格式');
    }
    @IsTest static void dealerAndRegisteredRequirements() {
        Asset missingDealer = registration('DEALER-001'); missingDealer.Purchase_Channel__c = 'Dealer';
        rejected(missingDealer, '請選擇購買經銷商');
        Asset wrongDealer = registration('DEALER-002'); wrongDealer.Purchase_Channel__c = 'Dealer'; wrongDealer.Selling_Dealer__c = wrongDealer.AccountId;
        Database.SaveResult bad = Database.insert(wrongDealer, false);
        Assert.isFalse(bad.isSuccess());
        Assert.areEqual(StatusCode.FIELD_FILTER_VALIDATION_EXCEPTION, bad.getErrors()[0].getStatusCode());
        Asset validDealer = registration('DEALER-003'); validDealer.Purchase_Channel__c = 'Dealer';
        validDealer.Selling_Dealer__c = [SELECT Id FROM Account WHERE IsPersonAccount = false LIMIT 1].Id;
        insert validDealer;
        Asset noDate = registration('REQUIRED-01'); noDate.PurchaseDate = null;
        rejected(noDate, '登錄保固時請填寫');
        noDate.Status = 'Purchased';
        insert noDate;
        Assert.areEqual('未登錄', reload(noDate.Id).Warranty_Status__c);
        Assert.isNull(reload(noDate.Id).Registered_At__c);
        Assert.isFalse(reload(noDate.Id).Warranty_Registration_Initialized__c);
        Asset noProduct = registration('REQUIRED-02'); noProduct.Product2Id = null;
        rejected(noProduct, '登錄保固時請填寫');
        Asset noChannel = registration('REQUIRED-03'); noChannel.Purchase_Channel__c = null;
        rejected(noChannel, '登錄保固時請填寫');
        Asset noSerial = registration(null);
        rejected(noSerial, '登錄保固時請填寫');
        Asset business = registration('REQUIRED-04'); business.AccountId = validDealer.Selling_Dealer__c;
        rejected(business, '登錄保固時請選擇個人帳戶');
        Asset noAccount = registration('REQUIRED-05'); noAccount.AccountId = null;
        rejected(noAccount, '登錄保固時請選擇個人帳戶');
    }
    @IsTest static void unknownTermsAndRangeGuards() {
        Asset unknown = registration('UNKNOWN-001');
        unknown.Product2Id = [SELECT Id FROM Product2 WHERE Name = 'Synthetic Unknown Term' LIMIT 1].Id;
        rejected(unknown, '產品保固月數未設定');
        unknown.Status = 'Purchased'; insert unknown;
        Assert.isNull(reload(unknown.Id).Warranty_End_Date__c);
        Assert.isTrue(String.isBlank(reload(unknown.Id).Warranty_Status__c));
        Asset noProduct = registration('UNKNOWN-002'); noProduct.Status = 'Purchased'; noProduct.Product2Id = null;
        insert noProduct;
        Assert.isNull(reload(noProduct.Id).Warranty_End_Date__c);
        Assert.isTrue(String.isBlank(reload(noProduct.Id).Warranty_Status__c));
        Asset future = registration('RANGE-00001'); future.PurchaseDate = Date.today().addDays(1);
        rejected(future, '購買日期不可晚於今天');
        Asset negative = registration('RANGE-00002'); negative.Extended_Warranty_Months__c = -1;
        rejected(negative, '延長保固月數必須介於');
        Asset high = registration('RANGE-00003'); high.Extended_Warranty_Months__c = 37;
        rejected(high, '延長保固月數必須介於');
        Asset max = registration('RANGE-00004'); max.Extended_Warranty_Months__c = 36; insert max;
    }
    @IsTest static void firstRegistrationDefaultsOnlyOnce() {
        Asset a = registration('DEFAULT-001'); a.Status = 'Purchased'; insert a;
        Assert.isFalse(reload(a.Id).Warranty_Registration_Initialized__c);
        a.Status = 'Registered'; update a;
        Asset first = reload(a.Id);
        Assert.isNotNull(first.Registered_At__c);
        Assert.areEqual('Agent', first.Registration_Source__c);
        Assert.isTrue(first.Warranty_Registration_Initialized__c);
        a.Name = 'Synthetic later edit'; update a;
        Assert.areEqual(first.Registered_At__c, reload(a.Id).Registered_At__c);
        a.Registered_At__c = null; a.Registration_Source__c = null; update a;
        Assert.isNull(reload(a.Id).Registered_At__c);
        Assert.isTrue(String.isBlank(reload(a.Id).Registration_Source__c));
        a.Status = 'Purchased'; update a;
        a.Status = 'Registered'; update a;
        Assert.isNull(reload(a.Id).Registered_At__c);
        Assert.isTrue(String.isBlank(reload(a.Id).Registration_Source__c));
        Assert.isTrue(reload(a.Id).Warranty_Registration_Initialized__c);
        Datetime supplied = Datetime.newInstanceGmt(2026, 1, 10, 3, 0, 0);
        Asset imported = registration('DEFAULT-002'); imported.Registration_Source__c = 'Import'; imported.Registered_At__c = supplied;
        insert imported;
        Assert.areEqual(supplied, reload(imported.Id).Registered_At__c);
        Assert.areEqual('Import', reload(imported.Id).Registration_Source__c);
        Asset suppliedTime = registration('DEFAULT-003'); suppliedTime.Registered_At__c = supplied; insert suppliedTime;
        Assert.areEqual(supplied, reload(suppliedTime.Id).Registered_At__c);
        Assert.areEqual('Agent', reload(suppliedTime.Id).Registration_Source__c);
        Asset suppliedSource = registration('DEFAULT-004'); suppliedSource.Registration_Source__c = 'Web_Self_Service'; insert suppliedSource;
        Assert.isNotNull(reload(suppliedSource.Id).Registered_At__c);
        Assert.areEqual('Web_Self_Service', reload(suppliedSource.Id).Registration_Source__c);
    }
    @IsTest static void failedSaveRollsBackDefaults() {
        Asset a = registration('ROLLBACK-01'); a.Status = 'Purchased'; insert a;
        a.Status = 'Registered'; a.Invoice_Number__c = 'bad';
        Assert.isFalse(Database.update(a, false).isSuccess());
        Asset saved = reload(a.Id);
        Assert.areEqual('Purchased', saved.Status);
        Assert.isFalse(saved.Warranty_Registration_Initialized__c);
        Assert.isNull(saved.Registered_At__c);
        a.Invoice_Number__c = 'AB12345678'; update a;
        Assert.isTrue(reload(a.Id).Warranty_Registration_Initialized__c);
    }
    @IsTest static void partialInsertTwoHundred() {
        Asset template = registration('BULK-SEED'); insert template;
        List<Asset> rows = new List<Asset>();
        for (Integer i = 0; i < 200; i++) {
            Asset a = template.clone(false, false, false, false);
            a.Registered_Serial__c = i < 3 ? 'BULK-SEED' : 'BULK-ROW-' + i;
            a.Registration_Source__c = 'Import';
            a.Registered_At__c = null;
            a.Warranty_Registration_Initialized__c = false;
            rows.add(a);
        }
        Test.startTest();
        List<Database.SaveResult> results = Database.insert(rows, false);
        Test.stopTest();
        Integer succeeded = 0, duplicates = 0;
        Set<Id> ids = new Set<Id>();
        for (Database.SaveResult result : results) {
            if (result.isSuccess()) { succeeded++; ids.add(result.getId()); }
            else {
                Assert.areEqual(StatusCode.DUPLICATE_VALUE, result.getErrors()[0].getStatusCode());
                duplicates++;
            }
        }
        Assert.areEqual(197, succeeded);
        Assert.areEqual(3, duplicates);
        Assert.areEqual(197, [SELECT count() FROM Asset WHERE Id IN :ids AND Registration_Source__c = 'Import' AND Warranty_Registration_Initialized__c = true AND Registered_At__c != null]);
    }
}
