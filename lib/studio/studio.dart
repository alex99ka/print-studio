import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_selector/file_selector.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../core/errors.dart';
import '../core/server.dart';

/// Print Studio's records. The app writes customers, requests, quotes, its
/// own comments and publishing (checked by firestore.rules); the Pi writes
/// versions, the customer's comments and approvals (server/app/studio.py).

typedef Doc = DocumentSnapshot<Map<String, dynamic>>;

final _db = FirebaseFirestore.instance;
final customersRef = _db.collection('customers');
final requestsRef = _db.collection('requests');
final versionsRef = _db.collection('versions');
final quotesRef = _db.collection('quotes');
final commentsRef = _db.collection('comments');

const statuses = ['draft', 'waiting', 'approved', 'printing', 'ready', 'delivered', 'paid'];
const statusLabels = {
  'draft': 'טיוטה',
  'waiting': 'ממתין לאישור',
  'approved': 'אושר',
  'printing': 'בהדפסה',
  'ready': 'מוכן',
  'delivered': 'נמסר',
  'paid': 'שולם',
};
const defaultVatPercent = 18;

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

Future<String> addRequest({required Doc customer, required String title, required int qty, String notes = ''}) async {
  final ref = await requestsRef.add({
    'customerId': customer.id,
    'customerName': customer.data()?['name'] ?? '',
    'title': title.trim(),
    'qty': qty,
    'notes': notes.trim(),
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

Future<void> setStatus(Doc request, String status) =>
    request.reference.update({'status': status, 'updatedAt': FieldValue.serverTimestamp()});

// --- the Pi -------------------------------------------------------------------------

/// Which upload field a picked file is, by its name, as the Flag Maker names them.
String? uploadField(String fileName) {
  final n = fileName.toLowerCase();
  if (n.endsWith('.png')) return 'preview';
  if (n.endsWith('.3mf')) return 'model';
  if (n.endsWith('.json')) return 'recipe';
  if (n.endsWith('.glb')) return n.contains('assembled') ? 'assembled' : 'plate';
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

/// A new key for the Flag Maker; the previous one stops working.
Future<String> pairFlagMaker() async => (await server('POST', '/studio/flagmaker-key'))['key'] as String;
