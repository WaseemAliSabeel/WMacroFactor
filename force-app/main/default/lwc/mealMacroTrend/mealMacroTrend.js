import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { subscribe, unsubscribe, MessageContext } from 'lightning/messageService';
import MEAL_LOGGED_CHANNEL    from '@salesforce/messageChannel/MealLogged__c';
import THEME_SYNC_CHANNEL     from '@salesforce/messageChannel/ThemeSync__c';
import PROFILE_SELECTED_CHANNEL from '@salesforce/messageChannel/ProfileSelected__c';
import getDailyMacroDistribution from '@salesforce/apex/WMF_MealAnalysisController.getDailyMacroDistribution';
import getActiveNutritionProfile from '@salesforce/apex/WMF_MealAnalysisController.getActiveNutritionProfile';

// Macro colours — kept consistent with the mealCapture donut chart.
const COLOR_CARBS = '#E03F4F';
const COLOR_FAT = '#F8C463';
const COLOR_PROTEIN = '#639754';

// SVG plot geometry (viewBox units).
const VIEW_W = 720;
const VIEW_H = 300;
const PAD_LEFT = 40;
const PAD_RIGHT = 14;
const PLOT_TOP = 14;
const PLOT_BOTTOM = 250; // baseline (0%) — space below for x-axis labels
const PLOT_H = PLOT_BOTTOM - PLOT_TOP;
const MAX_BAR_W = 48;
const MIN_LABEL_H = 18; // hide a segment's % label when the segment is thinner than this
const MIN_GRAMS_H = 24; // show the grams line only when the segment can fit two lines

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

export default class MealMacroTrend extends LightningElement {
    @api daysToShow = 10;
    @api theme = 'Dark';
    @api chartTitle = 'Daily Macro Distribution';

    rows;
    error;

    // Resolved display name of the same system-wide last-modified Nutrition Profile
    // used by mealCapture, appended to the configured chartTitle. Empty until loaded.
    _profileName       = '';
    _selectedProfileId = null; // null → Apex resolves own profile via priority logic

    // Held so refreshApex() can re-query the same wire (manual button + auto-refresh).
    _wiredResult;
    _subscription;
    _themeSubscription;
    _profileSubscription;
    _themeOverride;     // set when a sibling component broadcasts a theme change
    refreshing = false; // drives the spinner during a refresh
    renderSeq = 0;      // bumped each refresh so bar keys change and the fill animation replays

    @wire(MessageContext)
    _messageContext;

