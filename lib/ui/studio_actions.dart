import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/errors.dart';
import '../core/server.dart';
import '../studio/desktop.dart';
import '../studio/studio.dart';
import 'studio_dialogs.dart';

/// The request on screen, for the ribbon: its customer, its versions (by
/// number) and the version being looked at.
class Selection {
  const Selection({required this.request, required this.customer, required this.versions, required this.version});

  final Doc request;
  final Doc? customer;
  final List<Doc> versions;
  final Doc? version;

  Map<String, dynamic> get r => request.data() ?? const {};
  String get title => '${r['title'] ?? ''}';
  String get token => '${customer?.data()?['portalToken'] ?? ''}';
  bool get open => r['status'] == 'draft' || r['status'] == 'waiting';
  Doc? get approved => versions.where((v) => v.id == r['approvedVersionId']).firstOrNull;
  Doc? get latestDraft => versions.where((v) => v.data()?['state'] == 'draft').lastOrNull;
}

final selection = ValueNotifier<Selection?>(null);

List<String> filesOf(Doc? v) => [...(v?.data()?['files'] as List? ?? const [])].cast<String>();

void say(BuildContext context, String text, {SnackBarAction? action}) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), action: action, persist: false));

Future<void> _open(Uri uri) async {
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) throw Errors.noConnection;
}

Future<void> _guard(BuildContext context, String failed, Future<void> Function() run) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (!hasServer) throw Errors.noServer;
    await run();
  } catch (e) {
    showError(messenger, e, failed);
  }
}

/// Files picked by hand: the Flag Maker export (PNG, 3MF, recipe).
Future<void> importVersion(BuildContext context, Selection s) => _guard(context, 'ההעלאה נכשלה', () async {
      final files = await openFiles(acceptedTypeGroups: const [
        XTypeGroup(label: 'ייצוא Flag Maker', extensions: ['png', '3mf', 'json']),
      ]);
      if (files.isEmpty) return;
      if (!files.any((f) => uploadField(f.name) == 'preview')) throw Errors.noPreview;
      if (context.mounted) say(context, 'מעלה ${files.length} קבצים…');
      final n = await uploadVersion(s.request.id, files);
      if (context.mounted) say(context, 'גרסה $n נוספה כטיוטה. הלקוח יראה אותה אחרי "פרסם ללקוח"');
    });

/// The version on screen if it's a draft, else the newest draft.
Doc? publishable(Selection s) {
  final v = s.version;
  if (!s.open) return null;
  return v?.data()?['state'] == 'draft' ? v : s.latestDraft;
}

Future<void> publishVersion(BuildContext context, Selection s) async {
  final v = publishable(s);
  if (v == null) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await publish(s.request, v);
    messenger.showSnackBar(SnackBar(
      // A button no longer keeps it on screen (Flutter's default since 3.29): it closes by itself.
      persist: false,
      duration: const Duration(seconds: 6),
      content: Text('גרסה ${v.data()?['n']} פורסמה ללקוח'),
      action: s.customer == null
          ? null
          : SnackBarAction(label: 'שליחה בוואטסאפ', onPressed: () => sendWhatsapp(context, s.customer!)),
    ));
  } catch (e) {
    showError(messenger, e, 'הפרסום נכשל');
  }
}

Future<void> sendWhatsapp(BuildContext context, Doc customer) async {
  final c = customer.data() ?? const {};
  final messenger = ScaffoldMessenger.of(context);
  try {
    await _open(whatsapp('${c['phone'] ?? ''}', portalMessage('${c['name'] ?? ''}', portalUrl('${c['portalToken']}'))));
  } catch (e) {
    showError(messenger, e, 'וואטסאפ לא נפתח');
  }
}

Future<void> copyPortalLink(BuildContext context, Doc customer) async {
  await Clipboard.setData(ClipboardData(text: portalUrl('${customer.data()?['portalToken']}')));
  if (context.mounted) say(context, 'הקישור של ${customer.data()?['name']} הועתק');
}

