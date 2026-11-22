import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/errors.dart';
import '../studio/studio.dart';
import 'skeleton.dart';
import 'theme.dart';

/// Payment requests (דרישות תשלום): made by the Pi on the billing day or here on demand,
/// sent by Alex on WhatsApp, paid by pasting the receipt app's message.

String _day(Object? t) {
  final d = (t as Timestamp?)?.toDate();
  return d == null ? '' : '${d.day}.${d.month}.${d.year}';
}

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), persist: false));

Future<void> _send(BuildContext context, Doc bill) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final b = bill.data()!;
    final c = (await customersRef.doc('${b['customerId']}').get()).data() ?? const {};
    final url = '${portalUrl('${c['portalToken']}')}#tab=bills';
    if (!await launchUrl(whatsapp('${c['phone'] ?? b['phone'] ?? ''}', billMessage(b, url)), mode: LaunchMode.externalApplication)) {
      throw Errors.noConnection;
    }
    await bill.reference.update({'sentAt': FieldValue.serverTimestamp()});
  } catch (e) {
    showError(messenger, e, 'וואטסאפ לא נפתח');
  }
}

Future<void> billCustomerNow(BuildContext context, String customerId) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final b = await billNow(customerId);
    messenger.showSnackBar(SnackBar(
        persist: false,
        content: Text(b == null
            ? 'אין מה לדרוש: אין הזמנות מוכנות או שנמסרו שלא שולמו'
            : b['new'] == true
                ? 'דרישה מס׳ ${b['number']} על ${shekel(b['due'] as int)} מוכנה לשליחה'
                : 'דרישה מס׳ ${b['number']} כבר פתוחה, ולא השתנה בה דבר')));
  } catch (e) {
    showError(messenger, e, 'יצירת הדרישה נכשלה');
  }
}

Future<void> _trash(BuildContext context, Doc bill) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('להעביר את דרישה ${bill['number']} לסל?'),
      content: const Text('הקישור שנשלח ללקוח יפסיק לעבוד. אפשר לשחזר מהסל עד $trashDays יום, '
          'ואז היא נמחקת לצמיתות. תשלומים שכבר נרשמו נשארים.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('העברה לסל'),
        ),
      ],
    ),
  );
  if (yes != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await trashBill(bill, true);
    messenger.showSnackBar(SnackBar(
        content: const Text('הועבר לסל'),
        action: SnackBarAction(label: 'ביטול', onPressed: () => trashBill(bill, false).ignore())));
  } catch (e) {
    showError(messenger, e, 'ההעברה לסל נכשלה');
  }
}

/// One bill: number, day, amount, state, and what can be done with it.
class BillTile extends StatelessWidget {
  const BillTile(this.bill, {super.key, this.showName = false});
  final Doc bill;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final s = context.studio;
    final b = bill.data()!;
    final state = '${b['state']}';
    final trashed = b['deletedAt'] != null;
    final receipt = (b['receipt'] as Map?) ?? const {};
    final color = trashed ? s.muted : (state == 'paid' ? s.okInk : (state == 'open' ? s.warnInk : s.muted));
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.receipt_long_outlined, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text([if (showName) '${b['customerName']}', 'דרישה ${b['number']}'].join(' · '),
                    style: const TextStyle(fontWeight: FontWeight.w500)),
                Text(
                  [
                    _day(b['createdAt']),
                    '${(b['lines'] as List).length} פריטים',
                    if (trashed) 'בסל מאז ${_day(b['deletedAt'])}' else billStates[state] ?? state,
                    if (state == 'open' && !trashed) b['sentAt'] == null ? 'עוד לא נשלחה' : 'נשלחה ${_day(b['sentAt'])}',
                    if (receipt['number'] != null) 'קבלה ${receipt['number']}',
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: s.muted),
                ),
              ]),
            ),
            Text(shekel(b['due'] as int),
                textDirection: TextDirection.ltr, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
          ]),
          Wrap(spacing: 4, children: [
            if (trashed)
              TextButton.icon(
                  onPressed: () => trashBill(bill, false), icon: const Icon(Icons.restore), label: const Text('שחזור'))
            else ...[
              if (state == 'open') ...[
                TextButton.icon(
                    onPressed: () => _send(context, bill), icon: const Icon(Icons.chat_outlined), label: const Text('וואטסאפ')),
                TextButton.icon(
                    onPressed: () => pasteReceipt(context, bill: bill),
                    icon: const Icon(Icons.content_paste),
                    label: const Text('הדבקת קבלה')),
              ],
              TextButton.icon(
                onPressed: () => launchUrl(Uri.parse(billUrl('${b['token']}')), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_browser),
                label: const Text('פתיחה'),
              ),
              if (receipt['url'] != null)
                TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse('${receipt['url']}'), mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('הקבלה'),
                ),
              IconButton(
                tooltip: 'העתקת קישור',
                icon: const Icon(Icons.link),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: billUrl('${b['token']}')));
                  if (context.mounted) _say(context, 'הקישור הועתק');
                },
              ),
              IconButton(tooltip: 'העברה לסל', icon: const Icon(Icons.delete_outline), onPressed: () => _trash(context, bill)),
            ],
          ]),
        ]),
      ),
    );
  }
}

