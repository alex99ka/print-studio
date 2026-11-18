import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/errors.dart';
import '../studio/studio.dart';
import '../studio/website.dart';
import 'skeleton.dart';
import 'studio_actions.dart';
import 'theme.dart';

/// Bumped when a push about a new call-back request opens the tab: the list reloads.
final websiteLeadsPing = ValueNotifier<int>(0);

String _day(Object? iso, {bool time = false}) {
  final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  if (d == null) return '';
  final day = '${d.day}.${d.month}.${d.year}';
  return time ? '$day ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}' : day;
}

TextDirection _dir(String lang) => lang == 'he' ? TextDirection.rtl : TextDirection.ltr;

Future<bool> _try(BuildContext context, String failed, Future<void> Function() run) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await run();
    return true;
  } catch (e) {
    showError(messenger, e, failed);
    return false;
  }
}

Future<bool> _confirm(BuildContext context, String title, String text, String yes) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('ביטול')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(yes)),
        ],
      ),
    ) ==
    true;

/// The shop website, managed from here: call-back requests, products with their pictures,
/// and every sentence of the site. A change shows on the site within 5 minutes.
class WebsiteView extends StatefulWidget {
  const WebsiteView({super.key});

  @override
  State<WebsiteView> createState() => _WebsiteViewState();
}

class _WebsiteViewState extends State<WebsiteView> {
  int _tab = 0;
  late Future<List<Map<String, dynamic>>> _leads = siteLeads();
  late Future<List<Map<String, dynamic>>> _gifts = siteGifts();
  Future<({Wording defaults, Wording overrides})>? _texts; // loaded when its tab is first opened
  Map<String, String> _giftNames = const {};

  @override
  void initState() {
    super.initState();
    websiteLeadsPing.addListener(_reloadLeads);
    _nameGifts();
  }

  @override
  void dispose() {
    websiteLeadsPing.removeListener(_reloadLeads);
    super.dispose();
  }

  /// Leads name the gifts by slug; the list shows their Hebrew names once the products are in.
  void _nameGifts() => _gifts.then((gifts) {
        if (mounted) setState(() => _giftNames = {for (final g in gifts) '${g['slug']}': '${(g['name'] as Map)['he']}'});
      }, onError: (_) {}); // the products tab shows the failure

  void _reloadLeads() => setState(() {
        _tab = 0;
        _leads = siteLeads();
      });

  void _reloadGifts() {
    setState(() => _gifts = siteGifts());
    _nameGifts();
  }

  void _reload() => switch (_tab) {
        0 => setState(() => _leads = siteLeads()),
        1 => _reloadGifts(),
        _ => setState(() => _texts = siteTexts()),
      };

