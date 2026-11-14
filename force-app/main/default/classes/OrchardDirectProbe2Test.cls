@IsTest
private class OrchardDirectProbe2Test {
    @IsTest
    static void nullReturnsZero() {
        System.assertEquals(0, OrchardDirectProbe2.twice(null));
    }

    @IsTest
    static void threeReturnsSix() {
        System.assertEquals(6, OrchardDirectProbe2.twice(3));
    }
}
