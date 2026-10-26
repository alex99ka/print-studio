import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../studio/studio.dart';
import 'requests_view.dart';
import 'skeleton.dart';
import 'studio_dialogs.dart';
import 'theme.dart';

/// The money tab: received this month, still owed on approved orders, open
/// offers, and what came in month by month. Everything is summed from the
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

  Widget _body(List<Doc> requests, List<Doc> quotes, List<Doc> payments) {
    final s = context.studio;
    final totals = {
      for (final q in quotes) q.id: money(q['unit'] as int, q['qty'] as int, q['vatPercent'] as int).total,
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
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('התקבל לפי חודש', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final m in months) MoneyLine(ltr('${m.month.toString().padLeft(2, '0')}/${m.year}'), inMonth(m)),
          ]),
        ),
      ),
    ]);
  }
}
