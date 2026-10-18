import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { publish, MessageContext } from 'lightning/messageService';
import MEAL_LOGGED_CHANNEL    from '@salesforce/messageChannel/MealLogged__c';
import THEME_SYNC_CHANNEL     from '@salesforce/messageChannel/ThemeSync__c';
import PROFILE_SELECTED_CHANNEL from '@salesforce/messageChannel/ProfileSelected__c';
import USER_ID                from '@salesforce/user/Id';
import CAN_MODIFY_ALL         from '@salesforce/userPermission/ModifyAllData';
import createMealRecord          from '@salesforce/apex/WMF_MealAnalysisController.createMealRecord';
import uploadMealPhoto           from '@salesforce/apex/WMF_MealAnalysisController.uploadMealPhoto';
import analyseExistingMeal       from '@salesforce/apex/WMF_MealAnalysisController.analyseExistingMeal';
import getTodayStats             from '@salesforce/apex/WMF_MealAnalysisController.getTodayStats';
import getTodayMeals             from '@salesforce/apex/WMF_MealAnalysisController.getTodayMeals';
import getMealResult             from '@salesforce/apex/WMF_MealAnalysisController.getMealResult';
import getActiveNutritionProfile from '@salesforce/apex/WMF_MealAnalysisController.getActiveNutritionProfile';
import getAllNutritionProfiles   from '@salesforce/apex/WMF_MealAnalysisController.getAllNutritionProfiles';
import selectNutritionProfile    from '@salesforce/apex/WMF_MealAnalysisController.selectNutritionProfile';
import { readPhotoTimestamp } from './photoTimestamp';

// SVG pie chart constants
const CX = 110, CY = 110, R = 100;
// SLDS-themed colours: carbs = red/maroon, protein = green/teal, fat = yellow
const PIE_COLORS = ['#E03F4F', '#639754', '#F8C463'];
// Macro key order must match PIE_COLORS
const MACRO_ORDER = ['carbsPct', 'proteinPct', 'fatPct'];
const MACRO_NAMES = ['Carbs', 'Protein', 'Fat'];

// Default calorie reference — overridden at runtime by the active profile's
// Daily_Caloric_Threshold__c field once the profile resolves.
const DEFAULT_CALORIE_TARGET = 2000;

export default class MealCapture extends NavigationMixin(LightningElement) {
    @track photoPreviewUrl;
    @track mealNotes = '';
    @track darkMode = true; // default to dark mode on page load

    _phase          = 'capture';
    _result         = null;
    _is503          = false;
    _photoBase64;
    _photoMimeType;
    _photoFileName;
    _todayStats     = { mealCount: 0, totalCalories: 0 };
    @track _todayMeals      = [];
    @track _timelineOffset  = 0;    // 0 = today, -1 = yesterday, etc.
    @track _profileTimeZone = null; // IANA timezone of the active profile's user (reactive so timelineClusters re-evaluates on switch)

    @track _profileLoading    = true;
    @track _hasProfile        = false;
    @track _welcomeName       = '';
    _activeProfileId;
    _activeProfileUserId      = null;  // User__c of the active profile; compared vs USER_ID for edit gating
    _activeProfileIsActive    = true;  // Nutrition_Profile__c.Active__c of the shown profile; inactive ones are view-only
    _caloricThreshold         = DEFAULT_CALORIE_TARGET;

    @track showProfileModal        = false;
    @track isLoadingProfileOptions = false;
    @track _profileData            = [];   // raw profile objects from Apex for tile rendering
    @track selectedProfileId;

    @wire(MessageContext)
    _messageContext;
    _loggedDateTime = new Date().toISOString();
    // True once the user has typed their own date/time, so a later photo never overrides it.
    _loggedDateTimeEdited = false;

    // Lifecycle hook: fetch today's running stats, resolve the system-wide
    // Nutrition Profile that gates/personalises the UI, and broadcast the
    // initial theme so sibling components (e.g. mealMacroTrend) land in the same mode.
    connectedCallback() {
        this._loadNutritionProfile();
        this._publishTheme();
    }

    // Fetches the system-wide last-modified Nutrition Profile (if any) and its
    // resolved display name, then loads today's stats scoped to that profile.
    // Stats are loaded here (not in parallel from connectedCallback) so they
    // always reflect the resolved active profile's meals, not all meals today.
    async _loadNutritionProfile() {
        try {
            const info = await getActiveNutritionProfile();
            this._activeProfileId     = (info && info.profileId) || undefined;
            this._hasProfile          = !!(info && info.profileId);
            this._welcomeName         = (info && info.displayName) || '';
            this._caloricThreshold    = (info && info.dailyCaloricThreshold) || DEFAULT_CALORIE_TARGET;
            this._activeProfileUserId = (info && info.profileUserId) || null;
            this._profileTimeZone     = (info && info.userTimeZone)    || null;
            this._activeProfileIsActive = !info || info.profileActive !== false;
        } catch (e) {
            this._activeProfileId    = undefined;
            this._hasProfile         = false;
            this._welcomeName        = '';
            this._caloricThreshold   = DEFAULT_CALORIE_TARGET;
            this._activeProfileUserId = null;
            this._activeProfileIsActive = true;
        } finally {
            this._profileLoading = false;
        }
        this._loadTodayStats(this._activeProfileId);
        this._loadTodayMeals(this._activeProfileId);
    }

