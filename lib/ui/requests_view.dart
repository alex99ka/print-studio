import 'dart:async';
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/errors.dart';
import '../core/home_widgets.dart';
import '../core/server.dart';
import '../core/tour.dart';
import '../studio/studio.dart';
import 'ribbon.dart';
import 'skeleton.dart';
import 'studio_actions.dart';
import 'studio_dialogs.dart';
import 'theme.dart';

typedef Docs = List<QueryDocumentSnapshot<Map<String, dynamic>>>;

DateTime _at(Object? t) => t is Timestamp ? t.toDate() : DateTime.now(); // pending = just now
String day(Object? t) {
  final d = _at(t);
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final s = context.studio;
    final ink = Theme.of(context).colorScheme.onSurface;
    final (bg, fg) = switch (status) {
      'waiting' => (s.warnSoft, s.warnInk),
      'approved' || 'ready' => (s.okSoft, s.okInk),
      'printing' => (s.accentSoft, ink),
      'delivered' => (s.sunk, ink),
      _ => (s.sunk, s.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Text(statusLabels[status] ?? status,
          style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w500)),
    );
  }
}

/// The home tab: the list beside the open request on a wide screen, the list
/// alone on a phone (a request opens as its own page there).
class RequestsView extends StatefulWidget {
  const RequestsView({super.key});

  @override
  State<RequestsView> createState() => _RequestsViewState();
}

class _RequestsViewState extends State<RequestsView> {
  String? _open;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 900;
        final list = RequestList(
          selected: wide ? _open : null,
          onOpen: (id) {
            if (wide) {
              setState(() => _open = id);
            } else {
              Navigator.push(context, MaterialPageRoute<void>(builder: (_) => RequestPage(requestId: id)));
            }
          },
        );
        if (!wide) return list;
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: (box.maxWidth * 0.42).clamp(380, 560), child: list),
          VerticalDivider(width: 1, color: context.studio.line),
          Expanded(
            child: _open == null
                ? const Center(child: Text('בוחרים בקשה מהרשימה, או "בקשה חדשה" למעלה.'))
                : RequestDetail(key: ValueKey(_open), requestId: _open!),
          ),
        ]);
      });
}

/// On a phone: one request, with the ribbon's actions under its title.
class RequestPage extends StatelessWidget {
  const RequestPage({super.key, required this.requestId});
  final String requestId;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('בקשה')),
        body: Column(children: [
          const Ribbon(compact: true),
          Expanded(child: RequestDetail(requestId: requestId)),
        ]),
      );
}

class RequestList extends StatefulWidget {
  const RequestList({super.key, required this.selected, required this.onOpen});
  final String? selected;
  final void Function(String id) onOpen;

  @override
  State<RequestList> createState() => _RequestListState();
}

class _RequestListState extends State<RequestList> {
  final _requests = requestsRef.orderBy('updatedAt', descending: true).snapshots();
  final _customers = customersRef.snapshots();
  String? _filter; // a status, 'reply', or null for all

