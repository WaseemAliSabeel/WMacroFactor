@IsTest
private class WMF_GeminiCommTest {

    // ── Mock helpers ──────────────────────────────────────────────────────────

    // Builds a valid Gemini generateContent response with the given macro values
    // embedded as a properly-escaped JSON string inside the candidates structure.
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

    // Mocks a valid 200 response carrying a complete, well-formed macro set.
    private class SuccessMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(200);
            res.setBody(geminiBody(new Map<String, Object>{
                'calories' => 520, 'carbs_g' => 60, 'protein_g' => 35, 'fat_g' => 18,
                'carbs_pct' => 46, 'protein_pct' => 27, 'fat_pct' => 27,
                'meal_observations' => 'This appears to be a grilled chicken salad with mixed greens and olive oil dressing. It is a well-balanced meal with good protein content and moderate carbohydrates, making it a healthy choice.'
            }));
            return res;
        }
    }

    // Mocks an HTTP 400 (Bad Request) error response.
    private class Http4xxMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(400);
            res.setStatus('Bad Request');
            res.setBody('{}');
            return res;
        }
    }

    // Simulates a network timeout by throwing a CalloutException.
    private class TimeoutMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            throw new CalloutException('Read timed out');
        }
    }

    // Mocks a 200 whose part text is not parseable JSON (Gemini ignored responseMimeType).
    private class MalformedJsonMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(200);
            // text value is a plain non-JSON string — simulates Gemini ignoring responseMimeType
            res.setBody(JSON.serialize(new Map<String, Object>{
                'candidates' => new List<Object>{
                    new Map<String, Object>{
                        'content' => new Map<String, Object>{
                            'parts' => new List<Object>{
                                new Map<String, Object>{ 'text' => 'not valid json at all' }
                            }
                        }
                    }
                }
            }));
            return res;
        }
    }

    // Mocks a 200 whose macro percentages do not sum to ~100 (invalid distribution).
    private class BadPctMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(200);
            // pct values sum to 60, not 100
            res.setBody(geminiBody(new Map<String, Object>{
                'calories' => 400, 'carbs_g' => 50, 'protein_g' => 30, 'fat_g' => 10,
                'carbs_pct' => 20, 'protein_pct' => 20, 'fat_pct' => 20
            }));
            return res;
        }
    }

    // Mocks a 200 with all-zero macros (a genuine water/black-coffee result).
    private class ZeroCaloriesMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(200);
            // Per the prompt's zero-macro rule, water/black-coffee return ALL zeros
            // (including percentages summing to 0).
            res.setBody(geminiBody(new Map<String, Object>{
                'calories' => 0, 'carbs_g' => 0, 'protein_g' => 0, 'fat_g' => 0,
                'carbs_pct' => 0, 'protein_pct' => 0, 'fat_pct' => 0
            }));
            return res;
        }
    }

    // A 200 response whose candidate has no content/parts — must be handled
    // gracefully (no NPE), returning an error result.
    private class NoPartsMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new Map<String, Object>{
                'candidates' => new List<Object>{ new Map<String, Object>{} }
            }));
            return res;
        }
    }

    // Mocks a 200 reporting negative calories (an impossible, must-reject value).
    private class NegativeCaloriesMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(200);
            res.setBody(geminiBody(new Map<String, Object>{
                'calories' => -50, 'carbs_g' => 0, 'protein_g' => 0, 'fat_g' => 0,
                'carbs_pct' => 33, 'protein_pct' => 33, 'fat_pct' => 34
            }));
            return res;
        }
    }

    // ── Tests ─────────────────────────────────────────────────────────────────

    // Verifies a valid image response parses into a successful result with all macros mapped.
    @IsTest
    static void testAnalyseImageSuccess() {
        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        Test.startTest();
        WMF_GeminiComm.AnalysisResult r = WMF_GeminiComm.analyseImage('base64data', 'image/jpeg', 'Grilled chicken');
        Test.stopTest();

        System.assertEquals(true,  r.success,    'Should succeed on valid response');
        System.assertEquals(520,   r.calories,   'Calories should match');
        System.assertEquals(60,    r.carbsG,     'Carbs g should match');
        System.assertEquals(35,    r.proteinG,   'Protein g should match');
        System.assertEquals(18,    r.fatG,       'Fat g should match');
        System.assertEquals(46,    r.carbsPct,   'Carbs pct should match');
        System.assertEquals(27,    r.proteinPct, 'Protein pct should match');
        System.assertEquals(27,    r.fatPct,     'Fat pct should match');
        System.assertNotEquals(null, r.mealAnalysis, 'Meal observations should be populated');
        System.assertEquals(null,  r.errorMessage, 'No error message on success');
    }

    // Verifies a description-only request (no image bytes) still analyses successfully.
    @IsTest
    static void testAnalyseTextOnlyNoImage() {
        // Description-only: no photo bytes, just notes. Must still work.
        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        Test.startTest();
        WMF_GeminiComm.AnalysisResult r = WMF_GeminiComm.analyseImage(null, null, 'Two boiled eggs and toast');
        Test.stopTest();

        System.assertEquals(true, r.success, 'Text-only analysis should succeed');
        System.assertEquals(520, r.calories, 'Calories should map from the response');
    }

    // Verifies an HTTP 4xx response yields a failure result whose message names the status code.
    @IsTest
    static void testAnalyseImageHttp4xx() {
        Test.setMock(HttpCalloutMock.class, new Http4xxMock());
        Test.startTest();
        WMF_GeminiComm.AnalysisResult r = WMF_GeminiComm.analyseImage('base64data', 'image/jpeg', null);
        Test.stopTest();

        System.assertEquals(false, r.success, 'Should fail on 4xx');
        System.assert(r.errorMessage.contains('400'), 'Error message should mention HTTP 400');
    }

    // Verifies a callout timeout is caught and returns a failure result with an error message.
    @IsTest
    static void testAnalyseImageTimeout() {
        Test.setMock(HttpCalloutMock.class, new TimeoutMock());
        Test.startTest();
        WMF_GeminiComm.AnalysisResult r = WMF_GeminiComm.analyseImage('base64data', 'image/jpeg', null);
        Test.stopTest();

        System.assertEquals(false, r.success, 'Should fail on timeout');
        System.assert(String.isNotBlank(r.errorMessage), 'Error message should be set');
    }

    // Verifies an unparseable JSON body returns a failure result rather than throwing.
    @IsTest
    static void testAnalyseImageMalformedJson() {
        Test.setMock(HttpCalloutMock.class, new MalformedJsonMock());
        Test.startTest();
        WMF_GeminiComm.AnalysisResult r = WMF_GeminiComm.analyseImage('base64data', 'image/jpeg', null);
        Test.stopTest();

        System.assertEquals(false, r.success, 'Should fail on malformed JSON body');
        System.assert(String.isNotBlank(r.errorMessage), 'Error message should be set');
    }

    // Verifies macro percentages not summing to ~100 are rejected with a sum-related error.
    @IsTest
    static void testAnalyseImageBadPercentages() {
        Test.setMock(HttpCalloutMock.class, new BadPctMock());
        Test.startTest();
        WMF_GeminiComm.AnalysisResult r = WMF_GeminiComm.analyseImage('base64data', 'image/jpeg', null);
        Test.stopTest();

        System.assertEquals(false, r.success, 'Should fail when pct values do not sum to ~100');
        System.assert(r.errorMessage.contains('sum'), 'Error should mention percentage sum');
    }

    // Verifies an all-zero (water) response is accepted as valid, not rejected.
    @IsTest
    static void testAnalyseImageZeroCaloriesAllowed() {
        // A glass of water: 0 calories is a genuine, valid result.
        Test.setMock(HttpCalloutMock.class, new ZeroCaloriesMock());
        Test.startTest();
        WMF_GeminiComm.AnalysisResult r = WMF_GeminiComm.analyseImage('base64data', 'image/jpeg', 'Glass of water');
        Test.stopTest();

        System.assertEquals(true, r.success, 'Zero-calorie meals (e.g. water) must be accepted');
        System.assertEquals(0, r.calories, 'Calories should be 0');
        System.assertEquals(null, r.errorMessage, 'No error message for a valid zero-calorie meal');
    }

    // Verifies a candidate lacking content/parts fails gracefully with an error, not an NPE.
    @IsTest
    static void testAnalyseImageNoParts() {
        Test.setMock(HttpCalloutMock.class, new NoPartsMock());
        Test.startTest();
        WMF_GeminiComm.AnalysisResult r = WMF_GeminiComm.analyseImage('base64data', 'image/jpeg', null);
        Test.stopTest();

        System.assertEquals(false, r.success, 'A candidate with no content/parts must fail gracefully');
        System.assert(String.isNotBlank(r.errorMessage), 'An error message should be set, not an NPE');
    }

    // Verifies negative calories are rejected with a message mentioning "negative".
    @IsTest
    static void testAnalyseImageNegativeCalories() {
        Test.setMock(HttpCalloutMock.class, new NegativeCaloriesMock());
        Test.startTest();
        WMF_GeminiComm.AnalysisResult r = WMF_GeminiComm.analyseImage('base64data', 'image/jpeg', null);
        Test.stopTest();

        System.assertEquals(false, r.success, 'Negative calories must still be rejected');
        System.assert(r.errorMessage.contains('negative'), 'Error should mention negative calories');
    }

    // Verifies the end-to-end log-and-analyse path saves an Analyzed meal with mocked macros.
    @IsTest
    static void testLogAndAnalyseMealSuccess() {
        insert new Nutrition_Profile__c(User__c = UserInfo.getUserId()); // Nutrition_Profile__c is a master-detail parent of Meal__c
        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        Test.startTest();
        // Null photo avoids ContentVersion/ContentPublication; callout fires with notes only.
        WMF_MealAnalysisController.MealAnalysisResult result =
            WMF_MealAnalysisController.logAndAnalyseMeal(
                null, null, null, 'Pasta bolognese'
            );
        Test.stopTest();

        System.assertEquals(true,       result.success, 'Success flag should be true');
        System.assertEquals('Analyzed', result.status,  'Status should be Analyzed');
        System.assertNotEquals(null,     result.mealId,  'Meal ID should be returned');
        System.assertEquals(520,         result.calories, 'Calories should match mock');

        Meal__c saved = [SELECT Status__c, Calories__c, Analysis_Attempt_Count__c FROM Meal__c WHERE Id = :result.mealId];
        System.assertEquals('Analyzed', saved.Status__c, 'Meal status in DB should be Analyzed');
        System.assertEquals(520, saved.Calories__c, 'Calories in DB should match');
        System.assertEquals(1, saved.Analysis_Attempt_Count__c, 'Attempt count should be 1');
    }

    // Verifies a callout failure leaves the meal saved but in Analysis Pending with 0 calories.
    @IsTest
    static void testLogAndAnalyseMealCalloutFailure() {
        insert new Nutrition_Profile__c(User__c = UserInfo.getUserId()); // Nutrition_Profile__c is a master-detail parent of Meal__c
        Test.setMock(HttpCalloutMock.class, new Http4xxMock());
        Test.startTest();
        // Null photo avoids ContentVersion/ContentPublication; callout fires with notes only.
        WMF_MealAnalysisController.MealAnalysisResult result =
            WMF_MealAnalysisController.logAndAnalyseMeal(
                null, null, null, 'Mystery meal'
            );
        Test.stopTest();

        System.assertEquals(false,              result.success, 'Success flag should be false');
        System.assertEquals('Analysis Pending', result.status,  'Status should be Analysis Pending');
        System.assertNotEquals(null,            result.mealId,  'Meal ID should still be returned');

        Meal__c saved = [SELECT Status__c, Calories__c FROM Meal__c WHERE Id = :result.mealId];
        System.assertEquals('Analysis Pending', saved.Status__c, 'DB status should be Analysis Pending');
        System.assertEquals(0, saved.Calories__c, 'Calories should be 0 on failure');
    }
}