/// On a customer: their bills, the monthly switch, and "bill now".
class BillsSection extends StatefulWidget {
  const BillsSection({super.key, required this.customer});
  final Doc customer;

  @override
  State<BillsSection> createState() => _BillsSectionState();
}

class _BillsSectionState extends State<BillsSection> {
  late final _bills = billsRef.where('customerId', isEqualTo: widget.customer.id).snapshots();
  bool _showOld = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.customer;
    final monthly = c.data()?['billing'] != false;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _bills,
      builder: (context, snap) {
        final all = [...?snap.data?.docs]..sort((a, b) => (b['number'] as int).compareTo(a['number'] as int));
        final live = all.where((b) => b.data()['deletedAt'] == null && b['state'] != 'replaced').toList();
        final old = all.where((b) => !live.contains(b)).toList();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('דרישות תשלום', style: Theme.of(context).textTheme.titleMedium)),
            FilledButton.tonalIcon(
                onPressed: () => billCustomerNow(context, c.id),
                icon: const Icon(Icons.request_quote_outlined),
                label: const Text('דרישת תשלום עכשיו')),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('דרישת תשלום חודשית'),
            subtitle: const Text('ביום החיוב (בהגדרות), על כל מה שמוכן או נמסר ולא שולם'),
            value: monthly,
            onChanged: (v) => c.reference.update({'billing': v}),
          ),
          if (snap.hasError) Text(errorText(snap.error!, 'טעינת הדרישות נכשלה')),
          for (final b in live) BillTile(b),
          if (old.isNotEmpty)
            TextButton(
              onPressed: () => setState(() => _showOld = !_showOld),
              child: Text(_showOld ? 'הסתרת הישנות' : 'דרישות שהוחלפו ובסל (${old.length})'),
            ),
          if (_showOld) for (final b in old) BillTile(b),
        ]);
      },
    );
  }
}

/// Every bill: to send first, then open, paid, and the trash.
class BillsPage extends StatelessWidget {
  const BillsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('דרישות תשלום'), actions: [
          IconButton(tooltip: 'הדבקת קבלה', icon: const Icon(Icons.content_paste), onPressed: () => pasteReceipt(context)),
          IconButton(
            tooltip: 'פרטי תשלום והגדרות',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const BillingSettingsPage())),
          ),
        ]),
        body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: billsRef.orderBy('number', descending: true).snapshots(),
          builder: (context, snap) {
            if (snap.hasError) return Center(child: Text(errorText(snap.error!, 'טעינת הדרישות נכשלה')));
            if (!snap.hasData) return const SkeletonList();
            final all = snap.data!.docs;
            bool live(Doc b) => b.data()?['deletedAt'] == null;
            final groups = {
              'לשליחה': all.where((b) => live(b) && b['state'] == 'open' && b.data()['sentAt'] == null),
              'נשלחו, ממתינות לתשלום': all.where((b) => live(b) && b['state'] == 'open' && b.data()['sentAt'] != null),
              'שולמו': all.where((b) => live(b) && b['state'] == 'paid'),
              'בסל (נמחקות לצמיתות אחרי $trashDays יום)': all.where((b) => !live(b)),
            };
            if (all.isEmpty) {
              return const Center(child: Text('עוד אין דרישות תשלום. יוצרים אחת מכרטיס הלקוח, או שהן נוצרות ביום החיוב.'));
            }
            return ListView(padding: const EdgeInsets.all(16), children: [
              for (final g in groups.entries)
                if (g.value.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Text('${g.key} (${g.value.length})', style: Theme.of(context).textTheme.titleSmall),
                  ),
                  for (final b in g.value) BillTile(b, showName: true),
                ],
            ]);
          },
        ),
      );
}