  Future<void> _menu(QueryDocumentSnapshot<Map<String, dynamic>> d) async {
    final draft = d['status'] == 'draft';
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('שינוי שם'), onTap: () => Navigator.pop(c, 'rename')),
          if (draft)
            ListTile(leading: const Icon(Icons.delete_outline), title: const Text('מחיקה'), onTap: () => Navigator.pop(c, 'delete')),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (choice == 'rename') {
      final c = TextEditingController(text: '${d['title']}');
      final title = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('שם הבקשה'),
          content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ביטול')),
            FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('שמירה')),
          ],
        ),
      );
      if (title != null && title.trim().isNotEmpty) {
        d.reference.update({'title': title.trim()}).catchError((Object e) => showError(messenger, e, 'השמירה נכשלה'));
      }
    } else if (choice == 'delete') {
      // A draft the customer never saw; still not undoable (its files go too), so ask.
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('למחוק את "${d['title']}"?'),
          content: const Text('הבקשה עוד לא פורסמה ללקוח. אי אפשר לבטל.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ביטול')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('מחיקה')),
          ],
        ),
      );
      if (yes == true) d.reference.delete().catchError((Object e) => showError(messenger, e, 'המחיקה נכשלה'));
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _customers,
        builder: (context, cs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _requests,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                  child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(errorText(snap.error!, 'טעינת הבקשות נכשלה'), textAlign: TextAlign.center),
              ));
            }
            if (!snap.hasData) return const SkeletonList();
            final all = snap.data!.docs;
            final tokens = {for (final c in cs.data?.docs ?? const <Doc>[]) c.id: '${c.data()?['portalToken'] ?? ''}'};
            final waiting = all.where((d) => d['status'] == 'waiting');
            updateHomeWidgets(open: waiting.length, titles: [for (final d in waiting.take(3)) '${d['title']}']);
            final shown = all.where((d) => switch (_filter) {
                  null => true,
                  'reply' => d.data()['needsReply'] == true,
                  final f => d['status'] == f,
                }).toList();
            final counts = <String?, int>{
              null: all.length,
              'reply': all.where((d) => d.data()['needsReply'] == true).length,
              for (final s in statuses) s: all.where((d) => d['status'] == s).length,
            };
            final chips = [
              for (final f in <String?>[null, 'reply', ...statuses])
                if (f == null || counts[f]! > 0)
                  ChoiceChip(
                    label: Text('${f == null ? 'הכול' : f == 'reply' ? 'הערות חדשות' : statusLabels[f]} ${counts[f]}'),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
            ];
            Widget row(QueryDocumentSnapshot<Map<String, dynamic>> d) => _RequestRow(
                  d,
                  token: tokens[d['customerId']] ?? '',
                  selected: widget.selected == d.id,
                  onTap: () => widget.onOpen(d.id),
                  onMenu: () => _menu(d),
                );
            return RefreshIndicator(
              onRefresh: () => requestsRef
                  .get(const GetOptions(source: Source.server))
                  .timeout(const Duration(seconds: 10))
                  .then((_) {}, onError: (_) {}),
              child: ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                    child: Wrap(spacing: 6, runSpacing: 6, children: chips),
                  ),
                  if (all.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('עוד אין בקשות. מתחילים ב"לקוח חדש" ואז "בקשה חדשה" ברצועה למעלה.',
                          textAlign: TextAlign.center),
                    ),
                  for (final (i, d) in shown.indexed)
                    if (i == 0) TourTarget('home.first', child: row(d)) else row(d),
                ],
              ),
            );
          },
        ),
      );
}

class _RequestRow extends StatelessWidget {
  const _RequestRow(this.d, {required this.token, required this.selected, required this.onTap, required this.onMenu});
  final QueryDocumentSnapshot<Map<String, dynamic>> d;
  final String token;
  final bool selected;
  final VoidCallback onTap, onMenu;

  @override
  Widget build(BuildContext context) {
    final s = context.studio;
    final r = d.data();
    final shown = r['publishedVersionId'] as String?;
    return Material(
      type: selected ? MaterialType.canvas : MaterialType.transparency,
      color: selected ? s.accentSoft : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onMenu,
        onSecondaryTap: onMenu,
        child: Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: s.line))),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: s.sunk, borderRadius: BorderRadius.circular(8)),
              clipBehavior: Clip.antiAlias,
              child: shown != null && token.isNotEmpty && hasServer
                  ? Image.network(fileUrl(token, shown, 'preview.png'),
                      fit: BoxFit.contain, errorBuilder: (_, _, _) => Icon(Icons.image_outlined, color: s.muted))
                  : Icon(Icons.view_in_ar_outlined, color: s.muted),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text('${r['title']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                  ),
                  if (r['needsReply'] == true) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.mark_chat_unread_outlined, size: 18, color: Theme.of(context).colorScheme.primary,
                        semanticLabel: 'הערה חדשה מהלקוח'),
                  ],
                ]),
                Text('${r['customerName'] ?? ''} · גרסה ${r['latestVersion'] ?? 0} · ${r['qty'] ?? 1} יח׳ · ${day(r['updatedAt'])}',
                    style: TextStyle(fontSize: 12, color: s.muted)),
              ]),
            ),
            const SizedBox(width: 8),
            StatusChip('${r['status']}'),
          ]),
        ),
      ),
    );
  }
}

