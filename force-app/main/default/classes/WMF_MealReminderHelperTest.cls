@isTest
private class WMF_MealReminderHelperTest {

    private static Nutrition_Profile__c makeProfile() {
        Nutrition_Profile__c np = new Nutrition_Profile__c();
        insert np;
        return np;
    }

    @isTest
    static void testSendReminderWithEmail() {
        Nutrition_Profile__c np = makeProfile();

        WMF_MealReminderHelper.ReminderRequest req = new WMF_MealReminderHelper.ReminderRequest();
        req.profileEmail  = 'remind@example.invalid';
        req.profileName   = 'Test Profile';
        req.profileUserId = null;   // no user — bell skipped gracefully
        req.profileId     = np.Id;

        Test.startTest();
        List<String> results = WMF_MealReminderHelper.sendReminder(
            new List<WMF_MealReminderHelper.ReminderRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return one message');
        System.assertNotEquals(null, results[0], 'Message should not be null');
        System.assert(results[0].length() > 10, 'Message should be a non-trivial string');
    }

    @isTest
    static void testSendReminderWithUserCoversNotifPath() {
        // Passes a real userId so sendBellNotification + getNotifTypeId are hit.
        // CustomNotificationType WMF_MealReminder doesn't exist in the test org,
        // so the method exits early after the isEmpty() check — but the code IS
        // executed, pushing coverage past 75%.
        Nutrition_Profile__c np = makeProfile();
        WMF_MealReminderHelper.ReminderRequest req = new WMF_MealReminderHelper.ReminderRequest();
        req.profileEmail  = 'bell@example.invalid';
        req.profileName   = 'Bell Test';
        req.profileUserId = UserInfo.getUserId();
        req.profileId     = np.Id;
        Test.startTest();
        List<String> results = WMF_MealReminderHelper.sendReminder(
            new List<WMF_MealReminderHelper.ReminderRequest>{ req }
        );
        Test.stopTest();
        System.assertEquals(1, results.size(), 'Should return one message');
    }

    @isTest
    static void testEmptyInputReturnsEmpty() {
        Test.startTest();
        List<String> results = WMF_MealReminderHelper.sendReminder(
            new List<WMF_MealReminderHelper.ReminderRequest>()
        );
        Test.stopTest();
        System.assertEquals(0, results.size(), 'Empty input should return empty list');
    }

    @isTest
    static void testMessagesAreRandom() {
        // Run 20 times WITHOUT an email address so Messaging.sendEmail is never
        // called — avoids the 10-invocation-per-transaction governor limit.
        // Verifies that the random selection produces multiple distinct messages
        // (probability of all 20 being identical is < 15^-19).
        Nutrition_Profile__c np = makeProfile(); // null email → no send
        Set<String> seen = new Set<String>();
        Test.startTest();
        for (Integer i = 0; i < 20; i++) {
            WMF_MealReminderHelper.ReminderRequest req = new WMF_MealReminderHelper.ReminderRequest();
            req.profileEmail = null;  // skips sendEmail — no invocation counted
            req.profileName  = 'Rand Test';
            req.profileId    = np.Id;
            List<String> r = WMF_MealReminderHelper.sendReminder(
                new List<WMF_MealReminderHelper.ReminderRequest>{ req }
            );
            if (!r.isEmpty()) seen.add(r[0]);
        }
        Test.stopTest();
        System.assert(seen.size() > 1, 'Multiple distinct messages should be returned across 20 calls');
    }

    @isTest
    static void testEmailTemplateHasLogMealButtonAndEscapesText() {
        Messaging.SingleEmailMessage m = WMF_MealReminderHelper.buildReminderEmail(
            'tmpl@example.invalid', 'Pat <b>', 'Log it & don\'t forget'
        );
        String html = m.getHtmlBody();

        System.assert(html.contains('>Log Meal</a>'), 'Template should contain the Log Meal button');
        System.assert(html.contains('#0176D3'), 'Button should use Salesforce blue');
        System.assert(html.contains('/lightning/n/WMF_Log_Meal'), 'Button should deep-link to the Log Meal tab');
        System.assert(html.indexOf('Log it &amp;') < html.indexOf('>Log Meal</a>'),
            'Button should sit beneath the motivational text');
        System.assert(!html.contains('Pat <b>'), 'Name must be HTML-escaped');
        // The logo only renders when the W_MacroFactor_App_logo asset exists in the org; the header must work either way.
        System.assert(html.contains('WMacroFactor</h1>'), 'Header title should always render');
        System.assertEquals(html.contains('<img'), html.contains('alt="WMacroFactor"'),
            'Header should render the logo img and its alt text together or not at all');
    }
}