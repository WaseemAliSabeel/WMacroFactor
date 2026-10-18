@IsTest
private class WMF_ReAnalyzeMealActionTest {

    private class SuccessMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new Map<String, Object>{
                'candidates' => new List<Object>{
                    new Map<String, Object>{
                        'content' => new Map<String, Object>{
                            'parts' => new List<Object>{
                                new Map<String, Object>{ 'text' => JSON.serialize(new Map<String, Object>{
                                    'calories' => 500, 'carbs_g' => 60, 'protein_g' => 40, 'fat_g' => 20,
                                    'carbs_pct' => 50, 'protein_pct' => 30, 'fat_pct' => 20,
                                    'meal_observations' => 'Balanced plate with lean protein and complex carbs.'
                                }) }
                            }
                        }
                    }
                }
            }));
            return res;
        }
    }

    private class FailMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(503);
            res.setStatus('Service Unavailable');
            res.setBody('{}');
            return res;
        }
    }

    private static Id makeMeal(String notes) {
        Nutrition_Profile__c p = new Nutrition_Profile__c(User__c = UserInfo.getUserId());
        insert p;
        Meal__c m = new Meal__c(
            Nutrition_Profile__c = p.Id,
            Logged_DateTime__c   = Datetime.now(),
            Meal_Notes__c        = notes,
            Status__c            = 'Analysis Pending'
        );
        insert m;
        return m.Id;
    }

    private static WMF_ReAnalyzeMealAction.Result run(Id mealId) {
        WMF_ReAnalyzeMealAction.Request req = new WMF_ReAnalyzeMealAction.Request();
        req.mealId = mealId;
        return WMF_ReAnalyzeMealAction.reAnalyse(new List<WMF_ReAnalyzeMealAction.Request>{ req })[0];
    }

    @IsTest
    static void testSuccessReturnsSummaryAndUpdatesMeal() {
        Id mealId = makeMeal('Grilled chicken salad');
        Test.setMock(HttpCalloutMock.class, new SuccessMock());

        Test.startTest();
        WMF_ReAnalyzeMealAction.Result r = run(mealId);
        Test.stopTest();

        System.assertEquals(true, r.success, 'Analysis should succeed: ' + r.errorMessage);
        System.assert(r.message.contains('500 kcal') && r.message.contains('30% protein'), 'Summary: ' + r.message);
        System.assertEquals('Analyzed', [SELECT Status__c FROM Meal__c WHERE Id = :mealId].Status__c);
    }

    @IsTest
    static void testGeminiFailureReturnsError() {
        Id mealId = makeMeal('Grilled chicken salad');
        Test.setMock(HttpCalloutMock.class, new FailMock());

        Test.startTest();
        WMF_ReAnalyzeMealAction.Result r = run(mealId);
        Test.stopTest();

        System.assertEquals(false, r.success);
        System.assert(String.isNotBlank(r.errorMessage), 'An error message should come back');
    }

    @IsTest
    static void testNothingToAnalyseReturnsError() {
        Id mealId = makeMeal(null);

        Test.startTest();
        WMF_ReAnalyzeMealAction.Result r = run(mealId);
        Test.stopTest();

        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains('photo or a description'), r.errorMessage);
    }
}