/// One request: the design on screen (2D, with the customer's pins), its
/// versions, the price and the conversation.
class RequestDetail extends StatefulWidget {
  const RequestDetail({super.key, required this.requestId});
  final String requestId;

  @override
  State<RequestDetail> createState() => _RequestDetailState();
}

class _RequestDetailState extends State<RequestDetail> {
  late final _request = requestsRef.doc(widget.requestId).snapshots();
  late final _versions = versionsRef.where('requestId', isEqualTo: widget.requestId).snapshots();
  late final _quotes = quotesRef.where('requestId', isEqualTo: widget.requestId).snapshots();
  late final _comments = commentsRef.where('requestId', isEqualTo: widget.requestId).snapshots();
  Stream<Doc>? _customer;
  String? _versionId;
  String _view = '2d';
  int _frame = 0, _focus = 0; // _focus: bumped to re-open the preview on a comment's pin
  bool _seen = false;
  final _reply = TextEditingController();

  @override
  void dispose() {
    if (selection.value?.request.id == widget.requestId) {
      // After this frame: the ribbon may be building right now.
      scheduleMicrotask(() => selection.value = null);
    }
    _reply.dispose();
    super.dispose();
  }

  Widget _fail(Object e) => Center(
      child: Padding(padding: const EdgeInsets.all(24), child: Text(errorText(e, 'טעינת הבקשה נכשלה'), textAlign: TextAlign.center)));

