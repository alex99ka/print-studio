import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../config.dart';
import '../core/app_info.dart';
import '../core/errors.dart';
import '../core/home_widgets.dart';
import '../core/lock.dart';
import '../core/notifications.dart';
import '../core/tour.dart';
import '../core/update.dart';
import '../core/web_update.dart';
import 'settings_page.dart';
import 'skeleton.dart';
import 'update_banner.dart';

/// The example feature: one shared list. It exists to show every UI standard
/// working (skeleton, quick add, long-press menu, undo, pull to refresh,
/// empty state) and to be replaced by the real app's screens.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

final _items = FirebaseFirestore.instance.collection('items');

class _HomeScreenState extends State<HomeScreen> {
  final _add = TextEditingController();
  final _addFocus = FocusNode();
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<Uri?>? _widgetTaps;

  @override
  void initState() {
    super.initState();
    // Updates: at launch, and on coming back to the app.
    _checkUpdates();
    _lifecycle = AppLifecycleListener(onResume: _checkUpdates);
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterFirstFrame());
    // The quick-add home widget opens the app ready to type.
    _widgetTaps = listenWidgetTaps((action) {
      if (action == 'add') _addFocus.requestFocus();
    });
  }

  void _checkUpdates() {
    AppUpdater.instance?.checkIfDue();
    WebUpdate.instance.check();
  }

  Future<void> _afterFirstFrame() async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setUpNotifications(messenger).ignore();
    // The whole tour on a new device; after an update, what it brought.
    final steps = await tourForThisLaunch(AppInfo.version);
    if (steps != null && steps.isNotEmpty) {
      runningTour.value = steps;
    } else if (steps != null && AppConfig.releaseNotes.isNotEmpty) {
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text('מה חדש בגרסה ${AppInfo.version}: ${AppConfig.releaseNotes}'),
      ));
    }
    if (steps == null && await shouldOfferFingerprint() && mounted) {
      _offerFingerprint(messenger);
    }
  }

  Future<void> _offerFingerprint(ScaffoldMessengerState messenger) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.fingerprint),
        title: const Text('להיכנס בטביעת אצבע?'),
        content: const Text('בפעם הבאה שתפתחו את האפליקציה, טביעת אצבע במקום '
            'Google. אפשר לשנות בהגדרות.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('לא עכשיו')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('כן')),
        ],
      ),
    );
    if (yes != true) return;
    final r = await enableFingerprint();
    messenger.showSnackBar(SnackBar(
      content: Text(switch (r) {
        FingerprintResult.enabled => 'טביעת האצבע פעילה',
        FingerprintResult.cancelled => 'לא הופעל. אפשר להפעיל בהגדרות',
        FingerprintResult.unsupported => errorText(Errors.noBiometrics),
      }),
    ));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _widgetTaps?.cancel();
    _add.dispose();
    _addFocus.dispose();
    super.dispose();
  }

  Future<void> _addItem(String text) async {
    final title = text.trim();
    if (title.isEmpty) return;
    _add.clear();
    final u = FirebaseAuth.instance.currentUser!;
    // Not awaited: Firestore applies it locally at once and queues it offline.
    _items.add({
      'title': title,
      'done': false,
      'by': u.uid,
      'byName': u.displayName,
      'createdAt': FieldValue.serverTimestamp(),
    }).catchError((Object e) {
      if (mounted) showError(ScaffoldMessenger.of(context), e, 'ההוספה נכשלה');
      return _items.doc();
    });
  }

  /// Delete now, undo for 5 seconds: no confirm dialog for what can be undone.
  void _delete(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    doc.reference.delete();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 5),
      content: Text('"${data['title']}" נמחק'),
      action: SnackBarAction(label: 'ביטול', onPressed: () => doc.reference.set(data)),
    ));
  }

  Future<void> _rename(QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
    final c = TextEditingController(text: '${doc['title']}');
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('עריכה'),
        content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ביטול')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('שמירה')),
        ],
      ),
    );
    if (title != null && title.trim().isNotEmpty) doc.reference.update({'title': title.trim()});
  }

  void _menu(QueryDocumentSnapshot<Map<String, dynamic>> doc) => showModalBottomSheet<void>(
        context: context,
        builder: (c) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('עריכה'),
              onTap: () {
                Navigator.pop(c);
                _rename(doc);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('מחיקה'),
              onTap: () {
                Navigator.pop(c);
                _delete(doc);
              },
            ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppConfig.name),
        actions: [
          TourTarget(
            'settings',
            child: IconButton(
              tooltip: 'הגדרות',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute<void>(builder: (_) => const SettingsPage())),
            ),
          ),
        ],
      ),
      body: Column(children: [
        const UpdateBanner(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TourTarget(
            'home.add',
            child: TextField(
              controller: _add,
              focusNode: _addFocus,
              textInputAction: TextInputAction.done,
              onSubmitted: _addItem,
              decoration: const InputDecoration(
                hintText: 'הוספה מהירה…',
                prefixIcon: Icon(Icons.add),
                border: OutlineInputBorder(),
              ),
            ),
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _items.orderBy('createdAt', descending: true).snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(errorText(snap.error!, 'טעינת הרשימה נכשלה'),
                      textAlign: TextAlign.center),
                ));
              }
              if (!snap.hasData) return const SkeletonList();
              final docs = snap.data!.docs;
              final open = docs.where((d) => d['done'] != true);
              updateHomeWidgets(
                  open: open.length,
                  titles: [for (final d in open.take(3)) '${d['title']}']);
              return RefreshIndicator(
                // Live already; a pull also checks for updates and re-reads
                // from the server, so it's never a dead gesture.
                onRefresh: () async {
                  _checkUpdates();
                  await _items.get(const GetOptions(source: Source.server))
                      .timeout(const Duration(seconds: 10))
                      .catchError((_) => snap.data!);
                },
                child: docs.isEmpty
                    ? ListView(children: const [
                        SizedBox(height: 120),
                        Center(child: Text('הרשימה ריקה. מוסיפים בשורה למעלה.')),
                      ])
                    : ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (_, i) {
                          final d = docs[i];
                          final tile = CheckboxListTile(
                            value: d['done'] == true,
                            onChanged: (v) => d.reference.update({'done': v}),
                            title: Text('${d['title']}'),
                            subtitle: d['by'] != FirebaseAuth.instance.currentUser?.uid
                                ? Text('נוסף ע״י ${d.data()['byName'] ?? ''}')
                                : null,
                            controlAffinity: ListTileControlAffinity.leading,
                          );
                          return GestureDetector(
                            key: ValueKey(d.id),
                            onLongPress: () => _menu(d),
                            child: i == 0 ? TourTarget('home.first', child: tile) : tile,
                          );
                        },
                      ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
