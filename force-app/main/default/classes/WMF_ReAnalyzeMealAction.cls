// Invocable wrapper so the "Re-Analyze" Screen Flow action can run the same Gemini analysis
// the old reAnalyseMeal LWC ran. LWC quick actions don't render in the Salesforce mobile app;
// Flow quick actions do. All the real work stays in WMF_MealAnalysisController.analyseExistingMeal.
// Runs in the flow user's context (with sharing, USER_MODE inside the controller).
public with sharing class WMF_ReAnalyzeMealAction {

    public class Request {
        @InvocableVariable(label='Meal Record ID' required=true)
        public Id mealId;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Summary Message')
        public String message;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    @InvocableMethod(
        label='Re-Analyze Meal with Gemini'
        description='Re-sends the meal photo/notes to Gemini and updates the Meal with the new macros'
        category='WMacroFactor'
        callout=true
    )
    public static List<Result> reAnalyse(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result r = new Result();
            try {
                WMF_MealAnalysisController.MealAnalysisResult res =
                    WMF_MealAnalysisController.analyseExistingMeal(req.mealId);
                r.success = res.success;
                if (res.success) {
                    r.message = 'Meal analyzed! ' + rounded(res.calories) + ' kcal — '
                              + rounded(res.proteinPct) + '% protein, '
                              + rounded(res.carbsPct)   + '% carbs, '
                              + rounded(res.fatPct)     + '% fat.';
                } else {
                    r.errorMessage = String.isNotBlank(res.errorMessage) ? res.errorMessage : 'Analysis failed.';
                }
            } catch (Exception e) {
                r.success      = false;
                r.errorMessage = e.getMessage();
            }
            results.add(r);
        }
        return results;
    }

    private static Long rounded(Decimal d) {
        return d == null ? 0 : Math.round(d);
    }
}