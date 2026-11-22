import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_selector/file_selector.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../core/errors.dart';
import '../core/server.dart';

/// Print Studio's records. The app writes customers, requests, quotes, its
/// own comments and publishing (checked by firestore.rules); the Pi writes
/// versions, the customer's comments and approvals (server/app/studio.py),
/// and a request's production and guests (server/app/giftfactory.py). The
/// app's writes to a request are field updates, so they never drop those.

typedef Doc = DocumentSnapshot<Map<String, dynamic>>;

final _db = FirebaseFirestore.instance;
final customersRef = _db.collection('customers');
final requestsRef = _db.collection('requests');
final versionsRef = _db.collection('versions');
final quotesRef = _db.collection('quotes');
final commentsRef = _db.collection('comments');
final paymentsRef = _db.collection('payments');

/// declined: the client cancelled it on the portal (server/app/studio.py); setting it back reopens it.
const statuses = ['draft', 'waiting', 'approved', 'printing', 'ready', 'delivered', 'paid', 'declined'];
const statusLabels = {
  'draft': 'טיוטה',
  'waiting': 'ממתין לאישור',
  'approved': 'אושר',
  'printing': 'בהדפסה',
  'ready': 'מוכן',
  'delivered': 'נמסר',
  'paid': 'שולם',
  'declined': 'הלקוח ביטל',
};
const defaultVatPercent = 18;
const paymentMethods = {'bit': 'ביט', 'paybox': 'פייבוקס', 'transfer': 'העברה בנקאית', 'cash': 'מזומן', 'check': 'צ׳ק', 'other': 'אחר'};

/// Approved and later: the client owes the approved quote. Before that a quote is only an offer.
bool owes(String status) => !const {'draft', 'waiting', 'declined'}.contains(status);

/// What is left of [total] after [paid]; never below zero (an overpayment shows as nothing left).
int leftToPay(int total, int paid) => total > paid ? total - paid : 0;

/// A customer's money over all their orders: what the approved ones cost, what came in
/// (deposits on open offers too) and what is left (per order, an overpayment never
/// lowers another order's debt).
({int billed, int paid, int left}) balance(Iterable<({String status, int? total, int paid})> orders) {
  var billed = 0, paid = 0, left = 0;
  for (final o in orders) {
    paid += o.paid;
    if (owes(o.status) && o.total != null) {
      billed += o.total!;
      left += leftToPay(o.total!, o.paid);
    }
  }
  return (billed: billed, paid: paid, left: left);
}

/// A request's deadline is a day, "2026-11-12": no time, no time zone (the Pi reminds by it).
String isoDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? deadlineOf(Map<String, dynamic>? r) => DateTime.tryParse('${r?['deadline'] ?? ''}');

/// Days from [today] to the deadline (0 = today, below 0 = passed); null without one
/// or once the order is out the door.
int? daysLeft(Map<String, dynamic>? r, DateTime today) {
  final d = deadlineOf(r);
  if (d == null || const {'delivered', 'paid', 'declined'}.contains(r?['status'])) return null;
  return DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
}

/// Hours of printing still ahead: Gift Factory's printHours less the plates done; else the
/// Flag Maker's printMinutes per unit (request.estimate) times the quantity; else one day.
/// Same as print_hours_left in server/app/jobs.py.
double printHoursLeft(Map<String, dynamic> r) {
  final p = productionOf(r);
  final hours = ((p['quote'] as Map?)?['printHours'] as num?)?.toDouble() ?? 0;
  if (hours > 0) {
    final prog = (p['progress'] as Map?) ?? const {};
    final total = (prog['platesTotal'] as num?) ?? 0, done = (prog['platesDone'] as num?) ?? 0;
    return total > 0 ? hours * (total - done).clamp(0, total) / total : hours;
  }
  final minutes = ((r['estimate'] as Map?)?['printMinutes'] as num?) ?? 0;
  if (minutes > 0) return minutes * max(1, (r['qty'] as num?)?.toInt() ?? 1) / 60;
  return 24;
}

/// Days of printing still ahead. Same as print_days_left in server/app/jobs.py.
int printDaysLeft(Map<String, dynamic> r) => (printHoursLeft(r) / 24).ceil();

