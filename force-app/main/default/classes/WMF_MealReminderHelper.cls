// Invocable Apex called by the WMF_MealReminderScheduler flow.
// Picks a random one-liner from 15 branded messages, sends an HTML email,
// and fires the Salesforce bell (Custom Notification) to the profile owner.
// All three concerns are here because Flow cannot do randomness or HTML email
// natively — everything else is orchestrated by the flow.
public class WMF_MealReminderHelper {

    private static final List<String> MESSAGES = new List<String>{
        'Your goals don\'t care about your poor memory. Log that meal before it logs onto your waistline.',
        'Did you eat, or are you just pretending calories don\'t count when you ignore them? Open WMacroFactor.',
        'Gains aren\'t built on secret calories. Log your meal now and stay on track for your peak physique.',
        'Your stomach remembers what you ate, even if your brain is acting like it forgot. Log it!',
        'That meal was too good to leave out. Show off those macros in WMacroFactor right now!',
        'Late logging ruins smart tracking. Drop a 10-second log right now to keep your meal timings honest.',
        'Every unlogged meal is a step away from your fat loss goals. Don\'t cheat yourself—log it.',
        'Plot twist: Unlogged calories still count. Tap here to record your masterpiece before you forget.',
        'Fuelling the engine? Make sure WMacroFactor knows so your muscle-building algorithm can adapt.',
        'Stop scrolling, start logging. It takes 5 seconds to keep your streak alive!',
        'Untracked food has a funny way of turning into unwanted weight. Log your meal in WMacroFactor.',
        'You remembered to eat, didn\'t you? Now finish the job and log it before the food coma hits.',
        'Out of sight, out of log, right onto your gut. Tap to log your last meal immediately.',
        'Respect the process, log the macros. Don\'t let a missing entry sabotage your hard work.',
        'Is that meal secretly recorded, or are you waiting for WMacroFactor to read your mind? Tap to log!'
    };

    // ── Invocable input ───────────────────────────────────────────────────────
    public class ReminderRequest {
        @InvocableVariable(label='Profile Email' required=true)
        public String profileEmail;

        @InvocableVariable(label='Profile Name' required=true)
        public String profileName;

        @InvocableVariable(label='Profile User ID')
        public String profileUserId;

        @InvocableVariable(label='Profile Record ID' required=true)
        public String profileId;
    }

    // ── Entry point called by Flow ────────────────────────────────────────────
    @InvocableMethod(
        label='Send WMF Meal Reminder'
        description='Picks a random message, sends the HTML email and the bell notification'
        category='WMacroFactor'
    )
    public static List<String> sendReminder(List<ReminderRequest> requests) {
        if (requests == null || requests.isEmpty()) return new List<String>();

        ReminderRequest req = requests[0];
        String msg = randomMessage();

        // Resolve the User's real first/last name — profileName from the Flow
        // is the auto-number record name (e.g. "NP-0001"), not the person's name.
        String displayName = resolveUserDisplayName(req.profileUserId);

        // Bell (in-app) notification
        if (String.isNotBlank(req.profileUserId) && String.isNotBlank(req.profileId)) {
            sendBellNotification(req.profileUserId, req.profileId, msg);
        }

        // HTML email
        if (String.isNotBlank(req.profileEmail)) {
            sendEmail(req.profileEmail, displayName, msg);
        }

        return new List<String>{ msg };
    }

    // ── Private helpers ───────────────────────────────────────────────────────

    private static String randomMessage() {
        return MESSAGES[(Integer) Math.floor(Math.random() * MESSAGES.size())];
    }

    // Looks up the User's FirstName (falls back to LastName, then 'there') so the
    // email greeting never shows the Nutrition Profile auto-number like "NP-0001".
    private static String resolveUserDisplayName(String userId) {
        if (String.isBlank(userId)) return 'there';
        List<User> users = [SELECT FirstName, LastName FROM User WHERE Id = :userId LIMIT 1];
        if (users.isEmpty()) return 'there';
        if (String.isNotBlank(users[0].FirstName)) return users[0].FirstName;
        if (String.isNotBlank(users[0].LastName))  return users[0].LastName;
        return 'there';
    }

    private static void sendBellNotification(String userId, String profileId, String message) {
        try {
            List<CustomNotificationType> types = [
                SELECT Id FROM CustomNotificationType
                WHERE DeveloperName = 'WMF_MealReminder' LIMIT 1
            ];
            if (types.isEmpty()) return;

            Messaging.CustomNotification n = new Messaging.CustomNotification();
            n.setNotificationTypeId(types[0].Id);
            n.setTitle('⏰ WMacroFactor — Meal Reminder');
            n.setBody(message);
            n.setTargetId(profileId);
            n.send(new Set<String>{ userId });
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Bell notification failed: ' + e.getMessage());
        }
    }

