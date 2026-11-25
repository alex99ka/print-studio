import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/errors.dart';
import '../studio/studio.dart';
import 'logo_photos.dart';

/// A new request: who it's for, what (the names on the flag), how many.
class NewRequestDialog extends StatefulWidget {
  const NewRequestDialog({super.key, this.customer, this.qty = 1, this.notes = '', this.deadline, this.gift, this.design});
  final Doc? customer;

  /// What a call-back request from the website already says (lib/ui/website_view.dart).
  final int qty;
  final String notes;
  final DateTime? deadline;
  final String? gift;
  final Map<String, dynamic>? design; // C-12, from a website lead

  @override
  State<NewRequestDialog> createState() => _NewRequestDialogState();
}

class _NewRequestDialogState extends State<NewRequestDialog> {
  final _title = TextEditingController();
  late final _qty = TextEditingController(text: '${widget.qty}');
  late final _notes = TextEditingController(text: widget.notes);
  late Doc? _customer = widget.customer;
  late DateTime? _deadline = widget.deadline;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _qty.dispose();
    _notes.dispose();
    super.dispose();
  }

  int? get _quantity => int.tryParse(_qty.text.trim());
  bool get _valid => _customer != null && _title.text.trim().isNotEmpty && (_quantity ?? 0) >= 1;

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final id = await addRequest(customer: _customer!, title: _title.text, qty: _quantity!, notes: _notes.text, deadline: _deadline, gift: widget.gift, design: widget.design);
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(ScaffoldMessenger.of(context), e, 'יצירת הבקשה נכשלה');
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('בקשה חדשה'),
        content: SizedBox(
          width: 420,
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: customersRef.orderBy('name').snapshots(),
            builder: (context, snap) {
              final customers = snap.data?.docs ?? const [];
              if (_customer == null && customers.length == 1) _customer = customers.first;
              return Column(mainAxisSize: MainAxisSize.min, children: [
                if (snap.hasData && customers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('עוד אין לקוחות. מוסיפים לקוח בלשונית "לקוחות" או ב"לקוח חדש".'),
                  ),
                DropdownButtonFormField<String>(
                  initialValue: _customer?.id,
                  decoration: const InputDecoration(labelText: 'לקוח'),
                  items: [for (final c in customers) DropdownMenuItem(value: c.id, child: Text('${c['name']}'))],
                  onChanged: (id) => setState(() => _customer = customers.firstWhere((c) => c.id == id)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _title,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'שם הבקשה', helperText: 'למשל השמות על הדגל: אלכס ❤ אביטל'),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _qty,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'כמות'),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.event_outlined),
                      label: Text(_deadline == null
                          ? 'תאריך יעד (לא חובה)'
                          : 'תאריך יעד: ${_deadline!.day}.${_deadline!.month}.${_deadline!.year}'),
                      onPressed: () async {
                        final now = DateTime.now();
                        final d = await showDatePicker(
                            context: context,
                            helpText: 'תאריך יעד',
                            initialDate: _deadline ?? now.add(const Duration(days: 7)),
                            firstDate: DateTime(now.year, now.month, now.day),
                            lastDate: DateTime(now.year + 2));
                        if (d != null) setState(() => _deadline = d);
                      },
                    ),
                  ),
                  if (_deadline != null)
                    IconButton(
                        tooltip: 'בלי תאריך יעד', icon: const Icon(Icons.close), onPressed: () => setState(() => _deadline = null)),
                ]),
                if (widget.gift != null) Align(alignment: AlignmentDirectional.centerStart, child: Text('מוצר מהאתר: ${widget.gift}')),
                const SizedBox(height: 12),
                TextField(
                  controller: _notes,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'הערות (רק אצלך)'),
                ),
              ]);
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ביטול')),
          FilledButton(onPressed: _valid && !_busy ? _save : null, child: const Text('יצירה')),
        ],
      );
}

/// A new customer, or [customer]'s details. The portal link is made with it.
class CustomerDialog extends StatefulWidget {
  const CustomerDialog({super.key, this.customer});
  final Doc? customer;