/// C-2: one X2D for every order. Each request with a deadline and printing still ahead gets
/// its (start, end), as late as it can: ending 2 days before its deadline and before the next
/// one starts (latest deadline placed first). A start before today = the printer can't make it.
/// Same as print_schedule in server/app/jobs.py (same test cases); times are wall-clock days.
Map<String, ({DateTime start, DateTime end})> printSchedule(Map<String, Map<String, dynamic>> rows) {
  final queue = <(DateTime, String, double)>[];
  for (final e in rows.entries) {
    final due = DateTime.tryParse('${e.value['deadline'] ?? ''}');
    if (due == null || const {'ready', 'delivered', 'paid', 'declined'}.contains(e.value['status'])) continue;
    queue.add((DateTime.utc(due.year, due.month, due.day), e.key, printHoursLeft(e.value)));
  }
  queue.sort((a, b) => a.$1 != b.$1 ? b.$1.compareTo(a.$1) : b.$2.compareTo(a.$2));
  final out = <String, ({DateTime start, DateTime end})>{};
  DateTime? cursor;
  for (final (due, id, hours) in queue) {
    var end = due.subtract(const Duration(days: 2));
    if (cursor != null && cursor.isBefore(end)) end = cursor;
    cursor = end.subtract(Duration(minutes: (hours * 60).round()));
    out[id] = (start: cursor, end: end);
  }
  return out;
}

/// The Pi's first reminder (and the app's amber) comes this many days before the deadline.
int remindDays(Map<String, dynamic> r) => printDaysLeft(r) + 2;

/// "היום", "מחר", "בעוד 5 ימים", "עבר לפני 2 ימים".
String daysLeftText(int n) => switch (n) {
      0 => 'היום',
      1 => 'מחר',
      -1 => 'עבר אתמול',
      < 0 => 'עבר לפני ${-n} ימים',
      _ => 'בעוד $n ימים',
    };

/// Agorot in, agorot out; [discount] (agorot) comes off before VAT, and VAT is rounded
/// half up to the agora, exactly like money() in server/app/studio.py (the portal shows
/// the server's numbers: the client sees only the total).
({int net, int vat, int total}) money(int unit, int qty, int vatPercent, [int discount = 0]) {
  final net = max(0, unit * qty - discount);
  final vat = (net * vatPercent + 50) ~/ 100;
  return (net: net, vat: vat, total: net + vat);
}

/// A saved quote's money (quotes before 0.3.5 have no discount).
({int net, int vat, int total}) quoteMoney(Map<String, dynamic> q) =>
    money(q['unit'] as int, q['qty'] as int, q['vatPercent'] as int, (q['discount'] as int?) ?? 0);

/// [percent] of [unit] × [qty], rounded half up to the agora.
int discountOf(int unit, int qty, num percent) => (unit * qty * percent / 100).round();

/// 42480 → "₪424.80", 123456789 → "₪1,234,567.89".
/// Keeps an amount or number left to right inside Hebrew text (an LTR isolate).
String ltr(String s) => '\u2066$s\u2069';

String shekel(int agorot) {
  final sign = agorot < 0 ? '-' : '';
  final a = agorot.abs();
  final whole = (a ~/ 100).toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');
  return '$sign₪$whole.${(a % 100).toString().padLeft(2, '0')}';
}

/// "180", "180.5", "1,234.50", "₪ 99" → agorot; null when it isn't a price.
int? parseShekel(String text) {
  final t = text.replaceAll(RegExp(r'[₪,\s]'), '');
  final m = RegExp(r'^(\d{1,9})(?:\.(\d{1,2}))?$').firstMatch(t);
  if (m == null) return null;
  return int.parse(m[1]!) * 100 + int.parse((m[2] ?? '0').padRight(2, '0'));
}

/// The portal link's secret: 16 random bytes, 22 URL-safe characters.
String newPortalToken() {
  final r = Random.secure();
  return base64Url.encode([for (var i = 0; i < 16; i++) r.nextInt(256)]).replaceAll('=', '');
}

