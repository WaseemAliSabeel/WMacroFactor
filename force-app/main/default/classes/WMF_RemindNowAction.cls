// Invocable wrapper so the "Remind Now" Screen Flow action can send the same reminder the
// old remindNow LWC did. LWC quick actions don't render in the Salesforce mobile app; Flow
// quick actions do. All the real work stays in WMF_MealReminderController.sendReminderNow.
public with sharing class WMF_RemindNowAction {

    public class Request {
        @InvocableVariable(label='Nutrition Profile Record ID' required=true)
        public Id profileId;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Reminder Message Sent')
        public String message;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(
        label='Send Meal Reminder Now'
        description='Sends the meal-logging reminder (email + bell) to a Nutrition Profile on demand and stamps Last Meal Reminder Sent'
        category='WMacroFactor'
    )
    public static List<Result> sendNow(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result r = new Result();
            try {
                r.message = WMF_MealReminderController.sendReminderNow(req.profileId);
                r.success = true;
            } catch (Exception e) {
                r.success      = false;
                r.errorMessage = e.getMessage();
            }
            results.add(r);
        }
        return results;
    }
}