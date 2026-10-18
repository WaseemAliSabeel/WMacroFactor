// Scheduled Apex sweep that finds Analysis Pending meals and enqueues a
// WMF_MealAnalysisQueueable per meal. Scheduled Apex cannot make callouts
// directly — the Queueable (which implements Database.AllowsCallouts) does
// the actual Gemini callout and DML update.
public without sharing class WMF_MealRetrySweep implements Schedulable {

    public static final String CRON_HOURLY = '0 0 * * * ?';
    public static final String JOB_NAME   = 'WMF Meal Analysis Retry Sweep';
    // Salesforce requires single-integer cron minutes; achieve ~20-min frequency with 3 named jobs
    private static final List<String> CRON_20_MIN = new List<String>{
        '0 0 * * * ?', '0 20 * * * ?', '0 40 * * * ?'
    };
    private static final List<String> JOB_NAMES_20_MIN = new List<String>{
        'WMF Meal Retry :00', 'WMF Meal Retry :20', 'WMF Meal Retry :40'
    };

    // Max meals processed per sweep run. Developer Edition has low volume;
    // raise this in full production and consider Queueable-per-meal for large batches
    // to avoid reading many VersionData blobs into a single heap.
    @TestVisible
    private static Integer BATCH_SIZE = 20;

    // WHAT: scheduled entry point that retries stuck meal analyses.
    // HOW: queries up to BATCH_SIZE oldest "Analysis Pending" meals with fewer than 5
    // attempts, then enqueues one WMF_MealAnalysisQueueable per meal to do the callout+DML.
    public void execute(SchedulableContext sc) {
        List<Meal__c> pendingMeals = [
            SELECT Id
            FROM Meal__c
            WHERE Status__c = 'Analysis Pending'
            AND Analysis_Attempt_Count__c < 5
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC
            LIMIT :BATCH_SIZE
        ];
        // Enqueue one Queueable per meal — each handles its own callout + DML
        for (Meal__c m : pendingMeals) {
            System.enqueueJob(new WMF_MealAnalysisQueueable(m.Id));
        }
    }

    // Register ~20-minute schedule (3 named jobs at :00, :20, :40).
    // WHAT: (re)installs the ~20-minute retry schedule. HOW: aborts any existing
    // "WMF Meal Ret%" CronTriggers, then schedules the three named jobs.
    // Salesforce cron requires single-integer minutes — increment syntax not supported.
    // Run once: WMF_MealRetrySweep.reschedule();
    public static void reschedule() {
        // Abort old single-name job if exists
        for (CronTrigger ct : [SELECT Id FROM CronTrigger
                               WHERE CronJobDetail.Name LIKE 'WMF Meal Ret%']) {
            System.abortJob(ct.Id);
        }
        for (Integer i = 0; i < CRON_20_MIN.size(); i++) {
            System.schedule(JOB_NAMES_20_MIN[i], CRON_20_MIN[i], new WMF_MealRetrySweep());
        }
    }

    // Convenience alternative to reschedule(): registers a single hourly job.
    public static void scheduleHourly() {
        System.schedule(JOB_NAME, CRON_HOURLY, new WMF_MealRetrySweep());
    }
}