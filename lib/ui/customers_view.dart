import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/errors.dart';
import '../studio/studio.dart';
import 'skeleton.dart';
import 'studio_actions.dart';
import 'studio_dialogs.dart';
import 'theme.dart';

/// Customers and their portal links: one permanent link each, for every order.
class CustomersView extends StatefulWidget {
  const CustomersView({super.key});

  @override
  State<CustomersView> createState() => _CustomersViewState();
}

class _CustomersViewState extends State<CustomersView> {
  final _customers = customersRef.orderBy('name').snapshots();
  final _requests = requestsRef.snapshots();

  Future<void> _replaceLink(Doc c) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('להחליף את הקישור?'),
        content: Text('הקישור הנוכחי של ${c['name']} יפסיק לעבוד מיד, גם אצל מי שהוא הועבר אליו. '
            'שולחים ללקוח את הקישור החדש.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('החלפה')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await replacePortalLink(c);
      messenger.showSnackBar(const SnackBar(content: Text('יש קישור חדש. הישן לא עובד יותר')));
    } catch (e) {
      showError(messenger, e, 'החלפת הקישור נכשלה');
    }
  }

  Future<void> _delete(QueryDocumentSnapshot<Map<String, dynamic>> c, int total) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('למחוק את ${c['name']}?'),
        content: Text('יימחקו גם $total הבקשות של הלקוח, עם הגרסאות, הקבצים, הצעות המחיר וההערות. '
            'קישור הפורטל יפסיק לעבוד. אי אפשר לבטל.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('מחיקה'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await deleteCustomer(c.id);
    } catch (e) {
      showError(messenger, e, 'המחיקה נכשלה');
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _requests,
        builder: (context, rs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _customers,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(child: Text(errorText(snap.error!, 'טעינת הלקוחות נכשלה'), textAlign: TextAlign.center));
            }
            if (!snap.hasData) return const SkeletonList();
            final customers = snap.data!.docs;
            final requests = rs.data?.docs ?? const [];
            if (customers.isEmpty) {
              return Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('עוד אין לקוחות.'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                      onPressed: () => newCustomer(context), icon: const Icon(Icons.person_add_alt), label: const Text('לקוח חדש')),
                ]),
              );
            }
            return ListView(padding: const EdgeInsets.all(16), children: [
              for (final c in customers) ...[
                _CustomerCard(
                  c,
                  waiting: requests.where((r) => r['customerId'] == c.id && r['status'] == 'waiting').length,
                  total: requests.where((r) => r['customerId'] == c.id).length,
                  onReplace: () => _replaceLink(c),
                  onDelete: () => _delete(c, requests.where((r) => r['customerId'] == c.id).length),
                ),
                const SizedBox(height: 12),
              ],
            ]);
          },
        ),
      );
}

class _CustomerCard extends StatelessWidget {
  const _CustomerCard(this.c, {required this.waiting, required this.total, required this.onReplace, required this.onDelete});
  final QueryDocumentSnapshot<Map<String, dynamic>> c;
  final int waiting, total;
  final VoidCallback onReplace, onDelete;

  @override
  Widget build(BuildContext context) {
    final s = context.studio;
    final phone = '${c.data()['phone'] ?? ''}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${c['name']}', style: Theme.of(context).textTheme.titleMedium)),
            IconButton(
              tooltip: 'עריכה',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => showDialog<void>(context: context, builder: (_) => CustomerDialog(customer: c)),
            ),
            IconButton(tooltip: 'מחיקה', icon: const Icon(Icons.delete_outline), onPressed: onDelete),
          ]),
          Text(
            [
              if (phone.isNotEmpty) phone,
              c.data()['lang'] == 'en' ? 'פורטל באנגלית' : 'פורטל בעברית',
              '$total בקשות',
              if (waiting > 0) '$waiting ממתינות לאישור',
            ].join(' · '),
            style: TextStyle(color: s.muted),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonalIcon(
                onPressed: () => sendWhatsapp(context, c), icon: const Icon(Icons.chat_outlined), label: const Text('וואטסאפ')),
            OutlinedButton.icon(
                onPressed: () => copyPortalLink(context, c), icon: const Icon(Icons.link), label: const Text('העתקת קישור')),
            OutlinedButton.icon(
              onPressed: () => launchUrl(Uri.parse(portalUrl('${c['portalToken']}')), mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_browser),
              label: const Text('פתיחת הפורטל'),
            ),
            TextButton(onPressed: onReplace, child: const Text('החלפת קישור')),
          ]),
        ]),
      ),
    );
  }
}
