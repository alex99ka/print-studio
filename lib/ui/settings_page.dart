import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config.dart';
import '../core/app_info.dart';
import '../core/auth.dart';
import '../core/diagnostics.dart';
import '../core/errors.dart';
import '../core/export.dart';
import '../core/home_widgets.dart';
import '../core/lock.dart';
import '../core/notifications.dart';
import '../core/report.dart';
import '../core/settings_store.dart';
import '../core/tour.dart';
import '../core/update.dart';
import '../core/web_update.dart';
import 'skeleton.dart';

/// The standard set, in this order: updates, sign-in and security, look,
/// notifications, help, data, account. A new app adds its own section above
/// "עזרה".
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool? _fingerprint;

  @override
  void initState() {
    super.initState();
    fingerprintSetting().then((v) {
      if (mounted) setState(() => _fingerprint = v);
    });
  }

  ScaffoldMessengerState get _messenger => ScaffoldMessenger.of(context);
  void _say(String text) => _messenger.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _toggleFingerprint(bool on) async {
    if (!on) {
      await disableFingerprint();
      setState(() => _fingerprint = false);
      return;
    }
    final r = await enableFingerprint();
    if (!mounted) return;
    setState(() => _fingerprint = r == FingerprintResult.enabled);
    if (r == FingerprintResult.unsupported) _say(errorText(Errors.noBiometrics));
  }

  Future<void> _report() async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('דיווח על בעיה'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: 5,
          decoration: const InputDecoration(
              hintText: 'מה קרה? מה ניסיתם לעשות?',
              helperText: 'יישלחו גם הגרסה, המכשיר והשגיאות האחרונות',
              helperMaxLines: 2),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ביטול')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('שליחה')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      await sendProblemReport(text.trim());
      _say('הדיווח נשלח. תודה!');
    } catch (e) {
      showError(_messenger, e, 'שליחת הדיווח נכשלה');
    }
  }

  void _whatsNew() {
    // This version's own steps, else its release notes as one card.
    final steps = whatsNew(AppInfo.previousVersion(), AppInfo.version);
    Navigator.pop(context);
    runningTour.value = steps.isNotEmpty
        ? steps
        : [
            TourStep('מה חדש בגרסה ${AppInfo.version}',
                AppConfig.releaseNotes.isEmpty ? 'תיקונים ושיפורים.' : AppConfig.releaseNotes),
          ];
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final updater = AppUpdater.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('הגדרות')),
      body: ListView(children: [
        _Section('עדכונים'),
        TourTarget(
          'settings.update',
          child: ListenableBuilder(
            listenable: Listenable.merge([updater, WebUpdate.instance]),
            builder: (context, _) => ListTile(
              leading: const Icon(Icons.system_update),
              title: Text('גרסה ${AppInfo.versionLabel}'),
              subtitle: Text(updater == null
                  ? (WebUpdate.instance.available != null
                      ? 'גרסה ${WebUpdate.instance.available} זמינה: רענון'
                      : 'האתר מתעדכן לבד')
                  : updater.checking
                      ? 'בודק…'
                      : updater.progress != null
                          ? 'מוריד… ${(updater.progress! * 100).round()}%'
                          : updater.error != null
                              ? errorText(updater.error!)
                              : updater.available != null
                                  ? (updater.ready && updater.installsByItself
                                      ? 'גרסה ${updater.available!.version} תותקן לבד כשתצאו'
                                      : 'גרסה ${updater.available!.version} זמינה')
                                  : updater.lastResult ?? 'מתעדכן לבד ברקע'),
              trailing: updater?.available != null
                  ? FilledButton(onPressed: updater!.install, child: const Text('עדכון'))
                  : TextButton(
                      onPressed: () => updater == null
                          ? (WebUpdate.instance.available != null
                              ? WebUpdate.instance.apply()
                              : WebUpdate.instance.check())
                          : updater.check(),
                      child: const Text('בדיקה')),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.new_releases_outlined),
          title: const Text('מה חדש בגרסה הזו'),
          onTap: _whatsNew,
        ),

        _Section('כניסה ואבטחה'),
        if (_fingerprint != null)
          TourTarget(
            'settings.fingerprint',
            child: SwitchListTile(
              secondary: const Icon(Icons.fingerprint),
              title: const Text('כניסה בטביעת אצבע'),
              subtitle: const Text('נפתח בטביעת אצבע, ואחרי 5 דקות בחוץ'),
              value: _fingerprint!,
              onChanged: _toggleFingerprint,
            ),
          ),
        if (user != null)
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance.doc('users/${user.uid}').snapshots(),
            builder: (context, snap) {
              final prev = snap.data?.data()?['previousSignIn'];
              final where = snap.data?.data()?['previousPlatform'];
              return ListTile(
                leading: const Icon(Icons.history),
                title: const Text('כניסה קודמת לחשבון'),
                subtitle: Text(prev is Timestamp
                    ? '${prev.toDate().toString().substring(0, 16)}${where == null ? '' : ' · $where'}'
                    : 'זו הכניסה הראשונה'),
              );
            },
          ),
        const ListTile(
          leading: Icon(Icons.shield_outlined),
          title: Text('מה מגן על הנתונים'),
          subtitle: Text('רק חשבונות מורשים נכנסים, והשרת בודק כל בקשה. '
              'מומלץ אימות דו-שלבי בחשבון Google.'),
        ),

        _Section('תצוגה'),
        ListenableBuilder(
          listenable: SettingsStore.instance,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('כמו במכשיר')),
                ButtonSegment(value: ThemeMode.light, label: Text('בהיר')),
                ButtonSegment(value: ThemeMode.dark, label: Text('כהה')),
              ],
              selected: {SettingsStore.instance.themeMode},
              onSelectionChanged: (s) => SettingsStore.instance.setThemeMode(s.first),
            ),
          ),
        ),
        if (homeWidgetsSupported)
          ListTile(
            leading: const Icon(Icons.widgets_outlined),
            title: const Text('הוספת וידג׳ט למסך הבית'),
            onTap: () => pinHomeWidget(context),
          ),

        _Section('התראות'),
        if (kIsWeb)
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('התראות במכשיר הזה'),
            onTap: () async => _say(await enableWebNotifications()),
          ),
        if (defaultTargetPlatform == TargetPlatform.windows && !kIsWeb)
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('במחשב יש רק התראות של האפליקציה עצמה'),
          ),
        if (user != null)
          StreamBuilder<Map<String, bool>>(
            stream: notificationPrefs(),
            builder: (context, snap) => Column(children: [
              for (final e in notificationTypes.entries)
                SwitchListTile(
                  title: Text(e.value),
                  value: snap.data?[e.key] ?? true,
                  onChanged: (v) => setNotificationPref(e.key, v),
                ),
            ]),
          ),

        _Section('עזרה'),
        TourTarget(
          'settings.tour',
          child: ListTile(
            leading: const Icon(Icons.school_outlined),
            title: const Text('סיור באפליקציה'),
            subtitle: const Text('הדרכה אינטראקטיבית בכל מה שיש כאן'),
            onTap: () {
              Navigator.pop(context);
              runningTour.value = fullTour;
            },
          ),
        ),
        TourTarget(
          'settings.report',
          child: ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('דיווח על בעיה'),
            onTap: _report,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.monitor_heart_outlined),
          title: const Text('מצב המערכת'),
          onTap: () => Navigator.push(context,
              MaterialPageRoute<void>(builder: (_) => const DiagnosticsPage())),
        ),

        _Section('נתונים'),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('ייצוא נתונים'),
          subtitle: const Text('JSON וקובץ CSV לאקסל'),
          onTap: () async {
            try {
              final n = await exportData();
              _say('יוצאו $n רשומות');
            } catch (e) {
              showError(_messenger, e, 'הייצוא נכשל');
            }
          },
        ),

        _Section('חשבון'),
        ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: Text(user?.displayName ?? ''),
          subtitle: Text(user?.email ?? ''),
        ),
        ListTile(
          leading: const Icon(Icons.switch_account_outlined),
          title: const Text('החלפת חשבון'),
          onTap: () async {
            Navigator.popUntil(context, (r) => r.isFirst);
            try {
              await Auth.switchAccount();
            } catch (e) {
              showError(_messenger, e, 'החלפת החשבון נכשלה');
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('יציאה'),
          onTap: () async {
            final yes = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('לצאת מהחשבון?'),
                content: const Text('הכניסה הבאה תהיה שוב עם Google.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('ביטול')),
                  FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('יציאה')),
                ],
              ),
            );
            if (yes != true || !context.mounted) return;
            Navigator.popUntil(context, (r) => r.isFirst);
            await Auth.signOut();
          },
        ),
        const SizedBox(height: 32),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
        child: Text(title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary)),
      );
}

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  late Future<List<Check>> _checks = runDiagnostics();

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('מצב המערכת')),
      body: RefreshIndicator(
        onRefresh: () async {
          setState(() => _checks = runDiagnostics());
          await _checks;
        },
        child: FutureBuilder<List<Check>>(
          future: _checks,
          builder: (context, snap) => !snap.hasData
              ? const SkeletonList(rows: 5)
              : ListView(children: [
                  for (final check in snap.data!)
                    ListTile(
                      leading: Icon(
                        check.ok == null
                            ? Icons.info_outline
                            : check.ok!
                                ? Icons.check_circle_outline
                                : Icons.error_outline,
                        color: check.ok == false ? c.error : c.primary,
                      ),
                      title: Text(check.label),
                      subtitle: Text(check.value),
                    ),
                ]),
        ),
      ),
    );
  }
}