String portalUrl(String token, {String? preview}) =>
    '${AppConfig.serverUrl}/p/$token${preview == null ? '' : '?preview=$preview'}';

/// A version's file through the signed-in route: the 3MF and the recipe never
/// go through the client's link.
Future<Uint8List> studioFile(String versionId, String name) => _download('/studio/versions/$versionId/$name');

/// The client's guest list as they uploaded it on the portal (.xlsx or .csv).
Future<Uint8List> guestFile(String requestId) => _download('/studio/requests/$requestId/guests');

Future<Uint8List> _download(String path) async {
  final token = await FirebaseAuth.instance.currentUser?.getIdToken();
  final res = await http.get(Uri.parse('${AppConfig.serverUrl}$path'),
      headers: {if (token != null) 'Authorization': 'Bearer $token'}).timeout(const Duration(minutes: 2));
  if (res.statusCode != 200) throw ServerException(res.statusCode, res.body);
  return res.bodyBytes;
}

/// Pictures and 3D views only (the client's link serves nothing else).
String fileUrl(String token, String versionId, String name) =>
    '${AppConfig.serverUrl}/p/$token/f/$versionId/$name';

/// wa.me wants the number in international form: 052-123-4567 → 972521234567.
Uri whatsapp(String phone, String text) {
  var digits = phone.replaceAll(RegExp(r'\D'), '');
  if (digits.startsWith('0')) digits = '972${digits.substring(1)}';
  return Uri.https('wa.me', digits.isEmpty ? '/' : '/$digits', {'text': text});
}

String portalMessage(String customerName, String url) =>
    'שלום $customerName, יש עיצוב חדש לאישור בסטודיו הדפסה. אפשר לראות, להעיר ולאשר כאן:\n$url';

/// C-8: the order is ready (מוכן). In the customer's portal language; Alex taps send.
String readyMessage(String customerName, String what, String url, {String lang = 'he'}) => lang == 'en'
    ? 'Hi $customerName, your order is ready: $what 🎉\nAll the details are here:\n$url'
    : 'שלום $customerName, ההזמנה שלך מוכנה: $what 🎉\nכל הפרטים כאן:\n$url';

/// For someone asking about a microphone flag (WhatsApp: *bold*). Alex's prices, 18.11.2026.
const micPriceList = '''היי, תודה על ההתעניינות! 🎤
הנה המחירון לדגלים למיקרופון:

*✨ הזמנה חדשה: עיצוב מאפס והדפסה*
120–150 ₪
(לפי מורכבות העיצוב וזמן ההדפסה)

*🔁 הזמנה חוזרת*
100 ₪
שינויים קטנים בעיצוב קיים והדפסה, או מעל 5 יחידות באותה הזמנה (אפשר גם עם שינויים קטנים)

אשמח לענות על כל שאלה 😊''';

// --- writes -------------------------------------------------------------------------

/// A gift customer, or a regular one (לקוח קבוע, `returning`), opens the link only in their Google account
/// (studio.py signs_in); a regular one's link is a personal area: every project, bills and receipts.
bool signsIn(Map<String, dynamic>? c) => c?['kind'] == 'gift' || c?['returning'] == true;

/// The invitation to a regular customer's personal area (their portal link; the first Google account to sign up owns it).
String inviteMessage(String customerName, String url, {String lang = 'he'}) => lang == 'en'
    ? 'Hi $customerName, you have a personal area at the studio now: every project, design, payment request and receipt in one place.\nSign up once with Google here:\n$url'
    : 'שלום $customerName, פתחתי לך אזור אישי בסטודיו: כל הפרויקטים, העיצובים, דרישות התשלום והקבלות במקום אחד.\nנרשמים פעם אחת עם Google כאן:\n$url';

/// A customer's kind: what they order.
const customerKinds = {'mic': 'מיקרופון', 'gift': 'מתנות'};

Future<DocumentReference<Map<String, dynamic>>> addCustomer(
        {required String name, required String phone, required String lang, required String kind, bool returning = false}) =>
    customersRef.add({
      'name': name.trim(),
      'phone': phone.trim(),
      'lang': lang,
      'kind': kind,
      if (returning) 'returning': true,
      'portalToken': newPortalToken(),
      'createdAt': FieldValue.serverTimestamp(),
    });