  @override
  State<CustomerDialog> createState() => _CustomerDialogState();
}

class _CustomerDialogState extends State<CustomerDialog> {
  late final _name = TextEditingController(text: '${widget.customer?.data()?['name'] ?? ''}');
  late final _phone = TextEditingController(text: '${widget.customer?.data()?['phone'] ?? ''}');
  late String _lang = '${widget.customer?.data()?['lang'] ?? 'he'}';
  late String _kind = '${widget.customer?.data()?['kind'] ?? 'mic'}';
  late bool _returning = widget.customer?.data()?['returning'] == true;
  final _photos = <XFile>[]; // a new customer's logo photos, sent once the customer exists

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    try {
      final c = widget.customer;
      if (c == null) {
        final ref = await addCustomer(name: _name.text, phone: _phone.text, lang: _lang, kind: _kind, returning: _returning);
        if (_photos.isNotEmpty) {
          await addPhotos(logosOf(ref.id), _photos);
          messenger.showSnackBar(SnackBar(content: Text('${_photos.length} תמונות לוגו נשמרו')));
        }
      } else {
        await c.reference.update({'name': _name.text.trim(), 'phone': _phone.text.trim(), 'lang': _lang, 'kind': _kind, 'returning': _returning});
      }
    } catch (e) {
      showError(messenger, e, 'שמירת הלקוח נכשלה');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.customer == null ? 'לקוח חדש' : 'פרטי לקוח'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'שם'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'טלפון (לוואטסאפ)'),
            ),
            const SizedBox(height: 16),
            SegmentedButton<String>(
              segments: [
                for (final k in customerKinds.entries)
                  ButtonSegment(value: k.key, label: Text(k.value), icon: Icon(k.key == 'mic' ? Icons.mic_none : Icons.redeem_outlined)),
              ],
              selected: {_kind},
              onSelectionChanged: (v) => setState(() => _kind = v.first),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('לקוח קבוע'),
              subtitle: const Text('אזור אישי עם כניסת Google: כל הפרויקטים, דרישות התשלום והקבלות. לקוח חד-פעמי נשאר עם הקישור הרגיל'),
              value: _returning,
              onChanged: (v) => setState(() => _returning = v),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'he', label: Text('פורטל בעברית')),
                ButtonSegment(value: 'en', label: Text('English')),
              ],
              selected: {_lang},
              onSelectionChanged: (v) => setState(() => _lang = v.first),
            ),
            // C-6: on an existing customer the photos are on its page.
            if (widget.customer == null) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(_photos.isEmpty ? 'תמונות לוגו' : '${_photos.length} תמונות לוגו'),
                ...logoPickButtons((p) => setState(() => _photos.addAll(p))),
              ]),
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ביטול')),
          FilledButton(onPressed: _name.text.trim().isEmpty ? null : _save, child: const Text('שמירה')),
        ],
      );
}

/// A price per unit, an optional discount (₪ or %), VAT off by default (Alex switches it on
/// per quote). Gift Factory's suggestion and its calculation show on top, and the cost and
/// profit follow the price as you type. The client sees only the total.
class QuoteDialog extends StatefulWidget {
  const QuoteDialog({super.key, required this.request, this.current, this.unit, this.qty, this.suggestion});
  final Doc request;
  final Map<String, dynamic>? current;

  /// Filled in instead: Gift Factory's suggestion ("שימוש כהצעת מחיר"), unit in agorot.
  final int? unit, qty;

  /// Gift Factory's production.quote (unitCost, unitPrice, units, breakdown), when there is one.
  final Map? suggestion;

  @override
  State<QuoteDialog> createState() => _QuoteDialogState();
}

class _QuoteDialogState extends State<QuoteDialog> {
  late final _start = widget.unit ?? widget.current?['unit'] as int?;
  late final _unit = TextEditingController(text: _start == null ? '' : _plain(_start));
  late final _qty = TextEditingController(text: '${widget.qty ?? widget.request.data()?['qty'] ?? 1}');
  late final _note = TextEditingController(text: '${widget.current?['note'] ?? ''}');
  late bool _vat = ((widget.current?['vatPercent'] as int?) ?? 0) > 0;
  bool _correction = false;
  late bool _pct = widget.current == null || widget.current?['discountPct'] != null;
  late final _discount = TextEditingController(
      text: switch (widget.current) {
        final c? when c['discountPct'] != null => '${c['discountPct']}',
        final c? when ((c['discount'] as int?) ?? 0) > 0 => _plain(c['discount'] as int),
        _ => '',
      });

