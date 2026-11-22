import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/export.dart';
import '../studio/studio.dart';
import 'bills.dart';
import 'requests_view.dart';
import 'skeleton.dart';
import 'studio_dialogs.dart';
import 'theme.dart';

/// The money tab: received this month, still owed on approved orders, open
/// offers, and a monthly or quarterly report of sales and payments. Everything is summed from the
/// quotes and the payments; nothing here is stored.
class MoneyView extends StatefulWidget {
  const MoneyView({super.key});

  @override
  State<MoneyView> createState() => _MoneyViewState();
}

class _MoneyViewState extends State<MoneyView> {
  final _requests = requestsRef.snapshots();
  final _quotes = quotesRef.snapshots();
  final _payments = paymentsRef.snapshots();
  bool _quarterly = false;

  @override
  Widget build(BuildContext context) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _requests,
        builder: (context, rs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _quotes,
          builder: (context, qs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _payments,
            builder: (context, ps) {
              final err = rs.error ?? qs.error ?? ps.error;
              if (err != null) return Center(child: Text(errorText(err, 'טעינת הכספים נכשלה'), textAlign: TextAlign.center));
              if (!rs.hasData || !qs.hasData || !ps.hasData) return const SkeletonList();
              return _body(rs.data!.docs, qs.data!.docs, ps.data!.docs);
            },
          ),
        ),
      );

  /// Sales (orders approved, by the day the client approved) and payments (by their day), per month or quarter.
  Widget _report(List<Doc> requests, Map<String, Map<String, dynamic>?> quoteData, List<Doc> payments, DateTime now) {
    final s = context.studio;
    final byId = {for (final r in requests) r.id: r.data()!};
    final sales = [
      for (final r in requests)
        if ((r.data()!, quoteData[r.data()?['approvedQuoteId'] ?? r.data()?['quoteId']])
            case (final d, final q?) when d['approvedAt'] is Timestamp && owes('${d['status']}'))
          () {
            final m = quoteMoney(q);
            final cost = (productionOf(d)['actualCost'] as Map?)?['total'];
            return (
              requestId: r.id,
              at: (d['approvedAt'] as Timestamp).toDate(),
              net: m.net,
              vat: m.vat,
              discount: (q['discount'] as int?) ?? 0,
              cost: cost is int ? cost : null,
            );
          }(),
    ];
    final pays = [
      for (final p in payments)
        if (p['at'] is Timestamp)
          (requestId: '${p['requestId']}', at: (p['at'] as Timestamp).toDate(), amount: p['amount'] as int, method: '${p['method']}'),
    ];
    final periods = periodReport(quarterly: _quarterly, now: now, sales: sales, payments: pays);
    String who(String id) => '${byId[id]?['customerName'] ?? ''} · ${byId[id]?['title'] ?? ''}';
    String day(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    String plain(int agorot) => (agorot / 100).toStringAsFixed(2);

    Future<void> csv() async {
      final rows = [
        for (final p in periods) ...[
          for (final x in p.sales)
            {'תקופה': p.label, 'סוג': 'מכירה', 'תאריך': day(x.at), 'הזמנה': who(x.requestId),
             'לפני מע״מ': plain(x.net), 'מע״מ': plain(x.vat), 'הנחה': plain(x.discount),
             'עלות': x.cost == null ? '' : plain(x.cost!), 'התקבל': '', 'אמצעי': ''},
          for (final x in p.payments)
            {'תקופה': p.label, 'סוג': 'תשלום', 'תאריך': day(x.at), 'הזמנה': who(x.requestId),
             'לפני מע״מ': '', 'מע״מ': '', 'הנחה': '', 'עלות': '', 'התקבל': plain(x.amount),
             'אמצעי': paymentMethods[x.method] ?? x.method},
        ],
      ];
      try {
        await exportCsv('${_quarterly ? 'quarterly' : 'monthly'}-report-${now.toIso8601String().substring(0, 10)}.csv', rows);
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(e, 'הייצוא נכשל'))));
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('דוח מכירות ותשלומים', style: Theme.of(context).textTheme.titleMedium),
            SegmentedButton<bool>(
              segments: const [ButtonSegment(value: false, label: Text('חודשי')), ButtonSegment(value: true, label: Text('רבעוני'))],
              selected: {_quarterly},
              onSelectionChanged: (v) => setState(() => _quarterly = v.first),
            ),
            TextButton.icon(onPressed: csv, icon: const Icon(Icons.download), label: const Text('CSV')),
          ]),
          Text('מכירה: הזמנה שהלקוח אישר בתקופה, לפי יום האישור. התקבל: לפי יום התשלום. רווח: רק הזמנות ש-Gift Factory דיווח את עלותן.',
              style: TextStyle(color: s.muted, fontSize: 12)),
          for (final p in periods)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Row(children: [
                Expanded(child: Text(ltr(p.label))),
                Text('${p.sales.length} הזמנות · ', style: TextStyle(color: s.muted)),
                Text(shekel(p.net), textDirection: TextDirection.ltr),
              ]),
              childrenPadding: const EdgeInsetsDirectional.only(start: 12, bottom: 8),
              children: [
                MoneyLine('מכירות לפני מע״מ', p.net),
                MoneyLine('מע״מ', p.vat),
                if (p.discount > 0) MoneyLine('הנחות שניתנו', p.discount),
                MoneyLine('התקבל', p.received),
                if (p.profit.counted > 0) MoneyLine('רווח (${p.profit.counted} מתוך ${p.sales.length})', p.profit.profit, bold: true),
                if (p.sales.isNotEmpty || p.payments.isNotEmpty) const Divider(),
                for (final x in p.sales) MoneyLine('${ltr(day(x.at))} · מכירה · ${who(x.requestId)}', x.net + x.vat),
                for (final x in p.payments)
                  MoneyLine('${ltr(day(x.at))} · ${paymentMethods[x.method] ?? x.method} · ${who(x.requestId)}', x.amount),
              ],
            ),
        ]),
      ),
    );
  }

  Widget _body(List<Doc> requests, List<Doc> quotes, List<Doc> payments) {
    final s = context.studio;
    final totals = {
      for (final q in quotes) q.id: quoteMoney(q.data()!).total,
    };
    final paidBy = <String, int>{};
    for (final p in payments) {
      paidBy['${p['requestId']}'] = (paidBy['${p['requestId']}'] ?? 0) + (p['amount'] as int);
    }
    final owing = [
      for (final r in requests)
        if (owes('${r['status']}') && totals[r.data()?['quoteId']] != null)
          (r, leftToPay(totals[r['quoteId']]!, paidBy[r.id] ?? 0)),
    ].where((e) => e.$2 > 0).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    final offers = requests
        .where((r) => r['status'] == 'waiting')
        .fold(0, (a, r) => a + (totals[r.data()?['quoteId']] ?? 0));
    final now = DateTime.now();
    final months = [for (var i = 0; i < 6; i++) DateTime(now.year, now.month - i)];
    // Real profit (Gift Factory's actual cost) on orders approved in the months shown.
    final quoteData = {for (final q in quotes) q.id: q.data()};
    final runs = [
      for (final r in requests)
        if (r.data()?['approvedAt'] case final Timestamp at when !at.toDate().isBefore(months.last))
          (r, profit(r.data()!, quoteData[r.data()?['approvedQuoteId'] ?? r.data()?['quoteId']])),
    ];
    final earned = runs.fold(0, (a, e) => a + (e.$2 ?? 0));
    int inMonth(DateTime m) => payments.where((p) {
          final at = p['at'] is Timestamp ? (p['at'] as Timestamp).toDate() : now;
          return at.year == m.year && at.month == m.month;
        }).fold(0, (a, p) => a + (p['amount'] as int));

    Widget stat(String label, int agorot, String hint) => SizedBox(
          width: 220,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: TextStyle(color: s.muted)),
                const SizedBox(height: 4),
                Text(shekel(agorot), textDirection: TextDirection.ltr, style: Theme.of(context).textTheme.headlineSmall),
                Text(hint, style: TextStyle(color: s.muted, fontSize: 12)),
              ]),
            ),
          ),
        );

    return ListView(padding: const EdgeInsets.all(16), children: [
      // The ribbon's payment buttons, here too: on a phone the ribbon is easy to miss.
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.tonalIcon(
            icon: const Icon(Icons.receipt_long_outlined),
            label: const Text('דרישות תשלום וקבלות'),
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const BillsPage()))),
        OutlinedButton.icon(
            icon: const Icon(Icons.content_paste), label: const Text('הדבקת קבלה'), onPressed: () => pasteReceipt(context)),
      ]),
      const SizedBox(height: 16),
      Wrap(spacing: 12, runSpacing: 12, children: [
        stat('התקבל החודש', inMonth(months.first), 'לפי יום התשלום'),
        stat('נותר לגבייה', owing.fold(0, (a, e) => a + e.$2), '${owing.length} הזמנות שאושרו'),
        stat('הצעות פתוחות', offers, 'ממתינות לאישור הלקוח'),
      ]),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('נותר לגבייה', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (owing.isEmpty) Text('אין חובות פתוחים.', style: TextStyle(color: s.muted)),
            for (final (r, left) in owing)
              InkWell(
                onTap: () => Navigator.push(
                    context, MaterialPageRoute<void>(builder: (_) => RequestPage(requestId: r.id))),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: MoneyLine('${r['customerName'] ?? ''} · ${r['title']} · ${statusLabels[r['status']] ?? ''}', left),
                ),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 16),
      _report(requests, quoteData, payments, now),
      if (runs.any((e) => e.$2 != null)) ...[
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('רווח בפועל', style: Theme.of(context).textTheme.titleMedium),
              Text('המחיר שאושר לפני מע״מ, פחות העלות שדיווח Gift Factory. הזמנות שאושרו ב-6 החודשים האחרונים.',
                  style: TextStyle(color: s.muted, fontSize: 12)),
              const SizedBox(height: 8),
              for (final (r, p) in runs)
                InkWell(
                  onTap: () => Navigator.push(
                      context, MaterialPageRoute<void>(builder: (_) => RequestPage(requestId: r.id))),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      Expanded(child: Text('${r['customerName'] ?? ''} · ${r['title']}')),
                      Text(p == null ? '—' : shekel(p), textDirection: TextDirection.ltr),
                    ]),
                  ),
                ),
              const Divider(),
              MoneyLine('סה״כ רווח', earned, bold: true),
            ]),
          ),
        ),
      ],
    ]);
  }
}
