import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../studio/studio.dart';

/// A new request: who it's for, what (the names on the flag), how many.
class NewRequestDialog extends StatefulWidget {
  const NewRequestDialog({super.key});

  @override
  State<NewRequestDialog> createState() => _NewRequestDialogState();
}

class _NewRequestDialogState extends State<NewRequestDialog> {
  final _title = TextEditingController();
  final _qty = TextEditingController(text: '1');
  final _notes = TextEditingController();
  Doc? _customer;
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
      final id = await addRequest(customer: _customer!, title: _title.text, qty: _quantity!, notes: _notes.text);
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
        await addCustomer(name: _name.text, phone: _phone.text, lang: _lang);
      } else {
        await c.reference.update({'name': _name.text.trim(), 'phone': _phone.text.trim(), 'lang': _lang});
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
              segments: const [
                ButtonSegment(value: 'he', label: Text('פורטל בעברית')),
                ButtonSegment(value: 'en', label: Text('English')),
              ],
              selected: {_lang},
              onSelectionChanged: (v) => setState(() => _lang = v.first),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('ביטול')),
          FilledButton(onPressed: _name.text.trim().isEmpty ? null : _save, child: const Text('שמירה')),
        ],
      );
}

/// A price per unit, VAT off by default (Alex switches it on per quote); the total shows as you type.
class QuoteDialog extends StatefulWidget {
  const QuoteDialog({super.key, required this.request, this.current, this.unit, this.qty});
  final Doc request;
  final Map<String, dynamic>? current;

  /// Filled in instead: Gift Factory's suggestion ("שימוש כהצעת מחיר"), unit in agorot.
  final int? unit, qty;

  @override
  State<QuoteDialog> createState() => _QuoteDialogState();
}

class _QuoteDialogState extends State<QuoteDialog> {
  late final _start = widget.unit ?? widget.current?['unit'] as int?;
  late final _unit = TextEditingController(text: _start == null ? '' : shekel(_start).replaceAll(RegExp('[₪,]'), ''));
  late final _qty = TextEditingController(text: '${widget.qty ?? widget.request.data()?['qty'] ?? 1}');
  late final _note = TextEditingController(text: '${widget.current?['note'] ?? ''}');
  late bool _vat = ((widget.current?['vatPercent'] as int?) ?? 0) > 0;

  @override
  void dispose() {
    _unit.dispose();
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unit = parseShekel(_unit.text);
    final qty = int.tryParse(_qty.text.trim());
    final ok = unit != null && qty != null && qty >= 1;
    final vatPercent = _vat ? defaultVatPercent : 0;
    final m = ok ? money(unit, qty, vatPercent) : null;
    return AlertDialog(
      title: Text(widget.current == null ? 'הצעת מחיר' : 'הצעת מחיר חדשה'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.current != null)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('הלקוח יראה את המחיר החדש, וגם שהיה מחיר קודם.'),
            ),
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('להוסיף מע״מ $defaultVatPercent%'),
            value: _vat,
            onChanged: (v) => setState(() => _vat = v),
          ),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'הערה ללקוח (לא חובה)')),
          if (m != null) ...[
            const SizedBox(height: 16),
            if (_vat) ...[
              MoneyLine('לפני מע״מ', m.net),
              MoneyLine('מע״מ $vatPercent%', m.vat),
            ],
            MoneyLine('סה״כ', m.total, bold: true),
          ],
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
                    await addQuote(widget.request, unit: unit, qty: qty, vatPercent: vatPercent, note: _note.text);
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
  const PaymentDialog({super.key, required this.request, required this.left});
  final Doc request;
  final int left;

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
      title: const Text('רישום תשלום'),
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
                    await addPayment(widget.request, amount: amount, method: _method, at: _at, note: _note.text);
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