  static String _plain(int agorot) => shekel(agorot).replaceAll(RegExp('[₪,]'), '');

  @override
  void dispose() {
    _unit.dispose();
    _qty.dispose();
    _note.dispose();
    _discount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).hintColor, fontSize: 12);
    final unit = parseShekel(_unit.text);
    final qty = int.tryParse(_qty.text.trim());
    final d = _discount.text.trim();
    final pct = _pct ? int.tryParse(d) : null;
    final gross = unit != null && qty != null ? unit * qty : null;
    final discount = d.isEmpty ? 0 : (_pct ? (pct == null || pct > 100 ? null : discountOf(unit ?? 0, qty ?? 0, pct)) : parseShekel(d));
    final badDiscount = discount == null || (gross != null && discount > gross);
    final ok = unit != null && qty != null && qty >= 1 && !badDiscount;
    final vatPercent = _vat ? defaultVatPercent : 0;
    final m = ok ? money(unit, qty, vatPercent, discount) : null;
    final g = widget.suggestion;
    final cost = g?['unitCost'] as int?;
    return AlertDialog(
      title: Text(widget.current == null ? 'הצעת מחיר' : 'הצעת מחיר חדשה'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.current != null) ...[
            Text(_correction
                ? 'הלקוח יראה רק את המחיר החדש: המחירים הקודמים נעלמים מהדף שלו.'
                : 'הלקוח יראה את המחיר החדש, וגם שהיה מחיר קודם.'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('תיקון טעות'),
              subtitle: const Text('המחיר הקודם היה טעות: לא להראות ללקוח מחירים קודמים'),
              value: _correction,
              onChanged: (v) => setState(() => _correction = v),
            ),
            const SizedBox(height: 4),
          ],
          if (g != null) ...[
            Text('הצעה מ-${g['from'] ?? 'Gift Factory'}', style: const TextStyle(fontWeight: FontWeight.w500)),
            if (g['breakdown'] != null) ...[
            for (final (k, label) in const [
              ('filament', 'חומר'),
              ('power', 'חשמל'),
              ('wear', 'בלאי'),
              ('packaging', 'אריזה'),
              ('labour', 'עבודה'),
            ])
              MoneyLine('  $label ליחידה', ((g['breakdown'] as Map?)?[k] as int?) ?? 0),
            Text('  מרווח לכשלים: ${(g['breakdown'] as Map?)?['failureMarginPct'] ?? 0}%', style: muted),
            ],
            if (cost != null) MoneyLine('עלות ליחידה', cost),
            Row(children: [
              Expanded(child: MoneyLine('מחיר מוצע ליחידה', g['unitPrice'] as int, bold: true)),
              TextButton(
                onPressed: () => setState(() => _unit.text = _plain(g['unitPrice'] as int)),
                child: const Text('להשתמש'),
              ),
            ]),
            const Divider(),
          ],
          Row(children: [
            Expanded(
              child: TextField(
                controller: _unit,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: _vat ? 'מחיר ליחידה לפני מע״מ (₪)' : 'מחיר ליחידה (₪)',
                    errorText: _unit.text.isNotEmpty && unit == null ? 'מספר, למשל 180 או 180.50' : null),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 96,
              child: TextField(
                controller: _qty,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'כמות'),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _discount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: _pct ? 'הנחה (%)' : 'הנחה על הכול (₪)',
                    helperText: 'לא חובה',
                    errorText: d.isNotEmpty && badDiscount ? (_pct ? 'אחוז שלם, 0-100' : 'סכום עד המחיר המלא') : null),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            SegmentedButton<bool>(
              segments: const [ButtonSegment(value: true, label: Text('%')), ButtonSegment(value: false, label: Text('₪'))],
              selected: {_pct},
              onSelectionChanged: (v) => setState(() => _pct = v.first),
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('להוסיף מע״מ $defaultVatPercent%'),
            value: _vat,
            onChanged: (v) => setState(() => _vat = v),
          ),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'הערה ללקוח (לא חובה)')),
          if (m != null) ...[
            const SizedBox(height: 16),
            MoneyLine('$qty × ${ltr(shekel(unit!))}', gross!),
            if (discount! > 0) MoneyLine(_pct ? 'הנחה $pct%' : 'הנחה', -discount),
            if (_vat) ...[
              MoneyLine('לפני מע״מ', m.net),
              MoneyLine('מע״מ $vatPercent%', m.vat),
            ],
            MoneyLine('סה״כ ללקוח', m.total, bold: true),
            if (cost != null) ...[
              MoneyLine('עלות ($qty × ${ltr(shekel(cost))})', cost * qty!),
              MoneyLine('רווח משוער (לפני מע״מ)', m.net - cost * qty),
            ],
            Text('הלקוח רואה רק את הסה״כ: בלי מחיר ליחידה, הנחה או חישוב.', style: muted),
          ],
        ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('ביטול')),
        FilledButton(
          onPressed: !ok
              ? null
              : () async {
                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.pop(context);
                  try {
                    await addQuote(widget.request,
                        unit: unit,
                        qty: qty,
                        vatPercent: vatPercent,
                        note: _note.text,
                        discount: discount,
                        discountPct: pct,
                        correction: _correction);
                  } catch (e) {
                    showError(messenger, e, 'שמירת המחיר נכשלה');
                  }
                },
          child: const Text('שמירה'),
        ),
      ],
    );
  }
}

