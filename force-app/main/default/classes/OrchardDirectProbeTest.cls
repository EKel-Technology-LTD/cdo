@IsTest
private class OrchardDirectProbeTest {
    @IsTest
    static void nullReturnsZero() {
        System.assertEquals(0, OrchardDirectProbe.twice(null));
    }

    @IsTest
    static void threeReturnsSix() {
        System.assertEquals(6, OrchardDirectProbe.twice(3));
    }
}