    // Wired handler: stores the daily macro rows on success, or a reduced error message
    // on failure, clearing the other so the template only ever shows one state.
    // The provisioned value is retained so it can be refreshed imperatively.
    @wire(getDailyMacroDistribution, { daysBack: '$daysToShow', profileId: '$_selectedProfileId' })
    wiredData(result) {
        this._wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.rows = data;
            this.error = undefined;
        } else if (error) {
            this.error = this.reduceError(error);
            this.rows = undefined;
        }
    }

    // Subscribe to the Meal Logged channel so the chart auto-refreshes when a
    // meal is logged elsewhere on the page (e.g. the mealCapture component).
    connectedCallback() {
        if (!this._subscription) {
            this._subscription = subscribe(
                this._messageContext,
                MEAL_LOGGED_CHANNEL,
                () => this.handleRefresh()
            );
        }
        // Sync light/dark mode with sibling components (e.g. mealCapture's toggle).
        if (!this._themeSubscription) {
            this._themeSubscription = subscribe(
                this._messageContext,
                THEME_SYNC_CHANNEL,
                (msg) => { if (msg && msg.mode) this._themeOverride = msg.mode; }
            );
        }
        // React to profile switches from mealCapture — update chart data and title live.
        if (!this._profileSubscription) {
            this._profileSubscription = subscribe(
                this._messageContext,
                PROFILE_SELECTED_CHANNEL,
                (msg) => {
                    if (msg && msg.profileId) {
                        this._selectedProfileId = msg.profileId;
                        this._profileName       = msg.displayName || '';
                    }
                }
            );
        }
        this._loadNutritionProfileName();
    }

    // Resolves the active profile's display name and seeds _selectedProfileId so the
    // wired chart query uses it on first render. On subsequent profile switches, LMS
    // updates _selectedProfileId directly (no Apex round-trip needed).
    async _loadNutritionProfileName() {
        try {
            const info = await getActiveNutritionProfile();
            this._profileName       = (info && info.displayName) || '';
            this._selectedProfileId = (info && info.profileId)   || null;
        } catch (e) {
            this._profileName       = '';
            this._selectedProfileId = null;
        }
    }

    disconnectedCallback() {
        if (this._subscription) {
            unsubscribe(this._subscription);
            this._subscription = null;
        }
        if (this._themeSubscription) {
            unsubscribe(this._themeSubscription);
            this._themeSubscription = null;
        }
        if (this._profileSubscription) {
            unsubscribe(this._profileSubscription);
            this._profileSubscription = null;
        }
    }

    // True while a refresh is in flight — shows the spinner.
    get isRefreshing() {
        return this.refreshing;
    }

    // Re-run the wired Apex query so the chart re-renders with the latest meals.
    // A spinner is shown for at least 500ms so the click always gives feedback,
    // even when the data is unchanged (cached) and re-renders instantly.
    handleRefresh() {
        if (!this._wiredResult || this.refreshing) {
            return;
        }
        this.refreshing = true;
        Promise.all([
            refreshApex(this._wiredResult),
            new Promise((resolve) => setTimeout(resolve, 500))
        ]).finally(() => {
            this.refreshing = false;
            // Change the bar keys so LWC re-creates the elements and the
            // grow-from-baseline fill animation plays again.
            this.renderSeq += 1;
        });
    }

    // True when the component is in light theme. A synced override (from a
    // sibling's toggle) wins over the configured @api theme; both default Dark.
    get isLight() {
        return (this._themeOverride || this.theme || 'Dark').toLowerCase() === 'light';
    }

    // Theme class drives all colour tokens via CSS custom properties.
    get cardClass() {
        return `wmf-trend-card slds-p-around_medium ${this.isLight ? 'theme-light' : 'theme-dark'}`;
    }

    // Render the title only when a non-blank chartTitle is supplied.
    get showTitle() {
        return !!(this.chartTitle && this.chartTitle.trim().length);
    }

    // The configured chartTitle personalised with the resolved Nutrition Profile
    // name (e.g. "Daily Macro Distribution for Jane"); falls back to the plain
    // configured title when no name has resolved yet.
    get displayTitle() {
        return this._profileName ? `${this.chartTitle} for ${this._profileName}` : this.chartTitle;
    }

    get titlePrefix() { return this._profileName ? `${this.chartTitle} for ` : this.chartTitle; }
    get titleName()   { return this._profileName || '';
    }

    // True when at least one data row is available to plot.
    get hasData() {
        return Array.isArray(this.rows) && this.rows.length > 0;
    }

    // True when an error message should be shown instead of the chart.
    get hasError() {
        return !!this.error;
    }

    // SVG viewBox string built from the fixed geometry constants.
    get viewBox() {
        return `0 0 ${VIEW_W} ${VIEW_H}`;
    }

    // Horizontal gridlines + y-axis labels at 0/25/50/75/100%.
    // Maps each percent tick to a line spanning the plot width and a right-aligned label.
    get gridLines() {
        return [0, 25, 50, 75, 100].map((pct) => {
            // Convert the % up from the baseline into a SVG y (y grows downward).
            const y = PLOT_BOTTOM - (pct / 100) * PLOT_H;
            return {
                key: `grid-${pct}`,
                x1: PAD_LEFT,
                x2: VIEW_W - PAD_RIGHT,
                y,
                labelX: PAD_LEFT - 8,
                labelY: y + 4,
                label: `${pct}%`
            };
        });
    }

    // Builds the full set of stacked bars for the chart. For each day it splits the plot
    // width into equal bands, then stacks carbs/fat/protein segments (each sized by its
    // fraction of total grams so the stack always fills 100% height), computing the
    // geometry and label positions/visibility for every segment. Empty days get a marker.
    get bars() {
        if (!this.hasData) {
            return [];
        }
        // Divide the usable plot width into one band per day; bar is 62% of the band.
        const plotW = VIEW_W - PAD_LEFT - PAD_RIGHT;
        const band = plotW / this.rows.length;
        const barW = Math.min(MAX_BAR_W, band * 0.62);

        return this.rows.map((row, i) => {
            const carbs = Number(row.carbsG) || 0;
            const fat = Number(row.fatG) || 0;
            const protein = Number(row.proteinG) || 0;
            const total = carbs + fat + protein;

            // Centre the bar within its band, then left-align by half the bar width.
            const xCenter = PAD_LEFT + band * i + band / 2;
            const x = xCenter - barW / 2;

            const segments = [];
            if (total > 0) {
                // Fractions drive geometry (exact 100% height); rounded values are labels only.
                const parts = [
                    { macro: 'Carbs', grams: carbs, fill: COLOR_CARBS },
                    { macro: 'Fat', grams: fat, fill: COLOR_FAT },
                    { macro: 'Protein', grams: protein, fill: COLOR_PROTEIN }
                ];
                let cursor = PLOT_BOTTOM; // stack upward from the baseline
                parts.forEach((p) => {
                    // Segment height is its share of total grams; y is measured from the top.
                    const h = (p.grams / total) * PLOT_H;
                    const y = cursor - h;
                    const center = y + h / 2;
                    const pct = Math.round((p.grams / total) * 100);
                    const showGrams = h >= MIN_GRAMS_H; // room for a second line
                    segments.push({
                        key: `${row.logDay}-${p.macro}`,
                        x,
                        y,
                        width: barW,
                        height: h,
                        fill: p.fill,
                        pct,
                        showLabel: h >= MIN_LABEL_H,
                        showGrams,
                        gramsLabel: `${Math.round(p.grams)} g`,
                        labelX: xCenter,
                        labelY: showGrams ? center - 3 : center + 4,
                        gramsY: center + 11,
                        title: `${p.macro}: ${this.trim(p.grams)} g (${pct}%)`
                    });
                    cursor = y; // next segment stacks on top of this one
                });
            }

            return {
                key: `${row.logDay}-${this.renderSeq}`,
                segments,
                empty: total <= 0,
                emptyX: x,
                emptyY: PLOT_BOTTOM - 3,
                emptyW: barW,
                xLabel: this.shortDate(row.logDay),
                xLabelX: xCenter,
                xLabelY: PLOT_BOTTOM + 18,
                mealLabel: `${row.mealCount} meal${row.mealCount === 1 ? '' : 's'}`,
                mealLabelY: PLOT_BOTTOM + 32
            };
        });
    }

    // Static legend swatches mapping each macro to its fill colour.
    get legend() {
        return [
            { key: 'c', label: 'Carbs', style: `background:${COLOR_CARBS};` },
            { key: 'f', label: 'Fat', style: `background:${COLOR_FAT};` },
            { key: 'p', label: 'Protein', style: `background:${COLOR_PROTEIN};` }
        ];
    }

    // yyyy-MM-dd -> "Sep 27" (parsed as local date components, no TZ shift)
    shortDate(iso) {
        if (!iso) {
            return '';
        }
        const [, m, d] = iso.split('-').map((n) => parseInt(n, 10));
        return `${MONTHS[m - 1]} ${d}`;
    }

    // Round a number to one decimal place for tidy gram tooltips.
    trim(n) {
        const num = Number(n) || 0;
        return Math.round(num * 10) / 10;
    }

    // Flatten a wire/Apex error into a single display string, joining multiple
    // page-level errors and falling back through message shapes to a default.
    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        return error?.body?.message || error?.message || 'Unable to load macro data.';
    }
}