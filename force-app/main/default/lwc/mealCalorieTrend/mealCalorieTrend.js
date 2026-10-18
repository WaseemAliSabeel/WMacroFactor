import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { subscribe, unsubscribe, MessageContext } from 'lightning/messageService';
import MEAL_LOGGED_CHANNEL      from '@salesforce/messageChannel/MealLogged__c';
import THEME_SYNC_CHANNEL       from '@salesforce/messageChannel/ThemeSync__c';
import PROFILE_SELECTED_CHANNEL from '@salesforce/messageChannel/ProfileSelected__c';
import getDailyCalorieDistribution from '@salesforce/apex/WMF_MealAnalysisController.getDailyCalorieDistribution';
import getActiveNutritionProfile   from '@salesforce/apex/WMF_MealAnalysisController.getActiveNutritionProfile';

// ── SVG geometry (viewBox units) ────────────────────────────────────────────
const VIEW_W      = 720;
const VIEW_H      = 320;
const PAD_LEFT    = 52;
const PAD_RIGHT   = 20;
const PAD_TOP     = 20;
const PLOT_BOTTOM = 262;
const PLOT_H      = PLOT_BOTTOM - PAD_TOP;
const PLOT_LEFT   = PAD_LEFT;
const PLOT_RIGHT  = VIEW_W - PAD_RIGHT;
const PLOT_W      = PLOT_RIGHT - PLOT_LEFT;

// Calorie tooltip dimensions (viewBox units)
const TT_W = 76, TT_H = 20, TT_GAP = 8, TT_R = 3;

// "Nice" step values for dynamic y-axis tick spacing
const NICE_STEPS = [50, 100, 200, 250, 500, 1000, 1500, 2000, 2500, 5000];

const DEFAULT_REF_LINE_CAL = 2000;
const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

export default class MealCalorieTrend extends LightningElement {
    @api daysToShow  = 10;
    @api theme       = 'Dark';
    @api chartTitle  = 'Daily Calorie Trend';

    rows;
    error;

    _profileName       = '';
    _refLineCal        = DEFAULT_REF_LINE_CAL;
    _selectedProfileId = null; // null → Apex resolves own profile via priority logic
    _wiredResult;
    _subscription;
    _themeSubscription;
    _profileSubscription;
    _themeOverride;
    refreshing = false;
    renderSeq  = 0;

    @wire(MessageContext) _messageContext;