/// "label ........ ₪424.80", the amount kept left-to-right.
class MoneyLine extends StatelessWidget {
  const MoneyLine(this.label, this.agorot, {super.key, this.bold = false});
  final String label;
  final int agorot;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold ? const TextStyle(fontWeight: FontWeight.w700, fontSize: 16) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(child: Text(label, style: style)),
        Text(shekel(agorot), textDirection: TextDirection.ltr, style: style),
      ]),
    );
  }
}

/// Money received for a request: the amount (what is left, to start with), how, and which day.
class PaymentDialog extends StatefulWidget {
  const PaymentDialog({super.key, required this.request, required this.left, this.markPaid = false});
  final Doc request;
  final int left;

  /// Opened by changing the status to שולם: saving logs the payment and sets the status together.
  final bool markPaid;

  @override
  State<PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<PaymentDialog> {
  late final _amount =
      TextEditingController(text: widget.left > 0 ? shekel(widget.left).replaceAll(RegExp('[₪,]'), '') : '');
  final _note = TextEditingController();
  String _method = 'bit';
  DateTime _at = DateTime.now();

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amount = parseShekel(_amount.text);
    final ok = amount != null && amount > 0;
    return AlertDialog(
      title: Text(widget.markPaid ? 'איך שולם?' : 'רישום תשלום'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: 'סכום (₪)',
                helperText: widget.left > 0 ? 'נותר לתשלום: ${ltr(shekel(widget.left))}' : null,
                errorText: _amount.text.isNotEmpty && !ok ? 'מספר, למשל 200 או 212.40' : null),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _method,
            decoration: const InputDecoration(labelText: 'אמצעי תשלום'),
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
          const SizedBox(height: 12),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'הערה (לא חובה, רק אצלך)')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('ביטול')),
        FilledButton(
          onPressed: !ok
              ? null
              : () async {
                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.pop(context);
                  try {
                    await addPayment(widget.request,
                        amount: amount,
                        method: _method,
                        at: _at,
                        note: _note.text,
                        markPaid: widget.markPaid ||
                            settles(status: '${widget.request.data()?['status']}', left: widget.left, amount: amount));
                  } catch (e) {
                    showError(messenger, e, 'רישום התשלום נכשל');
                  }
                },
          child: const Text('שמירה'),
        ),
      ],
    );
  }
}
