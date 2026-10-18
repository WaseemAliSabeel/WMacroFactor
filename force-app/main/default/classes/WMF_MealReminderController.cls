// Backs the "Remind Now" quick action on Nutrition_Profile__c.
// Reuses WMF_MealReminderHelper (the same Apex the scheduled flow invokes) so a manual
// reminder gets the same random message, HTML email and bell notification, then stamps
// Last_Meal_Reminder_Sent__c exactly like the automated paths do.
public with sharing class WMF_MealReminderController {

    // Sends a reminder to the given Nutrition Profile immediately and returns the message text.
    // Throws AuraHandledException (readable by the LWC) when there is nobody to notify.
    @AuraEnabled
    public static String sendReminderNow(Id profileId) {
        if (profileId == null) {
            throw auraError('No Nutrition Profile was supplied.');
        }

        List<Nutrition_Profile__c> rows = [
            SELECT Id, Name, User__c, User__r.Email
            FROM Nutrition_Profile__c
            WHERE Id = :profileId
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw auraError('Nutrition Profile not found or you do not have access to it.');
        }
        Nutrition_Profile__c p = rows[0];

        if (p.User__c == null) {
            throw auraError('This profile has no linked User, so there is nobody to remind.');
        }

        WMF_MealReminderHelper.ReminderRequest req = new WMF_MealReminderHelper.ReminderRequest();
        req.profileEmail  = p.User__r.Email;
        req.profileName   = p.Name;
        req.profileUserId = p.User__c;
        req.profileId     = p.Id;

        List<String> sent = WMF_MealReminderHelper.sendReminder(
            new List<WMF_MealReminderHelper.ReminderRequest>{ req }
        );

        update new Nutrition_Profile__c(Id = p.Id, Last_Meal_Reminder_Sent__c = Datetime.now());

        return sent.isEmpty() ? null : sent[0];
    }

    // AuraHandledException only surfaces its text to the client when setMessage is called.
    private static AuraHandledException auraError(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        return e;
    }
}