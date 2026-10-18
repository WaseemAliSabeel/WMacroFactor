@IsTest
private class WMF_RemindNowActionTest {

    private static WMF_RemindNowAction.Result run(Id profileId) {
        WMF_RemindNowAction.Request req = new WMF_RemindNowAction.Request();
        req.profileId = profileId;
        return WMF_RemindNowAction.sendNow(new List<WMF_RemindNowAction.Request>{ req })[0];
    }

    @IsTest
    static void testSendsAndStamps() {
        Nutrition_Profile__c np = new Nutrition_Profile__c(User__c = UserInfo.getUserId());
        insert np;

        Test.startTest();
        WMF_RemindNowAction.Result r = run(np.Id);
        Test.stopTest();

        System.assertEquals(true, r.success, 'Reminder should send: ' + r.errorMessage);
        System.assert(String.isNotBlank(r.message), 'The message that was sent should be returned');
        System.assertNotEquals(null,
            [SELECT Last_Meal_Reminder_Sent__c FROM Nutrition_Profile__c WHERE Id = :np.Id].Last_Meal_Reminder_Sent__c);
    }

    @IsTest
    static void testNoLinkedUserReturnsError() {
        Nutrition_Profile__c np = new Nutrition_Profile__c();
        insert np;

        Test.startTest();
        WMF_RemindNowAction.Result r = run(np.Id);
        Test.stopTest();

        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains('nobody to remind'), r.errorMessage);
    }
}