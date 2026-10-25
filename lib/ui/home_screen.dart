import 'dart:async';

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
import 'customers_view.dart';
import 'requests_view.dart';
import 'ribbon.dart';
import 'settings_page.dart';
import 'studio_actions.dart';
import 'theme.dart';
import 'update_banner.dart';

/// Tabs along the top like Word's (בית · לקוחות · הגדרות), the ribbon under
/// them, and the tab's page below.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

const _tabs = ['בית', 'לקוחות', 'הגדרות'];

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  late final AppLifecycleListener _lifecycle;
  StreamSubscription<Uri?>? _widgetTaps;

  @override
  void initState() {
    super.initState();
    // Updates: at launch, and on coming back to the app.
    _checkUpdates();
    _lifecycle = AppLifecycleListener(onResume: _checkUpdates);
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterFirstFrame());
    // The quick-add home widget opens the app on a new request.
    _widgetTaps = listenWidgetTaps((action) {
      if (action == 'add' && mounted) newRequest(context);
    });
  }

  void _checkUpdates() {
    AppUpdater.instance?.checkIfDue();
    WebUpdate.instance.check();
  }

  void _openFromPush(Map<String, dynamic> data) {
    final id = data['id'];
    if (data['route'] == '/request' && id is String && mounted) {
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => RequestPage(requestId: id)));
    }
  }

  Future<void> _afterFirstFrame() async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setUpNotifications(messenger, onOpen: _openFromPush).ignore();
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.studio;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(children: [
        Container(
          color: s.bar,
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          child: SizedBox(
            height: 48,
            child: Row(children: [
              const SizedBox(width: 16),
              Icon(Icons.view_in_ar_outlined, color: s.barInk, size: 22),
              const SizedBox(width: 10),
              Text(AppConfig.name, style: TextStyle(color: s.barInk, fontWeight: FontWeight.w700, fontSize: 16)),
              const Spacer(),
              Text(AppInfo.version, textDirection: TextDirection.ltr,
                  style: TextStyle(color: s.barInk.withValues(alpha: .75), fontSize: 12)),
              const SizedBox(width: 16),
            ]),
          ),
        ),
        Material(
          color: scheme.surface,
          child: Container(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: s.line))),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: AlignmentDirectional.centerStart,
            child: Row(children: [
              for (final (i, label) in _tabs.indexed)
                if (i == 2) TourTarget('settings', child: _tabButton(i, label)) else _tabButton(i, label),
            ]),
          ),
        ),
        if (_tab < 2) const Ribbon(),
        const UpdateBanner(),
        Expanded(
          child: IndexedStack(index: _tab, children: const [
            RequestsView(),
            CustomersView(),
            SettingsPage(embedded: true),
          ]),
        ),
      ]),
    );
  }

  Widget _tabButton(int i, String label) {
    final selected = _tab == i;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: () => setState(() => _tab = i),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: selected ? scheme.primary : AppTokens.lightBg.withValues(alpha: 0), width: 3)),
          ),
          child: Text(label,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                color: selected ? scheme.onSurface : context.studio.muted,
              )),
        ),
      ),
    );
  }
}
