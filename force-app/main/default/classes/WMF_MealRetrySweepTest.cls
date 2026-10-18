@IsTest
private class WMF_MealRetrySweepTest {

    // Builds a valid Gemini generateContent JSON body wrapping the given macros as part text.
    private static String geminiBody(Map<String, Object> macros) {
        String macroJson = JSON.serialize(macros);
        return JSON.serialize(new Map<String, Object>{
            'candidates' => new List<Object>{
                new Map<String, Object>{
                    'content' => new Map<String, Object>{
                        'parts' => new List<Object>{
                            new Map<String, Object>{ 'text' => macroJson }
                        }
                    }
                }
            }
        });
    }

    // Mocks a valid 200 response with a complete, balanced macro set.
    private class SuccessMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(200);
            res.setBody(geminiBody(new Map<String, Object>{
                'calories' => 400, 'carbs_g' => 50, 'protein_g' => 30, 'fat_g' => 15,
                'carbs_pct' => 48, 'protein_pct' => 29, 'fat_pct' => 23,
                'meal_observations' => 'This looks like a balanced pasta dish with protein and vegetables. It provides a good energy mix though slightly high in carbohydrates.'
            }));
            return res;
        }
    }

    // Mocks an HTTP 503 (Service Unavailable) error response.
    private class FailMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(503);
            res.setStatus('Service Unavailable');
            res.setBody('{}');
            return res;
        }
    }

    // Creates a Nutrition_Profile__c for tests that insert Meal__c directly —
    // Nutrition_Profile__c is a master-detail parent, so every Meal__c needs one.
    private static Id testProfileId() {
        Nutrition_Profile__c p = new Nutrition_Profile__c(User__c = UserInfo.getUserId());
        insert p;
        return p.Id;
    }

    // Inserts an Analysis Pending meal with notes and the given prior attempt count.
    // No ContentVersion is created so tests never hit the org's daily ContentPublication
    // quota. The HttpCalloutMock drives the Gemini response; notes-only analysis is valid.
    private static Meal__c createPendingMeal(Integer attemptCount) {
        Meal__c m = new Meal__c(
            Status__c                 = 'Analysis Pending',
            Logged_DateTime__c        = System.now(),
            Analysis_Attempt_Count__c = attemptCount,
            Meal_Notes__c             = 'Test meal',
            Nutrition_Profile__c      = testProfileId()
        );
        insert m;
        return m;
    }

    // Verifies a successful retry marks the meal Analyzed and increments the attempt count.
    @IsTest
    static void testRetrySucceeds() {
        Meal__c m = createPendingMeal(1);
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        WMF_MealRetrySweep.BATCH_SIZE = 1;
        Test.startTest();
        new WMF_MealRetrySweep().execute(null);
        Test.stopTest();

        Meal__c updated = [SELECT Status__c, Calories__c, Analysis_Attempt_Count__c, Last_Analysis_Outcome__c
                           FROM Meal__c WHERE Id = :m.Id];
        System.assertEquals('Analyzed', updated.Status__c, 'Meal should be Analyzed after successful retry');
        System.assertEquals(400, updated.Calories__c, 'Calories should be populated');
        System.assertEquals(2, updated.Analysis_Attempt_Count__c, 'Attempt count should increment to 2');
        System.assertEquals('Success', updated.Last_Analysis_Outcome__c, 'Outcome should be Success');
    }

    // Verifies a failed retry stays Analysis Pending, increments attempts, and records the error.
    @IsTest
    static void testRetryFailsAndIncrements() {
        Meal__c m = createPendingMeal(2);
        Test.setMock(HttpCalloutMock.class, new FailMock());

        WMF_MealRetrySweep.BATCH_SIZE = 1;
        Test.startTest();
        new WMF_MealRetrySweep().execute(null);
        Test.stopTest();

        Meal__c updated = [SELECT Status__c, Calories__c, Analysis_Attempt_Count__c, Last_Analysis_Outcome__c, Last_Analysis_Error__c
                           FROM Meal__c WHERE Id = :m.Id];
        System.assertEquals('Analysis Pending', updated.Status__c, 'Status should remain Analysis Pending');
        System.assertEquals(0, updated.Calories__c, 'Calories should remain 0');
        System.assertEquals(3, updated.Analysis_Attempt_Count__c, 'Attempt count should increment to 3');
        System.assertEquals('Failed', updated.Last_Analysis_Outcome__c, 'Outcome should be Failed');
        System.assert(String.isNotBlank(updated.Last_Analysis_Error__c), 'Error message should be recorded');
    }

    // Verifies a meal at the max attempt count (5) is skipped and left untouched by the sweep.
    @IsTest
    static void testAttemptCountAt5NotRetried() {
        Meal__c m = new Meal__c(
            Status__c                 = 'Analysis Pending',
            Logged_DateTime__c        = System.now(),
            Analysis_Attempt_Count__c = 5,
            Nutrition_Profile__c      = testProfileId()
        );
        insert m;

        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        WMF_MealRetrySweep.BATCH_SIZE = 10;
        Test.startTest();
        new WMF_MealRetrySweep().execute(null);
        Test.stopTest();

        Meal__c unchanged = [SELECT Status__c, Analysis_Attempt_Count__c FROM Meal__c WHERE Id = :m.Id];
        System.assertEquals('Analysis Pending', unchanged.Status__c,
            'Meal at max attempts must not be touched by sweep');
        System.assertEquals(5, unchanged.Analysis_Attempt_Count__c,
            'Attempt count must not change for maxed-out meal');
    }

    // Verifies scheduleHourly registers exactly one scheduled sweep job.
    @IsTest
    static void testScheduleHourly() {
        Test.startTest();
        WMF_MealRetrySweep.scheduleHourly();
        Test.stopTest();

        List<CronTrigger> jobs = [SELECT CronJobDetail.Name FROM CronTrigger
                                  WHERE CronJobDetail.Name = :WMF_MealRetrySweep.JOB_NAME];
        System.assertEquals(1, jobs.size(), 'Exactly one scheduled job should be registered');
    }

    // Verifies reschedule registers three staggered 20-minute sweep jobs.
    @IsTest
    static void testReschedule() {
        Test.startTest();
        WMF_MealRetrySweep.reschedule();
        Test.stopTest();

        List<CronTrigger> jobs = [SELECT CronJobDetail.Name FROM CronTrigger
                                  WHERE CronJobDetail.Name LIKE 'WMF Meal Retry :%'];
        System.assertEquals(3, jobs.size(), 'Reschedule should register three 20-minute jobs');
    }
}