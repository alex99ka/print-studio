import 'package:flutter/material.dart';

import '../core/tour.dart';
import '../studio/desktop.dart';
import 'studio_actions.dart';
import 'theme.dart';

/// The Word-like ribbon under the tabs: groups of big buttons, each group
/// named under it. Buttons for the open request wake up when one is open.
class Ribbon extends StatelessWidget {
  const Ribbon({super.key, this.compact = false});

  /// On a phone's request page: only what acts on that request.
  final bool compact;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Selection?>(
        valueListenable: selection,
        builder: (context, s, _) {
          final customer = s?.customer;
          final groups = [
            if (!compact)
              _Group('חדש', [
                TourTarget('home.new',
                    child: _Button(Icons.add_box_outlined, 'בקשה חדשה', () => newRequest(context), primary: true)),
                _Button(Icons.person_add_alt, 'לקוח חדש', () => newCustomer(context)),
              ]),
            _Group('Flag Maker', [
              _Button(Icons.upload_file_outlined, 'ייבוא גרסה',
                  s != null && s.open ? () => importVersion(context, s) : null),
              if (isWindows)
                _Button(Icons.open_in_new, 'פתיחה ב-Flag Maker',
                    s != null && (withRecipe(s) != null || s.open) ? () => openFlagMaker(context, s) : null),
            ]),
            if (isWindows)
              _Group('Gift Factory', [
                _Button(Icons.redeem_outlined, 'פתח ב-Gift Factory', s != null ? () => openGiftFactory(context, s) : null),
              ]),
            TourTarget(
              'home.client',
              child: _Group('לקוח', [
                _Button(Icons.send_outlined, 'פרסם ללקוח',
                    s != null && publishable(s) != null ? () => publishVersion(context, s) : null),
                _Button(Icons.chat_outlined, 'שליחה בוואטסאפ',
                    customer != null ? () => sendWhatsapp(context, customer) : null),
                _Button(Icons.link, 'העתקת קישור', customer != null ? () => copyPortalLink(context, customer) : null),
              ]),
            ),
            _Group('הדפסה', [
              _Button(isWindows ? Icons.print_outlined : Icons.download_outlined,
                  isWindows ? 'פתיחה ב-Bambu' : 'הורדת 3MF', s != null && printable(s) != null ? () => openSlicer(context, s) : null),
            ]),
          ];
          return Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              border: Border(bottom: BorderSide(color: context.studio.line)),
            ),
            width: double.infinity,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
              child: IntrinsicHeight(child: Row(children: groups)),
            ),
          );
        },
      );
}

class _Group extends StatelessWidget {
  const _Group(this.label, this.buttons);
  final String label;
  final List<Widget> buttons;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(border: BorderDirectional(end: BorderSide(color: context.studio.line))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: buttons),
          Text(label, style: TextStyle(fontSize: 11, color: context.studio.muted)),
        ]),
      );
}

class _Button extends StatelessWidget {
  const _Button(this.icon, this.label, this.onPressed, {this.primary = false});
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final s = context.studio;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(76, 60),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        backgroundColor: primary ? s.accentSoft : null,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        disabledForegroundColor: s.muted.withValues(alpha: .5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 22),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ]),
    );
  }
}