    // ── Nutrition Profile switcher modal ─────────────────────────────────────
    // Opens the modal and loads every Nutrition Profile in the org as tile cards,
    // pre-selecting whichever one is currently active.
    handleOpenProfileModal() {
        this.showProfileModal  = true;
        // An inactive profile isn't a tile, so leave nothing pre-selected in that case.
        this.selectedProfileId = this._activeProfileIsActive ? this._activeProfileId : undefined;
        this._loadProfileOptions();
    }

    async _loadProfileOptions() {
        this.isLoadingProfileOptions = true;
        try {
            const profiles = await getAllNutritionProfiles();
            // Only Active profiles can be switched to (inactive ones keep charts/timeline elsewhere).
            this._profileData = (profiles || []).filter(p => p.profileActive !== false);
        } catch (e) {
            this._profileData = [];
            const msg = (e.body && e.body.message) || e.message || 'Could not load Nutrition Profiles.';
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could Not Load Profiles', message: msg, variant: 'error'
            }));
        } finally {
            this.isLoadingProfileOptions = false;
        }
    }

    get hasProfileOptions() {
        return this._profileData && this._profileData.length > 0;
    }

    get isConfirmSelectionDisabled() {
        return !this.selectedProfileId;
    }

    // Builds rich tile objects from the raw profile data. Computed as a getter
    // so the tile class (selected/unselected) re-evaluates reactively when
    // selectedProfileId changes without any extra tracking.
    get profileTiles() {
        return (this._profileData || []).map(p => {
            const selected = p.profileId === this.selectedProfileId;
            const parts = [];
            if (p.age) parts.push(`Age ${p.age}`);
            parts.push(`${p.dailyCaloricThreshold || 2000} kcal/day`);
            return {
                profileId:    p.profileId,
                fullUserName: p.fullUserName || p.displayName || 'Unknown',
                metaLine:     parts.join(' · '),
                isSelected:   selected,
                ariaChecked:  String(selected),
                tileClass:    `wmf-profile-tile${selected ? ' wmf-profile-tile--selected' : ''}`,
                checkClass:   `wmf-tile-check${selected ? ' wmf-tile-check--selected' : ''}`,
                photoUrl:     p.userPhotoUrl || null
            };
        });
    }

    handleTileClick(event) {
        this.selectedProfileId = event.currentTarget.dataset.id;
    }

    handleTileKeydown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            this.selectedProfileId = event.currentTarget.dataset.id;
            event.preventDefault();
        }
    }

    handleCloseProfileModal() {
        this.showProfileModal = false;
    }

    // Switches the active profile locally: fetches the selected profile's info (no DML),
    // updates this component's reactive state, and broadcasts via LMS so the chart LWCs
    // (mealMacroTrend, mealCalorieTrend) refresh their data for the chosen profile live.
    async handleConfirmProfileSelection() {
        if (!this.selectedProfileId) return;
        try {
            const info = await selectNutritionProfile({ profileId: this.selectedProfileId });
            // Update own reactive state
            this._activeProfileId     = info.profileId;
            this._hasProfile          = true;
            this._welcomeName         = info.displayName || '';
            this._caloricThreshold    = info.dailyCaloricThreshold || DEFAULT_CALORIE_TARGET;
            this._activeProfileUserId = info.profileUserId || null;
            this._profileTimeZone     = info.userTimeZone || null;
            this._activeProfileIsActive = info.profileActive !== false;
            // Clear any meal result/capture carried over from the previous profile
            // so the newly selected profile starts fresh (no lingering meal in the UI).
            this._resetCaptureState();
            // Reload today stats + meal timeline scoped to the newly selected profile
            this._timelineOffset = 0; // reset to today's view for the new profile
            this._loadTodayStats(this._activeProfileId);
            this._loadTodayMeals(this._activeProfileId);
            // Broadcast to chart siblings so they re-query with the new profileId
            publish(this._messageContext, PROFILE_SELECTED_CHANNEL, {
                profileId:            info.profileId,
                displayName:          info.displayName,
                dailyCaloricThreshold: info.dailyCaloricThreshold,
                profileUserId:         info.profileUserId
            });
            this.showProfileModal = false;
        } catch (e) {
            const msg = (e.body && e.body.message) || e.message || 'Could not switch Nutrition Profile.';
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could Not Switch Profile', message: msg, variant: 'error', mode: 'sticky'
            }));
        }
    }

    // ── Nutrition Profile gate ──────────────────────────────────────────────
    get isProfileLoading()    { return this._profileLoading; }
    get hasNutritionProfile() { return this._hasProfile; }
    get showProfileGate()     { return !this._profileLoading && !this._hasProfile; }
    // "Welcome <FirstName>" when a name is available; plain "Welcome" otherwise —
    // never a dangling "Welcome " with trailing whitespace.
    get welcomeTitle() {
        return this._welcomeName ? `Welcome ${this._welcomeName}` : 'Welcome';
    }

    // Profile first name exposed separately so the template can apply gradient
    // styling only to the name part, not the "Welcome" prefix.
    get profileFirstName() { return this._welcomeName || ''; }
    get hasWelcomeName()   { return !!this._welcomeName; }

    // True when the running user may log meals against the current profile:
    // their own profile (profileUserId == logged-in user) OR System Admin (ModifyAllData).
    // Inactive profiles are view-only: the Log Meal form is hidden for them (UI only —
    // there is deliberately no server-side block on creating meals for them).
    get canLogMeals() {
        return this._activeProfileIsActive
            && (this._activeProfileUserId === USER_ID || CAN_MODIFY_ALL === true);
    }
    // True when the profile on screen is inactive (drives the notice that replaces the form).
    get isActiveProfileInactive() { return !this._activeProfileIsActive; }

    // Navigates to the standard "New" page for Nutrition_Profile__c so the user
    // can create the profile the gate requires before they can log a meal.
    handleCreateProfile() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Nutrition_Profile__c',
                actionName: 'new'
            }
        });
    }

    // Broadcast the current mode on the ThemeSync channel so both LWCs toggle together.
    _publishTheme() {
        publish(this._messageContext, THEME_SYNC_CHANNEL, {
            mode: this.darkMode ? 'Dark' : 'Light'
        });
    }

    // Fetches meal count + calorie total for the selected timeline day.
    // Uses UTC datetime range (profile-timezone aware) so cross-timezone profiles
    // always surface the correct set of meals. Failure swallowed — stats are non-critical.
    async _loadTodayStats(profileId) {
        try {
            const { startUtc, endUtc } = this._dayUtcRange;
            const s = await getTodayStats({ profileId: profileId || null, startUtc, endUtc });
            this._todayStats = {
                mealCount:     parseInt(s.mealCount,     10) || 0,
                totalCalories: Math.round(+s.totalCalories || 0)
            };
        } catch (e) { /* non-critical */ }
    }

    // Fetches the meal list for the active timeline day, scoped to the given profile.
    // Uses UTC datetime range so meals in the profile owner's timezone are always
    // captured correctly regardless of the viewer's or org's timezone.
    async _loadTodayMeals(profileId) {
        try {
            const { startUtc, endUtc } = this._dayUtcRange;
            const meals = await getTodayMeals({ profileId: profileId || null, startUtc, endUtc });
            this._todayMeals = meals || [];
        } catch (e) { /* non-critical */ }
    }

    // Returns the UTC datetime that corresponds to midnight (00:00:00) of a given
    // calendar date in the specified IANA timezone. Uses noon UTC as the probe point
    // to avoid DST edge cases (noon is always the same calendar date in every tz).
    _midnightUtcInTz(year, month, day, timezone) {
        const noonUtc = new Date(Date.UTC(year, month - 1, day, 12, 0, 0));
        try {
            const parts = new Intl.DateTimeFormat('en-US', {
                timeZone: timezone, hour: 'numeric', minute: 'numeric', hour12: false
            }).formatToParts(noonUtc);
            const h = parseInt(parts.find(p => p.type === 'hour').value,   10);
            const m = parseInt(parts.find(p => p.type === 'minute').value, 10);
            // noonUtc corresponds to h:m in the target tz.
            // Midnight in the target tz = noonUtc - h hours - m minutes.
            return new Date(noonUtc.getTime() - (h * 60 + m) * 60000);
        } catch (e) {
            return new Date(Date.UTC(year, month - 1, day, 0, 0, 0));
        }
    }

    // Computes { startUtc, endUtc, dateLabel } for the day at the current timeline
    // offset, expressed in the active profile owner's timezone.
    // Using UTC datetime ranges (not date strings) ensures cross-timezone profile
    // switching returns the correct meals — the SOQL date-function approach is tied
    // to the org timezone and misses early-morning meals in forward timezones.
    get _dayUtcRange() {
        const tz = this._profileTimeZone;
        const offset = this._timelineOffset;
        const now = new Date();

        let year, month, day;
        if (tz) {
            try {
                const p = new Intl.DateTimeFormat('en-US', {
                    timeZone: tz, year: 'numeric', month: 'numeric', day: 'numeric'
                }).formatToParts(now);
                year  = parseInt(p.find(x => x.type === 'year').value);
                month = parseInt(p.find(x => x.type === 'month').value);
                day   = parseInt(p.find(x => x.type === 'day').value);
            } catch (e) {
                year = now.getFullYear(); month = now.getMonth() + 1; day = now.getDate();
            }
        } else {
            year = now.getFullYear(); month = now.getMonth() + 1; day = now.getDate();
        }

        // Apply offset to get the target day
        const base = new Date(year, month - 1, day + offset);
        const ty = base.getFullYear(), tm = base.getMonth() + 1, td = base.getDate();

        const effectiveTz = tz || Intl.DateTimeFormat().resolvedOptions().timeZone;
        const startUtcDt  = this._midnightUtcInTz(ty, tm, td,     effectiveTz);
        const endUtcDt    = this._midnightUtcInTz(ty, tm, td + 1, effectiveTz);

        const toIso = d => d.toISOString().replace('.000', '');
        return {
            startUtc:  toIso(startUtcDt),
            endUtc:    toIso(endUtcDt),
            dateLabel: offset === 0 ? null
                : base.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' })
        };
    }

    // ── Timeline day navigation ────────────────────────────────────────────────
    // True when the timeline is showing today — disables the forward (next day) chevron.
    get isTimelineToday() { return this._timelineOffset >= 0; }

    // Label shown next to the title: "Today" on today's view, short date otherwise.
    get timelineDateLabel() {
        if (this._timelineOffset === 0) return 'Today';
        return this._dayUtcRange.dateLabel || 'Today';
    }

    // Navigate one day back; reload both the progress bar and meal tiles.
    handleTimelinePrev() {
        this._timelineOffset--;
        this._loadTodayStats(this._activeProfileId);
        this._loadTodayMeals(this._activeProfileId);
    }

    // Navigate one day forward (capped at today); reload both cards.
    handleTimelineNext() {
        if (this._timelineOffset >= 0) return;
        this._timelineOffset++;
        this._loadTodayStats(this._activeProfileId);
        this._loadTodayMeals(this._activeProfileId);
    }

    // ── Today's Meals timeline ─────────────────────────────────────────────────
    // True when there is at least one meal to render in the timeline.
    get hasTodayMeals() { return this._todayMeals && this._todayMeals.length > 0; }

    // Always show the timeline card when a profile exists — mirrors the progress bar
    // which shows at 0 meals. Users can navigate days even before logging any meals.
    get showMealTimeline() { return this._hasProfile; }

    // Dynamic label for the stats card header: "Today" on current day, short date otherwise.
    get todayStatsDateLabel() {
        if (this._timelineOffset === 0) return 'Today';
        return this._dayUtcRange.dateLabel || 'Today';
    }

    // ── Timezone-aware time helpers ───────────────────────────────────────────
    // Returns minutes-from-midnight for an ISO datetime in the active profile
    // owner's timezone so the timeline positions meals at their LOCAL time for
    // that user — not the viewing user's browser timezone.
    _getMinutesInProfileTz(isoDatetime) {
        const dt = new Date(isoDatetime);
        const tz = this._profileTimeZone;
        if (tz) {
            try {
                const parts = new Intl.DateTimeFormat('en-US', {
                    timeZone: tz, hour: 'numeric', minute: 'numeric', hour12: false
                }).formatToParts(dt);
                const h = parseInt(parts.find(p => p.type === 'hour').value,   10);
                const m = parseInt(parts.find(p => p.type === 'minute').value, 10);
                return (isNaN(h) ? dt.getHours() : h) * 60
                     + (isNaN(m) ? dt.getMinutes() : m);
            } catch (e) { /* fall through */ }
        }
        return dt.getHours() * 60 + dt.getMinutes();
    }

    // Returns a formatted "h:mm AM/PM" string in the active profile owner's timezone.
    _formatTimeInProfileTz(isoDatetime) {
        const dt = new Date(isoDatetime);
        const tz = this._profileTimeZone;
        if (tz) {
            try {
                return new Intl.DateTimeFormat('en-US', {
                    timeZone: tz, hour: 'numeric', minute: '2-digit', hour12: true
                }).format(dt);
            } catch (e) { /* fall through */ }
        }
        const h   = dt.getHours();
        const ap  = h >= 12 ? 'PM' : 'AM';
        const h12 = h > 12 ? h - 12 : (h === 0 ? 12 : h);
        return `${h12}:${String(dt.getMinutes()).padStart(2, '0')} ${ap}`;
    }

    // ── Fasting ratio ─────────────────────────────────────────────────────────
    // Shows <fasted> : <eating window> for PAST days only (not today), once at
    // least 2 meals are logged so both ends of the eating window are known.
    // Both values round to the nearest whole hour and always sum to 24.
    get fastingRatio() {
        // Show for any day (today or past) as long as ≥2 meals exist —
        // the first and last meal define the eating window regardless of viewer.
        const meals = this._todayMeals || [];
        if (meals.length < 2) return null;

        const sorted = [...meals].sort(
            (a, b) => new Date(a.loggedDatetime) - new Date(b.loggedDatetime)
        );
        const eatingWindowH = Math.round(
            (this._getMinutesInProfileTz(sorted[sorted.length - 1].loggedDatetime)
           - this._getMinutesInProfileTz(sorted[0].loggedDatetime)) / 60
        );
        if (eatingWindowH <= 0) return null; // meals too close together

        const fastedH = 24 - eatingWindowH;
        // Colour palette matches the pie-chart slices for consistency:
        //   red (#E03F4F = carbs) → fasted ≤ 12h (short fast)
        //   amber (#F8C463 = fat)  → fasted 13–15h (moderate)
        //   green (#639754 = protein) → fasted > 15h (strong fast)
        const color = fastedH <= 12 ? '#E03F4F'
                    : fastedH <= 15 ? '#F8C463'
                    : '#639754';
        return { label: `${fastedH} : ${eatingWindowH}`, color };
    }

    get fastingRatioStyle() {
        return this.fastingRatio ? `color: ${this.fastingRatio.color};` : '';
    }

    // Builds timeline cluster objects for the template.
    //
    // Dynamic scaling: the in-window span is NOT a fixed 6AM–6PM ruler.
    // Instead, the left anchor is the FIRST in-window meal's actual time and the
    // right anchor is always 6 PM. This squeezes the first meal to the leftmost
    // position and proportionally spreads the rest of the day towards 6 PM —
    // so a lone 10 AM meal starts near the sunrise icon and leaves the full visual
    // width available for any later meals.
    //
    // OOR meals (before 6 AM / after 6 PM) are pinned at the extreme edges with
    // a red border and are excluded from the dynamic scaling.
    get timelineClusters() {
        const meals = this._todayMeals || [];
        if (!meals.length) return [];

        const DAWN_MIN    = 6 * 60;   // 360 min from midnight
        const DUSK_MIN    = 18 * 60;  // 1080 min from midnight
        const CLUSTER_GAP = 30;       // merge meals within 30 raw minutes

        // ── Build sorted flat tile list ───────────────────────────────────────
        const tiles = [...meals].map(m => {
            // Use the profile owner's timezone so the timeline always shows the
            // meal at the time it was logged locally — not the viewer's local time.
            const min = this._getMinutesInProfileTz(m.loggedDatetime);
            const beforeDawn  = min < DAWN_MIN;
            const afterDusk   = min > DUSK_MIN;
            const outOfWindow = beforeDawn || afterDusk;
            const thumbnailUrl = m.contentVersionId
                ? `/sfc/servlet.shepherd/version/renditionDownload?rendition=THUMB120BY90&versionId=${m.contentVersionId}&operationContext=CHATTER`
                : null;
            const timeStr = this._formatTimeInProfileTz(m.loggedDatetime);
            return {
                mealId: m.mealId, rawMin: min,
                outOfWindow, beforeDawn, afterDusk,
                thumbnailUrl, timeStr,
                tileClass: `wmf-meal-tile${outOfWindow ? ' wmf-meal-tile--oor' : ''}`
            };
        }).sort((a, b) => a.rawMin - b.rawMin);

        // ── Dynamic scale: left anchor = first in-window meal; right = 6 PM ──
        const inWindowTiles = tiles.filter(t => !t.outOfWindow);
        const dynStart = inWindowTiles.length > 0 ? inWindowTiles[0].rawMin : DAWN_MIN;
        const dynEnd   = DUSK_MIN;
        const dynSpan  = Math.max(1, dynEnd - dynStart); // guard against zero span

        // Assign display pct to every tile
        for (const tile of tiles) {
            if (tile.beforeDawn) {
                tile.pct = 2;   // pinned extreme-left (OOR)
            } else if (tile.afterDusk) {
                tile.pct = 98;  // pinned extreme-right (OOR)
            } else {
                // Map [dynStart, DUSK_MIN] → display [4, 92] with edge buffer
                const rawPct = ((tile.rawMin - dynStart) / dynSpan) * 100;
                tile.pct = rawPct * 0.88 + 4;
            }
        }

        // ── Group into clusters (OOR tiles never merge with in-window) ────────
        const clusters = [];
        for (const tile of tiles) {
            const last = clusters[clusters.length - 1];
            const canMerge = last
                && !tile.outOfWindow
                && !last.meals[0].outOfWindow
                && (tile.rawMin - last._lastRawMin) <= CLUSTER_GAP;
            if (canMerge) {
                last.meals.push(tile);
                last._lastRawMin = tile.rawMin;
            } else {
                clusters.push({ meals: [tile], _lastRawMin: tile.rawMin });
            }
        }

        // Average pct per cluster from its member tile pcts
        clusters.forEach(c => {
            c.pct = c.meals.reduce((s, t) => s + t.pct, 0) / c.meals.length;
        });

        // ── Collision avoidance (in-window only) ──────────────────────────────
        const TILE_PCT  = 15;  // ~50px tile on ~333px container
        const inWin = clusters.filter(c => !c.meals[0].outOfWindow);
        for (let i = 1; i < inWin.length; i++) {
            const prev = inWin[i - 1];
            const curr = inWin[i];
            const prevRight = prev.pct + (prev.meals.length * TILE_PCT) / 2;
            const currLeft  = curr.pct - (curr.meals.length * TILE_PCT) / 2;
            if (currLeft < prevRight + 1) {
                curr.pct = prevRight + 1 + (curr.meals.length * TILE_PCT) / 2;
            }
            curr.pct = Math.min(94, curr.pct); // cap before right icon
        }

        // ── Final template objects ────────────────────────────────────────────
        return clusters.map((c, i) => ({
            key:       `c-${i}`,
            style:     `left: ${c.pct.toFixed(1)}%; transform: translateX(-50%);`,
            timeLabel: c.meals[0].timeStr,
            meals:     c.meals
        }));
    }

    // Formats the logged datetime for display in the result view.
    // Uses the active capture datetime for new meals, or the datetime loaded from
    // a historical tile click (set via _loggedDateTime in handleMealTileClick).
    get resultLoggedTime() {
        if (!this._loggedDateTime) return null;
        try {
            const dt = new Date(this._loggedDateTime);
            const opts = {
                weekday: 'short', month: 'short', day: 'numeric',
                hour: '2-digit', minute: '2-digit'
            };
            if (this._profileTimeZone) opts.timeZone = this._profileTimeZone;
            return dt.toLocaleString([], opts);
        } catch (e) { return null; }
    }

    // Handles a click on a today's-meal timeline tile: loads the stored analysis
    // result (no Gemini re-run) and updates the result view in-place.
    // Deliberately does NOT change _phase before the data arrives — avoids the
    // analysing-spinner flicker, content-stack collapse, and layout shift.
    async handleMealTileClick(event) {
        const mealId = event.currentTarget.dataset.mealId;
        if (!mealId) return;
        try {
            const result = await getMealResult({ mealId });
            this.photoPreviewUrl = result.photoBase64    || undefined;
            this.mealNotes       = result.mealNotes      || '';
            this._loggedDateTime = result.loggedDatetime || new Date().toISOString();
            this._result         = result;
            this._phase          = result.success ? 'complete' : 'pending';
            this._scrollToTop();
        } catch (e) {
            const msg = (e.body && e.body.message) || e.message || 'Could not load meal data.';
            this.dispatchEvent(new ShowToastEvent({
                title: 'Could Not Load Meal', message: msg, variant: 'error'
            }));
        }
    }

    // ── Phase flags ───────────────────────────────────────────────────────────
    // True while in the initial capture screen — drives which section renders.
    get isCapture()       { return this._phase === 'capture';   }
    // True while the analysis spinner should show.
    get isAnalysing()     { return this._phase === 'analysing'; }
    // True once analysis has succeeded and results are ready to display.
    get isComplete()      { return this._phase === 'complete';  }
    // True when a photo preview is present.
    get hasPhoto()        { return !!this.photoPreviewUrl;       }
    // Log Meal enabled once EITHER a photo is attached OR a description is entered
    get isLogDisabled()   { return !this.photoPreviewUrl && !(this.mealNotes && this.mealNotes.trim()); }
    // Show the today's-progress card in every phase except mid-analysis.
    get showTodayStats()  { return this._phase !== 'analysing'; }
    // Selected logged date/time bound to the datetime input.
    get loggedDateTime()  { return this._loggedDateTime; }
    get maxDateTime()     { return new Date().toISOString(); } // block future dates in the picker

    // True only when the logged date falls on the running user's local "today".
    _isLoggedToday() {
        const d = new Date(this._loggedDateTime);
        const n = new Date();
        return d.getFullYear() === n.getFullYear()
            && d.getMonth() === n.getMonth()
            && d.getDate() === n.getDate();
    }
    // Show the "analysis pending" card only for non-503 pending states (503 gets its own toast).
    get showPendingCard() { return this._phase === 'pending' && !this._is503; }
    // True when the user has typed any notes.
    get hasMealNotes()    { return !!this.mealNotes; }

    // ── Dark mode toggle ────────────────────────────────────────────────────
    // Root CSS class — appends the dark-mode modifier when enabled.
    get rootClass()    { return this.darkMode ? 'wmf-capture wmf-dark' : 'wmf-capture'; }
    // Icon for the theme toggle button.
    get themeIcon()    { return 'utility:topic'; }
    // Accessible alt text describing the action the toggle will perform.
    get themeAltText() { return this.darkMode ? 'Switch to light mode' : 'Switch to dark mode'; }
    // Flip between light and dark themes.
    toggleTheme()      { this.darkMode = !this.darkMode; this._publishTheme(); }

    // Scroll the component back to the top of its scroll container. Runs after the
    // next frame so the newly-rendered analysing view is laid out before scrolling.
    _scrollToTop() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const root = this.template.querySelector('.wmf-capture');
            if (root && root.scrollIntoView) {
                root.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
        });
    }

    // ── Today's progress ──────────────────────────────────────────────────────
    // Today's meal count (0 if stats not yet loaded).
    get todayMealCount()   { return this._todayStats?.mealCount     || 0; }
    // Today's calorie total (0 if stats not yet loaded).
    get todayCalories()    { return this._todayStats?.totalCalories  || 0; }
    // Pluralise "meal(s)" for the count label.
    get todayMealPlural()  { return this.todayMealCount === 1 ? '' : 's'; }
    // Expose the calorie target constant to the template.
    get calorieTarget()    { return this._caloricThreshold; }
    // Progress toward the daily target as a whole percent, capped at 100.
    get todayCaloriesPct() { return Math.round((this.todayCalories / this._caloricThreshold) * 100); }
    // Inline style for the progress bar. Uses the same hex palette as the
    // pie-chart slices for visual consistency across the component.
    //   green  (#639754) = protein colour  → ≤ 50 % of target
    //   amber  (#F8C463) = fat colour      → > 50 % up to 80 %
    //   red    (#E03F4F) = carbs colour    → > 80 %
    get todayBarStyle() {
        const pct = Math.min(100, (this.todayCalories / this._caloricThreshold) * 100);
        let color = '#639754';
        if      (pct > 80) color = '#E03F4F';
        else if (pct > 50) color = '#F8C463';
        return `width: ${pct.toFixed(1)}%; background-color: ${color};`;
    }

    // ── Nutrition result getters ──────────────────────────────────────────────
    // Each getter safely reads an analysis-result field, formatting grams to 1 dp and
    // rounding calories/percentages, and falls back to a zero-value when no result yet.
    get resultCalories()         { return this._result ? Math.round(this._result.calories)          : 0; }
    get resultProteinG()         { return this._result ? (+this._result.proteinG).toFixed(1)        : '0.0'; }
    get resultCarbsG()           { return this._result ? (+this._result.carbsG).toFixed(1)          : '0.0'; }
    get resultFatG()             { return this._result ? (+this._result.fatG).toFixed(1)            : '0.0'; }
    get resultProteinPct()       { return this._result ? Math.round(this._result.proteinPct)        : 0; }
    get resultCarbsPct()         { return this._result ? Math.round(this._result.carbsPct)          : 0; }
    get resultFatPct()           { return this._result ? Math.round(this._result.fatPct)            : 0; }
    // The free-text observations returned by analysis, or null when absent.
    get resultMealAnalysis() { return (this._result && this._result.mealAnalysis) ? this._result.mealAnalysis : null; }
    // True when observations exist to render.
    get hasMealAnalysis()    { return !!this.resultMealAnalysis; }

    // ── Pie chart segment getters ─────────────────────────────────────────────
    // index 0 = carbs (red), 1 = protein (green), 2 = fat (yellow)
    // Carbs slice (index 0) — delegates geometry to _pieSlice.
    get carbsSlice()   { return this._pieSlice(0); }
    // Protein slice (index 1).
    get proteinSlice() { return this._pieSlice(1); }
    // Fat slice (index 2).
    get fatSlice()     { return this._pieSlice(2); }

    // Builds one SVG donut/pie wedge for the macro at `index`. Approach: walk the
    // preceding macros to find this slice's start angle, convert its percentage to a
    // sweep, then trig out the arc endpoints and a mid-angle anchor for the % label.
    _pieSlice(index) {
        const blank = { path: '', showText: false, color: PIE_COLORS[index] };
        if (!this._result) return blank;

        // Accumulate the sweeps of all earlier macros to find where this slice begins.
        const pcts = MACRO_ORDER.map(k => +(this._result[k] || 0));
        let startAngle = -Math.PI / 2; // start at 12 o'clock
        for (let i = 0; i < index; i++) {
            startAngle += (pcts[i] / 100) * 2 * Math.PI;
        }
        const sweep = (pcts[index] / 100) * 2 * Math.PI;
        if (sweep <= 0) return blank; // nothing to draw for a zero-value macro

        // Special case: full-circle slice (100% of one macro).
        // SVG arc degenerates when start == end (sweep = 2π), so use two 180° half-arcs.
        const top    = `${CX} ${(CY - R).toFixed(2)}`;
        const bottom = `${CX} ${(CY + R).toFixed(2)}`;
        if (sweep >= 2 * Math.PI - 0.001) {
            const path = `M ${top} A ${R} ${R} 0 1 1 ${bottom} A ${R} ${R} 0 1 1 ${top} Z`;
            return {
                path,
                color: PIE_COLORS[index],
                name:  MACRO_NAMES[index],
                pct:   100,
                tx:    String(CX),
                ty:    String(CY + 5),
                showText: true
            };
        }

        const endAngle = startAngle + sweep;
        const midAngle = startAngle + sweep / 2;
        const largeArc = sweep > Math.PI ? 1 : 0; // SVG large-arc flag for sweeps > 180°

        // Arc endpoints on the circle (start and end of this wedge).
        const x1 = (CX + R * Math.cos(startAngle)).toFixed(2);
        const y1 = (CY + R * Math.sin(startAngle)).toFixed(2);
        const x2 = (CX + R * Math.cos(endAngle)).toFixed(2);
        const y2 = (CY + R * Math.sin(endAngle)).toFixed(2);

        // Wedge path: move to centre, line to arc start, sweep the arc, close back to centre.
        const path = `M ${CX} ${CY} L ${x1} ${y1} A ${R} ${R} 0 ${largeArc} 1 ${x2} ${y2} Z`;

        // Place the % label partway out along the slice's mid-angle.
        const textR = R * 0.62;
        const tx = (CX + textR * Math.cos(midAngle)).toFixed(2);
        const ty = (CY + textR * Math.sin(midAngle)).toFixed(2);

        return {
            path,
            color: PIE_COLORS[index],
            name:  MACRO_NAMES[index],
            pct:   Math.round(pcts[index]),
            tx, ty,
            showText: pcts[index] >= 7  // hide label if slice is too thin
        };
    }

    // ── File selection + canvas compression ───────────────────────────────────
    // Handles the file input change. Reads the chosen image as a data URL, shows it as
    // the preview, derives its MIME type, then compresses it to base64 for upload —
    // falling back to the raw (uncompressed) bytes if canvas compression throws.
    handleFileSelected(event) {
        const file = event.target.files[0];
        if (!file) return;
        this._photoFileName = file.name;
        this._applyPhotoTimestamp(file);
        const reader = new FileReader();
        reader.onload = async () => {
            const dataUrl = reader.result;
            this.photoPreviewUrl = dataUrl;
            // Extract the MIME type from the "data:<mime>;base64,..." prefix.
            const [meta] = dataUrl.split(',');
            this._photoMimeType = meta.split(':')[1].split(';')[0] || 'image/jpeg';
            try {
                this._photoBase64 = await this._compressPhoto(dataUrl);
            } catch {
                // Compression failed — fall back to the original base64 payload.
                this._photoBase64 = dataUrl.split(',')[1];
            }
        };
        reader.readAsDataURL(file);
    }

    // Defaults "Logged Date & Time" to when the photo was taken (EXIF capture time, else the
    // file's date) so a meal photographed in the morning but logged at night is stamped
    // correctly without manual entry. Skipped if the user already typed a time, or if the
    // photo's timestamp is missing or in the future. Reads the original File because the
    // canvas compression below strips EXIF.
    async _applyPhotoTimestamp(file) {
        if (this._loggedDateTimeEdited) return;
        const ts = await readPhotoTimestamp(file);
        if (!ts || ts.date.getTime() > Date.now() || this._loggedDateTimeEdited) return;
        this._loggedDateTime = ts.date.toISOString();
    }

    // Downscales an image via an offscreen canvas and re-encodes it as JPEG (0.7 quality)
    // to shrink the upload. Approach: load into an Image, cap the longest edge at MAX px
    // while preserving aspect ratio, draw onto the hidden canvas, then read back base64.
    async _compressPhoto(dataUrl) {
        return new Promise((resolve, reject) => {
            const img = new Image();
            img.onerror = reject;
            img.onload = () => {
                try {
                    const MAX = 1024;
                    let w = img.naturalWidth  || img.width  || MAX;
                    let h = img.naturalHeight || img.height || MAX;
                    // Scale the longer side down to MAX, keeping aspect ratio.
                    if (w > MAX || h > MAX) {
                        if (w >= h) { h = Math.round(h * MAX / w); w = MAX; }
                        else        { w = Math.round(w * MAX / h); h = MAX; }
                    }
                    const canvas = this.template.querySelector('.hidden-canvas');
                    canvas.width  = w;
                    canvas.height = h;
                    canvas.getContext('2d').drawImage(img, 0, 0, w, h);
                    // Re-encode as JPEG at 70% quality and keep only the base64 body.
                    const [, b64] = canvas.toDataURL('image/jpeg', 0.7).split(',');
                    this._photoMimeType = 'image/jpeg';
                    if (this._photoFileName) {
                        this._photoFileName = this._photoFileName.replace(/\.[^.]+$/, '.jpg');
                    }
                    resolve(b64);
                } catch (e) { reject(e); }
            };
            img.src = dataUrl;
        });
    }

    // Two-way bind the notes textarea into component state.
    handleNotesChange(event) {
        this.mealNotes = event.detail.value;
    }

    // Updates the logged date/time from the picker, with a failsafe that rejects any
    // future value (resets to now and warns) in case the maxDateTime guard is bypassed.
    handleLoggedDateTimeChange(event) {
        const val = event.detail.value || new Date().toISOString();
        // Failsafe: reject a future date/time and reset to now.
        if (new Date(val).getTime() > Date.now()) {
            this._loggedDateTime = new Date().toISOString();
            this.dispatchEvent(new ShowToastEvent({
                title: 'Future date not allowed',
                message: 'The logged date/time can’t be in the future — reset to now.',
                variant: 'warning'
            }));
        } else {
            this._loggedDateTime = val;
            this._loggedDateTimeEdited = true;
        }
    }

    // ── 3-step save flow ──────────────────────────────────────────────────────
    // Orchestrates the log-and-analyse flow: (1) create the Meal__c record, (2) upload
    // the photo if present, (3) run analysis. Updates today's stats optimistically,
    // handles the async-503 "pending" path, and degrades gracefully on partial failure.
    async handleSave() {
        // Guard: require at least a photo or some notes before doing anything.
        const hasPhoto = !!this._photoBase64;
        const hasNotes = !!(this.mealNotes && this.mealNotes.trim());
        if (!hasPhoto && !hasNotes) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Add a Photo or Description',
                message: 'Attach a photo, write a description, or both before logging.',
                variant: 'warning'
            }));
            return;
        }
        this._phase     = 'analysing';
        this._is503     = false;
        // Mobile: bring the component back to the top so the "Sending to Gemini"
        // analysing animation is in view (the form section above it collapses).
        this._scrollToTop();
        // Today's progress bar must only reflect meals logged for today — a meal
        // logged for a past (or any non-today) date must not move today's totals.
        const countsToday = this._isLoggedToday();
        let mealId;
        try {
            // Step 1: persist the meal shell so we have an Id for the photo + analysis.
            mealId = await createMealRecord({ notes: this.mealNotes, loggedDatetime: this._loggedDateTime });
            // Optimistic count increment — only when the meal is logged for today
            if (countsToday) {
                this._todayStats = {
                    mealCount:    (this._todayStats?.mealCount     || 0) + 1,
                    totalCalories: this._todayStats?.totalCalories || 0
                };
            }

            // Step 2: attach the compressed photo to the meal record (if one was chosen).
            if (hasPhoto) {
                await uploadMealPhoto({
                    mealId:      mealId,
                    photoBase64: this._photoBase64,
                    fileName:    this._photoFileName || 'meal.jpg'
                });
            }

            // Step 3: run the nutrition analysis on the saved meal.
            const result = await analyseExistingMeal({ mealId });

            if (result.success) {
                // Fold the analysed calories into today's running total (today-only).
                if (countsToday) {
                    this._todayStats = {
                        mealCount:    this._todayStats.mealCount,
                        totalCalories: (this._todayStats.totalCalories || 0) + Math.round(+result.calories)
                    };
                }
            } else {
                // Analysis unavailable (503): meal is saved but will be analysed later.
                const is503 = result.errorMessage && result.errorMessage.includes('503');
                if (is503) {
                    this._is503 = true;
                    this.dispatchEvent(new ShowToastEvent({
                        title:   'Your Meal has been logged. Nutrition Analysis processing will happen in some time.',
                        message: 'Please be patient. Enjoy your Meal consciously !',
                        variant: 'warning',
                        mode:    'sticky'
                    }));
                }
            }

            this._result = result;
            this._phase  = result.success ? 'complete' : 'pending';

            // Notify dashboard widgets (e.g. mealMacroTrend) to refresh once a
            // meal is successfully analysed, so the chart re-renders on its own.
            if (result.success) {
                publish(this._messageContext, MEAL_LOGGED_CHANNEL, { mealId });
                // Reload timeline so the newly logged meal tile appears immediately.
                this._loadTodayMeals(this._activeProfileId);
            }

        } catch (err) {
            const msg = (err.body && err.body.message) || err.message || 'An error occurred.';
            // If the record never got created, stay on capture; otherwise the meal
            // exists so surface it as "pending" rather than losing the user's entry.
            if (!mealId) {
                this._phase = 'capture';
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Could Not Save', message: msg, variant: 'error', mode: 'sticky'
                }));
            } else {
                this._result = { success: false, mealId, status: 'Analysis Pending', errorMessage: msg };
                this._phase  = 'pending';
            }
        }
    }

    // Resets all state back to a clean capture screen so the user can log another meal,
    // including clearing the native file inputs (whose value isn't reactive).
    handleLogAnother() {
        this._resetCaptureState();
    }

    // Clears any logged-meal result and the capture form back to a fresh state so
    // the capture phase renders cleanly. Used by "Log Another Meal" and when the
    // Nutrition Profile is switched (so the previous profile's meal doesn't linger).
    _resetCaptureState() {
        this._phase          = 'capture';
        this._result         = null;
        this._is503          = false;
        this.mealNotes       = '';
        this._loggedDateTime = new Date().toISOString();
        this._loggedDateTimeEdited = false;
        this.photoPreviewUrl = undefined;
        this._photoBase64    = undefined;
        this._photoMimeType  = undefined;
        this._photoFileName  = undefined;
        this.template.querySelectorAll('input[type="file"]').forEach(el => { el.value = ''; });
    }
}