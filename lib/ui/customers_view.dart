import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/errors.dart';
import '../studio/studio.dart';
import 'requests_view.dart';
import 'skeleton.dart';
import 'studio_actions.dart';
import 'studio_dialogs.dart';
import 'theme.dart';

typedef _Snap = AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>>;

/// Per request: the current quote's total and what was paid on it.
({Map<String, int> totals, Map<String, int> paid}) _sums(List<Doc> quotes, List<Doc> payments) {
  final paid = <String, int>{};
  for (final p in payments) {
    paid['${p['requestId']}'] = (paid['${p['requestId']}'] ?? 0) + (p['amount'] as int);
  }
  return (
    totals: {for (final q in quotes) q.id: money(q['unit'] as int, q['qty'] as int, q['vatPercent'] as int).total},
    paid: paid,
  );
}

({int billed, int paid, int left}) _balanceOf(Iterable<Doc> requests, ({Map<String, int> totals, Map<String, int> paid}) m) =>
    balance([
      for (final r in requests) (status: '${r['status']}', total: m.totals[r.data()?['quoteId']], paid: m.paid[r.id] ?? 0),
    ]);

/// Customers: the list with what each one paid and still owes, beside the open
/// customer on a wide screen; on a phone a customer opens as its own page.
class CustomersView extends StatefulWidget {
  const CustomersView({super.key});

  @override
  State<CustomersView> createState() => _CustomersViewState();
}

class _CustomersViewState extends State<CustomersView> {
  final _customers = customersRef.orderBy('name').snapshots();
  final _requests = requestsRef.snapshots();
  final _quotes = quotesRef.snapshots();
  final _payments = paymentsRef.snapshots();
  String? _open;

  @override
  Widget build(BuildContext context) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _requests,
        builder: (context, rs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _quotes,
          builder: (context, qs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _payments,
            builder: (context, ps) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _customers,
              builder: (context, snap) => LayoutBuilder(builder: (context, box) => _body(box.maxWidth >= 900, snap, rs, qs, ps)),
            ),
          ),
        ),
      );

  Widget _body(bool wide, _Snap snap, _Snap rs, _Snap qs, _Snap ps) {
    final err = snap.error ?? rs.error ?? qs.error ?? ps.error;
    if (err != null) return Center(child: Text(errorText(err, 'טעינת הלקוחות נכשלה'), textAlign: TextAlign.center));
    if (!snap.hasData) return const SkeletonList();
    final customers = snap.data!.docs;
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
    final requests = rs.data?.docs ?? const [];
    final sums = _sums(qs.data?.docs ?? const [], ps.data?.docs ?? const []);
    final today = DateTime.now();
    final list = ListView(padding: const EdgeInsets.all(16), children: [
      for (final c in customers) ...[
        _CustomerCard(
          c,
          requests: requests.where((r) => r['customerId'] == c.id).toList(),
          balance: _balanceOf(requests.where((r) => r['customerId'] == c.id), sums),
          today: today,
          selected: wide && _open == c.id,
          onTap: () => wide
              ? setState(() => _open = c.id)
              : Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CustomerPage(customerId: c.id))),
        ),
        const SizedBox(height: 12),
      ],
    ]);
    if (!wide) return list;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 400, child: list),
      VerticalDivider(width: 1, color: context.studio.line),
      Expanded(
        child: _open == null
            ? const Center(child: Text('בוחרים לקוח כדי לראות את הבקשות והתשלומים שלו.'))
            : CustomerDetail(key: ValueKey(_open), customerId: _open!),
      ),
    ]);
  }
}

class _CustomerCard extends StatelessWidget {
  const _CustomerCard(this.c,
      {required this.requests, required this.balance, required this.today, required this.selected, required this.onTap});
  final Doc c;
  final List<Doc> requests;
  final ({int billed, int paid, int left}) balance;
  final DateTime today;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.studio;
    final phone = '${c.data()?['phone'] ?? ''}';
    final waiting = requests.where((r) => r['status'] == 'waiting').length;
    final soon = requests.where((r) => (daysLeft(r.data(), today) ?? 1 << 30) <= remindDays(r.data()!)).length;
    return Card(
      color: selected ? s.accentSoft : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('${c['name']}', style: Theme.of(context).textTheme.titleMedium)),
              Icon(Icons.chevron_left, color: s.muted),
            ]),
            Text(
              [
                if (phone.isNotEmpty) ltr(phone),
                '${requests.length} בקשות',
                if (waiting > 0) '$waiting ממתינות לאישור',
                if (soon > 0) '$soon עם תאריך יעד קרוב',
              ].join(' · '),
              style: TextStyle(color: s.muted),
            ),
            if (balance.billed > 0 || balance.paid > 0)
              Text('שולם ${ltr(shekel(balance.paid))} · נותר ${ltr(shekel(balance.left))}',
                  style: TextStyle(color: balance.left > 0 ? s.warnInk : s.okInk, fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
    );
  }
}

/// On a phone: one customer as its own page.
class CustomerPage extends StatelessWidget {
  const CustomerPage({super.key, required this.customerId});
  final String customerId;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('לקוח')),
        body: CustomerDetail(customerId: customerId),
      );
}

/// One customer: details, portal link, money, and every request of theirs (open
/// them, add one, record a payment).
class CustomerDetail extends StatefulWidget {
  const CustomerDetail({super.key, required this.customerId});
  final String customerId;

  @override
  State<CustomerDetail> createState() => _CustomerDetailState();
}