  @override
  Widget build(BuildContext context) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('פניות'), icon: Icon(Icons.phone_callback_outlined)),
                ButtonSegment(value: 1, label: Text('מוצרים'), icon: Icon(Icons.redeem_outlined)),
                ButtonSegment(value: 2, label: Text('טקסטים'), icon: Icon(Icons.translate)),
              ],
              selected: {_tab},
              onSelectionChanged: (v) => setState(() {
                _tab = v.first;
                if (_tab == 2) _texts ??= siteTexts();
              }),
            ),
            IconButton(tooltip: 'רענון', icon: const Icon(Icons.refresh), onPressed: _reload),
            if (_tab == 1) FilledButton.icon(onPressed: () => _openGift(null), icon: const Icon(Icons.add), label: const Text('מוצר חדש')),
            Text('שינוי מופיע באתר תוך 5 דקות', style: TextStyle(color: context.studio.muted, fontSize: 12)),
          ]),
        ),
        Expanded(
          child: switch (_tab) {
            0 => _section(_leads, 'טעינת הפניות נכשלה', _leadList),
            1 => _section(_gifts, 'טעינת המוצרים נכשלה', _giftList),
            _ => _section(_texts, 'טעינת הטקסטים נכשלה', _textList),
          },
        ),
      ]);

  /// Skeleton while loading, the failure with its code and a retry, then the list with pull-to-refresh.
  Widget _section<T>(Future<T>? future, String failed, Widget Function(T) list) => FutureBuilder<T>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const SkeletonList();
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(errorText(snap.error!, failed), textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _reload, child: const Text('ניסיון נוסף')),
                ]),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: list(snap.data as T))),
          );
        },
      );

  Widget _empty(String text) => ListView(children: [
        Padding(
          padding: const EdgeInsets.all(32),
          child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: context.studio.muted)),
        ),
      ]);

  // --- call-back requests -----------------------------------------------------------

  Widget _leadList(List<Map<String, dynamic>> leads) => leads.isEmpty
      ? _empty('עוד אין פניות מהאתר. כשמישהו משאיר פרטים ב"חזרו אליי", מגיעה התראה והפנייה מופיעה כאן.')
      : ListView(padding: const EdgeInsets.all(16), children: [for (final l in leads) _leadCard(l)]);

  Widget _leadCard(Map<String, dynamic> l) {
    final s = context.studio;
    final phone = '${l['phone']}';
    final liked = [for (final g in l['gifts'] as List? ?? const []) _giftNames['$g'] ?? '$g'];
    final isNew = l['status'] == 'new';
    return Card(
      color: isNew ? s.accentSoft : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${l['name']}', style: Theme.of(context).textTheme.titleMedium)),
            DropdownButton<String>(
              value: leadStatuses.containsKey(l['status']) ? '${l['status']}' : null,
              hint: Text('${l['status']}'),
              underline: const SizedBox.shrink(),
              items: [for (final e in leadStatuses.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
              onChanged: (v) async {
                if (v != null && v != l['status'] && await _try(context, 'שינוי המצב נכשל', () => setLeadStatus(l['id'], v))) {
                  setState(() => l['status'] = v);
                }
              },
            ),
          ]),
          Row(children: [
            SelectableText(phone, textDirection: TextDirection.ltr),
            IconButton(
                tooltip: 'חיוג', icon: const Icon(Icons.call_outlined),
                onPressed: () => _try(context, 'החיוג לא נפתח', () => launchUrl(Uri(scheme: 'tel', path: phone)))),
            IconButton(
                tooltip: 'וואטסאפ', icon: const Icon(Icons.chat_outlined),
                onPressed: () => _try(context, 'וואטסאפ לא נפתח',
                    () => launchUrl(whatsapp(phone, ''), mode: LaunchMode.externalApplication))),
          ]),
          Text(
            [
              'התקבלה ${ltr(_day(l['created_at'], time: true))}',
              if (l['wedding_date'] != null) 'חתונה ב-${ltr(_day(l['wedding_date']))}',
              if (l['gift'] != null) 'מוצר: ${_giftNames['${l['gift']}'] ?? l['gift']}${l['qty'] == null ? '' : ' × ${l['qty']}'}',
              if (l['guests'] != null) '${l['guests']} אורחים',
              'נוח לדבר: ${callTimes[l['call_time']] ?? l['call_time']}',
              'שפה: ${siteLangNames[l['lang']] ?? l['lang']}',
            ].join(' · '),
            style: TextStyle(color: s.muted),
          ),
          if (liked.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('אהבו: ${liked.join(', ')}')),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: () => _requestFrom(l),
              icon: const Icon(Icons.add_box_outlined),
              label: const Text('צור לקוח + בקשה'),
            ),
          ),
        ]),
      ),
    );
  }

  /// The lead becomes a customer (found by phone, else added) and a request with what the lead said.
  Future<void> _requestFrom(Map<String, dynamic> l) => _try(context, 'פתיחת הבקשה נכשלה', () async {
        final found = await customersRef.where('phone', isEqualTo: '${l['phone']}'.trim()).limit(1).get();
        final Doc customer = found.docs.isNotEmpty
            ? found.docs.first
            // The portal speaks Hebrew and English only.
            : await (await addCustomer(name: '${l['name']}', phone: '${l['phone']}', lang: l['lang'] == 'he' ? 'he' : 'en', kind: 'gift')).get();
        if (!mounted) return;
        final from = requestFromLead(l, DateTime.now());
        final id = await newRequest(context,
            customer: customer, qty: from.qty, notes: from.notes, deadline: from.deadline, gift: from.gift);
        if (id == null) return;
        await setLeadStatus(l['id'], 'opened');
        if (mounted) setState(() => l['status'] = 'opened');
      });

  // --- products ---------------------------------------------------------------------

  Future<void> _openGift(Map<String, dynamic>? gift) async {
    final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => GiftPage(gift: gift)));
    if (changed == true && mounted) _reloadGifts();
  }

  Widget _giftList(List<Map<String, dynamic>> gifts) => gifts.isEmpty
      ? _empty('עוד אין מוצרים באתר. "מוצר חדש" מוסיף אחד, או שולחים את הקטלוג עם סקריפט התמונות של האתר.')
      : ListView(padding: const EdgeInsets.all(16), children: [for (final g in gifts) _giftCard(g)]);

  Widget _giftCard(Map<String, dynamic> g) {
    final s = context.studio;
    final images = g['images'] as Map? ?? const {};
    final file = images.containsKey('photo.jpg') ? 'photo.jpg' : 'still.jpg';
    Widget tag(String text, Color bg, Color ink) => Container(
          margin: const EdgeInsetsDirectional.only(end: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
          child: Text(text, style: TextStyle(color: ink, fontSize: 12)),
        );
    return Card(
      child: ListTile(
        onTap: () => _openGift(g),
        leading: SizedBox(
          width: 56,
          height: 56,
          child: images.containsKey(file)
              ? Image.network(pictureUrl('${g['slug']}', file, images[file]), fit: BoxFit.cover, cacheWidth: 168,
                  errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined))
              : const Icon(Icons.image_not_supported_outlined),
        ),
        title: Text('${(g['name'] as Map)['he']}'),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${ltr('${g['slug']}')} · ${giftKinds[g['kind']] ?? g['kind']} · מינימום ${g['min_qty']} · ${g['lead_days']} ימים · סדר ${g['sort']}'),
          const SizedBox(height: 4),
          Wrap(children: [
            g['published'] == true ? tag('מוצג באתר', s.okSoft, s.okInk) : tag('מוסתר', s.sunk, s.muted),
            if (g['feature'] == true) tag('בדף הבית', s.accentSoft, Theme.of(context).colorScheme.onSurface),
            if (!images.containsKey(file)) tag('אין תמונה', s.warnSoft, s.warnInk),
          ]),
        ]),
      ),
    );
  }

  // --- wording ----------------------------------------------------------------------

  Widget _textList(({Wording defaults, Wording overrides}) t) {
    final s = context.studio;
    final groups = <String, List<String>>{};
    for (final key in t.defaults.keys) {
      groups.putIfAbsent(textGroup(key), () => []).add(key);
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      for (final g in groups.entries)
        Card(
          child: ExpansionTile(
            title: Text(ltr(g.key)),
            subtitle: Text('${g.value.length} טקסטים${switch (g.value.where(t.overrides.containsKey).length) { 0 => '', final n => ' · $n שונו' }}',
                style: TextStyle(color: s.muted, fontSize: 12)),
            children: [
              for (final key in g.value)
                ListTile(
                  onTap: () => _editText(t, key),
                  title: Text(ltr(key), style: TextStyle(color: s.muted, fontSize: 12)),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.defaults[key]!['he'] ?? ''),
                    for (final o in (t.overrides[key] ?? const <String, String>{}).entries)
                      Text('${siteLangNames[o.key]}: ${o.value}',
                          style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600)),
                  ]),
                  trailing: const Icon(Icons.edit_outlined, size: 18),
                ),
            ],
          ),
        ),
    ]);
  }

  Future<void> _editText(({Wording defaults, Wording overrides}) t, String key) async {
    final value = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _TextDialog(textKey: key, original: t.defaults[key]!, mine: t.overrides[key] ?? const {}),
    );
    if (value == null || !mounted) return;
    setState(() => value.isEmpty ? t.overrides.remove(key) : t.overrides[key] = value);
  }
}