/// The portal as the customer sees it; a draft through ?preview=, which only
/// the studio knows.
Future<void> previewInBrowser(BuildContext context, Selection s) => _guard(context, 'התצוגה לא נפתחה', () {
      final v = s.version;
      final draft = v != null && v.data()?['state'] == 'draft';
      return _open(Uri.parse('${portalUrl(s.token, preview: draft ? v.id : null)}#r=${s.request.id}'));
    });

/// The approved version's 3MF (else the one on screen) into Bambu Studio on
/// the PC; elsewhere it downloads.
Doc? printable(Selection s) {
  final v = s.approved ?? s.version;
  return filesOf(v).contains('model.3mf') ? v : null;
}

Future<void> openSlicer(BuildContext context, Selection s) => _guard(context, 'פתיחת הקובץ נכשלה', () async {
      final v = printable(s);
      if (v == null) return;
      final name = '${s.title} v${v.data()?['n']}.3mf';
      if (isWindows && context.mounted) say(context, 'מוריד ופותח ב-Bambu Studio…');
      final bytes = await studioFile(v.id, 'model.3mf');
      if (!isWindows) {
        await SharePlus.instance.share(ShareParams(files: [XFile.fromData(bytes, name: name, mimeType: 'model/3mf')]));
        return;
      }
      await openInSlicer(bytes, name);
    });

Doc? withRecipe(Selection s) => filesOf(s.version).contains('recipe.json') ? s.version : null;

/// The latest version that has a recipe opens as it was; a request without one
/// opens a new design with the names from its title.
Future<void> openFlagMaker(BuildContext context, Selection s) async {
  final v = withRecipe(s);
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (v != null) {
      if (await openInFlagMaker(v.id)) {
        messenger.showSnackBar(SnackBar(content: Text('ה-Flag Maker נפתח על גרסה ${v.data()?['n']}')));
      }
    } else {
      final names = namesFrom(s.title);
      if (await newInFlagMaker(s.request.id, names)) {
        messenger.showSnackBar(SnackBar(content: Text('ה-Flag Maker נפתח עם השמות: ${names.join(', ')}')));
      }
    }
  } catch (e) {
    showError(messenger, e, 'ה-Flag Maker לא נפתח');
  }
}

/// Gift Factory on this request (PC only).
Future<void> openGiftFactory(BuildContext context, Selection s) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (await openInGiftFactory(s.request.id)) {
      messenger.showSnackBar(SnackBar(content: Text('Gift Factory נפתח על "${s.title}"')));
    }
  } catch (e) {
    showError(messenger, e, 'Gift Factory לא נפתח');
  }
}

/// The client's guest list as they uploaded it: opened in Excel on the PC, shared elsewhere.
Future<void> downloadGuests(BuildContext context, Selection s) => _guard(context, 'ההורדה נכשלה', () async {
      final name = '${(s.r['guests'] as Map?)?['fileName'] ?? 'guests.xlsx'}';
      final bytes = await guestFile(s.request.id);
      if (!isWindows) {
        await SharePlus.instance.share(ShareParams(files: [XFile.fromData(bytes, name: name)]));
      } else if (!await openLocal(bytes, name) && context.mounted) {
        say(context, 'אין במחשב תוכנה שפותחת את $name');
      }
    });

/// Returns the new request's id; [customer] picks the customer up front.
Future<String?> newRequest(BuildContext context, {Doc? customer}) async {
  final id = await showDialog<String>(context: context, builder: (_) => NewRequestDialog(customer: customer));
  if (id != null && context.mounted) say(context, 'הבקשה נוצרה. עכשיו מייצאים אליה עיצוב מה-Flag Maker');
  return id;
}

/// The calendar; the Pi reminds 3 days before, the day before, on the day and the day after.
Future<void> pickDeadline(BuildContext context, Doc request) async {
  final now = DateTime.now();
  final d = await showDatePicker(
    context: context,
    helpText: 'תאריך יעד',
    initialDate: deadlineOf(request.data()) ?? now.add(const Duration(days: 7)),
    firstDate: DateTime(now.year - 1),
    lastDate: DateTime(now.year + 2),
  );
  if (d == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await setDeadline(request, d);
  } catch (e) {
    showError(messenger, e, 'השמירה נכשלה');
  }
}

Future<void> newCustomer(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const CustomerDialog());