/// A new link; the old one stops working at once.
Future<void> replacePortalLink(Doc customer) =>
    customer.reference.update({'portalToken': newPortalToken()});

Future<String> addRequest(
    {required Doc customer, required String title, required int qty, String notes = '', DateTime? deadline, String? gift}) async {
  final ref = await requestsRef.add({
    'customerId': customer.id,
    'customerName': customer.data()?['name'] ?? '',
    'title': title.trim(),
    'qty': qty,
    'notes': notes.trim(),
    if (deadline != null) 'deadline': isoDate(deadline),
    'gift': ?gift,
    'status': 'draft',
    'latestVersion': 0,
    'createdAt': FieldValue.serverTimestamp(),
    'updatedAt': FieldValue.serverTimestamp(),
  });
  return ref.id;
}

/// The customer sees this version from now on, and the request waits for them. [alongside]
/// keeps the versions already on offer, so the client approves one of them (studio.py offered()).
Future<void> publish(Doc request, Doc version, {bool alongside = false}) {
  final b = _db.batch()
    ..update(version.reference, {'state': 'published', 'publishedAt': FieldValue.serverTimestamp()})
    ..update(request.reference, {
      'publishedVersionId': version.id,
      'offeredVersionIds': alongside ? {...offeredVersions(request.data() ?? const {}), version.id}.toList() : [version.id],
      'status': 'waiting',
      'updatedAt': FieldValue.serverTimestamp(),
    });
  return b.commit();
}

/// The versions the client may approve now (studio.py offered()).
List<String> offeredVersions(Map<String, dynamic> r) => [
      ...?(r['offeredVersionIds'] as List?)?.cast<String>(),
      if (r['offeredVersionIds'] == null && r['publishedVersionId'] != null) r['publishedVersionId'] as String,
    ];

/// A new quote replaces the current one; quotes are never edited. [discount] in agorot,
/// [discountPct] only to show Alex how it was given (the client sees neither).
Future<void> addQuote(Doc request,
    {required int unit,
    required int qty,
    required int vatPercent,
    required String note,
    int discount = 0,
    int? discountPct,
    bool correction = false}) {
  final q = quotesRef.doc();
  final b = _db.batch()
    ..set(q, {
      'requestId': request.id,
      'customerId': request.data()?['customerId'],
      'unit': unit,
      'qty': qty,
      'vatPercent': vatPercent,
      if (discount > 0) 'discount': discount,
      if (discount > 0 && discountPct != null) 'discountPct': discountPct,
      'note': note.trim(),
      if (correction) 'correction': true,
      'createdAt': FieldValue.serverTimestamp(),
      'by': FirebaseAuth.instance.currentUser?.uid ?? '',
    })
    ..update(request.reference, {'quoteId': q.id, 'qty': qty, 'updatedAt': FieldValue.serverTimestamp()});
  return b.commit();
}

/// The client's 3D views: tiles on one sheet. A version stores its spinGrid,
/// grid x grid turns read as one row (Gift Factory 10 = 100 turns; older ones are
/// the Flag Maker's 6 x 6, crm_link.spin), or Gift Factory's views: cols turns a
/// row, a row per height (C2b). A 3D pin is {x, y} on the picture and z = the tile.
const spinGrid = 6;
int spinGridOf(Map<String, dynamic>? version) => (version?['spinGrid'] as num?)?.toInt() ?? spinGrid;

/// (cols, rows, turns a row, first tile) of a version's spin sheet.
(int, int, int, int) spinSheetOf(Map<String, dynamic>? version) {
  final v = version?['views'] as Map?;
  if (v == null) {
    final g = spinGridOf(version);
    return (g, g, g * g, 0);
  }
  final cols = (v['cols'] as num).toInt(), start = v['start'] as List;
  return (cols, (v['pitches'] as List).length, cols, (start[0] as num).toInt() * cols + (start[1] as num).toInt());
}

