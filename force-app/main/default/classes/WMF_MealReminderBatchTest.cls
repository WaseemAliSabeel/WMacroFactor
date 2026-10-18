@isTest
private class WMF_MealReminderBatchTest {

    // Creates a minimal Meal__c for a given profile, logged N hours ago
    private static Meal__c makeMeal(Id profileId, Integer hoursAgo) {
        return new Meal__c(
            Nutrition_Profile__c      = profileId,
            Logged_DateTime__c        = Datetime.now().addHours(-hoursAgo),
            Status__c                 = 'Analyzed',
            Analysis_Attempt_Count__c = 1,
            Calories__c               = 500,
            Protein_g__c              = 30,
            Carbs_g__c                = 50,
            Fat_g__c                  = 15,
            Protein_Pct__c            = 30,
            Carbs_Pct__c              = 50,
            Fat_Pct__c                = 20
        );
    }

    @isTest
    static void testReminderSentForStaleMeal() {
        Nutrition_Profile__c np = new Nutrition_Profile__c(User__c = UserInfo.getUserId());
        insert np;
        insert makeMeal(np.Id, 24); // 24-hour-old meal — overdue

        Test.startTest();
        Database.executeBatch(new WMF_MealReminderBatch(), 50);
        Test.stopTest();

        np = [SELECT Last_Meal_Reminder_Sent__c FROM Nutrition_Profile__c WHERE Id = :np.Id];
        System.assertNotEquals(null, np.Last_Meal_Reminder_Sent__c,
            'Reminder timestamp should be stamped for a 24-hour-old meal');
    }

    @isTest
    static void testNoReminderForFreshMeal() {
        Nutrition_Profile__c np = new Nutrition_Profile__c(User__c = UserInfo.getUserId());
        insert np;
        insert makeMeal(np.Id, 2); // 2-hour-old meal — still fresh

        Test.startTest();
        Database.executeBatch(new WMF_MealReminderBatch(), 50);
        Test.stopTest();

        np = [SELECT Last_Meal_Reminder_Sent__c FROM Nutrition_Profile__c WHERE Id = :np.Id];
        System.assertEquals(null, np.Last_Meal_Reminder_Sent__c,
            'No reminder should be sent when last meal is within 15 hours');
    }

    @isTest
    static void testNoReminderWhenAlreadyRemindedThisCycle() {
        // Last reminder was AFTER the last meal → already handled this cycle, skip
        Nutrition_Profile__c np = new Nutrition_Profile__c(
            User__c = UserInfo.getUserId(),
            Last_Meal_Reminder_Sent__c = Datetime.now().addHours(-1)
        );
        insert np;
        insert makeMeal(np.Id, 24);

        Datetime reminderBefore = np.Last_Meal_Reminder_Sent__c;

        Test.startTest();
        Database.executeBatch(new WMF_MealReminderBatch(), 50);
        Test.stopTest();

        np = [SELECT Last_Meal_Reminder_Sent__c FROM Nutrition_Profile__c WHERE Id = :np.Id];
        System.assert(np.Last_Meal_Reminder_Sent__c < Datetime.now().addMinutes(-30),
            'Reminder timestamp should not have been updated this cycle');
    }

    @isTest
    static void testNoReminderWithNoEmail() {
        // Profile has no linked User email — should never trigger a send
        Nutrition_Profile__c np = new Nutrition_Profile__c(); // no User, so no email
        insert np;
        insert makeMeal(np.Id, 24);

        Test.startTest();
        Database.executeBatch(new WMF_MealReminderBatch(), 50);
        Test.stopTest();

        // Profile should not be in the batch scope (WHERE User__r.Email != null)
        np = [SELECT Last_Meal_Reminder_Sent__c FROM Nutrition_Profile__c WHERE Id = :np.Id];
        System.assertEquals(null, np.Last_Meal_Reminder_Sent__c,
            'Profile without email should never be reminded');
    }

    @isTest
    static void testSchedulable() {
        Test.startTest();
        System.schedule('WMF Meal Reminder Test', '0 0 8 * * ?', new WMF_MealReminderBatch());
        Test.stopTest();
        // Passes if no exception thrown
    }
}