public with sharing class WMF_MealAnalysisController {

    // DTO returned to the LWC. @AuraEnabled fields carry the persisted meal state
    // (macros, status, observations) plus the debug trail and any error message so
    // the component can render success and failure paths from a single shape.
    public class MealAnalysisResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  mealId;
        @AuraEnabled public Decimal calories;
        @AuraEnabled public Decimal proteinG;
        @AuraEnabled public Decimal carbsG;
        @AuraEnabled public Decimal fatG;
        @AuraEnabled public Decimal proteinPct;
        @AuraEnabled public Decimal carbsPct;
        @AuraEnabled public Decimal fatPct;
        @AuraEnabled public String  status;
        @AuraEnabled public String  mealAnalysis;
        @AuraEnabled public String  debugTrail;
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public String  photoBase64;     // full data-URL for historical meal loads
        @AuraEnabled public String  mealNotes;       // Meal_Notes__c for historical meal loads
        @AuraEnabled public String  loggedDatetime;  // ISO datetime for result-view display
    }

    // DTO for a single today's-meal summary row (timeline card).
    public class MealSummary {
        @AuraEnabled public String  mealId;
        @AuraEnabled public String  loggedDatetime;    // ISO datetime string (UTC)
        @AuraEnabled public String  status;
        @AuraEnabled public Decimal calories;
        @AuraEnabled public String  mealNotes;
        @AuraEnabled public String  contentVersionId;  // null when no photo attached
    }

    // ── Nutrition Profile resolution (system-wide last-modified profile) ────
    // DTO returned to the LWC: the Id of the last-modified Nutrition Profile across
    // the whole org (if any) plus its owning user's display name. Both fields are
    // left null when no profile exists so the component can render its gate.
    public class NutritionProfileInfo {
        @AuraEnabled public Id      profileId;
        @AuraEnabled public String  displayName;
        @AuraEnabled public Integer dailyCaloricThreshold;
        @AuraEnabled public String  fullUserName;   // User.Name — used by the profile-switcher tile cards
        @AuraEnabled public Integer age;            // Nutrition_Profile__c.Age__c
        @AuraEnabled public Id      profileUserId;  // Nutrition_Profile__c.User__c — for ownership check in LWC
        @AuraEnabled public String  userTimeZone;   // User.TimeZoneSidKey (IANA) — for correct timeline display in viewer's UI
        @AuraEnabled public String  userPhotoUrl;   // User.SmallPhotoUrl — avatar for the profile-switcher modal tiles
        @AuraEnabled public Boolean profileActive;  // Nutrition_Profile__c.Active__c — mealCapture hides inactive profiles from the switcher / Log Meal
    }

    // WHAT: returns the system-wide last-modified Nutrition Profile's Id and a
    // display name resolved from its related user, for the mealCapture gate/header
    // and the mealMacroTrend chart title.
    // HOW: cacheable so both LWCs share one round trip; the heavy lifting (which
    // profile, which name) lives in the shared getLastModifiedProfile()/resolveDisplayName()
    // helpers also used by createMealRecord, so the "chosen profile" rule only exists once.
    @AuraEnabled(cacheable=true)
    public static NutritionProfileInfo getActiveNutritionProfile() {
        NutritionProfileInfo info = new NutritionProfileInfo();
        Nutrition_Profile__c profile = getLastModifiedProfile();
        if (profile != null) {
            info.profileId   = profile.Id;
            info.displayName = resolveDisplayName(profile);
            info.dailyCaloricThreshold = profile.Daily_Caloric_Threshold__c != null
                ? (Integer) profile.Daily_Caloric_Threshold__c
                : 2000;
            info.profileUserId = profile.User__c;
            info.userTimeZone  = (profile.User__r != null)
                ? profile.User__r.TimeZoneSidKey : null;
            info.profileActive = profile.Active__c;
        }
        return info;
    }

    // ── All Nutrition Profiles — options for the profile-switcher tile cards ──
    // WHAT: returns every Nutrition Profile in the org with enough detail to render
    // a tile card: full user name, age, and daily caloric threshold.
    // HOW: same FirstName-else-LastName rule as getActiveNutritionProfile, falling back
    // to the profile's own auto-number Name when neither resolves.
    @AuraEnabled(cacheable=true)
    public static List<NutritionProfileInfo> getAllNutritionProfiles() {
        List<Nutrition_Profile__c> profiles = [
            SELECT Id, Name, User__c, User__r.FirstName, User__r.LastName, User__r.Name,
                   User__r.SmallPhotoUrl, Age__c, Daily_Caloric_Threshold__c, Active__c
            FROM Nutrition_Profile__c
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
        ];
        // Build info objects, separating the running user's own profile so it
        // can be placed first in the switcher tile list regardless of LastModifiedDate.
        List<NutritionProfileInfo> output = new List<NutritionProfileInfo>();
        NutritionProfileInfo ownProfileInfo = null;
        for (Nutrition_Profile__c p : profiles) {
            NutritionProfileInfo info = new NutritionProfileInfo();
            info.profileId = p.Id;
            String resolved = resolveDisplayName(p);
            info.displayName = String.isNotBlank(resolved) ? resolved : p.Name;
            info.fullUserName = (p.User__r != null && String.isNotBlank(p.User__r.Name))
                ? p.User__r.Name : p.Name;
            info.age = p.Age__c != null ? (Integer) p.Age__c : null;
            info.dailyCaloricThreshold = p.Daily_Caloric_Threshold__c != null
                ? (Integer) p.Daily_Caloric_Threshold__c : 2000;
            info.userPhotoUrl = (p.User__r != null) ? p.User__r.SmallPhotoUrl : null;
            info.profileActive = p.Active__c;
            if (p.User__c == UserInfo.getUserId()) {
                ownProfileInfo = info; // surface own profile first in the switcher
            } else {
                output.add(info);
            }
        }
        if (ownProfileInfo != null) output.add(0, ownProfileInfo);
        return output;
    }

    // ── Select a Nutrition Profile — read-only, no DML ──────────────────────
    // WHAT: validates that the chosen profile exists and returns its info for the LWC
    // to broadcast via LMS so all three chart components refresh immediately.
    // HOW: pure SOQL, no DML. Profile selection state lives in the LWC session only
    // (not persisted server-side). On page reload the priority-logic in
    // getLastModifiedProfile() re-applies (own profile first, then last-modified fallback).
    @AuraEnabled
    public static NutritionProfileInfo selectNutritionProfile(Id profileId) {
        try {
            if (profileId == null) {
                throw new AuraHandledException('Choose a Nutrition Profile first.');
            }
            List<Nutrition_Profile__c> profiles = [
                SELECT Id, Name, User__c, User__r.FirstName, User__r.LastName,
                       User__r.Name, User__r.TimeZoneSidKey,
                       Daily_Caloric_Threshold__c, Age__c, Active__c
                FROM Nutrition_Profile__c WHERE Id = :profileId WITH USER_MODE LIMIT 1
            ];
            if (profiles.isEmpty()) {
                throw new AuraHandledException('That Nutrition Profile could not be found.');
            }
            Nutrition_Profile__c p = profiles[0];
            NutritionProfileInfo info = new NutritionProfileInfo();
            info.profileId            = p.Id;
            String resolved           = resolveDisplayName(p);
            info.displayName          = String.isNotBlank(resolved) ? resolved : p.Name;
            info.fullUserName         = (p.User__r != null && String.isNotBlank(p.User__r.Name))
                                          ? p.User__r.Name : p.Name;
            info.dailyCaloricThreshold = p.Daily_Caloric_Threshold__c != null
                                          ? (Integer) p.Daily_Caloric_Threshold__c : 2000;
            info.age                  = p.Age__c != null ? (Integer) p.Age__c : null;
            info.profileUserId        = p.User__c;
            info.userTimeZone         = (p.User__r != null) ? p.User__r.TimeZoneSidKey : null;
            info.profileActive        = p.Active__c;
            return info;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // WHAT: resolves the active Nutrition Profile for all callers (charts, meal creation,
    // today stats, coaching context).
    // Priority 1 — the running user's own profile (User__c = running user), most recently
    //   modified. Using ORDER BY LastModifiedDate DESC means selectNutritionProfile() — which
    //   bumps LastModifiedDate on the chosen record — still works as an explicit override
    //   within the user's own profile set.
    // Priority 2 — system-wide last-modified fallback, used only when the running user has
    //   no profile linked to their User record (e.g. a shared/admin org).
    private static Nutrition_Profile__c getLastModifiedProfile() {
        // Priority 1: the running user's own linked profile
        List<Nutrition_Profile__c> ownProfiles = [
            SELECT Id, User__r.FirstName, User__r.LastName, User__r.TimeZoneSidKey,
                   Daily_Caloric_Threshold__c, Gender__c, Age__c, Height__c, Weight__c, BMI__c, Active__c
            FROM Nutrition_Profile__c
            WHERE User__c = :UserInfo.getUserId()
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (!ownProfiles.isEmpty()) return ownProfiles[0];

        // Priority 2: system-wide last-modified fallback
        List<Nutrition_Profile__c> profiles = [
            SELECT Id, User__r.FirstName, User__r.LastName, User__r.TimeZoneSidKey,
                   Daily_Caloric_Threshold__c, Gender__c, Age__c, Height__c, Weight__c, BMI__c, Active__c
            FROM Nutrition_Profile__c
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        return profiles.isEmpty() ? null : profiles[0];
    }

    // Resolves the display name for a profile: the related user's FirstName, falling
    // back to LastName when FirstName is blank, and null when neither is available
    // (so callers can degrade gracefully instead of rendering a dangling "Welcome ").
    @TestVisible
    private static String resolveDisplayName(Nutrition_Profile__c profile) {
        if (profile == null || profile.User__r == null) {
            return null;
        }
        if (String.isNotBlank(profile.User__r.FirstName)) {
            return profile.User__r.FirstName;
        }
        if (String.isNotBlank(profile.User__r.LastName)) {
            return profile.User__r.LastName;
        }
        return null;
    }

    // ── Upload config for LWC REST photo upload ──────────────────────────────
    // LWC runs on *.lightning.force.com; REST API is on *.my.salesforce.com.
    // Using cookies (credentials:'include') fails cross-origin, so the LWC
    // builds the full URL and passes the session ID as an Authorization header.
    // Returns the running user's session ID so the LWC can send it as an
    // Authorization bearer token on cross-origin REST photo uploads.
    @AuraEnabled
    public static String getSessionId() {
        return UserInfo.getSessionId();
    }

    // Returns the org's My Domain base URL so the LWC can build the absolute
    // REST endpoint (on *.my.salesforce.com) for the photo upload.
    @AuraEnabled
    public static String getBaseUrl() {
        return Url.getOrgDomainUrl().toExternalForm();
    }

    // ── Today's meal count + calories for the LWC progress card ─────────────
    // WHAT: returns today's meal count and total calories for the progress card,
    // scoped to the specified Nutrition Profile so the bar reflects only that
    // profile's meals. A null profileId returns zeros rather than leaking
    // cross-profile data (the caller gates on having a profile before rendering).
    // HOW: a single AggregateResult over Meal__c filtered to TODAY and the active
    // profile in USER_MODE; coalesces a null calorie sum (no meals yet) to 0.
    // WHAT: returns meal count + calorie total for the selected day.
    // HOW: uses UTC datetime range (computed client-side in the profile owner's timezone)
    // instead of DAY_ONLY(convertTimezone()) which would use the org timezone and
    // miss meals logged early-morning by users in forward timezones (e.g. IST).
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getTodayStats(Id profileId, String startUtc, String endUtc) {
        if (profileId == null) {
            return new Map<String, Object>{ 'mealCount' => 0, 'totalCalories' => 0 };
        }
        Datetime startDt;
        Datetime endDt;
        if (String.isNotBlank(startUtc) && String.isNotBlank(endUtc)) {
            startDt = (Datetime) JSON.deserialize('"' + startUtc + '"', Datetime.class);
            endDt   = (Datetime) JSON.deserialize('"' + endUtc   + '"', Datetime.class);
        } else {
            startDt = Datetime.newInstance(Date.today(), Time.newInstance(0, 0, 0, 0));
            endDt   = startDt.addDays(1);
        }
        AggregateResult row = [
            SELECT COUNT(Id) mealCount, SUM(Calories__c) totalCalories
            FROM Meal__c
            WHERE Logged_DateTime__c >= :startDt
              AND Logged_DateTime__c < :endDt
              AND Nutrition_Profile__c = :profileId
            WITH USER_MODE
        ];
        Object cal = row.get('totalCalories');
        return new Map<String, Object>{
            'mealCount'     => row.get('mealCount'),
            'totalCalories' => cal != null ? cal : 0
        };
    }

    // ── Daily calorie totals for the calorie trend line chart ────────────────
    // DTO for one calendar day's total calories + meal count.
    public class DailyCalorie {
        @AuraEnabled public String  logDay;
        @AuraEnabled public Decimal totalCalories;
        @AuraEnabled public Integer mealCount;
    }

    // WHAT: returns per-day calorie totals for the active Nutrition Profile's
    // Analyzed meals over the trailing window, for the mealCalorieTrend line chart.
    // HOW: same profile-scoping and timezone conversion as getDailyMacroDistribution;
    // defaults null/<=0 window to 10 days.
    // profileId (nullable): when provided, scopes data to that specific profile so
    // the chart can reflect a user-selected profile without an Apex round-trip each time.
    // When null, falls back to the priority-logic default (own profile → last-modified).
    @AuraEnabled(cacheable=true)
    public static List<DailyCalorie> getDailyCalorieDistribution(Integer daysBack, Id profileId) {
        // daysBack is now treated as a row limit (last N days that have logged meals),
        // not a calendar-day window, so non-consecutive logging days are included.
        Integer rowLimit = (daysBack == null || daysBack <= 0) ? 10 : daysBack;

        Id activeProfileId;
        if (profileId != null) {
            activeProfileId = profileId;
        } else {
            Nutrition_Profile__c activeProfile = getLastModifiedProfile();
            if (activeProfile == null) return new List<DailyCalorie>();
            activeProfileId = activeProfile.Id;
        }

        // Fetch the most-recent rowLimit days that have analysed meals, then reverse
        // so the chart X axis renders oldest-to-newest (left-to-right).
        List<AggregateResult> rows = [
            SELECT DAY_ONLY(convertTimezone(Logged_DateTime__c)) logDay,
                   SUM(Calories__c)  totalCalories,
                   COUNT(Id)         mealCount
            FROM Meal__c
            WHERE Status__c = 'Analyzed'
              AND Nutrition_Profile__c = :activeProfileId
            WITH USER_MODE
            GROUP BY DAY_ONLY(convertTimezone(Logged_DateTime__c))
            ORDER BY DAY_ONLY(convertTimezone(Logged_DateTime__c)) DESC
            LIMIT :rowLimit
        ];

        List<DailyCalorie> output = new List<DailyCalorie>();
        for (AggregateResult ar : rows) {
            DailyCalorie d = new DailyCalorie();
            d.logDay        = String.valueOf((Date) ar.get('logDay'));
            d.totalCalories = (Decimal) ar.get('totalCalories');
            d.mealCount     = (Integer) ar.get('mealCount');
            output.add(d);
        }
        // Reverse to restore chronological order for the chart
        List<DailyCalorie> chronological = new List<DailyCalorie>();
        for (Integer i = output.size() - 1; i >= 0; i--) {
            chronological.add(output[i]);
        }
        return chronological;
    }

    // ── Daily macro distribution for the stacked-bar dashboard widget ───────
    // Cumulative Carbs / Fat / Protein grams per calendar day (running user's
    // timezone) for the active Nutrition Profile's Analyzed meals. Percentages are
    // derived client-side so each day's bar totals 100%.
    // DTO for one calendar day's aggregated macro grams + meal count (percentages
    // are derived client-side). logDay is an ISO date string keyed to the user's timezone.
    public class DailyMacro {
        @AuraEnabled public String  logDay;    // ISO date (yyyy-MM-dd) of the logged day
        @AuraEnabled public Decimal carbsG;
        @AuraEnabled public Decimal fatG;
        @AuraEnabled public Decimal proteinG;
        @AuraEnabled public Integer mealCount;
    }

    // WHAT: returns per-day carb/fat/protein gram totals for the active Nutrition Profile's
    // Analyzed meals over the trailing window. HOW: defaults a null/non-positive window to 14
    // days, computes an inclusive startDate, then GROUPs BY the timezone-converted logged day
    // and maps each AggregateResult row into a DailyMacro.
    // profileId (nullable): when provided, scopes data to that specific profile so
    // the chart can reflect a user-selected profile without an Apex round-trip each time.
    // When null, falls back to the priority-logic default (own profile → last-modified).
    @AuraEnabled(cacheable=true)
    public static List<DailyMacro> getDailyMacroDistribution(Integer daysBack, Id profileId) {
        // daysBack is now treated as a row limit (last N days that have logged meals),
        // not a calendar-day window, so non-consecutive logging days are included.
        Integer rowLimit = (daysBack == null || daysBack <= 0) ? 10 : daysBack;

        Id activeProfileId;
        if (profileId != null) {
            activeProfileId = profileId;
        } else {
            Nutrition_Profile__c activeProfile = getLastModifiedProfile();
            if (activeProfile == null) return new List<DailyMacro>();
            activeProfileId = activeProfile.Id;
        }

        // Fetch the most-recent rowLimit days that have analysed meals, then reverse
        // so the chart X axis renders oldest-to-newest (left-to-right).
        List<AggregateResult> rows = [
            SELECT DAY_ONLY(convertTimezone(Logged_DateTime__c)) logDay,
                   SUM(Carbs_g__c)   carbsG,
                   SUM(Fat_g__c)     fatG,
                   SUM(Protein_g__c) proteinG,
                   COUNT(Id)         mealCount
            FROM Meal__c
            WHERE Status__c = 'Analyzed'
              AND Nutrition_Profile__c = :activeProfileId
            WITH USER_MODE
            GROUP BY DAY_ONLY(convertTimezone(Logged_DateTime__c))
            ORDER BY DAY_ONLY(convertTimezone(Logged_DateTime__c)) DESC
            LIMIT :rowLimit
        ];

        List<DailyMacro> reversed = new List<DailyMacro>();
        for (AggregateResult ar : rows) {
            DailyMacro d = new DailyMacro();
            d.logDay    = String.valueOf((Date) ar.get('logDay'));
            d.carbsG    = (Decimal) ar.get('carbsG');
            d.fatG      = (Decimal) ar.get('fatG');
            d.proteinG  = (Decimal) ar.get('proteinG');
            d.mealCount = (Integer) ar.get('mealCount');
            reversed.add(d);
        }
        // Reverse to restore chronological order for the chart
        List<DailyMacro> output = new List<DailyMacro>();
        for (Integer i = reversed.size() - 1; i >= 0; i--) {
            output.add(reversed[i]);
        }
        return output;
    }

    // ── Step 1: Create the Meal record (no photo, no callout, tiny payload) ──
    // WHAT: inserts a new "Analysis Pending" Meal__c and returns its Id.
    // HOW: parses the client's UTC ISO datetime (falls back to now), auto-links the
    // system-wide last-modified Nutrition Profile, and seeds all macro fields to 0 so
    // later steps only update.
    @AuraEnabled
    public static String createMealRecord(String notes, String loggedDatetime) {
        try {
            // Parse user-supplied UTC ISO datetime; fall back to server time if absent
            Datetime loggedDt = String.isNotBlank(loggedDatetime)
                ? (Datetime) JSON.deserialize('"' + loggedDatetime + '"', Datetime.class)
                : System.now();

            // Auto-link the system-wide last-modified Nutrition Profile (not the running
            // user's own profile — Nutrition_Profile__c is a master-detail parent, so the
            // UI gate must guarantee one exists before this is called).
            Nutrition_Profile__c profile = getLastModifiedProfile();
            Id profileId = profile != null ? profile.Id : null;

            Meal__c meal = new Meal__c(
                Logged_DateTime__c        = loggedDt,
                Meal_Notes__c             = notes,
                Nutrition_Profile__c      = profileId,
                Status__c                 = 'Analysis Pending',
                Analysis_Attempt_Count__c = 0,
                Calories__c               = 0,
                Protein_g__c              = 0,
                Carbs_g__c                = 0,
                Fat_g__c                  = 0,
                Protein_Pct__c            = 0,
                Carbs_Pct__c              = 0,
                Fat_Pct__c                = 0
            );
            Database.insert(meal, AccessLevel.USER_MODE);
            return meal.Id;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Step 2: Attach compressed photo as ContentVersion ────────────────────
    // WHAT: attaches the meal photo to the Meal record as a file.
    // HOW: base64-decodes the (client-compressed) image into a ContentVersion whose
    // FirstPublishLocationId is the meal, which creates and links the ContentDocument.
    @AuraEnabled
    public static void uploadMealPhoto(String mealId, String photoBase64, String fileName) {
        try {
            ContentVersion cv = new ContentVersion(
                Title                  = deriveTitle(fileName),
                PathOnClient           = String.isNotBlank(fileName) ? fileName : 'meal.jpg',
                FirstPublishLocationId = mealId,
                VersionData            = EncodingUtil.base64Decode(photoBase64)
            );
            Database.insert(cv, AccessLevel.USER_MODE);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Step 3: Read photo from ContentVersion, call Gemini, update Meal ──────
    // LWC calls this after uploading the photo via REST in step 2.
    // Transaction order: SOQL → SOQL → callout → DML  (no DML before callout).
    @AuraEnabled
    public static MealAnalysisResult analyseExistingMeal(String mealId) {
        MealAnalysisResult output = new MealAnalysisResult();
        try {
            // 1. Read meal notes + Nutrition Profile fields for the prompt and coaching context
            Meal__c mealForNotes = [
                SELECT Meal_Notes__c, Logged_DateTime__c, Nutrition_Profile__c, Analysis_Attempt_Count__c,
                       Nutrition_Profile__r.Gender__c,
                       Nutrition_Profile__r.Age__c,
                       Nutrition_Profile__r.Height__c,
                       Nutrition_Profile__r.Weight__c,
                       Nutrition_Profile__r.BMI__c,
                       Nutrition_Profile__r.Daily_Caloric_Threshold__c
                FROM Meal__c WHERE Id = :mealId WITH USER_MODE LIMIT 1
            ];

            // 1b. Today's other analyzed meals for the same profile (coaching context only;
            //     SOQL is safe here — no DML has occurred yet in this transaction).
            List<Meal__c> todayMeals = [
                SELECT Meal_Notes__c, Logged_DateTime__c, Calories__c, Protein_g__c, Carbs_g__c, Fat_g__c
                FROM Meal__c
                WHERE Status__c = 'Analyzed'
                  AND Nutrition_Profile__c = :mealForNotes.Nutrition_Profile__c
                  AND Logged_DateTime__c = TODAY
                  AND Id != :mealId
                WITH USER_MODE
                ORDER BY Logged_DateTime__c ASC
                LIMIT 20
            ];

            // 2. Find the latest ContentVersion linked to this meal (photo is optional)
            List<ContentDocumentLink> links = [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :mealId
                WITH USER_MODE
                LIMIT 1
            ];

            String photoBase64 = null;
            String mimeType    = null;
            if (!links.isEmpty()) {
                ContentVersion cv = [
                    SELECT VersionData, FileExtension
                    FROM ContentVersion
                    WHERE ContentDocumentId = :links[0].ContentDocumentId
                    AND IsLatest = true
                    WITH USER_MODE
                    LIMIT 1
                ];
                photoBase64 = EncodingUtil.base64Encode(cv.VersionData);
                mimeType    = mimeTypeFromExtension(cv.FileExtension);
            }

            // Need at least an image or a description to analyse
            if (String.isBlank(photoBase64) && String.isBlank(mealForNotes.Meal_Notes__c)) {
                output.success      = false;
                output.mealId       = mealId;
                output.status       = 'Analysis Pending';
                output.debugTrail   = 'Nothing to analyse — no photo and no description for meal ' + mealId;
                output.errorMessage = 'Add a photo or a description to analyse this meal.';
                return output;
            }

            // 3. Callout BEFORE any DML — include personalized coaching context
            String ctx = WMF_GeminiComm.buildAnalysisContext(mealForNotes.Nutrition_Profile__r, todayMeals, mealForNotes.Logged_DateTime__c);
            WMF_GeminiComm.AnalysisResult gem = WMF_GeminiComm.analyseImage(
                photoBase64, mimeType, mealForNotes.Meal_Notes__c, ctx
            );

            // 4. DML: update meal with result
            Meal__c meal = new Meal__c(Id = mealId);
            // Count every attempt (the Re-Analyze flow stops offering the action at 5).
            meal.Analysis_Attempt_Count__c = (mealForNotes.Analysis_Attempt_Count__c == null ? 0 : mealForNotes.Analysis_Attempt_Count__c) + 1;

            if (gem.success) {
                meal.Status__c                = 'Analyzed';
                meal.Calories__c              = gem.calories;
                meal.Protein_g__c             = gem.proteinG;
                meal.Carbs_g__c               = gem.carbsG;
                meal.Fat_g__c                 = gem.fatG;
                meal.Protein_Pct__c           = gem.proteinPct;
                meal.Carbs_Pct__c             = gem.carbsPct;
                meal.Fat_Pct__c               = gem.fatPct;
                meal.Meal_Analysis__c         = gem.mealAnalysis;
                meal.Last_Analysis_Outcome__c = 'Success';
                meal.Last_Analysis_Error__c   = null;
            } else {
                meal.Status__c                = 'Analysis Pending';
                meal.Last_Analysis_Outcome__c = 'Failed';
                meal.Last_Analysis_Error__c   = gem.errorMessage;
            }

            Database.update(meal, AccessLevel.USER_MODE);

            // 5. Populate return DTO
            output.success          = gem.success;
            output.mealId           = mealId;
            output.status           = meal.Status__c;
            output.calories         = meal.Calories__c;
            output.proteinG         = meal.Protein_g__c;
            output.carbsG           = meal.Carbs_g__c;
            output.fatG             = meal.Fat_g__c;
            output.proteinPct       = meal.Protein_Pct__c;
            output.carbsPct         = meal.Carbs_Pct__c;
            output.fatPct           = meal.Fat_Pct__c;
            output.mealAnalysis = gem.mealAnalysis;
            output.debugTrail       = gem.debugTrail;
            if (!gem.success) {
                output.errorMessage = gem.errorMessage;
            }

        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
        return output;
    }

    // ── Legacy single-call entry point (kept for test coverage) ─────────────
    // WHAT: one-shot log+analyse — callout, insert Meal, then attach photo.
    // HOW: calls Gemini first (before any DML), builds a Meal from the outcome
    // (Analyzed vs Analysis Pending), inserts it, and only then inserts the photo
    // ContentVersion so the meal Id exists to link to.
    // Not called from LWC — replaced by the 3-step flow to avoid
    // the Aura framework payload-size limit on large photo base64 strings.
    @AuraEnabled
    public static MealAnalysisResult logAndAnalyseMeal(
        String photoBase64, String mimeType, String fileName, String notes
    ) {
        MealAnalysisResult output = new MealAnalysisResult();
        try {
            // Query profile + today's meals before the callout (SOQL before DML — valid order).
            Nutrition_Profile__c profile = getLastModifiedProfile();
            List<Meal__c> todayMeals = profile != null ? [
                SELECT Meal_Notes__c, Logged_DateTime__c, Calories__c, Protein_g__c, Carbs_g__c, Fat_g__c
                FROM Meal__c
                WHERE Status__c = 'Analyzed'
                  AND Nutrition_Profile__c = :profile.Id
                  AND Logged_DateTime__c = TODAY
                WITH USER_MODE
                ORDER BY Logged_DateTime__c ASC
                LIMIT 20
            ] : new List<Meal__c>();

            // Callout first — no DML may precede it in the transaction. This legacy
            // path logs the meal at the current time, so pass now() as the meal timing.
            String ctx = WMF_GeminiComm.buildAnalysisContext(profile, todayMeals, System.now());
            WMF_GeminiComm.AnalysisResult gem = WMF_GeminiComm.analyseImage(photoBase64, mimeType, notes, ctx);

            // Nutrition_Profile__c is a master-detail parent — every Meal__c needs one.
            // (profile already fetched above)
            Id profileId = profile != null ? profile.Id : null;

            Meal__c meal = new Meal__c(
                Logged_DateTime__c        = System.now(),
                Meal_Notes__c             = notes,
                Nutrition_Profile__c      = profileId,
                Analysis_Attempt_Count__c = 1
            );

            if (gem.success) {
                meal.Status__c                = 'Analyzed';
                meal.Calories__c              = gem.calories;
                meal.Protein_g__c             = gem.proteinG;
                meal.Carbs_g__c               = gem.carbsG;
                meal.Fat_g__c                 = gem.fatG;
                meal.Protein_Pct__c           = gem.proteinPct;
                meal.Carbs_Pct__c             = gem.carbsPct;
                meal.Fat_Pct__c               = gem.fatPct;
                meal.Meal_Analysis__c         = gem.mealAnalysis;
                meal.Last_Analysis_Outcome__c = 'Success';
                meal.Last_Analysis_Error__c   = null;
            } else {
                meal.Status__c                = 'Analysis Pending';
                meal.Last_Analysis_Outcome__c = 'Failed';
                meal.Last_Analysis_Error__c   = gem.errorMessage;
            }

            Database.insert(meal, AccessLevel.USER_MODE);

            // Attach the photo only after insert so the meal Id exists to link against
            if (String.isNotBlank(photoBase64)) {
                ContentVersion cv = new ContentVersion(
                    Title                  = deriveTitle(fileName),
                    PathOnClient           = String.isNotBlank(fileName) ? fileName : 'meal.jpg',
                    FirstPublishLocationId = meal.Id,
                    VersionData            = EncodingUtil.base64Decode(photoBase64)
                );
                Database.insert(cv, AccessLevel.USER_MODE);
            }

            output.success          = gem.success;
            output.mealId           = meal.Id;
            output.status           = meal.Status__c;
            output.calories         = meal.Calories__c;
            output.proteinG         = meal.Protein_g__c;
            output.carbsG           = meal.Carbs_g__c;
            output.fatG             = meal.Fat_g__c;
            output.proteinPct       = meal.Protein_Pct__c;
            output.carbsPct         = meal.Carbs_Pct__c;
            output.fatPct           = meal.Fat_Pct__c;
            output.mealAnalysis = gem.mealAnalysis;
            output.debugTrail       = gem.debugTrail;
            if (!gem.success) output.errorMessage = gem.errorMessage;

        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
        return output;
    }

    // ── Today's meal list for the timeline card ──────────────────────────────
    // WHAT: returns every meal logged today for the active profile, with enough
    // summary data to render a timeline tile and a ContentVersion Id for the thumbnail.
    // HOW: queries meals for today with USER_MODE, then batch-queries ContentDocumentLink
    // to pick up each meal's latest photo version Id (null when no photo).
    // WHAT: returns the meal list for the selected day scoped to the profile.
    // HOW: uses a UTC datetime range (computed client-side in the profile owner's timezone)
    // so cross-timezone profile switching shows the correct set of meals. Early-morning
    // meals in forward timezones (e.g. IST breakfast) are no longer missed by an org
    // running in a western timezone.
    @AuraEnabled(cacheable=false)
    public static List<MealSummary> getTodayMeals(Id profileId, String startUtc, String endUtc) {
        if (profileId == null) return new List<MealSummary>();
        Datetime startDt;
        Datetime endDt;
        if (String.isNotBlank(startUtc) && String.isNotBlank(endUtc)) {
            startDt = (Datetime) JSON.deserialize('"' + startUtc + '"', Datetime.class);
            endDt   = (Datetime) JSON.deserialize('"' + endUtc   + '"', Datetime.class);
        } else {
            startDt = Datetime.newInstance(Date.today(), Time.newInstance(0, 0, 0, 0));
            endDt   = startDt.addDays(1);
        }
        List<Meal__c> meals = [
            SELECT Id, Logged_DateTime__c, Status__c, Calories__c, Meal_Notes__c
            FROM Meal__c
            WHERE Logged_DateTime__c >= :startDt
              AND Logged_DateTime__c < :endDt
              AND Nutrition_Profile__c = :profileId
            WITH USER_MODE
            ORDER BY Logged_DateTime__c ASC
            LIMIT 20
        ];
        if (meals.isEmpty()) return new List<MealSummary>();

        Set<Id> mealIds = (new Map<Id, Meal__c>(meals)).keySet();
        Map<Id, String> photoMap = new Map<Id, String>();
        for (ContentDocumentLink cdl : [
            SELECT LinkedEntityId, ContentDocument.LatestPublishedVersionId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :mealIds
            WITH USER_MODE
        ]) {
            if (cdl.ContentDocument != null && cdl.ContentDocument.LatestPublishedVersionId != null) {
                // Keep first photo encountered per meal (meals normally have one photo)
                if (!photoMap.containsKey(cdl.LinkedEntityId)) {
                    photoMap.put(cdl.LinkedEntityId, (String) cdl.ContentDocument.LatestPublishedVersionId);
                }
            }
        }

        List<MealSummary> output = new List<MealSummary>();
        for (Meal__c m : meals) {
            MealSummary s  = new MealSummary();
            s.mealId           = m.Id;
            s.loggedDatetime   = m.Logged_DateTime__c.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
            s.status           = m.Status__c;
            s.calories         = m.Calories__c;
            s.mealNotes        = m.Meal_Notes__c;
            s.contentVersionId = photoMap.get(m.Id);
            output.add(s);
        }
        return output;
    }

    // ── Load stored analysis result for a previously logged meal ─────────────
    // WHAT: reads the persisted macro data + photo from Salesforce (no Gemini callout)
    // and returns a MealAnalysisResult that the LWC can display using the same result
    // view as a freshly analysed meal.
    @AuraEnabled(cacheable=false)
    public static MealAnalysisResult getMealResult(String mealId) {
        MealAnalysisResult output = new MealAnalysisResult();
        try {
            Meal__c m = [
                SELECT Id, Status__c, Meal_Notes__c, Logged_DateTime__c,
                       Calories__c, Protein_g__c, Carbs_g__c, Fat_g__c,
                       Protein_Pct__c, Carbs_Pct__c, Fat_Pct__c, Meal_Analysis__c
                FROM Meal__c WHERE Id = :mealId WITH USER_MODE LIMIT 1
            ];
            List<ContentDocumentLink> links = [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :mealId
                WITH USER_MODE LIMIT 1
            ];
            if (!links.isEmpty()) {
                ContentVersion cv = [
                    SELECT VersionData, FileExtension
                    FROM ContentVersion
                    WHERE ContentDocumentId = :links[0].ContentDocumentId
                      AND IsLatest = true
                    WITH USER_MODE LIMIT 1
                ];
                String mime = mimeTypeFromExtension(cv.FileExtension);
                output.photoBase64 = 'data:' + mime + ';base64,' + EncodingUtil.base64Encode(cv.VersionData);
            }
            output.success         = (m.Status__c == 'Analyzed');
            output.mealId          = m.Id;
            output.status          = m.Status__c;
            output.mealNotes       = m.Meal_Notes__c;
            output.loggedDatetime  = m.Logged_DateTime__c.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
            output.calories     = m.Calories__c;
            output.proteinG     = m.Protein_g__c;
            output.carbsG       = m.Carbs_g__c;
            output.fatG         = m.Fat_g__c;
            output.proteinPct   = m.Protein_Pct__c;
            output.carbsPct     = m.Carbs_Pct__c;
            output.fatPct       = m.Fat_Pct__c;
            output.mealAnalysis = m.Meal_Analysis__c;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
        return output;
    }

    // Maps a file extension to its image MIME type for the Gemini inlineData part;
    // defaults to image/jpeg for blank or unrecognised extensions.
    private static String mimeTypeFromExtension(String ext) {
        if (String.isBlank(ext)) return 'image/jpeg';
        switch on ext.toLowerCase() {
            when 'png'        { return 'image/png'; }
            when 'gif'        { return 'image/gif'; }
            when 'webp'       { return 'image/webp'; }
            when 'heic','heif'{ return 'image/heic'; }
            when else         { return 'image/jpeg'; }
        }
    }

    // Derives a ContentVersion Title from a file name by stripping the extension;
    // returns a "Meal Photo" default when the name is blank.
    private static String deriveTitle(String fileName) {
        if (String.isBlank(fileName)) return 'Meal Photo';
        Integer dot = fileName.lastIndexOf('.');
        return (dot > 0) ? fileName.substring(0, dot) : fileName;
    }
}