/// A client comment marked handled, or open again.
Future<void> setHandled(DocumentReference<Map<String, dynamic>> comment, bool done) =>
    comment.update({'done': done, 'doneAt': done ? FieldValue.serverTimestamp() : null});

Future<void> reply(Doc request, Doc version, String text) {
  final b = _db.batch()
    ..set(commentsRef.doc(), {
      'requestId': request.id,
      'customerId': request.data()?['customerId'],
      'versionId': version.id,
      'versionN': version.data()?['n'],
      'from': 'studio',
      'text': text.trim(),
      'pin': null,
      'createdAt': FieldValue.serverTimestamp(),
    })
    ..update(request.reference, {'needsReply': false, 'updatedAt': FieldValue.serverTimestamp()});
  return b.commit();
}

/// Money received for a request; [at] is the day it came in. Never edited: deleted and entered again.
/// [markPaid] also sets the status to שולם, in the same write, so the two never disagree.
Future<void> addPayment(Doc request,
        {required int amount, required String method, required DateTime at, String note = '', bool markPaid = false}) =>
    (_db.batch()
          ..set(paymentsRef.doc(), {
            'requestId': request.id,
            'customerId': request.data()?['customerId'],
            'amount': amount,
            'method': method,
            'note': note.trim(),
            'at': Timestamp.fromDate(at),
            'createdAt': FieldValue.serverTimestamp(),
          })
          ..update(request.reference,
              {if (markPaid) 'status': 'paid', 'updatedAt': FieldValue.serverTimestamp()}))
        .commit();

/// A payment that clears what a delivered request still owed moves it to שולם by itself.
bool settles({required String status, required int left, required int amount}) =>
    status == 'delivered' && left > 0 && amount >= left;

/// [day] null clears it.
Future<void> setDeadline(Doc request, DateTime? day) => request.reference
    .update({'deadline': day == null ? null : isoDate(day), 'updatedAt': FieldValue.serverTimestamp()});

/// B4: the shop product the request is for (its slug), or none. Gift Factory opens that model.
Future<void> setGift(Doc request, String? slug) =>
    request.reference.update({'gift': slug, 'updatedAt': FieldValue.serverTimestamp()});

Future<void> setStatus(Doc request, String status) =>
    request.reference.update({'status': status, 'updatedAt': FieldValue.serverTimestamp()});

// --- the Pi -------------------------------------------------------------------------

/// Which upload field a picked file is, by its name, as the Flag Maker names them.
String? uploadField(String fileName) {
  final n = fileName.toLowerCase();
  if (n.endsWith('.png')) return 'preview';
  if (n.endsWith('.3mf')) return 'model';
  if (n.endsWith('.json')) return 'recipe';
  return null;
}

/// A design version from files picked by hand (the Flag Maker sends its own).
Future<int> uploadVersion(String requestId, List<XFile> files, {String note = ''}) async {
  final req = http.MultipartRequest('POST', Uri.parse('${AppConfig.serverUrl}/studio/requests/$requestId/versions'));
  final token = await FirebaseAuth.instance.currentUser?.getIdToken();
  if (token != null) req.headers['Authorization'] = 'Bearer $token';
  req.fields['note'] = note;
  for (final f in files) {
    final field = uploadField(f.name);
    if (field == null) continue;
    req.files.add(http.MultipartFile.fromBytes(field, await f.readAsBytes(), filename: f.name));
  }
  final res = await http.Response.fromStream(await req.send().timeout(const Duration(minutes: 3)));
  if (res.statusCode >= 400) throw ServerException(res.statusCode, res.body);
  return (jsonDecode(res.body) as Map<String, dynamic>)['n'] as int;
}

/// Photos kept on the Pi as sent, the client never sees them: a customer's logos (C-6, design sources)
/// and a request's printed product. [base] is one of these two.
String logosOf(String customerId) => '/studio/customers/$customerId/logos';
String productPhotosOf(String requestId) => '/studio/requests/$requestId/photos';

Future<List<Map<String, dynamic>>> photosAt(String base) async =>
    (jsonDecode(utf8.decode(await _download(base))) as List).cast<Map<String, dynamic>>();