    private static void sendEmail(String addr, String name, String msg) {
        try {
            Messaging.sendEmail(
                new List<Messaging.SingleEmailMessage>{ buildReminderEmail(addr, name, msg) }, false
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Email send failed: ' + e.getMessage());
        }
    }

    // ── Shared email template ─────────────────────────────────────────────────
    // Single source of truth for the reminder email, used by the flow/Remind Now path
    // (above) and by WMF_MealReminderBatch, so all reminders look identical.

    private static final String LOGO_ASSET_NAME = 'W_MacroFactor_App_logo';
    private static final String LOG_MEAL_TAB     = '/lightning/n/WMF_Log_Meal';
    private static final String SF_BLUE          = '#0176D3';

    private static String logoUrl;
    private static Boolean logoUrlLoaded = false;

    public static Messaging.SingleEmailMessage buildReminderEmail(String addr, String name, String msg) {
        Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
        m.setToAddresses(new List<String>{ addr });
        m.setSubject('🍽️ Did you Log your Meal yet ?');
        m.setSaveAsActivity(false);
        m.setHtmlBody(emailHtml(name, msg, getLogoUrl()));
        return m;
    }

    // Public download URL of the WMacroFactor app image (the W_MacroFactor_App_logo file). The file
    // itself needs a Salesforce login, which mail clients don't have, so the first send creates a
    // ContentDistribution (public link, follows the latest version) and every later send reuses it.
    // Returns null on any problem, so the header falls back to text-only: a reminder must never
    // fail over a logo.
    private static String getLogoUrl() {
        if (logoUrlLoaded) return logoUrl;
        logoUrlLoaded = true;
        try {
            List<ContentAsset> assets = [
                SELECT ContentDocumentId FROM ContentAsset
                WHERE DeveloperName = :LOGO_ASSET_NAME LIMIT 1
            ];
            if (assets.isEmpty()) return null;
            Id docId = assets[0].ContentDocumentId;

            List<ContentDistribution> dists = [
                SELECT ContentDownloadUrl FROM ContentDistribution
                WHERE ContentDocumentId = :docId AND PreferencesLinkLatestVersion = true LIMIT 1
            ];
            if (dists.isEmpty()) {
                ContentVersion cv = [
                    SELECT Id, Title FROM ContentVersion
                    WHERE ContentDocumentId = :docId AND IsLatest = true LIMIT 1
                ];
                insert new ContentDistribution(
                    Name                          = cv.Title,
                    ContentVersionId              = cv.Id,
                    PreferencesAllowViewInBrowser = true,
                    PreferencesLinkLatestVersion  = true,
                    PreferencesNotifyOnVisit      = false
                );
                dists = [
                    SELECT ContentDownloadUrl FROM ContentDistribution
                    WHERE ContentDocumentId = :docId AND PreferencesLinkLatestVersion = true LIMIT 1
                ];
            }
            if (!dists.isEmpty()) logoUrl = dists[0].ContentDownloadUrl;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Logo lookup failed: ' + e.getMessage());
        }
        return logoUrl;
    }

    private static String emailHtml(String name, String body, String logoSrc) {
        String logoCell = String.isNotBlank(logoSrc)
            ? '<td width="56" style="width:56px;padding-right:16px;vertical-align:middle;">'
              + '<img src="' + logoSrc.escapeHtml4() + '" width="56" height="56" alt="WMacroFactor" '
              + 'style="display:block;width:56px;height:56px;border:0;border-radius:12px;"/></td>'
            : '';
        String logMealUrl = URL.getOrgDomainUrl().toExternalForm() + LOG_MEAL_TAB;

        return '<!DOCTYPE html><html><body style="margin:0;padding:0;font-family:Arial,sans-serif;background:#f4f4f4;">'
             + '<div style="max-width:520px;margin:32px auto;background:#fff;border-radius:10px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.12);">'
             + '<div style="background:#0a2540;padding:24px 28px;">'
             + '<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>'
             + logoCell
             + '<td style="vertical-align:middle;">'
             + '<h1 style="margin:0;font-size:1.3rem;color:#fff;letter-spacing:.03em;">WMacroFactor</h1>'
             + '<p style="margin:4px 0 0;font-size:.75rem;color:#7fa8d8;text-transform:uppercase;letter-spacing:.08em;">Meal Logging Reminder</p>'
             + '</td></tr></table>'
             + '</div>'
             + '<div style="padding:28px;">'
             + '<p style="margin:0 0 12px;font-size:1rem;color:#111;">Hi <strong>' + name.escapeHtml4() + '</strong>,</p>'
             + '<p style="margin:0 0 20px;font-size:1.05rem;color:#0a2540;line-height:1.55;">' + body.escapeHtml4() + '</p>'
             + '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 20px;"><tr>'
             + '<td align="center" bgcolor="' + SF_BLUE + '" style="border-radius:4px;background:' + SF_BLUE + ';">'
             + '<a href="' + logMealUrl + '" target="_blank" style="display:inline-block;padding:10px 24px;font-size:.95rem;font-weight:600;'
             + 'color:#ffffff;text-decoration:none;border-radius:4px;border:1px solid ' + SF_BLUE + ';background:' + SF_BLUE + ';">Log Meal</a>'
             + '</td></tr></table>'
             + '<p style="margin:0;font-size:.85rem;color:#666;">Keep your tracking consistent — open WMacroFactor and log your last meal now.</p>'
             + '</div>'
             + '<div style="padding:14px 28px;background:#f8f9fb;border-top:1px solid #e8e8e8;">'
             + '<p style="margin:0;font-size:.72rem;color:#aaa;">You\'re receiving this because your Nutrition Profile is active on WMacroFactor.</p>'
             + '</div>'
             + '</div></body></html>';
    }
}