/// The receipt app's message: from the clipboard when it holds one, else pasted in the dialog.
/// Without [bill], the customer is found by the name after "לכבוד".
Future<void> pasteReceipt(BuildContext context, {Doc? bill}) async {
  final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
  if (!context.mounted) return;
  await showDialog<void>(
      context: context, builder: (_) => ReceiptDialog(bill: bill, text: parseReceipt(clip) == null ? '' : clip));
}

class ReceiptDialog extends StatefulWidget {
  const ReceiptDialog({super.key, this.bill, this.text = ''});
  final Doc? bill;
  final String text;

  @override
  State<ReceiptDialog> createState() => _ReceiptDialogState();
}

class _ReceiptDialogState extends State<ReceiptDialog> {
  late final _text = TextEditingController(text: widget.text);
  final _open = billsRef.where('state', isEqualTo: 'open').snapshots();
  String? _billId;
  bool _picked = false;
  String _method = 'transfer';
  DateTime _at = DateTime.now();

  @override
  void initState() {
    super.initState();
    _billId = widget.bill?.id;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.studio;
    final r = parseReceipt(_text.text);
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _open,
      builder: (context, snap) {
        final bills = [...?snap.data?.docs.where((b) => b.data()['deletedAt'] == null), ?widget.bill]
            .fold(<String, Doc>{}, (m, b) => m..[b.id] = b);
        // Pick the bill by the receipt's name once, unless Alex chose one.
        if (!_picked && widget.bill == null && r != null) {
          final names = {for (final b in bills.values) b.id: '${b['customerName']}'};
          _billId = matchCustomer(r.to, names);
        }
        final bill = bills[_billId];
        return AlertDialog(
          title: const Text('קבלה על דרישת תשלום'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(
                  controller: _text,
                  autofocus: widget.text.isEmpty,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                      labelText: 'ההודעה מאפליקציית הקבלות', hintText: 'לכבוד : …\nקיבלת קבלה מספר : …\nhttps://…'),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                if (_text.text.isNotEmpty && r == null)
                  Text('לא מצאתי קישור לקבלה בהודעה', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                if (r != null)
                  Text('לכבוד ${r.to.isEmpty ? '?' : r.to} · קבלה ${r.number.isEmpty ? '?' : ltr(r.number)}',
                      style: TextStyle(color: s.okInk, fontWeight: FontWeight.w500)),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: bills.containsKey(_billId) ? _billId : null,
                  key: ValueKey(_billId),
                  decoration: InputDecoration(
                      labelText: 'הדרישה ששולמה',
                      helperText: r != null && bill == null ? 'לא מצאתי דרישה פתוחה בשם הזה: בוחרים ידנית' : null),
                  items: [
                    for (final b in bills.values)
                      DropdownMenuItem(
                          value: b.id, child: Text('${b['customerName']} · ${b['number']} · ${shekel(b['due'] as int)}')),
                  ],
                  onChanged: (v) => setState(() {
                    _billId = v;
                    _picked = true;
                  }),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _method,
                  decoration: const InputDecoration(labelText: 'איך שולם'),
                  items: [for (final e in paymentMethods.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                  onChanged: (v) => setState(() => _method = v ?? _method),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.event_outlined),
                  label: Text('התקבל ב-${_at.day}.${_at.month}.${_at.year}'),
                  onPressed: () async {
                    final d = await showDatePicker(
                        context: context, initialDate: _at, firstDate: DateTime(2024), lastDate: DateTime.now());
                    if (d != null) setState(() => _at = d);
                  },
                ),
                if (bill != null) ...[
                  const SizedBox(height: 8),
                  Text('יירשם תשלום על כל פריט בדרישה, הזמנות שנמסרו יסומנו כשולמו, והלקוח יראה בקישור "שולם" עם הקבלה.',
                      style: TextStyle(fontSize: 12, color: s.muted)),
                ],
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('ביטול')),
            FilledButton(
              onPressed: r == null || bill == null
                  ? null
                  : () async {
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.pop(context);
                      try {
                        await payBill(bill, r, method: _method, at: _at);
                        messenger.showSnackBar(SnackBar(
                            persist: false, content: Text('דרישה ${bill['number']} של ${bill['customerName']} שולמה')));
                      } catch (e) {
                        showError(messenger, e, 'שמירת הקבלה נכשלה');
                      }
                    },
              child: const Text('שמירה'),
            ),
          ],
        );
      },
    );
  }
}

