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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), action: action));

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

/// Files picked by hand: the Flag Maker export (PNG, 3MF, recipe, GLBs).
Future<void> importVersion(BuildContext context, Selection s) => _guard(context, 'ההעלאה נכשלה', () async {
      final files = await openFiles(acceptedTypeGroups: const [
        XTypeGroup(label: 'ייצוא Flag Maker', extensions: ['png', '3mf', 'json', 'glb']),
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

Future<void> openFlagMaker(BuildContext context, Selection s) async {
  final v = withRecipe(s);
  if (v == null) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (await openInFlagMaker(v.id)) {
      messenger.showSnackBar(SnackBar(content: Text('ה-Flag Maker נפתח על גרסה ${v.data()?['n']}')));
    }
  } catch (e) {
    showError(messenger, e, 'ה-Flag Maker לא נפתח');
  }
}

Future<void> newRequest(BuildContext context) async {
  final id = await showDialog<String>(context: context, builder: (_) => const NewRequestDialog());
  if (id != null && context.mounted) say(context, 'הבקשה נוצרה. עכשיו מייצאים אליה עיצוב מה-Flag Maker');
}

Future<void> newCustomer(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const CustomerDialog());
