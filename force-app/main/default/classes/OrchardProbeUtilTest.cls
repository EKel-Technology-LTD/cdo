@IsTest
private class OrchardProbeUtilTest {
    @IsTest
    static void returnsNullForNull() {
        Test.startTest();
        String actual = OrchardProbeUtil.normalizeNote(null);
        Test.stopTest();
        Assert.areEqual(null, actual, 'Null input returns null.');
    }

    @IsTest
    static void returnsNullForEmpty() {
        Test.startTest();
        String actual = OrchardProbeUtil.normalizeNote('');
        Test.stopTest();
        Assert.areEqual(null, actual, 'Empty input returns null.');
    }

    @IsTest
    static void returnsNullForWhitespace() {
        Test.startTest();
        String actual = OrchardProbeUtil.normalizeNote(' \t\n\r ');
        Test.stopTest();
        Assert.areEqual(null, actual, 'Whitespace input returns null.');
    }

    @IsTest
    static void trimsShortText() {
        Test.startTest();
        String actual = OrchardProbeUtil.normalizeNote('  note  ');
        Test.stopTest();
        Assert.areEqual('note', actual, 'Short text is trimmed.');
    }

    @IsTest
    static void preservesExactlyFiftyCharacters() {
        Test.startTest();
        String actual = OrchardProbeUtil.normalizeNote('  01234567890123456789012345678901234567890123456789  ');
        Test.stopTest();
        Assert.areEqual('01234567890123456789012345678901234567890123456789', actual, 'Exactly fifty characters are preserved after trimming.');
    }

    @IsTest
    static void trimsThenTruncatesLongText() {
        Test.startTest();
        String actual = OrchardProbeUtil.normalizeNote('  01234567890123456789012345678901234567890123456789X  ');
        Test.stopTest();
        Assert.areEqual('01234567890123456789012345678901234567890123456789', actual, 'Trim before retaining the first fifty characters.');
    }
}
