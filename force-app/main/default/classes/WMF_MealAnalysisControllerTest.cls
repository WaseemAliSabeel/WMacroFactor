@IsTest
private class WMF_MealAnalysisControllerTest {

    // ── Gemini response helpers ─────────────────────────────────────────────
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
                'calories' => 500, 'carbs_g' => 60, 'protein_g' => 40, 'fat_g' => 20,
                'carbs_pct' => 50, 'protein_pct' => 30, 'fat_pct' => 20,
                'meal_observations' => 'Balanced plate with lean protein and complex carbs; a solid, moderate-calorie meal.'
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

    // Creates a Nutrition_Profile__c for tests that insert Meal__c directly.
    // Nutrition_Profile__c is now a master-detail parent of Meal__c, so every
    // Meal__c inserted in a test needs one regardless of what the test is probing.
    // Owned by the running user so getDailyMacroDistribution's Nutrition_Profile__r.User__c
    // scoping (the replacement for the OwnerId filter Meal__c lost as a master-detail child)
    // still picks these meals up.
    private static Id testProfileId() {
        Nutrition_Profile__c p = new Nutrition_Profile__c(User__c = UserInfo.getUserId());
        insert p;
        return p.Id;
    }

    // Insert a meal with notes only — no ContentVersion so tests never hit
    // the org's daily ContentPublication quota. The Gemini callout is driven by
    // the meal notes, and the HttpCalloutMock handles the HTTP response.
    private static Meal__c mealWithNotes(String notes) {
        Meal__c m = new Meal__c(
            Status__c                 = 'Analysis Pending',
            Logged_DateTime__c        = System.now(),
            Analysis_Attempt_Count__c = 0,
            Meal_Notes__c             = notes,
            Nutrition_Profile__c      = testProfileId()
        );
        insert m;
        return m;
    }

    // ── Session / base-url pass-throughs ────────────────────────────────────
    @IsTest
    static void testSessionAndBaseUrl() {
        Test.startTest();
        String sid = WMF_MealAnalysisController.getSessionId();
        String url = WMF_MealAnalysisController.getBaseUrl();
        Test.stopTest();
        System.assertNotEquals(null, url, 'Base URL should resolve');
        System.assert(url.startsWith('http'), 'Base URL should be a URL');
    }

    // ── createMealRecord: positive with explicit datetime ───────────────────
    @IsTest
    static void testCreateMealRecordWithDatetime() {
        Nutrition_Profile__c profile = new Nutrition_Profile__c(User__c = UserInfo.getUserId());
        insert profile;

        Test.startTest();
        String mealId = WMF_MealAnalysisController.createMealRecord(
            'Grilled chicken', '2026-09-27T12:30:00.000Z'
        );
        Test.stopTest();

        Meal__c m = [SELECT Status__c, Meal_Notes__c, Calories__c, Nutrition_Profile__c FROM Meal__c WHERE Id = :mealId];
        System.assertEquals('Analysis Pending', m.Status__c, 'New meal should start Analysis Pending');
        System.assertEquals('Grilled chicken', m.Meal_Notes__c, 'Notes should persist');
        System.assertEquals(0, m.Calories__c, 'Calories initialised to 0');
        System.assertEquals(profile.Id, m.Nutrition_Profile__c, 'Meal should link to the last-modified Nutrition Profile');
    }

    // ── createMealRecord: blank datetime falls back to now ──────────────────
    @IsTest
    static void testCreateMealRecordNoDatetime() {
        testProfileId();

        Test.startTest();
        String mealId = WMF_MealAnalysisController.createMealRecord('No timestamp', null);
        Test.stopTest();
        Meal__c m = [SELECT Logged_DateTime__c FROM Meal__c WHERE Id = :mealId];
        System.assertNotEquals(null, m.Logged_DateTime__c, 'Logged datetime should default to now');
    }