class _CustomerDetailState extends State<CustomerDetail> {
  late final _customer = customersRef.doc(widget.customerId).snapshots();
  late final _requests = requestsRef.where('customerId', isEqualTo: widget.customerId).snapshots();
  late final _quotes = quotesRef.where('customerId', isEqualTo: widget.customerId).snapshots();
  late final _payments = paymentsRef.where('customerId', isEqualTo: widget.customerId).snapshots();

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

  Future<void> _delete(Doc c, int total) async {
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
    final nav = Navigator.of(context);
    try {
      await deleteCustomer(c.id);
      if (nav.canPop()) nav.pop();
    } catch (e) {
      showError(messenger, e, 'המחיקה נכשלה');
    }
  }

  Future<void> _newRequest(Doc c) async {
    final id = await newRequest(context, customer: c);
    if (id != null && mounted) _openRequest(id);
  }

  void _openRequest(String id) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => RequestPage(requestId: id)));

  @override
  Widget build(BuildContext context) => StreamBuilder<Doc>(
        stream: _customer,
        builder: (context, cs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _requests,
          builder: (context, rs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _quotes,
            builder: (context, qs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _payments,
              builder: (context, ps) {
                final err = cs.error ?? rs.error ?? qs.error ?? ps.error;
                if (err != null) return Center(child: Text(errorText(err, 'טעינת הלקוח נכשלה'), textAlign: TextAlign.center));
                if (!cs.hasData || !rs.hasData || !qs.hasData || !ps.hasData) return const SkeletonList();
                if (!cs.data!.exists) return const Center(child: Text('הלקוח נמחק.'));
                return _body(cs.data!, rs.data!.docs, _sums(qs.data!.docs, ps.data!.docs));
              },
            ),
          ),
        ),
      );

  Widget _body(Doc c, List<Doc> requests, ({Map<String, int> totals, Map<String, int> paid}) sums) {
    final s = context.studio;
    final phone = '${c.data()?['phone'] ?? ''}';
    final b = _balanceOf(requests, sums);
    final today = DateTime.now();
    // Nearest deadline first, then the rest by last change.
    DateTime updated(Doc r) => (r.data()?['updatedAt'] as Timestamp?)?.toDate() ?? today;
    final sorted = [...requests]..sort((x, y) {
        final dx = daysLeft(x.data(), today), dy = daysLeft(y.data(), today);
        if (dx != null || dy != null) return (dx ?? 1 << 30).compareTo(dy ?? 1 << 30);
        return updated(y).compareTo(updated(x));
      });

    Widget stat(String label, int agorot, {Color? color}) => SizedBox(
          width: 180,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: TextStyle(color: s.muted)),
                const SizedBox(height: 4),
                Text(shekel(agorot),
                    textDirection: TextDirection.ltr, style: Theme.of(context).textTheme.titleLarge?.copyWith(color: color)),
              ]),
            ),
          ),
        );

    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(child: Text('${c['name']}', style: Theme.of(context).textTheme.headlineSmall)),
        IconButton(
          tooltip: 'עריכה',
          icon: const Icon(Icons.edit_outlined),
          onPressed: () => showDialog<void>(context: context, builder: (_) => CustomerDialog(customer: c)),
        ),
        IconButton(tooltip: 'מחיקה', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(c, requests.length)),
      ]),
      Text(
        [if (phone.isNotEmpty) ltr(phone), c.data()?['lang'] == 'en' ? 'פורטל באנגלית' : 'פורטל בעברית'].join(' · '),
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
        TextButton(onPressed: () => _replaceLink(c), child: const Text('החלפת קישור')),
      ]),
      const SizedBox(height: 16),
      Wrap(spacing: 12, runSpacing: 12, children: [
        stat('הזמנות שאושרו', b.billed),
        stat('שולם', b.paid, color: s.okInk),
        stat('נותר לתשלום', b.left, color: b.left > 0 ? s.warnInk : null),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: Text('בקשות (${requests.length})', style: Theme.of(context).textTheme.titleMedium)),
        FilledButton.icon(onPressed: () => _newRequest(c), icon: const Icon(Icons.add), label: const Text('בקשה חדשה')),
      ]),
      const SizedBox(height: 8),
      if (requests.isEmpty) Text('עוד אין בקשות ללקוח הזה.', style: TextStyle(color: s.muted)),
      for (final r in sorted) _row(r, sums),
    ]);
  }

  Widget _row(Doc r, ({Map<String, int> totals, Map<String, int> paid}) sums) {
    final s = context.studio;
    final total = sums.totals[r.data()?['quoteId']];
    final paid = sums.paid[r.id] ?? 0;
    final owed = total != null && owes('${r['status']}');
    final left = owed ? leftToPay(total, paid) : 0;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openRequest(r.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${r['title']}', style: const TextStyle(fontWeight: FontWeight.w500)),
                Text(
                  [
                    '${r.data()?['qty'] ?? 1} יח׳',
                    if (total == null) 'אין מחיר' else 'מחיר ${ltr(shekel(total))}',
                    if (paid > 0) 'שולם ${ltr(shekel(paid))}',
                    if (left > 0) 'נותר ${ltr(shekel(left))}',
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: s.muted),
                ),
              ]),
            ),
            if (left > 0)
              IconButton(
                tooltip: 'רישום תשלום',
                icon: const Icon(Icons.payments_outlined),
                onPressed: () => showDialog<void>(context: context, builder: (_) => PaymentDialog(request: r, left: left)),
              ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              StatusChip('${r['status']}'),
              if (r.data()?['deadline'] != null) ...[const SizedBox(height: 4), DeadlineChip(r.data()!)],
            ]),
          ]),
        ),
      ),
    );
  }
}