/// One text in three languages: the code's wording, and Alex's next to it. Returns what is
/// overridden after saving ({} after a reset), or null when closed.
class _TextDialog extends StatefulWidget {
  const _TextDialog({required this.textKey, required this.original, required this.mine});
  final String textKey;
  final Map<String, String> original, mine;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _fields = {for (final l in siteLangs) l: TextEditingController(text: widget.mine[l] ?? '')};
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Set<String> _missing(String lang) => missingPlaceholders(widget.original[lang] ?? '', _fields[lang]!.text);

  Future<void> _run(Future<Map<String, String>> Function() save) async {
    setState(() => _busy = true);
    Map<String, String>? value;
    await _try(context, 'שמירת הטקסט נכשלה', () async => value = await save());
    if (!mounted) return;
    if (value != null) return Navigator.pop(context, value);
    setState(() => _busy = false);
  }

  Future<void> _save() async {
    final gone = {for (final l in siteLangs) ..._missing(l)};
    if (gone.isNotEmpty &&
        !await _confirm(context, 'לשמור בלי ${gone.join(', ')}?',
            'האתר מחליף את ${gone.join(', ')} בערך אמיתי (שם, מספר, תאריך). בלי זה הערך לא יופיע במשפט.', 'לשמור בכל זאת')) {
      return;
    }
    await _run(() => saveText(widget.textKey, {for (final e in _fields.entries) e.key: e.value.text}));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.studio;
    return AlertDialog(
      title: Text(ltr(widget.textKey)),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('שדה ריק = הנוסח שבקוד האתר.', style: TextStyle(color: s.muted, fontSize: 12)),
            for (final l in siteLangs) ...[
              const SizedBox(height: 16),
              Text('${siteLangNames[l]} · בקוד:', style: TextStyle(color: s.muted, fontSize: 12)),
              SelectableText(widget.original[l] ?? '', textDirection: _dir(l)),
              const SizedBox(height: 6),
              TextField(
                controller: _fields[l],
                textDirection: _dir(l),
                minLines: 1,
                maxLines: 6,
                maxLength: 4000,
                decoration: InputDecoration(labelText: 'הנוסח שלי (${siteLangNames[l]})', counterText: ''),
                onChanged: (_) => setState(() {}),
              ),
              if (_missing(l).isNotEmpty)
                Text('חסר ${_missing(l).join(', ')}: האתר ממלא שם ערך אמיתי', style: TextStyle(color: s.warnInk, fontSize: 12)),
            ],
          ]),
        ),
      ),
      actions: [
        if (widget.mine.isNotEmpty)
          TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        await resetText(widget.textKey);
                        return {};
                      }),
              child: const Text('איפוס לנוסח שבקוד')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('ביטול')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('שמירה')),
      ],
    );
  }
}

