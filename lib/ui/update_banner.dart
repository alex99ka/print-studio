import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/update.dart';
import '../core/web_update.dart';

/// Top of the home screen, only when there is something to say: a new web
/// build (reload), a download in progress, or a build that needs a tap
/// because it can't install by itself (Android 11 and older, or the user
/// hasn't allowed installs yet). Silent updates show nothing here.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final u = AppUpdater.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([u, WebUpdate.instance]),
      builder: (context, _) {
        final web = WebUpdate.instance.available;
        if (web != null) {
          return _bar(context, 'גרסה $web זמינה', 'רענון', WebUpdate.instance.apply);
        }
        if (u == null || u.available == null || u.dismissed) {
          return const SizedBox.shrink();
        }
        if (u.progress != null) {
          return LinearProgressIndicator(value: u.progress, minHeight: 3);
        }
        if (u.ready && u.installsByItself) return const SizedBox.shrink();
        return _bar(
          context,
          u.needsPermission
              ? errorText(Errors.updateNotAllowed)
              : u.error != null
                  ? errorText(u.error!, 'העדכון')
                  : 'גרסה ${u.available!.version} זמינה',
          'עדכון',
          u.install,
          onLater: u.dismiss,
        );
      },
    );
  }

  Widget _bar(BuildContext context, String text, String action, VoidCallback onTap,
      {VoidCallback? onLater}) {
    final c = Theme.of(context).colorScheme;
    return Material(
      color: c.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(children: [
          Icon(Icons.system_update, color: c.onPrimaryContainer),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: TextStyle(color: c.onPrimaryContainer))),
          if (onLater != null) TextButton(onPressed: onLater, child: const Text('אחר כך')),
          FilledButton(onPressed: onTap, child: Text(action)),
        ]),
      ),
    );
  }
}