  @override
  Widget build(BuildContext context) => StreamBuilder<Doc>(
        stream: _request,
        builder: (context, rs) {
          if (rs.hasError) return _fail(rs.error!);
          if (!rs.hasData) return const SkeletonList();
          final request = rs.data!;
          if (!request.exists) return const Center(child: Text('הבקשה נמחקה.'));
          _customer ??= customersRef.doc('${request['customerId']}').snapshots();
          return StreamBuilder<Doc>(
            stream: _customer,
            builder: (context, cs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _versions,
              builder: (context, vs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: _quotes,
                builder: (context, qs) => StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _comments,
                  builder: (context, ms) {
                    final err = vs.error ?? qs.error ?? ms.error;
                    if (err != null) return _fail(err);
                    if (!vs.hasData || !qs.hasData || !ms.hasData) return const SkeletonList();
                    return _body(request, cs.data, vs.data!.docs, qs.data!.docs, ms.data!.docs);
                  },
                ),
              ),
            ),
          );
        },
      );

  Widget _body(Doc request, Doc? customer, Docs versionDocs, Docs quoteDocs, Docs commentDocs) {
    final r = request.data()!;
    final versions = [...versionDocs]..sort((a, b) => (a['n'] as int).compareTo(b['n'] as int));
    final quotes = [...quoteDocs]..sort((a, b) => _at(a['createdAt']).compareTo(_at(b['createdAt'])));
    final comments = [...commentDocs]..sort((a, b) => _at(a['createdAt']).compareTo(_at(b['createdAt'])));
    final version = versions.where((v) => v.id == _versionId).firstOrNull ??
        versions.where((v) => v.id == r['publishedVersionId']).firstOrNull ??
        versions.lastOrNull;
    final sel = Selection(request: request, customer: customer, versions: versions, version: version);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      selection.value = sel;
      if (r['needsReply'] == true && !_seen) {
        _seen = true; // opened = read
        request.reference.update({'needsReply': false}).ignore();
      }
    });

    final s = context.studio;
    final pinned = {for (final (i, c) in comments.where((c) => c['pin'] != null).indexed) c.id: i + 1};
    final token = '${customer?.data()?['portalToken'] ?? ''}';
    final open = r['status'] == 'draft' || r['status'] == 'waiting';
    final quote = quotes.where((q) => q.id == r['quoteId']).firstOrNull;
    final views = [
      for (final (k, f, label) in const [('2d', 'preview.png', '2D'), ('3d', 'spin.jpg', 'תלת-ממד'), ('asm', 'spin_asm.jpg', 'על המיקרופון')])
        if (version != null && filesOf(version).contains(f)) (k, f, label),
    ];
    final view = views.where((v) => v.$1 == _view).firstOrNull ?? views.firstOrNull;
    final openComments = comments.where((c) => c['from'] == 'client' && c.data()['done'] != true).length;
    // A pinned comment opens its version, view and turn in the preview.
    void show(QueryDocumentSnapshot<Map<String, dynamic>> c) {
      final pin = c['pin'] as Map?;
      if (pin == null) return;
      setState(() {
        _versionId = '${c['versionId']}';
        _view = '${pin['view']}';
        _frame = ((pin['z'] as num?) ?? 0).round();
        _focus++;
      });
    }

    final header = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('${r['title']}', style: Theme.of(context).textTheme.titleLarge)),
        PopupMenuButton<String>(
          tooltip: 'שינוי סטטוס',
          onSelected: (st) => setStatus(request, st).catchError((Object e) {
            if (mounted) showError(ScaffoldMessenger.of(context), e, 'שינוי הסטטוס נכשל');
          }),
          itemBuilder: (_) => [for (final st in statuses) PopupMenuItem(value: st, child: Text(statusLabels[st]!))],
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            StatusChip('${r['status']}'),
            Icon(Icons.arrow_drop_down, color: s.muted),
          ]),
        ),
      ]),
      Text('${r['customerName'] ?? ''} · ${r['qty'] ?? 1} יחידות', style: TextStyle(color: s.muted)),
      if ('${r['notes'] ?? ''}'.isNotEmpty) Text('הערות: ${r['notes']}', style: TextStyle(color: s.muted)),
    ]);

    final preview = Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (versions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Text('עוד אין גרסה. מייצאים מה-Flag Maker (Send to CRM), או "ייבוא גרסה" ברצועה.',
                  textAlign: TextAlign.center, style: TextStyle(color: s.muted)),
            )
          else ...[
            Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final v in versions)
                ChoiceChip(
                  label: Text('v${v['n']}${switch (v['state']) {
                    'draft' => ' · טיוטה',
                    'approved' => ' · אושרה',
                    _ => v.id == r['publishedVersionId'] ? ' · אצל הלקוח' : '',
                  }}'),
                  selected: v.id == version?.id,
                  onSelected: (_) => setState(() => _versionId = v.id),
                ),
            ]),
            const SizedBox(height: 12),
            if (view != null && token.isNotEmpty && hasServer) ...[
              if (views.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [for (final (k, _, label) in views) ButtonSegment(value: k, label: Text(label))],
                    selected: {view.$1},
                    onSelectionChanged: (k) => setState(() {
                      _view = k.first;
                      _frame = 0;
                    }),
                  ),
                ),
              SizedBox(
                height: 320,
                child: PinnedPreview(
                  key: ValueKey('${version!.id}/${view.$1}/$_focus'),
                  url: fileUrl(token, version.id, view.$2),
                  grid: view.$1 == '2d' ? 1 : spinGrid,
                  frame: _frame,
                  pins: [
                    for (final c in comments)
                      if (c['versionId'] == version.id && (c['pin'] as Map?)?['view'] == view.$1)
                        (Offset(((c['pin'] as Map)['x'] as num).toDouble(), ((c['pin'] as Map)['y'] as num).toDouble()),
                            '${pinned[c.id]}', (((c['pin'] as Map)['z'] as num?) ?? 0).round()),
                  ],
                ),
              ),
              if (view.$1 != '2d')
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('גוררים ימינה ושמאלה לסיבוב', style: TextStyle(fontSize: 12, color: s.muted)),
                ),
            ],
            if (version != null && '${version['note'] ?? ''}'.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text('${version['note']}', style: TextStyle(color: s.muted))),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: () => previewInBrowser(context, sel),
                icon: const Icon(Icons.view_in_ar_outlined),
                label: const Text('תצוגת לקוח (3D)'),
              ),
              if (publishable(sel) != null)
                FilledButton.icon(
                  onPressed: () => publishVersion(context, sel),
                  icon: const Icon(Icons.send_outlined),
                  label: Text('פרסם ללקוח (v${publishable(sel)!['n']})'),
                ),
            ]),
          ],
        ]),
      ),
    );

    final money_ = quote == null ? null : money(quote['unit'] as int, quote['qty'] as int, quote['vatPercent'] as int);
    final quoteCard = Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('הצעת מחיר', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (quote == null)
            Text('עוד אין מחיר. הלקוח יכול לאשר רק עיצוב עם מחיר.', style: TextStyle(color: s.muted))
          else ...[
            MoneyLine('${quote['qty']} × ${ltr(shekel(quote['unit'] as int))}', money_!.net),
            if ((quote['vatPercent'] as int) > 0) MoneyLine('מע״מ ${quote['vatPercent']}%', money_.vat),
            const Divider(),
            MoneyLine('סה״כ', money_.total, bold: true),
            if ('${quote['note'] ?? ''}'.isNotEmpty) Text('${quote['note']}', style: TextStyle(color: s.muted)),
            for (final q in quotes.where((q) => q.id != quote.id))
              Text('קודם: ${ltr(shekel(q['unit'] as int))} × ${q['qty']} · ${day(q['createdAt'])}',
                  style: TextStyle(color: s.muted, fontSize: 12)),
          ],
          if (r['approvedAt'] != null)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: s.okSoft, borderRadius: BorderRadius.circular(10)),
              child: Text('הלקוח אישר את v${versions.where((v) => v.id == r['approvedVersionId']).firstOrNull?['n'] ?? ''} '
                  'ואת המחיר ב-${day(r['approvedAt'])}', style: TextStyle(color: s.okInk, fontWeight: FontWeight.w500)),
            ),
          if (open) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => showDialog<void>(
                  context: context, builder: (_) => QuoteDialog(request: request, current: quote?.data())),
              child: Text(quote == null ? 'הוספת מחיר' : 'מחיר חדש'),
            ),
          ],
        ]),
      ),
    );

    Future<void> send() async {
      final text = _reply.text.trim();
      if (text.isEmpty || version == null) return;
      _reply.clear();
      try {
        await reply(request, version, text);
      } catch (e) {
        if (mounted) showError(ScaffoldMessenger.of(context), e, 'התשובה לא נשלחה');
      }
    }

    final talk = Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(openComments == 0 ? 'הערות' : 'הערות · $openComments פתוחות', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (comments.isEmpty) Text('עוד אין הערות.', style: TextStyle(color: s.muted)),
          for (final c in comments) _Comment(c, pin: pinned[c.id], onShow: () => show(c)),
          if (version != null) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _reply,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => send(),
              decoration: InputDecoration(
                hintText: 'תשובה ללקוח (על v${version['n']})…',
                suffixIcon: IconButton(tooltip: 'שליחה', icon: const Icon(Icons.send), onPressed: send),
              ),
            ),
          ],
        ]),
      ),
    );

    return LayoutBuilder(
      builder: (context, box) => ListView(padding: const EdgeInsets.all(16), children: [
        header,
        const SizedBox(height: 16),
        preview,
        const SizedBox(height: 16),
        if (box.maxWidth >= 700)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 320, child: quoteCard),
            const SizedBox(width: 16),
            Expanded(child: talk),
          ])
        else ...[
          quoteCard,
          const SizedBox(height: 16),
          talk,
        ],
      ]),
    );
  }
}