/// A product of the site: its texts and settings, and (once it exists) its pictures.
/// Pops true when something on the site changed.
class GiftPage extends StatefulWidget {
  const GiftPage({super.key, this.gift});
  final Map<String, dynamic>? gift;

  @override
  State<GiftPage> createState() => _GiftPageState();
}

class _GiftPageState extends State<GiftPage> {
  late final Map<String, dynamic> _g = widget.gift ?? const {};
  late final _slug = TextEditingController();
  late final _name = {for (final l in siteLangs) l: TextEditingController(text: '${(_g['name'] as Map?)?[l] ?? ''}')};
  late final _text = {for (final l in siteLangs) l: TextEditingController(text: '${(_g['text'] as Map?)?[l] ?? ''}')};
  late final _minQty = TextEditingController(text: '${_g['min_qty'] ?? 30}');
  late final _leadDays = TextEditingController(text: '${_g['lead_days'] ?? 14}');
  late final _sort = TextEditingController(text: '${_g['sort'] ?? 100}');
  late String _kind = '${_g['kind'] ?? 'table'}';
  late bool _published = _g['published'] == true;
  late bool _feature = _g['feature'] == true;
  late Map _images = _g['images'] as Map? ?? const {};
  bool _busy = false;
  bool _changed = false;

  bool get _isNew => widget.gift == null;
  String get _id => _isNew ? _slug.text.trim() : '${_g['slug']}';
  bool get _hasPicture => _images.containsKey('photo.jpg') || _images.containsKey('still.jpg');

