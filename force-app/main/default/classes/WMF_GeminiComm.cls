public with sharing class WMF_GeminiComm {

    private static final String GEMINI_PROMPT =
        'You are a precise clinical nutritionist and personalized diet analysis API. Your task is to analyse the provided incoming meal (via image, written text description, or both), calculate its estimated nutritional breakdown, aggregate it with the user\'s prior meals logged today, and evaluate progress against their personalized daily calorie and macro targets.\n\n' +
        '### RULES & CONSTRAINTS:\n' +
        '1. OUTPUT FORMAT: Return ONLY a raw, valid JSON object matching the requested schema. Do NOT use markdown code blocks (e.g., no ```json), no intro text, and no conversational filler.\n' +
        '2. PORTIONS & HIDDEN INGREDIENTS:\n' +
        '   - Estimate portion size relative to standard adult servings, adjusting for the user\'s biometric profile where relevant.\n' +
        '   - For cooked meals, account for hidden preparation fats/oils.\n' +
        '   - For juices, distinguish between 100% natural fruit sugars vs. added syrup if specified/visible.\n' +
        '   - For non-nutritive sweeteners (Stevia, Monk Fruit, Sucralose, Erythritol), assign 0 calories and 0 macros.\n' +
        '3. MATHEMATICAL CONSISTENCY & ZERO-MACRO EDGE CASES:\n' +
        '   - Grams and calories must be non-negative numbers.\n' +
        '   - Total Macro Mass = carbs_g + protein_g + fat_g.\n' +
        '   - IF Total Macro Mass > 0:\n' +
        '     carbs_pct = (carbs_g / Total Macro Mass) * 100; protein_pct = (protein_g / Total Macro Mass) * 100; fat_pct = (fat_g / Total Macro Mass) * 100\n' +
        '     carbs_pct + protein_pct + fat_pct MUST sum to EXACTLY 100.\n' +
        '   - IF Total Macro Mass == 0 (e.g., Water, Black Coffee, Diet Soda, Zero-Calorie Sweeteners, Unsweetened Tea):\n' +
        '     Set calories, carbs_g, protein_g, fat_g, carbs_pct, protein_pct, and fat_pct ALL to 0.\n' +
        '4. PERSONALIZED GOAL-ORIENTED COACHING (when user context is provided):\n' +
        '   - Use the user\'s full biometric profile (gender, age, height, weight, BMI) and daily calorie target to personalise the analysis.\n' +
        '   - Compute cumulative intake by adding THIS meal\'s calories to today\'s prior totals provided in context.\n' +
        '   - Deliver all coaching inside "meal_observations" as EXACTLY 4 bullet points separated by \\n newlines (start each bullet with ONE relevant emoji followed by a space — NOT a "•" or "-" — e.g. 🍽️ 📊 💪 🥗 (🧠 or 🔬 also suit bullet 3); pick the emoji that best fits that bullet\'s content and use no other emojis inside the text). Max 900 characters total.\n' +
        '     Bullet 1 (e.g. 🍽️): Meal content identification, macros breakdown, meal timing of the day and its alignment to fat-loss / muscle-building goals.\n' +
        '     Bullet 2 (e.g. 📊): Caloric Budget status for the day in plain natural language only — a brief sentence describing whether the user is within, near, or over their daily target.\n' +
        '     Bullet 3 (e.g. 💪, 🧠 or 🔬 — whichever fits the encouragement best): One encouraging sentence tailored to the user\'s progress today.\n' +
        '     Bullet 4 (e.g. 🥗): One specific, actionable recommendation for the next meal.\n\n' +
        '### JSON SCHEMA TO RETURN:\n' +
        '{\n' +
        '  "calories": 0,\n' +
        '  "carbs_g": 0,\n' +
        '  "protein_g": 0,\n' +
        '  "fat_g": 0,\n' +
        '  "carbs_pct": 0,\n' +
        '  "protein_pct": 0,\n' +
        '  "fat_pct": 0,\n' +
        '  "meal_observations": "Exactly 4 bullet points separated by \\n, each starting with one relevant emoji instead of a bullet character (e.g. 🍽️ 📊 💪/🧠/🔬 🥗): 1) Meal content ID, macros breakdown, meal timing of day & goal alignment. 2) Caloric budget status for the day in plain language (brief sentence). 3) One encouraging sentence. 4) One actionable next-meal recommendation. Max 900 characters."\n' +
        '}';

    // DTO holding the parsed Gemini nutrition result plus success/error state and
    // a human-readable debug trail. Defaults are safe zeros so callers can rely on
    // non-null numerics even when the callout or parse fails.
    public class AnalysisResult {
        public Boolean success       = false;
        public Decimal calories      = 0;
        public Decimal carbsG        = 0;
        public Decimal proteinG      = 0;
        public Decimal fatG          = 0;
        public Decimal carbsPct      = 0;
        public Decimal proteinPct    = 0;
        public Decimal fatPct        = 0;
        public String  mealAnalysis;
        public String  errorMessage;
        public String  debugTrail    = '';
    }

    // Backward-compatible 3-param entry point — delegates to the 4-param version
    // without personalized context. Existing callers require no changes.
    public static AnalysisResult analyseImage(String photoBase64, String mimeType, String mealNotes) {
        return analyseImage(photoBase64, mimeType, mealNotes, null);
    }

    // Primary entry point used by the LWC controller and the retry sweep.
    // WHAT: builds the Gemini request (prompt + optional coaching context + optional image + notes),
    // POSTs it via the WMFGemini named credential, and returns a parsed AnalysisResult.
    // contextData (nullable): structured text with the user's Nutrition Profile and today's
    // meal history, injected between the static rules and the meal description so Gemini
    // can give personalized coaching in the meal_observations field.
    // MUST be called before any DML in the same transaction (Apex callout ordering).
    public static AnalysisResult analyseImage(String photoBase64, String mimeType, String mealNotes, String contextData) {
        AnalysisResult result = new AnalysisResult();
        String trail = '';
        try {
            String prompt = GEMINI_PROMPT;
            if (String.isNotBlank(contextData)) {
                prompt += '\n\n### USER CONTEXT FOR THIS ANALYSIS:\n' + contextData;
            }
            if (String.isNotBlank(mealNotes)) {
                prompt += '\n\nUser meal description: ' + mealNotes;
            }

            // Estimate decoded image size from base64 length (3 bytes per 4 chars) for the trail
            Boolean hasImage = String.isNotBlank(photoBase64);
            Integer approxKb = hasImage ? (photoBase64.length() * 3 / 4 / 1024) : 0;
            trail += 'Endpoint : callout:WMFGemini\n';
            trail += hasImage
                ? 'Image    : ' + mimeType + ' | ~' + approxKb + ' KB\n'
                : 'Image    : none (text-only)\n';
            if (String.isNotBlank(contextData)) {
                trail += 'Context  : profile + daily meals provided\n';
            }
            if (String.isNotBlank(mealNotes)) {
                trail += 'Notes    : "' + mealNotes.left(120) + '"\n';
            }
            trail += '\n';

            String requestBody = buildRequestBody(photoBase64, mimeType, prompt);

            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:WMFGemini');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setBody(requestBody);
            req.setTimeout(30000);

            HttpResponse res = new Http().send(req);

            trail += 'HTTP Response : ' + res.getStatusCode() + ' ' + res.getStatus() + '\n';

            if (res.getStatusCode() != 200) {
                trail += 'Error body   : ' + res.getBody().left(600) + '\n';
                result.errorMessage = 'Gemini HTTP ' + res.getStatusCode() + ': ' + res.getStatus();
                result.debugTrail   = trail;
                return result;
            }

            trail += 'Response body (first 900 chars):\n' + res.getBody().left(900) + '\n\n';

            // Extract and validate the nutrition JSON out of the Gemini envelope
            result = parseGeminiResponse(res.getBody());

            trail += 'Parse result : ' + (result.success ? 'SUCCESS' : 'FAILED — ' + result.errorMessage) + '\n';
            if (result.success) {
                trail += 'Calories : ' + result.calories + ' kcal\n';
                trail += 'Protein  : ' + result.proteinG + 'g (' + result.proteinPct + '%)\n';
                trail += 'Carbs    : ' + result.carbsG   + 'g (' + result.carbsPct   + '%)\n';
                trail += 'Fat      : ' + result.fatG     + 'g (' + result.fatPct     + '%)\n';
            }

        } catch (CalloutException e) {
            trail += 'CalloutException : ' + e.getMessage() + '\n';
            result.errorMessage = 'Callout error: ' + e.getMessage();
        } catch (Exception e) {
            trail += 'Exception : ' + e.getMessage() + '\n';
            result.errorMessage = 'Unexpected error: ' + e.getMessage();
        }
        result.debugTrail = trail;
        return result;
    }

    // WHAT: assembles the Gemini generateContent request JSON from the prompt and
    // optional inline image. HOW: builds a parts[] list (image part only when a photo
    // is present, then the text prompt) and forces a JSON response via generationConfig.
    private static String buildRequestBody(String photoBase64, String mimeType, String prompt) {
        // The image part is optional — include it only when a photo was supplied,
        // so the callout works for image-only, text-only, or both.
        List<Object> parts = new List<Object>();
        if (String.isNotBlank(photoBase64)) {
            parts.add(new Map<String, Object>{
                'inlineData' => new Map<String, Object>{
                    'mimeType' => mimeType,
                    'data'     => photoBase64
                }
            });
        }
        parts.add(new Map<String, Object>{ 'text' => prompt });

        Map<String, Object> body = new Map<String, Object>{
            'contents' => new List<Object>{
                new Map<String, Object>{ 'parts' => parts }
            },
            // Force raw JSON output. (The newer temperature/thinking_level keys were
            // reverted — the model behind WMFGemini rejected them with HTTP 400.)
            'generationConfig' => new Map<String, Object>{
                'responseMimeType' => 'application/json'
            }
        };
        return JSON.serialize(body);
    }

    // WHAT: parses Gemini's response envelope into an AnalysisResult, validating the
    // nutrition numbers. HOW: walks candidates[0] -> content -> parts[0].text to reach the
    // model's JSON, strips any markdown code fences, coerces each macro via toDecimal,
    // and flags success only if calories are non-negative and (when macro mass > 0) the
    // percentages sum within a 95-105 tolerance band.
    @TestVisible
    private static AnalysisResult parseGeminiResponse(String responseBody) {
        AnalysisResult result = new AnalysisResult();
        try {
            Map<String, Object> resp = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            List<Object> candidates = (List<Object>) resp.get('candidates');
            if (candidates == null || candidates.isEmpty()) {
                result.errorMessage = 'No candidates in Gemini response';
                return result;
            }
            Map<String, Object> firstCandidate = (Map<String, Object>) candidates[0];
            Map<String, Object> content = firstCandidate == null
                ? null : (Map<String, Object>) firstCandidate.get('content');
            List<Object> parts = content == null ? null : (List<Object>) content.get('parts');
            if (parts == null || parts.isEmpty()) {
                result.errorMessage = 'No content parts in Gemini response';
                return result;
            }
            Map<String, Object> firstPart = (Map<String, Object>) parts[0];
            String jsonText = firstPart == null ? null : (String) firstPart.get('text');
            if (String.isBlank(jsonText)) {
                result.errorMessage = 'Empty text in Gemini response';
                return result;
            }

            // Strip markdown code fences if model ignores responseMimeType
            jsonText = jsonText.trim();
            if (jsonText.startsWith('```')) {
                jsonText = jsonText.replaceAll('(?s)```[a-z]*\\s*', '').replaceAll('```', '').trim();
            }

            Map<String, Object> macros = (Map<String, Object>) JSON.deserializeUntyped(jsonText);

            result.calories        = toDecimal(macros.get('calories'));
            result.carbsG          = toDecimal(macros.get('carbs_g'));
            result.proteinG        = toDecimal(macros.get('protein_g'));
            result.fatG            = toDecimal(macros.get('fat_g'));
            result.carbsPct        = toDecimal(macros.get('carbs_pct'));
            result.proteinPct      = toDecimal(macros.get('protein_pct'));
            result.fatPct          = toDecimal(macros.get('fat_pct'));
            String rawObs = (String) macros.get('meal_observations');
            result.mealAnalysis = rawObs != null ? rawObs.left(800) : null;

            // Zero calories is a valid result (e.g. a glass of water). Only a
            // negative value is invalid.
            if (result.calories < 0) {
                result.errorMessage = 'Invalid response: negative calories';
                return result;
            }
            // Percentages are only meaningful when there is macro mass. Zero-macro
            // items (water, black coffee, diet soda…) legitimately return all zeros.
            Decimal macroMass = result.carbsG + result.proteinG + result.fatG;
            if (macroMass > 0) {
                Decimal pctSum = result.carbsPct + result.proteinPct + result.fatPct;
                if (pctSum < 95 || pctSum > 105) {
                    result.errorMessage = 'Invalid response: macro percentages sum to ' + pctSum;
                    return result;
                }
            }

            result.success = true;

        } catch (Exception e) {
            result.errorMessage = 'Response parse error: ' + e.getMessage();
        }
        return result;
    }

    // ── Personalized coaching context builder ─────────────────────────────────
    // WHAT: formats the user's Nutrition Profile and today's other analyzed meals into
    // a compact, human-readable block that is injected into the Gemini prompt so the
    // model can give targeted dietary coaching in the meal_observations field.
    // HOW: pure string formatting — no SOQL; callers supply the already-queried data.
    // Backward-compatible overload — no incoming-meal timing supplied.
    public static String buildAnalysisContext(Nutrition_Profile__c profile, List<Meal__c> todayMeals) {
        return buildAnalysisContext(profile, todayMeals, null);
    }

    // incomingLoggedAt (nullable): the Logged_DateTime__c of THIS meal, surfaced so
    // Gemini can factor meal timing-of-day into the coaching.
    public static String buildAnalysisContext(Nutrition_Profile__c profile, List<Meal__c> todayMeals, Datetime incomingLoggedAt) {
        Integer threshold = 2000;
        List<String> lines = new List<String>();

        lines.add('=== USER BIOMETRIC PROFILE & GOALS ===');
        if (profile != null) {
            if (String.isNotBlank(profile.Gender__c))       lines.add('Gender: ' + profile.Gender__c);
            if (profile.Age__c != null)                     lines.add('Age: ' + profile.Age__c.intValue() + ' years');
            if (profile.Height__c != null)                  lines.add('Height: ' + profile.Height__c + ' cm');
            if (profile.Weight__c != null)                  lines.add('Weight: ' + profile.Weight__c + ' kg');
            if (profile.BMI__c != null)                     lines.add('BMI: ' + profile.BMI__c.setScale(1));
            if (profile.Daily_Caloric_Threshold__c != null) threshold = profile.Daily_Caloric_Threshold__c.intValue();
            lines.add('Daily Calorie Target: ' + threshold + ' kcal');
        } else {
            lines.add('No profile data available.');
        }

        lines.add('');
        lines.add('=== INCOMING MEAL TIMING ===');
        lines.add('Logged At: ' + (incomingLoggedAt != null
            ? incomingLoggedAt.format('EEE, d MMM yyyy, h:mm a')
            : '(not provided)'));

        lines.add('');
        lines.add('=== TODAY\'S PRIOR MEAL HISTORY (EXCLUDING INCOMING MEAL) ===');
        if (todayMeals == null || todayMeals.isEmpty()) {
            lines.add('Prior Calories Consumed Today: 0 kcal');
            lines.add('Prior Carbs: 0 g | Prior Protein: 0 g | Prior Fat: 0 g');
            lines.add('(This is the first logged meal today.)');
        } else {
            Decimal priorCal   = 0;
            Decimal priorCarbs = 0;
            Decimal priorProt  = 0;
            Decimal priorFat   = 0;
            for (Integer i = 0; i < todayMeals.size(); i++) {
                Meal__c m = todayMeals[i];
                Decimal cal = m.Calories__c != null ? m.Calories__c : 0;
                priorCal   += cal;
                priorCarbs += m.Carbs_g__c   != null ? m.Carbs_g__c   : 0;
                priorProt  += m.Protein_g__c  != null ? m.Protein_g__c  : 0;
                priorFat   += m.Fat_g__c      != null ? m.Fat_g__c      : 0;
                String label = String.isNotBlank(m.Meal_Notes__c)
                    ? '"' + m.Meal_Notes__c.left(60) + '"'
                    : '(no description)';
                String loggedAt = m.Logged_DateTime__c != null
                    ? m.Logged_DateTime__c.format('h:mm a')
                    : '--:--';
                lines.add((i + 1) + '. [' + loggedAt + '] ' + label
                    + ' — ' + cal.intValue() + ' kcal'
                    + ' (P:' + safeInt(m.Protein_g__c) + 'g'
                    + ' C:' + safeInt(m.Carbs_g__c)    + 'g'
                    + ' F:' + safeInt(m.Fat_g__c)       + 'g)');
            }
            lines.add('Prior Calories Consumed Today: ' + priorCal.intValue() + ' kcal');
            lines.add('Prior Carbs: ' + priorCarbs.intValue() + ' g | Prior Protein: ' + priorProt.intValue() + ' g | Prior Fat: ' + priorFat.intValue() + ' g');
            lines.add('Remaining Calorie Budget (before this meal): ' + (threshold - priorCal).intValue() + ' kcal');
        }

        return String.join(lines, '\n');
    }

    private static Integer safeInt(Decimal d) {
        return d != null ? d.intValue() : 0;
    }

    // WHAT: null-safe coercion of an untyped JSON value to Decimal. HOW: stringifies then
    // parses via Decimal.valueOf, returning 0 for null or any unparseable value.
    private static Decimal toDecimal(Object val) {
        if (val == null) return 0;
        try {
            return Decimal.valueOf(String.valueOf(val));
        } catch (Exception e) {
            return 0;
        }
    }
}