/// The original, or with [thumb] a small upright JPEG of about that many pixels.
Future<Uint8List> photoAt(String base, String id, {int? thumb}) => _download('$base/$id${thumb == null ? '' : '?thumb=$thumb'}');

Future<void> addPhotos(String base, List<XFile> photos) async {
  final req = http.MultipartRequest('POST', Uri.parse('${AppConfig.serverUrl}$base'));
  final token = await FirebaseAuth.instance.currentUser?.getIdToken();
  if (token != null) req.headers['Authorization'] = 'Bearer $token';
  for (final f in photos) {
    req.files.add(http.MultipartFile.fromBytes('photos', await f.readAsBytes(), filename: f.name));
  }
  final res = await http.Response.fromStream(await req.send().timeout(const Duration(minutes: 5)));
  if (res.statusCode >= 400) throw ServerException(res.statusCode, res.body);
}

Future<void> deletePhotoAt(String base, String id) => server('DELETE', '$base/$id');

/// Deleted on the server with its versions, files, quotes and comments. Not undoable.
Future<void> deleteRequest(String id) => server('DELETE', '/studio/requests/$id');

/// The customer, their portal link and every request of theirs. Not undoable.
Future<void> deleteCustomer(String id) => server('DELETE', '/studio/customers/$id');

/// A new key for the Flag Maker; the previous one stops working.
Future<String> pairFlagMaker() async => (await server('POST', '/studio/flagmaker-key'))['key'] as String;

/// A new key for Gift Factory; its previous one stops working, the Flag Maker's stays.
Future<String> pairGiftFactory() async => (await server('POST', '/studio/giftfactory-key'))['key'] as String;

// --- Gift Factory (server/GIFT_FACTORY.md): only the server writes request.production and .guests ---

/// What Gift Factory reported on a request: quote, progress, actualCost (each may be missing).
/// B10: Gift Factory's live printer state (requests.printer, written by the server).
const printerStates = {'printing': 'מדפיסה', 'paused': 'בהשהיה', 'failed': 'נכשלה', 'finished': 'הסתיימה'};

Map<String, dynamic> productionOf(Map<String, dynamic> request) =>
    (request['production'] as Map?)?.cast<String, dynamic>() ?? const {};

/// The real profit of a run: the approved price before VAT minus what the run
/// cost (production.actualCost.total). Null until both are known.
int? profit(Map<String, dynamic> request, Map<String, dynamic>? approvedQuote) {
  final cost = (productionOf(request)['actualCost'] as Map?)?['total'];
  if (approvedQuote == null || cost is! int || !owes('${request['status']}')) return null;
  return quoteMoney({...approvedQuote, 'vatPercent': 0}).net - cost;
}

/// One month or quarter of the Money tab's report. Sales are the orders the client
/// approved in it (price before VAT after discount, VAT, discount given, what Gift
/// Factory says they cost); received is the money that came in, by its day.
class Period {
  Period(this.start, this.label);
  final DateTime start;
  final String label;
  final sales = <({String requestId, DateTime at, int net, int vat, int discount, int? cost})>[];
  final payments = <({String requestId, DateTime at, int amount, String method})>[];
  int get net => sales.fold(0, (a, s) => a + s.net);
  int get vat => sales.fold(0, (a, s) => a + s.vat);
  int get discount => sales.fold(0, (a, s) => a + s.discount);
  int get received => payments.fold(0, (a, p) => a + p.amount);

  /// Profit of the sales whose cost is known (Gift Factory's actual cost), and how many those are.
  ({int profit, int counted}) get profit {
    final known = sales.where((s) => s.cost != null);
    return (profit: known.fold(0, (a, s) => a + s.net - s.cost!), counted: known.length);
  }
}

