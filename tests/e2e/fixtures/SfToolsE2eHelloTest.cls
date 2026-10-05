@isTest
private class SfToolsE2eHelloTest {
    @isTest
    static void helloReturnsGreeting() {
        System.assertEquals('Hello, World!', SfToolsE2eHello.hello());
    }
}
