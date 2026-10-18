// Scheduled batch that fires an in-app bell notification AND an email when a
// Nutrition Profile owner has not logged a meal in the past 15 hours.
// One reminder is sent per meal cycle: once reminded, the profile is skipped
// until the user logs a fresh meal (which resets the Last_Meal_Reminder_Sent__c
// logic on the next batch run).
//
// To install the hourly schedule from Anonymous Apex:
//   WMF_MealReminderBatch.scheduleHourly();
public class WMF_MealReminderBatch implements Database.Batchable<SObject>, Schedulable {

    private static final Integer REMINDER_HOURS = 15;

    private static final List<String> MESSAGES = new List<String>{
        'Your goals don\'t care about your poor memory. Log that meal before it logs onto your waistline.',
        'Did you eat, or are you just pretending calories don\'t count when you ignore them? Open WMacroFactor.',
        'Gains aren\'t built on secret calories. Log your meal now and stay on track for your peak physique.',
        'Your stomach remembers what you ate, even if your brain is acting like it forgot. Log it!',
        'That meal was too good to leave out. Show off those macros in WMacroFactor right now!',
        'Late logging ruins smart tracking. Drop a 10-second log right now to keep your meal timings honest.',
        'Every unlogged meal is a step away from your fat loss goals. Don\'t cheat yourself—log it.',
        'Plot twist: Unlogged calories still count. Tap here to record your masterpiece before you forget.',
        'Fuelling the engine? Make sure WMacroFactor knows so your muscle-building algorithm can adapt.',
        'Stop scrolling, start logging. It takes 5 seconds to keep your streak alive!',
        'Untracked food has a funny way of turning into unwanted weight. Log your meal in WMacroFactor.',
        'You remembered to eat, didn\'t you? Now finish the job and log it before the food coma hits.',
        'Out of sight, out of log, right onto your gut. Tap to log your last meal immediately.',
        'Respect the process, log the macros. Don\'t let a missing entry sabotage your hard work.',
        'Is that meal secretly recorded, or are you waiting for WMacroFactor to read your mind? Tap to log!'
    };

    // ── Schedulable ───────────────────────────────────────────────────────────
    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new WMF_MealReminderBatch(), 50);
    }

    // Convenience: schedule the batch to run every 2 hours (12 jobs covering 0–22h).
    // Call once from Anonymous Apex:  WMF_MealReminderBatch.scheduleHourly();
    public static void scheduleHourly() {
        for (Integer h = 0; h <= 22; h += 2) {
            String name = 'WMF Meal Reminder h' + h;
            String cron = '0 0 ' + h + ' * * ?';
            // Abort any existing job with the same name before rescheduling
            for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :name]) {
                System.abortJob(ct.Id);
            }
            System.schedule(name, cron, new WMF_MealReminderBatch());
        }
    }

    // ── Batchable: start ──────────────────────────────────────────────────────
    // Scope: every Nutrition Profile whose linked User has an email address.
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        return Database.getQueryLocator([
            SELECT Id, Name, User__c, User__r.Email, Last_Meal_Reminder_Sent__c
            FROM Nutrition_Profile__c
            WHERE User__r.Email != null
        ]);
    }

    // ── Batchable: execute ────────────────────────────────────────────────────
    public void execute(Database.BatchableContext ctx, List<Nutrition_Profile__c> profiles) {
        Datetime cutoff = Datetime.now().addHours(-REMINDER_HOURS);
        Set<Id> profileIds = (new Map<Id, Nutrition_Profile__c>(profiles)).keySet();

        // Most-recent meal datetime per profile (any status — a pending meal still counts)
        Map<Id, Datetime> lastMealMap = new Map<Id, Datetime>();
        for (AggregateResult ar : [
            SELECT Nutrition_Profile__c pid, MAX(Logged_DateTime__c) lastMeal
            FROM Meal__c
            WHERE Nutrition_Profile__c IN :profileIds
            GROUP BY Nutrition_Profile__c
        ]) {
            lastMealMap.put((Id) ar.get('pid'), (Datetime) ar.get('lastMeal'));
        }

        Id notifTypeId = getNotifTypeId();

        List<Messaging.SingleEmailMessage> emailQueue  = new List<Messaging.SingleEmailMessage>();
        List<Nutrition_Profile__c>         toUpdate    = new List<Nutrition_Profile__c>();

        for (Nutrition_Profile__c p : profiles) {
            Datetime lastMeal = lastMealMap.get(p.Id);

            // No meals ever, or last meal is still within the 15-hour window — skip
            if (lastMeal == null || lastMeal >= cutoff) continue;

            // Already sent a reminder for this meal cycle — skip
            if (p.Last_Meal_Reminder_Sent__c != null && p.Last_Meal_Reminder_Sent__c > lastMeal) continue;

            String msg = randomMessage();

            // Bell (in-app) notification
            if (p.User__c != null && notifTypeId != null) {
                sendBellNotification(notifTypeId, p.User__c, p.Id, msg);
            }

            // Email notification
            emailQueue.add(buildEmail(p.User__r.Email, p.Name, msg));

            toUpdate.add(new Nutrition_Profile__c(
                Id = p.Id,
                Last_Meal_Reminder_Sent__c = Datetime.now()
            ));
        }

        if (!emailQueue.isEmpty()) {
            Messaging.sendEmail(emailQueue, false); // allOrNothing = false
        }
        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }
    }

    public void finish(Database.BatchableContext ctx) { }

    // ── Private helpers ───────────────────────────────────────────────────────

    private static String randomMessage() {
        return MESSAGES[(Integer) Math.floor(Math.random() * MESSAGES.size())];
    }

    private static Id getNotifTypeId() {
        List<CustomNotificationType> types = [
            SELECT Id FROM CustomNotificationType
            WHERE DeveloperName = 'WMF_MealReminder'
            LIMIT 1
        ];
        return types.isEmpty() ? null : types[0].Id;
    }

    private static void sendBellNotification(Id typeId, Id userId, Id targetId, String message) {
        try {
            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(typeId);
            n.setTitle('⏰ WMacroFactor — Meal Reminder');
            n.setBody(message);
            n.setTargetId(targetId);
            n.send(new Set<String>{ (String) userId });
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Bell notification failed: ' + e.getMessage());
        }
    }

    // Email layout lives in WMF_MealReminderHelper so every reminder path looks the same.
    private static Messaging.SingleEmailMessage buildEmail(String addr, String name, String msg) {
        return WMF_MealReminderHelper.buildReminderEmail(addr, name, msg);
    }
}