/// The last [count] months (or quarters, newest first) up to [now].
List<Period> periodReport({
  required bool quarterly,
  required DateTime now,
  required Iterable<({String requestId, DateTime at, int net, int vat, int discount, int? cost})> sales,
  required Iterable<({String requestId, DateTime at, int amount, String method})> payments,
  int count = 6,
}) {
  final step = quarterly ? 3 : 1;
  final first = DateTime(now.year, quarterly ? (now.month - 1) ~/ 3 * 3 + 1 : now.month);
  final periods = [
    for (var i = 0; i < count; i++)
      () {
        final s = DateTime(first.year, first.month - i * step);
        return Period(s, quarterly ? 'Q${(s.month - 1) ~/ 3 + 1}/${s.year}' : '${s.month.toString().padLeft(2, '0')}/${s.year}');
      }(),
  ];
  // The newest period that started by then; older than the oldest one shown: left out.
  Period? of(DateTime at) => periods.where((p) => !at.isBefore(p.start)).firstOrNull;
  for (final s in sales) {
    of(s.at)?.sales.add(s);
  }
  for (final p in payments) {
    of(p.at)?.payments.add(p);
  }
  return periods;
}

/// "2026-11-12" → "12.11".
String isoDay(Object? day) {
  final p = '${day ?? ''}'.split('-');
  return p.length == 3 ? '${p[2]}.${p[1]}' : '';
}

/// The names on a flag from a request title: "שרון וגל" → [שרון, גל]. Splits at
/// commas, &, +, "and", and the Hebrew "ו" stuck to the next name (one ו only, so
/// "דנה וויקי" keeps ויקי). shortcut: "דנה ויקי" (no connector meant) comes out
/// דנה, יקי; fixed by hand in the Flag Maker, add a names field if it keeps happening.
List<String> namesFrom(String title) => title
    .split(RegExp(r'\s*[,&+]\s*|\s+(?:and|ו)\s+|\s+ו(?=\S)', caseSensitive: false))
    .map((n) => n.trim())
    .where((n) => n.isNotEmpty)
    .toList();

// --- payment requests (server/app/billing.py makes them; the app sends, pays and trashes them) ---

final billsRef = _db.collection('bills');

/// The studio's business, bank, Bit and PayBox details and the monthly billing day.
final billingRef = _db.doc('config/billing');
const billStates = {'open': 'פתוחה', 'paid': 'שולמה', 'replaced': 'הוחלפה'};
const trashDays = 30; // billing.TRASH_DAYS

String billUrl(String token) => '${AppConfig.serverUrl}/b/$token';

/// The bill on WhatsApp: [url] is the customer's portal, where the bill waits with its pay button.
/// [payUrl] (the bill's own page) is given for a customer who signs in: the portal link
/// invites them to join, the bill's page lets them pay without it.
String billMessage(Map<String, dynamic> b, String url, {String? payUrl}) {
  final name = '${b['customerName'] ?? ''}', due = shekel(b['due'] as int);
  if (payUrl != null) {
    return b['lang'] == 'en'
        ? 'Hi $name, payment request no. ${b['number']} for $due is waiting in your personal area. '
            'Sign up once with Google and every project, payment request and receipt of yours is in one place:\n$url\n'
            'Rather not sign up now? Pay directly here:\n$payUrl\nThank you!'
        : 'שלום $name, דרישת תשלום מס׳ ${b['number']} על סך $due מחכה לך באזור האישי. '
            'נרשמים פעם אחת עם Google, ומאז כל הפרויקטים, דרישות התשלום והקבלות שלך במקום אחד:\n$url\n'
            'מעדיפים לא להירשם עכשיו? אפשר לשלם ישירות כאן:\n$payUrl\nתודה רבה!';
  }
  return b['lang'] == 'en'
      ? 'Hi $name, payment request no. ${b['number']} for $due is waiting on your personal page, with the details and the ways to pay:\n$url\nThank you!'
      : 'שלום $name, דרישת תשלום מס׳ ${b['number']} על סך $due מחכה לך בדף האישי, עם הפירוט ואפשרויות התשלום:\n$url\nתודה רבה!';
}

/// Makes the customer's bill now (or returns the open one if nothing changed); null when nothing is owed.
/// [requestIds]: a bill for exactly these orders, paid ones too, for a receipt on a payment made before bills.
Future<Map<String, dynamic>?> billNow(String customerId, {List<String>? requestIds}) async {
  try {
    return await server('POST', '/studio/customers/$customerId/bill', requestIds == null ? null : {'requestIds': requestIds});
  } on ServerException catch (e) {
    if (e.status == 409) return null;
    rethrow;
  }
}

