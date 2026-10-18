// Per-meal Queueable that makes the Gemini callout and updates the Meal__c record.
// Enqueued by WMF_MealRetrySweep — Scheduled Apex cannot make callouts directly,
// but a Queueable with Database.AllowsCallouts can.
public without sharing class WMF_MealAnalysisQueueable implements Queueable, Database.AllowsCallouts {

    private Id mealId;

    // Stores the target Meal Id so execute() knows which record to analyse.
    public WMF_MealAnalysisQueueable(Id mealId) {
        this.mealId = mealId;
    }

    // WHAT: analyses one pending meal asynchronously and writes the result back.
    // HOW: loads the meal and its optional photo (SOQL before callout), calls Gemini
    // with image and/or notes, increments the attempt count, and updates the Meal in
    // SYSTEM_MODE — marking it Analyzed on success or recording the failure otherwise.
    public void execute(QueueableContext ctx) {
        // 1. Load meal + Nutrition Profile (SOQL before callout — valid order)
        Meal__c meal = [
            SELECT Id, Meal_Notes__c, Logged_DateTime__c, Analysis_Attempt_Count__c, Nutrition_Profile__c,
                   Nutrition_Profile__r.Gender__c,
                   Nutrition_Profile__r.Age__c,
                   Nutrition_Profile__r.Height__c,
                   Nutrition_Profile__r.Weight__c,
                   Nutrition_Profile__r.BMI__c,
                   Nutrition_Profile__r.Daily_Caloric_Threshold__c
            FROM Meal__c WHERE Id = :mealId WITH SYSTEM_MODE
        ];

        // Today's other analyzed meals for the same profile (SOQL before callout)
        List<Meal__c> todayMeals = [
            SELECT Meal_Notes__c, Logged_DateTime__c, Calories__c, Protein_g__c, Carbs_g__c, Fat_g__c
            FROM Meal__c
            WHERE Status__c = 'Analyzed'
              AND Nutrition_Profile__c = :meal.Nutrition_Profile__c
              AND Logged_DateTime__c = TODAY
              AND Id != :mealId
            WITH SYSTEM_MODE
            ORDER BY Logged_DateTime__c ASC
            LIMIT 20
        ];

        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId FROM ContentDocumentLink
            WHERE LinkedEntityId = :mealId WITH SYSTEM_MODE LIMIT 1
        ];

        String photoBase64 = null;
        String mimeType    = null;
        if (!links.isEmpty()) {
            ContentVersion cv = [
                SELECT ContentDocumentId, VersionData, FileExtension
                FROM ContentVersion
                WHERE ContentDocumentId = :links[0].ContentDocumentId
                AND IsLatest = true
                WITH SYSTEM_MODE LIMIT 1
            ];
            photoBase64 = EncodingUtil.base64Encode(cv.VersionData);
            mimeType    = mimeTypeFromExtension(cv.FileExtension);
        }

        WMF_GeminiComm.AnalysisResult r;
        if (String.isBlank(photoBase64) && String.isBlank(meal.Meal_Notes__c)) {
            r = new WMF_GeminiComm.AnalysisResult();
            r.errorMessage = 'Nothing to analyse — no photo or description for meal';
        } else {
            // 2. Callout with personalized coaching context (no DML yet — valid order)
            String coachingCtx = WMF_GeminiComm.buildAnalysisContext(meal.Nutrition_Profile__r, todayMeals, meal.Logged_DateTime__c);
            try {
                r = WMF_GeminiComm.analyseImage(photoBase64, mimeType, meal.Meal_Notes__c, coachingCtx);
            } catch (Exception e) {
                r = new WMF_GeminiComm.AnalysisResult();
                r.errorMessage = 'Queueable callout exception: ' + e.getMessage();
            }
        }

        // 3. DML after callout
        Meal__c upd = new Meal__c(Id = mealId);
        upd.Analysis_Attempt_Count__c = (meal.Analysis_Attempt_Count__c == null ? 0 : meal.Analysis_Attempt_Count__c) + 1;

        if (r.success) {
            upd.Status__c                = 'Analyzed';
            upd.Calories__c              = r.calories;
            upd.Protein_g__c             = r.proteinG;
            upd.Carbs_g__c               = r.carbsG;
            upd.Fat_g__c                 = r.fatG;
            upd.Protein_Pct__c           = r.proteinPct;
            upd.Carbs_Pct__c             = r.carbsPct;
            upd.Fat_Pct__c               = r.fatPct;
            upd.Meal_Analysis__c         = r.mealAnalysis;
            upd.Last_Analysis_Outcome__c = 'Success';
            upd.Last_Analysis_Error__c   = null;
        } else {
            upd.Last_Analysis_Outcome__c = 'Failed';
            upd.Last_Analysis_Error__c   = r.errorMessage;
        }

        Database.update(upd, AccessLevel.SYSTEM_MODE);
    }

    // Maps a file extension to its image MIME type for the Gemini inlineData part;
    // defaults to image/jpeg for blank or unrecognised extensions.
    private static String mimeTypeFromExtension(String ext) {
        if (String.isBlank(ext)) return 'image/jpeg';
        switch on ext.toLowerCase() {
            when 'png'        { return 'image/png';  }
            when 'gif'        { return 'image/gif';  }
            when 'webp'       { return 'image/webp'; }
            when 'heic','heif'{ return 'image/heic'; }
            when else         { return 'image/jpeg'; }
        }
    }
}