    @wire(getDailyCalorieDistribution, { daysBack: '$daysToShow', profileId: '$_selectedProfileId' })
    wiredData(result) {
        this._wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.rows  = data;
            this.error = undefined;
        } else if (error) {
            this.error = this._reduceError(error);
            this.rows  = undefined;
        }
    }

    connectedCallback() {
        if (!this._subscription) {
            this._subscription = subscribe(
                this._messageContext, MEAL_LOGGED_CHANNEL, () => this.handleRefresh()
            );
        }
        if (!this._themeSubscription) {
            this._themeSubscription = subscribe(
                this._messageContext, THEME_SYNC_CHANNEL,
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
                        this._refLineCal        = msg.dailyCaloricThreshold || DEFAULT_REF_LINE_CAL;
                    }
                }
            );
        }
        this._loadProfileName();
    }

    disconnectedCallback() {
        if (this._subscription)       { unsubscribe(this._subscription);       this._subscription       = null; }
        if (this._themeSubscription)  { unsubscribe(this._themeSubscription);  this._themeSubscription  = null; }
        if (this._profileSubscription){ unsubscribe(this._profileSubscription);this._profileSubscription= null; }
    }

    async _loadProfileName() {
        try {
            const info = await getActiveNutritionProfile();
            this._profileName       = (info && info.displayName)           || '';
            this._refLineCal        = (info && info.dailyCaloricThreshold) || DEFAULT_REF_LINE_CAL;
            this._selectedProfileId = (info && info.profileId)             || null;
        } catch (e) {
            this._profileName       = '';
            this._refLineCal        = DEFAULT_REF_LINE_CAL;
            this._selectedProfileId = null;
        }
    }

    handleRefresh() {
        if (!this._wiredResult || this.refreshing) return;
        this.refreshing = true;
        Promise.all([
            refreshApex(this._wiredResult),
            new Promise(resolve => setTimeout(resolve, 500))
        ]).finally(() => {
            this.refreshing = false;
            this.renderSeq += 1;
        });
    }

    // ── Theme ─────────────────────────────────────────────────────────────────
    get isRefreshing() { return this.refreshing; }

    get isLight() {
        return (this._themeOverride || this.theme || 'Dark').toLowerCase() === 'light';
    }

    get cardClass() {
        return `wmf-trend-card slds-p-around_medium ${this.isLight ? 'theme-light' : 'theme-dark'}`;
    }

    // ── Title ─────────────────────────────────────────────────────────────────
    get showTitle() {
        return !!(this.chartTitle && this.chartTitle.trim().length);
    }

    get displayTitle() {
        return this._profileName ? `${this.chartTitle} for ${this._profileName}` : this.chartTitle;
    }

    get titlePrefix() { return this._profileName ? `${this.chartTitle} for ` : this.chartTitle; }
    get titleName()   { return this._profileName || ''; }

    // ── Data ──────────────────────────────────────────────────────────────────
    get hasData()  { return Array.isArray(this.rows) && this.rows.length > 0; }
    get hasError() { return !!this.error; }
    get viewBox()  { return `0 0 ${VIEW_W} ${VIEW_H}`; }

    // Y-axis range: dynamic minimum that places the reference line in the
    // upper 70% of the chart (i.e. at ≥70% height from the bottom).
    //
    // Core constraint: (refCal - yMin) / (yMax - yMin) >= 0.70
    //   → yMin <= (refCal - 0.70·yMax) / 0.30
    //
    // When the data heavily exceeds the threshold the cap goes negative and yMin
    // falls back to 0, giving the highest possible ref-line position for that data.
    get _yBounds() {
        const refCal = this._refLineCal;
        const guard  = Math.ceil((refCal + 300) / 500) * 500;
        if (!this.hasData) return { yMin: 0, yMax: guard };
        const vals    = this.rows.map(r => Number(r.totalCalories) || 0);
        const peak    = Math.max(...vals);
        const trough  = Math.min(...vals);
        const yMax    = Math.max(guard, Math.ceil(peak * 1.1 / 100) * 100);
        // Data-driven lower bound: 15% below the trough, rounded down to 100.
        const dataMin = Math.max(0, Math.floor(trough * 0.85 / 100) * 100);
        // 70% position cap: solve for the yMin that puts refCal at 70% chart height.
        const seventyPctCap = (refCal - 0.70 * yMax) / 0.30;
        const yMin = Math.max(0, Math.min(dataMin, seventyPctCap));
        return { yMin, yMax };
    }

    // Exactly 5 evenly-spaced ticks spanning [yMin, yMax], each rounded to the
    // nearest 100 and clamped within the range so no tick renders outside the plot.
    get _yTicks() {
        const { yMin, yMax } = this._yBounds;
        const range = yMax - yMin || 1;
        const ticks = [];
        for (let i = 0; i <= 4; i++) {
            const raw     = yMin + (i / 4) * range;
            const snapped = Math.round(raw / 100) * 100;
            ticks.push(Math.max(yMin, Math.min(yMax, snapped)));
        }
        return [...new Set(ticks)];
    }

    _yPos(calories) {
        const { yMin, yMax } = this._yBounds;
        const range = (yMax - yMin) || 1;
        return PLOT_BOTTOM - ((calories - yMin) / range) * PLOT_H;
    }

    // ── SVG elements ──────────────────────────────────────────────────────────

    // 5 horizontal grid lines at the dynamic tick values.
    get gridLines() {
        return this._yTicks.map((cal, i) => {
            const y = this._yPos(cal);
            return {
                key:    `grid-${i}-${cal}`,
                x1: PLOT_LEFT, x2: PLOT_RIGHT, y,
                labelX: PLOT_LEFT - 6,
                labelY: y + 4,
                label:  String(cal)
            };
        });
    }

    get showRefLine()   { return this._yBounds.yMax >= this._refLineCal; }
    get refLineLabel()  { return `${this._refLineCal} kcal`; }

    get refLine() {
        const y = this._yPos(this._refLineCal);
        return {
            x1: PLOT_LEFT, x2: PLOT_RIGHT, y,
            labelX: PLOT_RIGHT,
            labelY: y - 4
        };
    }

    // One entry per data point, including calorie tooltip positioning data.
    get dataPoints() {
        if (!this.hasData) return [];
        const n = this.rows.length;
        return this.rows.map((row, i) => {
            const cal = Number(row.totalCalories) || 0;
            const x   = n === 1
                ? PLOT_LEFT + PLOT_W / 2
                : +(PLOT_LEFT + (i / (n - 1)) * PLOT_W).toFixed(2);
            const y   = +this._yPos(cal).toFixed(2);
            const dt  = this._shortDate(row.logDay);
            const mc  = row.mealCount;

            // Tooltip: put above the point unless it would clip into PAD_TOP.
            const above  = y - TT_H - TT_GAP > PAD_TOP;
            const rectY  = above ? y - TT_H - TT_GAP : y + TT_GAP;
            const rectX  = Math.max(PLOT_LEFT, Math.min(x - TT_W / 2, PLOT_RIGHT - TT_W));

            return {
                key:          `pt-${row.logDay}-${this.renderSeq}`,
                labelKey:     `lb-${row.logDay}-${this.renderSeq}`,
                x, y,
                calLabel:     `${Math.round(cal)} kcal`,
                tooltipRectX: +rectX.toFixed(2),
                tooltipRectY: +rectY.toFixed(2),
                tooltipRectW: TT_W,
                tooltipRectH: TT_H,
                tooltipRectR: TT_R,
                tooltipTx:    +(rectX + TT_W / 2).toFixed(2),
                tooltipTy:    +(rectY + TT_H / 2 + 4).toFixed(2),
                dateLabel:    dt,
                mealLabel:    `${mc} meal${mc === 1 ? '' : 's'}`,
                xLabelY:      PLOT_BOTTOM + 16,
                mealLabelY:   PLOT_BOTTOM + 30,
                tooltip:      `${dt}: ${Math.round(cal)} kcal (${mc} meal${mc === 1 ? '' : 's'})`
            };
        });
    }

    get linePoints() {
        return this.dataPoints.map(pt => `${pt.x},${pt.y}`).join(' ');
    }

    // Closed polygon for the filled area. Baseline is always at PLOT_BOTTOM
    // which equals _yPos(yMin), so the grow-from-bottom animation anchors correctly.
    get areaPolygon() {
        if (!this.hasData || !this.dataPoints.length) return '';
        const first = this.dataPoints[0];
        const last  = this.dataPoints[this.dataPoints.length - 1];
        const pts   = this.dataPoints.map(pt => `${pt.x},${pt.y}`).join(' ');
        return `${first.x},${PLOT_BOTTOM} ${pts} ${last.x},${PLOT_BOTTOM}`;
    }

    _shortDate(iso) {
        if (!iso) return '';
        const [, m, d] = iso.split('-').map(n => parseInt(n, 10));
        return `${MONTHS[m - 1]} ${d}`;
    }

    _reduceError(error) {
        if (Array.isArray(error?.body)) return error.body.map(e => e.message).join(', ');
        return error?.body?.message || error?.message || 'Unable to load calorie data.';
    }
}