class _Comment extends StatelessWidget {
  const _Comment(this.c, {this.pin, required this.onShow});
  final QueryDocumentSnapshot<Map<String, dynamic>> c;
  final int? pin;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final s = context.studio;
    final scheme = Theme.of(context).colorScheme;
    final mine = c['from'] == 'studio';
    final view = (c['pin'] as Map?)?['view'];
    final done = c.data()['done'] == true;
    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: mine ? s.accentSoft : s.sunk, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          '${mine ? 'את/ה' : 'הלקוח'} · v${c['versionN'] ?? ''} · ${day(c['createdAt'])}'
          '${view == '2d' ? ' · נעוץ בתמונה' : view == '3d' ? ' · נעוץ בתלת-ממד' : view == 'asm' ? ' · נעוץ על המיקרופון' : ''}'
          '${done ? ' · ✓ טופל' : ''}',
          style: TextStyle(fontSize: 12, color: done ? s.okInk : s.muted),
        ),
        SelectableText('${c['text']}', onTap: pin != null ? onShow : null),
      ]),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CircleAvatar(
          radius: 13,
          backgroundColor: pin != null ? scheme.primary : s.sunk,
          foregroundColor: pin != null ? scheme.onPrimary : s.muted,
          child: Text(pin != null ? '$pin' : (mine ? 'ס' : 'ל'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Opacity(
            opacity: done ? .6 : 1,
            child: pin == null ? bubble : InkWell(onTap: onShow, borderRadius: BorderRadius.circular(10), child: bubble),
          ),
        ),
        if (!mine)
          IconButton(
            tooltip: done ? 'פתיחה מחדש' : 'סימון כטופל',
            icon: Icon(done ? Icons.check_circle : Icons.radio_button_unchecked, color: done ? s.okInk : s.muted),
            onPressed: () => setHandled(c.reference, !done).catchError((Object e) {
              if (context.mounted) showError(ScaffoldMessenger.of(context), e, 'הסימון נכשל');
            }),
          ),
      ]),
    );
  }
}

