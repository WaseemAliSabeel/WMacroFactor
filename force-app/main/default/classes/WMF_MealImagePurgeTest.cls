@IsTest
private class WMF_MealImagePurgeTest {

    // Creates a Nutrition_Profile__c for tests that insert Meal__c directly —
    // Nutrition_Profile__c is a master-detail parent, so every Meal__c needs one.
    private static Id testProfileId() {
        Nutrition_Profile__c p = new Nutrition_Profile__c(User__c = UserInfo.getUserId());
        insert p;
        return p.Id;
    }

    // Create a meal and attach a photo (ContentVersion auto-creates the
    // ContentDocument + ContentDocumentLink).
    private static Meal__c mealWithPhoto(String status, Integer daysAgo) {
        Meal__c m = new Meal__c(
            Status__c            = status,
            Logged_DateTime__c   = System.now().addDays(-daysAgo),
            Nutrition_Profile__c = testProfileId()
        );
        insert m;
        ContentVersion cv = new ContentVersion(
            Title                  = 'Meal ' + daysAgo,
            PathOnClient           = 'meal.jpg',
            FirstPublishLocationId = m.Id,
            VersionData            = Blob.valueOf('imagebytes'),
            IsMajorVersion         = true
        );
        insert cv;
        return m;
    }

    // Returns how many files are currently linked to the given meal.
    private static Integer linkedDocCount(Id mealId) {
        return [
            SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :mealId
        ];
    }

    // Verifies the purge deletes only old Analyzed meal files, keeping recent and non-Analyzed ones.
    @IsTest
    static void testPurgeDeletesOldAnalyzedFilesOnly() {
        // Older than retention (3 days) AND Analyzed → should be purged
        Meal__c oldAnalyzed = mealWithPhoto('Analyzed', 5);
        // Recent Analyzed → keep (within retention window)
        Meal__c recentAnalyzed = mealWithPhoto('Analyzed', 1);
        // Old but not Analyzed → keep (photo still needed for analysis retry)
        Meal__c oldPending = mealWithPhoto('Analysis Pending', 5);

        // Sanity: each meal has exactly one file before the purge
        System.assertEquals(1, linkedDocCount(oldAnalyzed.Id), 'Old analyzed meal starts with a file');
        System.assertEquals(1, linkedDocCount(recentAnalyzed.Id), 'Recent meal starts with a file');
        System.assertEquals(1, linkedDocCount(oldPending.Id), 'Old pending meal starts with a file');

        Test.startTest();
        // Exercise the Schedulable entry point, which launches the batch;
        // the batch runs synchronously at stopTest.
        new WMF_MealImagePurge().execute((SchedulableContext) null);
        Test.stopTest();

        System.assertEquals(0, linkedDocCount(oldAnalyzed.Id),
            'Old Analyzed meal file must be deleted');
        System.assertEquals(1, linkedDocCount(recentAnalyzed.Id),
            'Recent meal file must be kept (within retention window)');
        System.assertEquals(1, linkedDocCount(oldPending.Id),
            'Non-Analyzed meal file must be kept');
    }

    // Verifies the batch purges files across 200 old Analyzed meals without governor issues.
    @IsTest
    static void testBulkPurge() {
        Id profileId = testProfileId();
        List<Meal__c> meals = new List<Meal__c>();
        for (Integer i = 0; i < 200; i++) {
            meals.add(new Meal__c(Status__c = 'Analyzed', Logged_DateTime__c = System.now().addDays(-10), Nutrition_Profile__c = profileId));
        }
        insert meals;

        List<ContentVersion> cvs = new List<ContentVersion>();
        for (Meal__c m : meals) {
            cvs.add(new ContentVersion(
                Title = 'Bulk', PathOnClient = 'm.jpg',
                FirstPublishLocationId = m.Id,
                VersionData = Blob.valueOf('x'), IsMajorVersion = true
            ));
        }
        insert cvs;

        Set<Id> mealIds = new Map<Id, Meal__c>(meals).keySet();

        Test.startTest();
        Database.executeBatch(new WMF_MealImagePurge(), 200);
        Test.stopTest();

        Integer remaining = [
            SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId IN :mealIds
        ];
        System.assertEquals(0, remaining, 'All old Analyzed meal files should be purged in bulk');
    }

    // Verifies scheduleDaily registers the daily cron job (tolerating a pre-existing one).
    @IsTest
    static void testScheduleDaily() {
        Test.startTest();
        try {
            WMF_MealImagePurge.scheduleDaily();
        } catch (Exception e) {
            // Tolerate a pre-existing live job of the same name in the target org;
            // the assertion below still verifies the schedule is in place.
            System.assert(
                e.getMessage().containsIgnoreCase('already scheduled'),
                'Only an already-scheduled collision is acceptable, got: ' + e.getMessage()
            );
        }
        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT Id FROM CronTrigger
            WHERE CronJobDetail.Name = :WMF_MealImagePurge.JOB_NAME
        ];
        System.assert(!jobs.isEmpty(), 'Daily purge job should be scheduled');
    }
}