/// What a payment request shows: the business, the bank account, Bit and PayBox (each on or off), the billing day.
class BillingSettingsPage extends StatefulWidget {
  const BillingSettingsPage({super.key});

  @override
  State<BillingSettingsPage> createState() => _BillingSettingsPageState();
}

class _BillingSettingsPageState extends State<BillingSettingsPage> {
  static const _fields = {
    'businessName': 'שם העסק',
    'businessId': 'עוסק פטור / מורשה ומספר',
    'contact': 'טלפון / מייל לפניות',
    'bankName': 'שם הבנק',
    'bankNumber': 'מספר בנק',
    'branch': 'מספר סניף',
    'account': 'מספר חשבון',
    'accountName': 'שם בעל החשבון',
    'bitPhone': 'מספר טלפון בביט',
    'payboxLink': 'קישור תשלום PayBox (או מספר טלפון)',
  };
  final _c = {for (final k in _fields.keys) k: TextEditingController()};
  bool _bit = false, _paybox = false, _loaded = false, _saving = false;
  int _day = 1;
  Map<String, dynamic> _saved = const {};

  @override
  void initState() {
    super.initState();
    billingRef.get().then((d) {
      if (!mounted) return;
      final v = d.data() ?? const {};
      setState(() {
        _saved = v;
        for (final e in _c.entries) {
          e.value.text = '${v[e.key] ?? ''}';
        }
        _bit = v['bitOn'] == true;
        _paybox = v['payboxOn'] == true;
        _day = (v['day'] as int?) ?? 1;
        _loaded = true;
      });
    }, onError: (Object e) {
      if (mounted) showError(ScaffoldMessenger.of(context), e, 'טעינת ההגדרות נכשלה');
    });
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> get _values => {
        for (final e in _c.entries) e.key: e.value.text.trim(),
        'bitOn': _bit,
        'payboxOn': _paybox,
        'day': _day,
      };

  Future<void> _save() async {
    // Clearing bank details that were filled in is asked first: the client's bill would lose them.
    final cleared = [for (final k in const ['bankNumber', 'branch', 'account']) if ('${_saved[k] ?? ''}'.isNotEmpty && _c[k]!.text.trim().isEmpty) _fields[k]];
    if (cleared.isNotEmpty) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('למחוק את פרטי הבנק?'),
          content: Text('${cleared.join(', ')} יימחקו, ודרישות תשלום לא יציגו העברה בנקאית. הגיבוי היומי שומר את הקודמים.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('מחיקה')),
          ],
        ),
      );
      if (yes != true) return;
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final v = _values;
      await billingRef.set({...v, 'updatedAt': FieldValue.serverTimestamp()});
      _saved = v;
      messenger.showSnackBar(const SnackBar(content: Text('נשמר'), persist: false));
    } catch (e) {
      showError(messenger, e, 'השמירה נכשלה');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(String k, {TextInputType? type}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(controller: _c[k], keyboardType: type, decoration: InputDecoration(labelText: _fields[k])),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('דרישות תשלום: פרטים')),
        body: !_loaded
            ? const SkeletonList()
            : ListView(padding: const EdgeInsets.all(16), children: [
                Text('העסק', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _field('businessName'),
                _field('businessId'),
                _field('contact'),
                Text('העברה בנקאית', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _field('bankName'),
                _field('bankNumber', type: TextInputType.number),
                _field('branch', type: TextInputType.number),
                _field('account', type: TextInputType.number),
                _field('accountName'),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('לקבל תשלום בביט'),
                    value: _bit,
                    onChanged: (v) => setState(() => _bit = v)),
                if (_bit) _field('bitPhone', type: TextInputType.phone),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('לקבל תשלום ב-PayBox'),
                    value: _paybox,
                    onChanged: (v) => setState(() => _paybox = v)),
                if (_paybox) _field('payboxLink'),
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  initialValue: _day,
                  decoration: const InputDecoration(
                      labelText: 'יום החיוב בחודש', helperText: 'ב-9:00 נוצרות הדרישות, ומגיעה התראה שהן מוכנות לשליחה'),
                  items: [for (var d = 1; d <= 28; d++) DropdownMenuItem(value: d, child: Text('$d בחודש'))],
                  onChanged: (v) => setState(() => _day = v ?? _day),
                ),
                const SizedBox(height: 20),
                FilledButton(onPressed: _saving ? null : _save, child: const Text('שמירה')),
              ]),
      );
}