  @override
  void dispose() {
    for (final c in [_slug, _minQty, _leadDays, _sort, ..._name.values, ..._text.values]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The first thing that stops saving, in plain words; the server checks the same.
  String? get _problem {
    if (_isNew && !validSlug(_id)) return 'מזהה: אותיות אנגליות קטנות, ספרות ומקפים (למשל cart-coin), עד 60 תווים';
    for (final l in siteLangs) {
      if (_name[l]!.text.trim().isEmpty) return 'חסר שם ב${siteLangNames[l]}';
      if (_text[l]!.text.trim().isEmpty) return 'חסר תיאור ב${siteLangNames[l]}';
    }
    if ((int.tryParse(_minQty.text.trim()) ?? 0) < 1) return 'כמות מינימלית: מספר שלם, 1 לפחות';
    final days = int.tryParse(_leadDays.text.trim());
    if (days == null || days < 0 || days > 365) return 'ימי הכנה: מספר שלם בין 0 ל-365';
    if ((int.tryParse(_sort.text.trim()) ?? -1) < 0) return 'סדר: מספר שלם, 0 ומעלה';
    return null;
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final ok = await _try(context, 'שמירת המוצר נכשלה', () => saveGift({
          'name': {for (final e in _name.entries) e.key: e.value.text.trim()},
          'text': {for (final e in _text.entries) e.key: e.value.text.trim()},
          'kind': _kind,
          'min_qty': int.parse(_minQty.text.trim()),
          'lead_days': int.parse(_leadDays.text.trim()),
          'sort': int.parse(_sort.text.trim()),
          'published': _published && _hasPicture,
          'feature': _feature,
        }, newSlug: _isNew ? _id : null, slug: _id));
    if (!mounted) return;
    if (!ok) return setState(() => _busy = false);
    say(context, _isNew ? 'המוצר נוסף, מוסתר. פותחים אותו, מעלים צילום ומציגים באתר' : 'נשמר. יופיע באתר תוך 5 דקות');
    Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    if (!await _confirm(context, 'למחוק את "${_name['he']!.text}" מהאתר?',
            'המוצר וכל התמונות שלו יימחקו מהאתר ומהשרת. אי אפשר לבטל.', 'מחיקה') ||
        !mounted) {
      return;
    }
    if (await _try(context, 'המחיקה נכשלה', () => deleteGift(_id)) && mounted) Navigator.pop(context, true);
  }

  /// After the photo changed: the pictures as the server now has them.
  Future<void> _picture(String failed, Future<void> Function() change) async {
    setState(() => _busy = true);
    await _try(context, failed, () async {
      await change();
      final fresh = (await siteGifts()).where((g) => g['slug'] == _id).firstOrNull;
      _changed = true;
      if (fresh != null && mounted) setState(() => _images = fresh['images'] as Map? ?? const {});
    });
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _pickPhoto() async {
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'תמונה', extensions: ['jpg', 'jpeg', 'png', 'webp'], mimeTypes: ['image/jpeg', 'image/png', 'image/webp']),
    ]);
    if (f == null) return;
    await _picture('העלאת הצילום נכשלה', () async => uploadPhoto(_id, f.name, await f.readAsBytes()));
  }

