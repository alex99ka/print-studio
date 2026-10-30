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

/// Days of printing still ahead: Gift Factory's printHours less the plates done; one day
/// without its numbers (a microphone flag). Same as print_days_left in server/app/jobs.py.
int printDaysLeft(Map<String, dynamic> r) {
  final p = productionOf(r);
  final hours = ((p['quote'] as Map?)?['printHours'] as num?)?.toDouble() ?? 0;
  if (hours <= 0) return 1;
  final prog = (p['progress'] as Map?) ?? const {};
  final total = (prog['platesTotal'] as num?) ?? 0, done = (prog['platesDone'] as num?) ?? 0;
  final ahead = total > 0 ? hours * (total - done).clamp(0, total) / total : hours;
  return (ahead / 24).ceil();
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

/// Agorot in, agorot out; VAT rounded half up to the agora, exactly like
/// money() in server/app/studio.py (the portal shows the server's numbers).
({int net, int vat, int total}) money(int unit, int qty, int vatPercent) {
  final net = unit * qty;
  final vat = (net * vatPercent + 50) ~/ 100;
  return (net: net, vat: vat, total: net + vat);
}

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

// --- writes -------------------------------------------------------------------------

Future<void> addCustomer({required String name, required String phone, required String lang}) =>
    customersRef.add({
      'name': name.trim(),
      'phone': phone.trim(),
      'lang': lang,
      'portalToken': newPortalToken(),
      'createdAt': FieldValue.serverTimestamp(),
    });

/// A new link; the old one stops working at once.
Future<void> replacePortalLink(Doc customer) =>
    customer.reference.update({'portalToken': newPortalToken()});

Future<String> addRequest(
    {required Doc customer, required String title, required int qty, String notes = '', DateTime? deadline}) async {
  final ref = await requestsRef.add({
    'customerId': customer.id,
    'customerName': customer.data()?['name'] ?? '',
    'title': title.trim(),
    'qty': qty,
    'notes': notes.trim(),
    if (deadline != null) 'deadline': isoDate(deadline),
    'status': 'draft',
    'latestVersion': 0,
    'createdAt': FieldValue.serverTimestamp(),
    'updatedAt': FieldValue.serverTimestamp(),
  });
  return ref.id;
}

/// The customer sees this version from now on, and the request waits for them.
Future<void> publish(Doc request, Doc version) {
  final b = _db.batch()
    ..update(version.reference, {'state': 'published', 'publishedAt': FieldValue.serverTimestamp()})
    ..update(request.reference, {
      'publishedVersionId': version.id,
      'status': 'waiting',
      'updatedAt': FieldValue.serverTimestamp(),
    });
  return b.commit();
}

/// A new quote replaces the current one; quotes are never edited.
Future<void> addQuote(Doc request,
    {required int unit, required int qty, required int vatPercent, required String note}) {
  final q = quotesRef.doc();
  final b = _db.batch()
    ..set(q, {
      'requestId': request.id,
      'customerId': request.data()?['customerId'],
      'unit': unit,
      'qty': qty,
      'vatPercent': vatPercent,
      'note': note.trim(),
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
Future<void> addPayment(Doc request, {required int amount, required String method, required DateTime at, String note = ''}) =>
    paymentsRef.add({
      'requestId': request.id,
      'customerId': request.data()?['customerId'],
      'amount': amount,
      'method': method,
      'note': note.trim(),
      'at': Timestamp.fromDate(at),
      'createdAt': FieldValue.serverTimestamp(),
    });

/// [day] null clears it.
Future<void> setDeadline(Doc request, DateTime? day) => request.reference
    .update({'deadline': day == null ? null : isoDate(day), 'updatedAt': FieldValue.serverTimestamp()});

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
Map<String, dynamic> productionOf(Map<String, dynamic> request) =>
    (request['production'] as Map?)?.cast<String, dynamic>() ?? const {};

/// The real profit of a run: the approved price before VAT minus what the run
/// cost (production.actualCost.total). Null until both are known.
int? profit(Map<String, dynamic> request, Map<String, dynamic>? approvedQuote) {
  final cost = (productionOf(request)['actualCost'] as Map?)?['total'];
  if (approvedQuote == null || cost is! int || !owes('${request['status']}')) return null;
  return money(approvedQuote['unit'] as int, approvedQuote['qty'] as int, 0).net - cost;
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