typedef Receipt = ({String to, String number, String url});

/// The receipt app's message: "לכבוד : X", "קיבלת קבלה מספר : N", a line with the issuer, the link.
Receipt? parseReceipt(String text) {
  final url = RegExp(r'https://\S+').firstMatch(text)?[0];
  if (url == null) return null;
  return (
    to: RegExp(r'לכבוד\s*:?\s*(.+)').firstMatch(text)?[1]?.trim() ?? '',
    number: RegExp(r'קבלה\s*(?:מספר|מס[׳\x27]?)\s*:?\s*(\d+)').firstMatch(text)?[1] ?? '',
    url: url,
  );
}

/// The one customer whose name is [to] (spaces and case aside), else the one name containing it or contained in it.
String? matchCustomer(String to, Map<String, String> names) {
  String n(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
  final t = n(to);
  if (t.isEmpty) return null;
  for (final test in [(String x) => x == t, (String x) => x.isNotEmpty && (x.contains(t) || t.contains(x))]) {
    final hits = names.entries.where((e) => test(n(e.value))).toList();
    if (hits.length == 1) return hits.first.key;
    if (hits.length > 1) return null;
  }
  return null;
}

/// Each request's status and what it still owes now (payments may have come in since the bill).
Future<Map<String, ({String status, int left})>> leftNow(String customerId) async {
  final rs = await requestsRef.where('customerId', isEqualTo: customerId).get();
  final qs = await quotesRef.where('customerId', isEqualTo: customerId).get();
  final ps = await paymentsRef.where('customerId', isEqualTo: customerId).get();
  final totals = {for (final q in qs.docs) q.id: quoteMoney(q.data()).total};
  final paid = <String, int>{};
  for (final p in ps.docs) {
    paid['${p['requestId']}'] = (paid['${p['requestId']}'] ?? 0) + (p['amount'] as int);
  }
  return {
    for (final r in rs.docs)
      r.id: (
        status: '${r['status']}',
        left: leftToPay(totals[r.data()['approvedQuoteId'] ?? r.data()['quoteId']] ?? 0, paid[r.id] ?? 0),
      ),
  };
}

/// The payments a receipt for [bill] logs: each line's due, but never more than the request still owes [now].
List<({String requestId, int amount})> billPayments(Map<String, dynamic> bill, Map<String, ({String status, int left})> now) => [
      for (final l in (bill['lines'] as List).cast<Map>())
        if (now[l['requestId']] case final cur? when min(l['due'] as int, cur.left) > 0)
          (requestId: l['requestId'] as String, amount: min(l['due'] as int, cur.left)),
    ];

/// The receipt pasted on a bill: logs a payment per line, settles delivered requests, marks the bill paid. One write.
Future<void> payBill(Doc bill, Receipt receipt, {required String method, required DateTime at}) async {
  final b = bill.data()!;
  final now = await leftNow('${b['customerId']}');
  final batch = _db.batch();
  for (final p in billPayments(b, now)) {
    batch.set(paymentsRef.doc(), {
      'requestId': p.requestId,
      'customerId': b['customerId'],
      'amount': p.amount,
      'method': method,
      'note': 'קבלה ${receipt.number} · דרישה ${b['number']}',
      'at': Timestamp.fromDate(at),
      'createdAt': FieldValue.serverTimestamp(),
    });
    final cur = now[p.requestId]!;
    batch.update(requestsRef.doc(p.requestId), {
      if (settles(status: cur.status, left: cur.left, amount: p.amount)) 'status': 'paid',
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }
  batch.update(bill.reference, {
    'state': 'paid',
    'paidAt': Timestamp.fromDate(at),
    'receipt': {'number': receipt.number, 'url': receipt.url, 'to': receipt.to},
  });
  await batch.commit();
}

/// To the trash (the Pi deletes it after [trashDays] days) or back; the link stops working while there.
Future<void> trashBill(Doc bill, bool trash) =>
    bill.reference.update({'deletedAt': trash ? FieldValue.serverTimestamp() : null});
