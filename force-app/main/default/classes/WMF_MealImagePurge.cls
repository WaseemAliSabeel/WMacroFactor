// Daily storage-hygiene job: deletes the photo files linked to Meal__c records
// that are already Analyzed and older than the retention window, so image
// storage doesn't accumulate indefinitely. The nutrient data stays on the Meal;
// only the (large) image ContentDocuments are removed.
//
// Runs WITHOUT SHARING + SYSTEM_MODE by design: this is a background maintenance
// job that must reclaim files across all users' meals regardless of record
// sharing — consistent with WMF_MealRetrySweep / WMF_MealAnalysisQueueable.
public without sharing class WMF_MealImagePurge implements Database.Batchable<SObject>, Schedulable {

    public static final String JOB_NAME  = 'WMF Meal Image Purge (Daily)';
    public static final String CRON_DAILY = '0 0 2 * * ?'; // 02:00 every day

    // Days of recent meal images to keep. Files for Analyzed meals older than
    // this are purged. TestVisible so tests can assert boundary behaviour.
    @TestVisible
    private static Integer RETENTION_DAYS = 5;

    // ── Schedulable entry point: launch the batch ───────────────────────────
    // WHAT: scheduled trigger that kicks off the purge. HOW: submits this class as a
    // batch job with a 200-record scope size (the class is both Schedulable and Batchable).
    public void execute(SchedulableContext sc) {
        Database.executeBatch(this, 200);
    }

    // ── Batch start: Analyzed meals older than the retention window ─────────
    // WHAT: selects the meals whose photos are eligible for purge. HOW: returns a
    // QueryLocator for Analyzed meals logged before now minus RETENTION_DAYS.
    public Database.QueryLocator start(Database.BatchableContext bc) {
        Datetime cutoff = System.now().addDays(-RETENTION_DAYS);
        return Database.getQueryLocator([
            SELECT Id
            FROM Meal__c
            WHERE Status__c = 'Analyzed'
            AND Logged_DateTime__c < :cutoff
            WITH SYSTEM_MODE
        ]);
    }

    // WHAT: for each batch chunk, deletes the photo files linked to the in-scope meals.
    // HOW: collects meal Ids, finds their ContentDocumentLinks, dedupes into a set of
    // ContentDocument Ids, and deletes those documents (which removes versions + links
    // and reclaims storage) with allOrNone=false so one locked file can't fail the chunk.
    public void execute(Database.BatchableContext bc, List<Meal__c> scope) {
        // Derive the meal Id set from the scope via a Map keyset (cheap, no extra SOQL)
        Set<Id> mealIds = new Map<Id, Meal__c>(scope).keySet();

        // Files linked to these meals
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :mealIds
            WITH SYSTEM_MODE
        ];
        if (links.isEmpty()) {
            return;
        }

        // Dedupe the linked document Ids (a doc could be linked more than once)
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink l : links) {
            docIds.add(l.ContentDocumentId);
        }

        // Deleting the ContentDocument removes the file, all its versions and
        // links in one shot. We then immediately empty the Recycle Bin for every
        // successfully deleted document so storage is freed right away rather
        // than held until the bin is manually or automatically cleared.
        List<ContentDocument> docs = [
            SELECT Id FROM ContentDocument WHERE Id IN :docIds WITH SYSTEM_MODE
        ];
        if (docs.isEmpty()) return;

        // allOrNone = false: a single locked/undeletable file must not abort the chunk.
        List<Database.DeleteResult> delResults = Database.delete(docs, false);

        // Collect only the Ids that were actually soft-deleted so the Recycle Bin
        // call doesn't choke on records that failed to delete.
        List<Id> deletedIds = new List<Id>();
        for (Integer i = 0; i < delResults.size(); i++) {
            if (delResults[i].isSuccess()) {
                deletedIds.add(docs[i].Id);
            }
        }

        // Hard-purge from the Recycle Bin — this is what actually frees storage.
        if (!deletedIds.isEmpty()) {
            Database.emptyRecycleBin(deletedIds);
        }
    }

    // Batch completion hook — no post-processing (no chaining, notifications, or cleanup) needed.
    public void finish(Database.BatchableContext bc) {
        // No post-processing needed.
    }

    // Registers the daily 02:00 purge as a scheduled job under JOB_NAME.
    // ── Register the daily schedule. Run once: WMF_MealImagePurge.scheduleDaily();
    public static void scheduleDaily() {
        System.schedule(JOB_NAME, CRON_DAILY, new WMF_MealImagePurge());
    }
}