  Widget _shot(String file, String label) => Column(mainAxisSize: MainAxisSize.min, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(pictureUrl(_id, file, _images[file]), width: 150, height: 150, fit: BoxFit.cover, cacheWidth: 450,
              errorBuilder: (_, _, _) => const SizedBox(width: 150, height: 150, child: Icon(Icons.broken_image_outlined))),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
        Text(ltr(_day(DateTime.fromMillisecondsSinceEpoch((_images[file] as int) * 1000).toIso8601String(), time: true)),
            style: TextStyle(color: context.studio.muted, fontSize: 12)),
      ]);

  @override
  Widget build(BuildContext context) {
    final s = context.studio;
    final head = Theme.of(context).textTheme.titleMedium;
    final strips = [for (var i = 0; i < 7; i++) 'spin-$i.jpg'].where(_images.containsKey).toList();
    Widget number(TextEditingController c, String label) => SizedBox(
          width: 150,
          child: TextField(
              controller: c,
              keyboardType: TextInputType.number,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(labelText: label),
              onChanged: (_) => setState(() {})),
        );
    return PopScope(
      canPop: false,
      // The list behind reloads when a picture changed, even if nothing else was saved.
      onPopInvokedWithResult: (didPop, _) => didPop ? null : Navigator.pop(context, _changed),
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? 'מוצר חדש באתר' : _name['he']!.text),
          actions: [if (!_isNew) IconButton(tooltip: 'מחיקה מהאתר', icon: const Icon(Icons.delete_outline), onPressed: _busy ? null : _delete)],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              if (_isNew)
                TextField(
                  controller: _slug,
                  autofocus: true,
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(
                      labelText: 'מזהה (באנגלית, בכתובת של המוצר)', helperText: 'למשל cart-coin. לא ניתן לשינוי אחר כך'),
                  onChanged: (_) => setState(() {}),
                )
              else
                Text('מזהה: ${ltr(_id)}', style: TextStyle(color: s.muted)),
              for (final l in siteLangs) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _name[l],
                  textDirection: _dir(l),
                  maxLength: 2000,
                  decoration: InputDecoration(labelText: 'שם (${siteLangNames[l]})', counterText: ''),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _text[l],
                  textDirection: _dir(l),
                  minLines: 2,
                  maxLines: 6,
                  maxLength: 2000,
                  decoration: InputDecoration(labelText: 'תיאור (${siteLangNames[l]})', counterText: ''),
                  onChanged: (_) => setState(() {}),
                ),
              ],
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: [for (final k in giftKinds.entries) ButtonSegment(value: k.key, label: Text(k.value))],
                selected: {_kind},
                onSelectionChanged: (v) => setState(() => _kind = v.first),
              ),
              const SizedBox(height: 16),
              Wrap(spacing: 12, runSpacing: 12, children: [
                number(_minQty, 'כמות מינימלית'),
                number(_leadDays, 'ימי הכנה'),
                number(_sort, 'סדר (נמוך קודם)'),
              ]),
              if (_g['unit_minutes'] case final num minutes) Builder(builder: (context) {
                // B13: never written by itself; Alex takes the suggestion or not.
                final want = suggestedLeadDays(int.tryParse(_minQty.text.trim()) ?? 1, minutes);
                return Row(children: [
                  Expanded(
                    child: Text('זמן הדפסה נמדד: ${minutes.toStringAsFixed(1)} דק׳ ליחידה · '
                        'ימי הכנה מוצעים לכמות המינימלית: $want'),
                  ),
                  if ('$want' != _leadDays.text.trim())
                    TextButton(onPressed: () => setState(() => _leadDays.text = '$want'), child: const Text('להשתמש')),
                ]);
              }),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('מוצג באתר'),
                subtitle: Text(_hasPicture ? 'כבוי = מוסתר מהאתר' : 'אפשר להציג אחרי שיש למוצר צילום או ציור'),
                value: _published && _hasPicture,
                onChanged: _hasPicture ? (v) => setState(() => _published = v) : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('בדף הבית'),
                value: _feature,
                onChanged: (v) => setState(() => _feature = v),
              ),
              if (!_isNew)
                Text(
                  'מ-Gift Factory (לא לעריכה): גודל ${ltr((_g['size_mm'] as List? ?? const []).join(' × '))} מ״מ · '
                  'סיבוב ${ltr('${(_g['spin'] as Map?)?['cols']} × ${(_g['spin'] as Map?)?['rows']}, ${(_g['spin'] as Map?)?['tile']}px')}',
                  style: TextStyle(color: s.muted, fontSize: 12),
                ),
              const SizedBox(height: 12),
              if (_problem != null) Text(_problem!, style: TextStyle(color: s.warnInk)),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton(onPressed: _busy || _problem != null ? null : _save, child: Text(_isNew ? 'הוספה לאתר' : 'שמירה')),
              ),
              if (!_isNew) ...[
                const Divider(height: 40),
                Text('צילום', style: head),
                Text('הצילום שלך של המתנה. כשיש צילום, האתר מציג אותו במקום הציור. JPG, PNG או WebP, עד 15MB.',
                    style: TextStyle(color: s.muted, fontSize: 12)),
                const SizedBox(height: 8),
                Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  if (_images.containsKey('photo.jpg')) _shot('photo.jpg', 'photo.jpg'),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _pickPhoto,
                    icon: const Icon(Icons.upload_outlined),
                    label: Text(_images.containsKey('photo.jpg') ? 'החלפה' : 'העלאת צילום'),
                  ),
                  if (_images.containsKey('photo.jpg'))
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              if (await _confirm(context, 'להסיר את הצילום?', 'האתר יחזור להציג את הציור של המוצר.', 'הסרה')) {
                                await _picture('הסרת הצילום נכשלה', () => deletePhoto(_id));
                              }
                            },
                      child: const Text('הסרה'),
                    ),
                ]),
                const SizedBox(height: 24),
                Text('ציורים', style: head),
                Text('מצוירים במחשב על ידי סקריפט התמונות של האתר (render_gifts.py) ונשלחים לשרת. לצפייה בלבד.',
                    style: TextStyle(color: s.muted, fontSize: 12)),
                const SizedBox(height: 8),
                if (!_images.keys.any((k) => k != 'photo.jpg'))
                  Text('עוד אין ציורים למוצר הזה.', style: TextStyle(color: s.muted))
                else ...[
                  Wrap(spacing: 16, runSpacing: 8, children: [
                    if (_images.containsKey('still.jpg')) _shot('still.jpg', 'still.jpg'),
                    if (_images.containsKey('top.jpg')) _shot('top.jpg', 'top.jpg'),
                  ]),
                  const SizedBox(height: 8),
                  // The seven all-round strips are 24 pictures wide each: listed, not drawn.
                  for (final f in strips)
                    Text('${ltr(f)} · ${ltr(_day(DateTime.fromMillisecondsSinceEpoch((_images[f] as int) * 1000).toIso8601String(), time: true))}',
                        style: TextStyle(color: s.muted, fontSize: 12)),
                ],
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