/// A picture with numbered pins at fractions of it (not of the box: the
/// picture is letterboxed), exactly where the customer tapped. With [grid] > 1
/// the picture is a sheet of [spinFrames] turns: dragging sideways turns it,
/// and a pin shows only on the turn it was placed on.
class PinnedPreview extends StatefulWidget {
  const PinnedPreview({super.key, required this.url, required this.pins, this.grid = 1, this.frame = 0});
  final String url;
  final int grid;
  final int frame;
  final List<(Offset, String, int)> pins;

  @override
  State<PinnedPreview> createState() => _PinnedPreviewState();
}

class _PinnedPreviewState extends State<PinnedPreview> {
  ImageInfo? _info;
  bool _failed = false;
  ImageStream? _stream;
  late int _frame = widget.grid > 1 ? widget.frame % spinFrames : 0;
  double _drag = 0;
  late final _listener = ImageStreamListener(
    (info, _) {
      if (!mounted) return info.dispose();
      setState(() {
        _info?.dispose();
        _info = info;
      });
    },
    onError: (_, _) {
      if (mounted) setState(() => _failed = true);
    },
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _stream ??= NetworkImage(widget.url).resolve(createLocalImageConfiguration(context))..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _info?.dispose();
    super.dispose();
  }

  void _turn(DragUpdateDetails d) {
    _drag += d.delta.dx;
    final step = (_drag / 10).truncate(); // 10 px a turn, like the client's page
    if (step == 0) return;
    _drag -= step * 10;
    setState(() => _frame = (_frame - step) % spinFrames);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.studio;
    final scheme = Theme.of(context).colorScheme;
    final image = _info?.image;
    final Widget child;
    if (_failed) {
      child = Center(child: Icon(Icons.broken_image_outlined, color: s.muted));
    } else if (image == null) {
      child = const Center(child: CircularProgressIndicator());
    } else {
      final g = widget.grid;
      final tile = Size(image.width / g, image.height / g);
      final src = Offset((_frame % g) * tile.width, (_frame ~/ g) * tile.height) & tile;
      child = GestureDetector(
        onHorizontalDragUpdate: g > 1 ? _turn : null,
        child: FittedBox(
          child: SizedBox.fromSize(
            size: tile,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned.fill(child: CustomPaint(painter: _Tile(image, src))),
              for (final (at, label, turn) in widget.pins)
                if (g == 1 || turn % spinFrames == _frame)
                  Positioned(
                    left: at.dx * tile.width - tile.shortestSide * .04,
                    top: at.dy * tile.height - tile.shortestSide * .04,
                    child: Container(
                      width: tile.shortestSide * .08,
                      height: tile.shortestSide * .08,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppTokens.white, width: tile.shortestSide * .006)),
                      child: Text(label,
                          style: TextStyle(
                              color: scheme.onPrimary, fontWeight: FontWeight.w700, fontSize: tile.shortestSide * .04)),
                    ),
                  ),
            ]),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(color: s.sunk, borderRadius: BorderRadius.circular(10)),
      padding: const EdgeInsets.all(8),
      child: child,
    );
  }
}

class _Tile extends CustomPainter {
  _Tile(this.image, this.src);
  final ui.Image image;
  final Rect src;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawImageRect(image, src, Offset.zero & size, Paint()..filterQuality = FilterQuality.medium);

  @override
  bool shouldRepaint(_Tile old) => old.image != image || old.src != src;
}
