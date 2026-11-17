import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../studio/studio.dart';
import 'requests_view.dart';
import 'theme.dart';

/// C-2: the one printer's calendar: every order with a deadline, Gift Factory runs and Flag
/// Maker flags alike, laid back to back (printSchedule, the Pi's reminders count the same).
class SchedulePage extends StatelessWidget {
  const SchedulePage({super.key});

  static String _when(DateTime d) => '${d.day}.${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final s = context.studio;
    final now = DateTime.now();
    final today = DateTime.utc(now.year, now.month, now.day);
    return Scaffold(
      appBar: AppBar(title: const Text('לוח מדפסת')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: requestsRef.snapshots(),
        builder: (context, snap) {
          final docs = {for (final d in snap.data?.docs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[]) d.id: d.data()};
          final plan = printSchedule(docs).entries.toList()..sort((a, b) => a.value.start.compareTo(b.value.start));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          if (plan.isEmpty) {
            return Center(child: Text('אין הזמנות עם תאריך יעד שעוד צריך להדפיס.', style: TextStyle(color: s.muted)));
          }
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text('המדפסת אחת: כל הזמנה מתוכננת כמה שיותר מאוחר, יומיים לפני תאריך היעד ולפני שהבאה מתחילה. '
                'אדום = כבר לא מספיקים: מזיזים תאריך יעד או מתחילים עכשיו.', style: TextStyle(color: s.muted, fontSize: 12)),
            const SizedBox(height: 8),
            for (final e in plan)
              Builder(builder: (context) {
                final r = docs[e.key]!;
                final late = e.value.start.isBefore(today) && r['status'] != 'printing';
                final hours = printHoursLeft(r);
                return Card(
                  color: late ? Theme.of(context).colorScheme.errorContainer : null,
                  child: ListTile(
                    title: Text('${r['title']} · ${r['customerName'] ?? ''}'),
                    subtitle: Text('להתחיל ${_when(e.value.start)} · לסיים ${_when(e.value.end)} · '
                        '${hours.toStringAsFixed(hours < 10 ? 1 : 0)} שעות הדפסה · '
                        '${statusLabels[r['status']] ?? r['status']}'
                        '${productionOf(r)['quote'] == null && r['estimate'] == null ? ' · בלי הערכה: יום' : ''}'),
                    trailing: DeadlineChip(r),
                    onTap: () => Navigator.push(
                        context, MaterialPageRoute<void>(builder: (_) => RequestPage(requestId: e.key))),
                  ),
                );
              }),
          ]);
        },
      ),
    );
  }
}
