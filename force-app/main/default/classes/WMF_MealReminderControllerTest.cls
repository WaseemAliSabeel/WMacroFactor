@isTest
private class WMF_MealReminderControllerTest {

    @isTest
    static void testSendReminderNowStampsTimestamp() {
        Nutrition_Profile__c np = new Nutrition_Profile__c(
            User__c = UserInfo.getUserId()
        );
        insert np;

        Test.startTest();
        String msg = WMF_MealReminderController.sendReminderNow(np.Id);
        Test.stopTest();

        System.assert(String.isNotBlank(msg), 'The sent message text should be returned');
        np = [SELECT Last_Meal_Reminder_Sent__c FROM Nutrition_Profile__c WHERE Id = :np.Id];
        System.assertNotEquals(null, np.Last_Meal_Reminder_Sent__c,
            'Manual reminder should stamp Last_Meal_Reminder_Sent__c');
    }

    @isTest
    static void testNoEmailNoUserThrows() {
        Nutrition_Profile__c np = new Nutrition_Profile__c();
        insert np;

        Boolean threw = false;
        Test.startTest();
        try {
            WMF_MealReminderController.sendReminderNow(np.Id);
        } catch (AuraHandledException e) {
            threw = true;
            System.assert(e.getMessage().contains('nobody to remind'), 'Message should explain why');
        }
        Test.stopTest();

        System.assert(threw, 'Should throw when there is no linked user');
        np = [SELECT Last_Meal_Reminder_Sent__c FROM Nutrition_Profile__c WHERE Id = :np.Id];
        System.assertEquals(null, np.Last_Meal_Reminder_Sent__c, 'Nothing sent, so nothing stamped');
    }

    @isTest
    static void testNullAndMissingProfileThrow() {
        Integer thrown = 0;
        Test.startTest();
        try { WMF_MealReminderController.sendReminderNow(null); }
        catch (AuraHandledException e) { thrown++; }
        try { WMF_MealReminderController.sendReminderNow(Nutrition_Profile__c.SObjectType.getDescribe().getKeyPrefix() + '000000000000AAA'); }
        catch (AuraHandledException e) { thrown++; }
        Test.stopTest();
        System.assertEquals(2, thrown, 'Both null and unknown ids should be rejected');
    }
}