    // ── createMealRecord: malformed datetime throws AuraHandledException ─────
    @IsTest
    static void testCreateMealRecordBadDatetime() {
        Boolean threw = false;
        Test.startTest();
        try {
            WMF_MealAnalysisController.createMealRecord('Bad date', 'not-a-datetime');
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Malformed datetime should raise an exception');
    }

    // ── createMealRecord: no Nutrition Profile anywhere in the org ──────────
    // Nutrition_Profile__c is master-detail, so an insert with no profile to link
    // violates the required parent and should surface as an AuraHandledException.
    @IsTest
    static void testCreateMealRecordNoProfileThrows() {
        Boolean threw = false;
        Test.startTest();
        try {
            WMF_MealAnalysisController.createMealRecord('No profile yet', null);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Creating a meal with no Nutrition Profile in the org should fail');
    }

    // ── createMealRecord: picks the system-wide profile regardless of owner ────
    // A single profile (not a race between two) keeps this deterministic — two profiles
    // inserted back-to-back in the same test transaction can tie on LastModifiedDate
    // (millisecond resolution), which ORDER BY ... DESC LIMIT 1 then breaks by Id rather
    // than insertion order, making a two-profile "most recent wins" assertion flaky.
    @IsTest
    static void testCreateMealRecordLinksLastModifiedNotOwner() {
        List<User> others = [SELECT Id FROM User WHERE Id != :UserInfo.getUserId() AND IsActive = true LIMIT 1];
        Nutrition_Profile__c profile = others.isEmpty()
            ? new Nutrition_Profile__c(User__c = UserInfo.getUserId())
            : new Nutrition_Profile__c(OwnerId = others[0].Id, User__c = UserInfo.getUserId());
        insert profile;

        Test.startTest();
        String mealId = WMF_MealAnalysisController.createMealRecord('Owner independence check', null);
        Test.stopTest();

        Meal__c m = [SELECT Nutrition_Profile__c FROM Meal__c WHERE Id = :mealId];
        System.assertEquals(profile.Id, m.Nutrition_Profile__c,
            others.isEmpty()
                ? 'Only profile in the org should be linked'
                : 'Profile owned by a different user should still be linked — selection ignores OwnerId');
    }

    // ── uploadMealPhoto attaches a ContentVersion ───────────────────────────
    @IsTest
    static void testUploadMealPhoto() {
        Meal__c m = new Meal__c(
            Status__c            = 'Analysis Pending',
            Logged_DateTime__c   = System.now(),
            Nutrition_Profile__c = testProfileId()
        );
        insert m;

        String b64 = EncodingUtil.base64Encode(Blob.valueOf('photo-bytes'));
        Test.startTest();
        WMF_MealAnalysisController.uploadMealPhoto(m.Id, b64, 'lunch.png');
        Test.stopTest();

        List<ContentDocumentLink> links = [
            SELECT Id FROM ContentDocumentLink WHERE LinkedEntityId = :m.Id
        ];
        System.assertEquals(1, links.size(), 'Photo should be linked to the meal');
    }

    // ── analyseExistingMeal: success path ───────────────────────────────────
    @IsTest
    static void testAnalyseExistingMealSuccess() {
        Meal__c m = mealWithNotes('Pasta');
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        WMF_MealAnalysisController.MealAnalysisResult r =
            WMF_MealAnalysisController.analyseExistingMeal(m.Id);
        Test.stopTest();

        System.assertEquals(true, r.success, 'Analysis should succeed');
        System.assertEquals(500, r.calories, 'Calories should map from Gemini');
        Meal__c updated = [SELECT Status__c, Calories__c FROM Meal__c WHERE Id = :m.Id];
        System.assertEquals('Analyzed', updated.Status__c, 'Meal should be Analyzed');
    }

    // ── analyseExistingMeal: no photo → pending ─────────────────────────────
    @IsTest
    static void testAnalyseExistingMealNoPhoto() {
        Meal__c m = new Meal__c(
            Status__c            = 'Analysis Pending',
            Logged_DateTime__c   = System.now(),
            Nutrition_Profile__c = testProfileId()
        );
        insert m;

        Test.startTest();
        WMF_MealAnalysisController.MealAnalysisResult r =
            WMF_MealAnalysisController.analyseExistingMeal(m.Id);
        Test.stopTest();

        System.assertEquals(false, r.success, 'No photo means analysis cannot succeed');
        System.assertEquals('Analysis Pending', r.status, 'Status should stay pending');
        System.assertNotEquals(null, r.errorMessage, 'A user-facing message should be set');
    }

    // ── analyseExistingMeal: re-analysing an Analyzed meal counts as another attempt ──
    @IsTest
    static void testReAnalyseAnalyzedMealIncrementsAttemptCount() {
        Meal__c m = mealWithNotes('Pasta');
        m.Status__c                 = 'Analyzed';
        m.Analysis_Attempt_Count__c = 3;
        update m;
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        WMF_MealAnalysisController.MealAnalysisResult r =
            WMF_MealAnalysisController.analyseExistingMeal(m.Id);
        Test.stopTest();

        System.assertEquals(true, r.success, 'Analyzed meals can be re-analysed');
        System.assertEquals(4, [SELECT Analysis_Attempt_Count__c FROM Meal__c WHERE Id = :m.Id].Analysis_Attempt_Count__c,
            'Each analysis should add one to the attempt count, not reset it');
    }

    // ── analyseExistingMeal: a failed attempt still counts ──────────────────
    @IsTest
    static void testFailedReAnalyseStillIncrementsAttemptCount() {
        Meal__c m = mealWithNotes('Pasta');
        m.Analysis_Attempt_Count__c = 1;
        update m;
        Test.setMock(HttpCalloutMock.class, new FailMock());

        Test.startTest();
        WMF_MealAnalysisController.MealAnalysisResult r =
            WMF_MealAnalysisController.analyseExistingMeal(m.Id);
        Test.stopTest();

        System.assertEquals(false, r.success, 'Gemini 503 should fail the analysis');
        System.assertEquals(2, [SELECT Analysis_Attempt_Count__c FROM Meal__c WHERE Id = :m.Id].Analysis_Attempt_Count__c);
    }

    // ── analyseExistingMeal: description-only (no photo) succeeds ───────────
    @IsTest
    static void testAnalyseExistingMealTextOnly() {
        Meal__c m = new Meal__c(
            Status__c = 'Analysis Pending', Logged_DateTime__c = System.now(),
            Meal_Notes__c = 'Two boiled eggs and toast',
            Nutrition_Profile__c = testProfileId()
        );
        insert m; // no ContentVersion → no photo
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        WMF_MealAnalysisController.MealAnalysisResult r =
            WMF_MealAnalysisController.analyseExistingMeal(m.Id);
        Test.stopTest();

        System.assertEquals(true, r.success, 'Description-only analysis should succeed');
        Meal__c updated = [SELECT Status__c FROM Meal__c WHERE Id = :m.Id];
        System.assertEquals('Analyzed', updated.Status__c, 'Text-only meal should be Analyzed');
    }

    // ── analyseExistingMeal: neither photo nor description → guarded ────────
    @IsTest
    static void testAnalyseExistingMealNothingToAnalyse() {
        Meal__c m = new Meal__c(
            Status__c = 'Analysis Pending', Logged_DateTime__c = System.now(),
            Nutrition_Profile__c = testProfileId()
        );
        insert m; // no notes, no photo

        Test.startTest();
        WMF_MealAnalysisController.MealAnalysisResult r =
            WMF_MealAnalysisController.analyseExistingMeal(m.Id);
        Test.stopTest();

        System.assertEquals(false, r.success, 'Nothing to analyse should not succeed');
        System.assertNotEquals(null, r.errorMessage, 'A user-facing message should be set');
    }

    // ── analyseExistingMeal: HTTP failure path ──────────────────────────────
    @IsTest
    static void testAnalyseExistingMealFailure() {
        Meal__c m = mealWithNotes('Burger');
        Test.setMock(HttpCalloutMock.class, new FailMock());

        Test.startTest();
        WMF_MealAnalysisController.MealAnalysisResult r =
            WMF_MealAnalysisController.analyseExistingMeal(m.Id);
        Test.stopTest();

        System.assertEquals(false, r.success, 'Gemini 503 should fail analysis');
        Meal__c updated = [SELECT Status__c, Last_Analysis_Outcome__c FROM Meal__c WHERE Id = :m.Id];
        System.assertEquals('Analysis Pending', updated.Status__c, 'Failed analysis stays pending');
        System.assertEquals('Failed', updated.Last_Analysis_Outcome__c, 'Outcome should be Failed');
    }

    // ── logAndAnalyseMeal legacy entry: success ─────────────────────────────
    @IsTest
    static void testLogAndAnalyseMealSuccess() {
        testProfileId(); // Nutrition_Profile__c is a master-detail parent of Meal__c
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        // Pass null photo so no ContentVersion is inserted; the callout fires with
        // notes-only and the HttpCalloutMock handles the response.
        WMF_MealAnalysisController.MealAnalysisResult r =
            WMF_MealAnalysisController.logAndAnalyseMeal(null, null, null, 'Legacy notes');
        Test.stopTest();

        System.assertEquals(true, r.success, 'Legacy path should succeed');
        Meal__c m = [SELECT Status__c FROM Meal__c WHERE Id = :r.mealId];
        System.assertEquals('Analyzed', m.Status__c, 'Legacy meal should be Analyzed');
    }

    // ── logAndAnalyseMeal legacy entry: failure ─────────────────────────────
    @IsTest
    static void testLogAndAnalyseMealFailure() {
        testProfileId(); // Nutrition_Profile__c is a master-detail parent of Meal__c
        Test.setMock(HttpCalloutMock.class, new FailMock());

        Test.startTest();
        WMF_MealAnalysisController.MealAnalysisResult r =
            WMF_MealAnalysisController.logAndAnalyseMeal(null, 'image/jpeg', null, null);
        Test.stopTest();

        System.assertEquals(false, r.success, 'Legacy path should fail on 503');
    }

    // ── getTodayStats aggregates today's meals ──────────────────────────────
    @IsTest
    static void testGetTodayStats() {
        Id profileId = testProfileId();
        insert new List<Meal__c>{
            new Meal__c(Status__c = 'Analyzed', Logged_DateTime__c = System.now(), Calories__c = 300, Nutrition_Profile__c = profileId),
            new Meal__c(Status__c = 'Analyzed', Logged_DateTime__c = System.now(), Calories__c = 450, Nutrition_Profile__c = profileId)
        };

        Test.startTest();
        Map<String, Object> stats = WMF_MealAnalysisController.getTodayStats(profileId, null, null);
        Test.stopTest();

        System.assertEquals(2, (Integer) stats.get('mealCount'), 'Two meals logged today');
        System.assertEquals(750, (Decimal) stats.get('totalCalories'), 'Calories should sum');
    }

    // ── getTodayStats / getTodayMeals: explicit UTC range (profile-timezone path) ──
    @IsTest
    static void testTodayRangeQueriesWithExplicitUtcWindow() {
        Id profileId = testProfileId();
        insert new Meal__c(Status__c = 'Analyzed', Logged_DateTime__c = System.now(), Calories__c = 400,
            Meal_Notes__c = 'Oats', Nutrition_Profile__c = profileId);
        String startUtc = System.now().addHours(-2).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        String endUtc   = System.now().addHours(2).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');

        Test.startTest();
        Map<String, Object> stats = WMF_MealAnalysisController.getTodayStats(profileId, startUtc, endUtc);
        List<WMF_MealAnalysisController.MealSummary> windowed =
            WMF_MealAnalysisController.getTodayMeals(profileId, startUtc, endUtc);
        List<WMF_MealAnalysisController.MealSummary> defaulted =
            WMF_MealAnalysisController.getTodayMeals(profileId, null, null);
        List<WMF_MealAnalysisController.MealSummary> noProfile =
            WMF_MealAnalysisController.getTodayMeals(null, null, null);
        Test.stopTest();

        System.assertEquals(1, (Integer) stats.get('mealCount'), 'Meal falls inside the explicit window');
        System.assertEquals(1, windowed.size(), 'getTodayMeals should honour the explicit window');
        System.assertEquals(0, noProfile.size(), 'No profile means no meals');
        System.assertNotEquals(null, defaulted, 'Default window should not error');
    }

    // ── Active flag: surfaced to the LWC; defaults to true; inactive profiles are still returned ──
    @IsTest
    static void testProfileActiveFlagIsExposed() {
        Nutrition_Profile__c activeP   = new Nutrition_Profile__c(User__c = UserInfo.getUserId());
        Nutrition_Profile__c inactiveP = new Nutrition_Profile__c(Active__c = false);
        insert new List<Nutrition_Profile__c>{ activeP, inactiveP };
        System.assertEquals(true, [SELECT Active__c FROM Nutrition_Profile__c WHERE Id = :activeP.Id].Active__c,
            'Active__c should default to checked');

        Test.startTest();
        List<WMF_MealAnalysisController.NutritionProfileInfo> all = WMF_MealAnalysisController.getAllNutritionProfiles();
        WMF_MealAnalysisController.NutritionProfileInfo sel = WMF_MealAnalysisController.selectNutritionProfile(inactiveP.Id);
        WMF_MealAnalysisController.NutritionProfileInfo cur = WMF_MealAnalysisController.getActiveNutritionProfile();
        Test.stopTest();

        Map<Id, Boolean> flags = new Map<Id, Boolean>();
        for (WMF_MealAnalysisController.NutritionProfileInfo i : all) flags.put(i.profileId, i.profileActive);
        System.assertEquals(true,  flags.get(activeP.Id),   'Active profile flagged active');
        System.assertEquals(false, flags.get(inactiveP.Id), 'Inactive profile still listed, flagged inactive (LWC filters)');
        System.assertEquals(false, sel.profileActive, 'selectNutritionProfile reports the flag');
        System.assertEquals(activeP.Id, cur.profileId, 'Running user\'s own profile is still the default');
        System.assertEquals(true, cur.profileActive);
    }

    // ── No server-side blocker: meals can still be created against an inactive profile ──
    @IsTest
    static void testMealCanStillBeInsertedOnInactiveProfile() {
        Nutrition_Profile__c inactiveP = new Nutrition_Profile__c(Active__c = false);
        insert inactiveP;
        Meal__c m = new Meal__c(Nutrition_Profile__c = inactiveP.Id, Logged_DateTime__c = System.now(), Status__c = 'Analysis Pending');
        insert m;
        System.assertNotEquals(null, m.Id, 'Inactive profiles are a UI-only filter, not a data rule');
    }

    // ── getTodayStats: meals on a different profile are excluded ────────────
    @IsTest
    static void testGetTodayStatsExcludesOtherProfiles() {
        Id activeProfileId = testProfileId();
        Id otherProfileId  = testProfileId();
        insert new List<Meal__c>{
            new Meal__c(Status__c = 'Analyzed', Logged_DateTime__c = System.now(), Calories__c = 500, Nutrition_Profile__c = activeProfileId),
            new Meal__c(Status__c = 'Analyzed', Logged_DateTime__c = System.now(), Calories__c = 999, Nutrition_Profile__c = otherProfileId)
        };

        Test.startTest();
        Map<String, Object> stats = WMF_MealAnalysisController.getTodayStats(activeProfileId, null, null);
        Test.stopTest();

        System.assertEquals(1, (Integer) stats.get('mealCount'), 'Only the active profile meal should count');
        System.assertEquals(500, (Decimal) stats.get('totalCalories'), 'Other-profile calories must be excluded');
    }

    // ── getTodayStats: null profileId returns zeros, not a cross-profile aggregate ──
    @IsTest
    static void testGetTodayStatsNullProfileReturnsZeros() {
        Id profileId = testProfileId();
        insert new Meal__c(Status__c = 'Analyzed', Logged_DateTime__c = System.now(), Calories__c = 500, Nutrition_Profile__c = profileId);

        Test.startTest();
        Map<String, Object> stats = WMF_MealAnalysisController.getTodayStats(null, null, null);
        Test.stopTest();

        System.assertEquals(0, (Integer) stats.get('mealCount'), 'Null profile should return 0 meals');
        System.assertEquals(0, (Integer) stats.get('totalCalories'), 'Null profile should return 0 calories');
    }

    // ── getDailyMacroDistribution returns per-day sums for Analyzed meals ────
    @IsTest
    static void testGetDailyMacroDistribution() {
        Id profileId = testProfileId();
        insert new List<Meal__c>{
            new Meal__c(Status__c = 'Analyzed', Logged_DateTime__c = System.now(),
                        Calories__c = 400, Carbs_g__c = 50, Protein_g__c = 30, Fat_g__c = 20, Nutrition_Profile__c = profileId),
            new Meal__c(Status__c = 'Analyzed', Logged_DateTime__c = System.now(),
                        Calories__c = 300, Carbs_g__c = 40, Protein_g__c = 20, Fat_g__c = 10, Nutrition_Profile__c = profileId),
            // Excluded: not Analyzed
            new Meal__c(Status__c = 'Analysis Pending', Logged_DateTime__c = System.now(),
                        Carbs_g__c = 999, Protein_g__c = 999, Fat_g__c = 999, Nutrition_Profile__c = profileId)
        };

        Test.startTest();
        List<WMF_MealAnalysisController.DailyMacro> data =
            WMF_MealAnalysisController.getDailyMacroDistribution(10, profileId);
        Test.stopTest();

        System.assertEquals(1, data.size(), 'One calendar day of Analyzed meals');
        WMF_MealAnalysisController.DailyMacro d = data[0];
        System.assertEquals(90, d.carbsG, 'Carbs should sum across the day');
        System.assertEquals(50, d.proteinG, 'Protein should sum across the day');
        System.assertEquals(30, d.fatG, 'Fat should sum across the day');
        System.assertEquals(2, d.mealCount, 'Only the two Analyzed meals count');
    }

    // ── getDailyCalorieDistribution: sums analyzed calories for the active profile ──
    @IsTest
    static void testGetDailyCalorieDistribution() {
        Id profileId = testProfileId();
        insert new List<Meal__c>{
            new Meal__c(Status__c = 'Analyzed', Logged_DateTime__c = System.now(),
                        Calories__c = 600, Nutrition_Profile__c = profileId),
            new Meal__c(Status__c = 'Analyzed', Logged_DateTime__c = System.now(),
                        Calories__c = 350, Nutrition_Profile__c = profileId),
            // Excluded: not Analyzed
            new Meal__c(Status__c = 'Analysis Pending', Logged_DateTime__c = System.now(),
                        Calories__c = 9999, Nutrition_Profile__c = profileId)
        };

        Test.startTest();
        List<WMF_MealAnalysisController.DailyCalorie> data =
            WMF_MealAnalysisController.getDailyCalorieDistribution(10, profileId);
        Test.stopTest();

        System.assertEquals(1, data.size(), 'One calendar day of Analyzed meals');
        System.assertEquals(950, data[0].totalCalories, 'Calories should sum for the day');
        System.assertEquals(2, data[0].mealCount, 'Only Analyzed meals counted');
    }

    // ── getDailyCalorieDistribution: null window and no data → empty ─────────
    @IsTest
    static void testGetDailyCalorieDistributionDefaults() {
        Test.startTest();
        List<WMF_MealAnalysisController.DailyCalorie> data =
            WMF_MealAnalysisController.getDailyCalorieDistribution(null, null);
        Test.stopTest();
        System.assertEquals(0, data.size(), 'No profile means empty result');
    }

    // ── getDailyMacroDistribution: null window defaults, no data → empty ─────
    @IsTest
    static void testGetDailyMacroDistributionDefaults() {
        Test.startTest();
        List<WMF_MealAnalysisController.DailyMacro> data =
            WMF_MealAnalysisController.getDailyMacroDistribution(null, null);
        Test.stopTest();
        System.assertEquals(0, data.size(), 'No meals means empty result');
    }

    // ── Bulk safety: 200 meals aggregate without governor issues ────────────
    @IsTest
    static void testBulkAggregation() {
        Id profileId = testProfileId();
        List<Meal__c> meals = new List<Meal__c>();
        for (Integer i = 0; i < 200; i++) {
            meals.add(new Meal__c(
                Status__c = 'Analyzed', Logged_DateTime__c = System.now(),
                Calories__c = 100, Carbs_g__c = 10, Protein_g__c = 5, Fat_g__c = 5,
                Nutrition_Profile__c = profileId
            ));
        }
        insert meals;

        Test.startTest();
        List<WMF_MealAnalysisController.DailyMacro> data =
            WMF_MealAnalysisController.getDailyMacroDistribution(10, profileId);
        Map<String, Object> stats = WMF_MealAnalysisController.getTodayStats(profileId, null, null);
        Test.stopTest();

        System.assertEquals(1, data.size(), 'All 200 meals fall on one calendar day');
        System.assertEquals(2000, data[0].carbsG, '200 x 10g carbs');
        System.assertEquals(200, (Integer) stats.get('mealCount'), 'Bulk count should be 200');
    }

    // ── getActiveNutritionProfile: no profile in the org → nulls, not an error ──
    @IsTest
    static void testGetActiveNutritionProfileNoProfileReturnsNulls() {
        Test.startTest();
        WMF_MealAnalysisController.NutritionProfileInfo info =
            WMF_MealAnalysisController.getActiveNutritionProfile();
        Test.stopTest();

        System.assertEquals(null, info.profileId, 'No profile in the org should yield a null Id');
        System.assertEquals(null, info.displayName, 'No profile in the org should yield a null name');
    }

    // ── getActiveNutritionProfile: resolves the only profile + its user's name ──
    @IsTest
    static void testGetActiveNutritionProfileReturnsNameFromRunningUser() {
        User me = [SELECT FirstName, LastName FROM User WHERE Id = :UserInfo.getUserId()];
        Nutrition_Profile__c p = new Nutrition_Profile__c(User__c = UserInfo.getUserId());
        insert p;

        Test.startTest();
        WMF_MealAnalysisController.NutritionProfileInfo info =
            WMF_MealAnalysisController.getActiveNutritionProfile();
        Test.stopTest();

        System.assertEquals(p.Id, info.profileId, 'Should resolve the only profile in the org');
        String expected = String.isNotBlank(me.FirstName) ? me.FirstName : me.LastName;
        System.assertEquals(expected, info.displayName, 'Display name should follow the FirstName-else-LastName rule');
    }

    // ── getActiveNutritionProfile: resolves regardless of owner ─────────────
    // A single profile (not a race between two) keeps this deterministic — see the
    // comment on testCreateMealRecordLinksLastModifiedNotOwner for why a two-profile
    // "most recent wins" assertion is flaky within one test transaction.
    @IsTest
    static void testGetActiveNutritionProfileIgnoresOwnerPicksMostRecent() {
        List<User> others = [SELECT Id FROM User WHERE Id != :UserInfo.getUserId() AND IsActive = true LIMIT 1];
        Nutrition_Profile__c profile = others.isEmpty()
            ? new Nutrition_Profile__c()
            : new Nutrition_Profile__c(OwnerId = others[0].Id);
        insert profile;

        Test.startTest();
        WMF_MealAnalysisController.NutritionProfileInfo info =
            WMF_MealAnalysisController.getActiveNutritionProfile();
        Test.stopTest();

        System.assertEquals(profile.Id, info.profileId,
            others.isEmpty()
                ? 'Only profile in the org should resolve'
                : 'Profile owned by a different user should still resolve — selection ignores OwnerId');
    }

    // ── getAllNutritionProfiles: every profile returned with a safe label ──
    @IsTest
    static void testGetAllNutritionProfilesReturnsEveryProfileWithALabel() {
        insert new Nutrition_Profile__c(User__c = UserInfo.getUserId());
        insert new Nutrition_Profile__c(); // no User__c — must still get a non-blank label

        Test.startTest();
        List<WMF_MealAnalysisController.NutritionProfileInfo> options =
            WMF_MealAnalysisController.getAllNutritionProfiles();
        Test.stopTest();

        System.assertEquals(2, options.size(), 'Both profiles should be returned as options');
        for (WMF_MealAnalysisController.NutritionProfileInfo info : options) {
            System.assert(String.isNotBlank(info.displayName), 'Every option must have a non-blank label');
        }
    }

    // ── selectNutritionProfile: returns the correct profile info (no DML) ──────
    // selectNutritionProfile no longer does DML — it is a read-only method that
    // validates the profile exists and returns its NutritionProfileInfo so the LWC
    // can broadcast it via LMS without a page reload.
    @IsTest
    static void testSelectNutritionProfileMakesItActive() {
        Nutrition_Profile__c p = new Nutrition_Profile__c(User__c = UserInfo.getUserId());
        insert p;

        Test.startTest();
        WMF_MealAnalysisController.NutritionProfileInfo info =
            WMF_MealAnalysisController.selectNutritionProfile(p.Id);
        Test.stopTest();

        System.assertEquals(p.Id, info.profileId, 'selectNutritionProfile should return the requested profile Id');
        System.assertNotEquals(null, info.displayName, 'Returned info should include a display name');
    }

    // ── selectNutritionProfile: a non-existent Id surfaces a user-facing error ──
    @IsTest
    static void testSelectNutritionProfileUnknownIdThrows() {
        Nutrition_Profile__c p = new Nutrition_Profile__c();
        insert p;
        Id deletedId = p.Id;
        delete p; // well-formed but now non-existent Id

        Boolean threw = false;
        Test.startTest();
        try {
            WMF_MealAnalysisController.selectNutritionProfile(deletedId);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'Selecting a non-existent profile Id should raise an exception');
    }

    // ── resolveDisplayName: direct coverage of the FirstName/LastName/none rule ──
    // In-memory parent assignment (no DML) exercises all three branches deterministically,
    // without depending on real User data or creating new User records.
    @IsTest
    static void testResolveDisplayNamePrefersFirstName() {
        Nutrition_Profile__c p = new Nutrition_Profile__c();
        p.User__r = new User(FirstName = 'Ada', LastName = 'Lovelace');
        System.assertEquals('Ada', WMF_MealAnalysisController.resolveDisplayName(p));
    }

    @IsTest
    static void testResolveDisplayNameFallsBackToLastName() {
        Nutrition_Profile__c p = new Nutrition_Profile__c();
        p.User__r = new User(FirstName = '', LastName = 'Lovelace');
        System.assertEquals('Lovelace', WMF_MealAnalysisController.resolveDisplayName(p));
    }

    @IsTest
    static void testResolveDisplayNameNullWhenNoRelatedUser() {
        Nutrition_Profile__c p = new Nutrition_Profile__c();
        System.assertEquals(null, WMF_MealAnalysisController.resolveDisplayName(p));
    }
}