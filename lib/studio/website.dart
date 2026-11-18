import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../core/errors.dart';
import '../core/server.dart';

/// The public shop site (C:\claude projects\3d\website): its products, pictures, wording and
/// call-back requests. Everything goes through the Pi (server/app/website.py), which alone
/// holds the site's Supabase key; nothing here talks to Supabase.

const siteLangs = ['he', 'en', 'ru'];
const siteLangNames = {'he': 'עברית', 'en': 'English', 'ru': 'Русский'};
const giftKinds = {'table': 'לשולחן', 'pocket': 'לכיס', 'play': 'למשחק'};
const leadStatuses = {'new': 'חדשה', 'called': 'דיברנו', 'opened': 'נפתחה בקשה', 'dropped': 'ירדה'};
const callTimes = {'any': 'לא משנה מתי', 'morning': 'בבוקר', 'noon': 'בצהריים', 'evening': 'בערב'};

/// gifts.slug in the website's schema.sql.
bool validSlug(String s) => RegExp(r'^[a-z0-9-]{1,60}$').hasMatch(s);

/// `{name}`, `{n}`…: the site fills these in, so an override has to keep them.
Set<String> placeholders(String text) => {for (final m in RegExp(r'\{[A-Za-z]+\}').allMatches(text)) m.group(0)!};

/// The placeholders of the code's wording that [override] dropped (an empty override keeps the code's).
Set<String> missingPlaceholders(String original, String override) =>
    override.trim().isEmpty ? const {} : placeholders(original).difference(placeholders(override));

/// B13: days to make [minQty] units at the measured minutes each, on one printer around the
/// clock, plus the same 2 spare days the Pi's reminders keep (server jobs.SPARE_DAYS).
int suggestedLeadDays(int minQty, num unitMinutes) => (minQty * unitMinutes / 60 / 24).ceil() + 2;

/// The first part of a text's key: "hero" of "hero.h1".
String textGroup(String key) => key.split('.').first;

/// A picture as anyone may load it; [version] (its time on the Pi) makes a replaced picture a new URL.
String pictureUrl(String slug, String file, Object? version) =>
    '${AppConfig.serverUrl}/gifts/$slug/$file${version == null ? '' : '?v=$version'}';

/// What a new CRM request takes from a lead: the amount asked for (else the guests) as the
/// quantity, the product it was sent from, the wedding day as the deadline when the calendar
/// can show it, and the rest as notes.
({int qty, DateTime? deadline, String notes, String? gift}) requestFromLead(Map<String, dynamic> lead, DateTime today) {
  final day = DateTime.tryParse('${lead['wedding_date'] ?? ''}');
  final from = DateTime(today.year, today.month, today.day);
  final guests = lead['guests'], qty = lead['qty'], gift = '${lead['gift'] ?? ''}';
  return (
    qty: qty is int && qty > 0 ? qty : guests is int && guests > 0 ? guests : 1,
    gift: validSlug(gift) ? gift : null,
    deadline: day != null && !day.isBefore(from) && day.isBefore(DateTime(today.year + 2)) ? day : null,
    notes: [
      'פנייה מהאתר',
      if (day != null) 'חתונה ב-${day.day}.${day.month}.${day.year}',
      if (qty is int && guests is int && guests > 0) '$guests אורחים',
      if ((lead['gifts'] as List? ?? const []).isNotEmpty) 'אהבו: ${(lead['gifts'] as List).join(', ')}',
      'נוח לדבר: ${callTimes[lead['call_time']] ?? lead['call_time']}',
    ].join(' · '),
  );
}

/// The server's own words for what went wrong, from FastAPI's `detail`.
String _detail(String body) {
  try {
    final d = (jsonDecode(body) as Map)['detail'];
    if (d is String) return d;
    if (d is List) return [for (final e in d) '${(e['loc'] as List).skip(1).join('.')}: ${e['msg']}'].join('; ');
  } catch (_) {} // not the server's JSON (a proxy's page): no words to show
  return '';
}

/// The website's failures by code, with the server's words inside where it has any.
AppError siteError(ServerException e) {
  final detail = _detail(e.message);
  AppError saying(AppError base) => detail.isEmpty ? base : AppError(base.code, '${base.why}: $detail', base.todo);
  return switch (e.status) {
    400 || 422 => saying(Errors.siteInvalid),
    409 => Errors.siteSlugTaken,
    413 || 415 => Errors.sitePicture,
    404 when detail.isNotEmpty => Errors.siteGone,
    503 when detail.isNotEmpty => Errors.siteNotSetUp,
    502 when detail.isNotEmpty => saying(Errors.siteRefused),
    _ => classify(e),
  };
}

Future<Map<String, dynamic>> _site(String method, String path, [Map<String, dynamic>? body]) async {
  if (!hasServer) throw Errors.noServer;
  try {
    return await server(method, path, body);
  } on ServerException catch (e) {
    throw siteError(e);
  }
}

List<Map<String, dynamic>> _rows(Object? list) => [for (final r in list as List) Map<String, dynamic>.from(r as Map)];

Future<List<Map<String, dynamic>>> siteGifts() async => _rows((await _site('GET', '/website/gifts'))['gifts']);

/// [slug] only for a new product; the fields are the ones Alex edits (server: Gift).
Future<void> saveGift(Map<String, dynamic> fields, {String? newSlug, String? slug}) => newSlug != null
    ? _site('POST', '/website/gifts', {...fields, 'slug': newSlug})
    : _site('PUT', '/website/gifts/$slug', fields);

Future<void> deleteGift(String slug) => _site('DELETE', '/website/gifts/$slug');

/// Uploads Alex's picture of the gift; the server turns it into photo.jpg.
Future<void> uploadPhoto(String slug, String fileName, Uint8List bytes) async {
  if (!hasServer) throw Errors.noServer;
  final req = http.MultipartRequest('POST', Uri.parse('${AppConfig.serverUrl}/website/gifts/$slug/photo'));
  final token = await FirebaseAuth.instance.currentUser?.getIdToken();
  if (token != null) req.headers['Authorization'] = 'Bearer $token';
  req.files.add(http.MultipartFile.fromBytes('file', bytes, filename: fileName));
  final res = await http.Response.fromStream(await req.send().timeout(const Duration(minutes: 3)));
  if (res.statusCode >= 400) throw siteError(ServerException(res.statusCode, res.body));
}

Future<void> deletePhoto(String slug) => _site('DELETE', '/website/gifts/$slug/photo');

/// A new key for the shop pictures sender (Gift Factory › Shop pictures); its previous one stops working.
Future<String> pairRenderScript() async => (await _site('POST', '/website/render-key'))['key'] as String;

typedef Wording = Map<String, Map<String, String>>;

Wording _wording(Object? m) => {
      for (final e in (m as Map).entries) '${e.key}': {for (final l in (e.value as Map).entries) '${l.key}': '${l.value}'},
    };

/// The code's wording per key, and what was changed from the CRM.
Future<({Wording defaults, Wording overrides})> siteTexts() async {
  final r = await _site('GET', '/website/texts');
  return (defaults: _wording(r['defaults']), overrides: _wording(r['overrides']));
}

/// Saves the override; a language left empty follows the code. Returns what is now overridden.
Future<Map<String, String>> saveText(String key, Map<String, String> value) async =>
    {for (final e in ((await _site('PUT', '/website/texts/$key', value))['value'] as Map).entries) '${e.key}': '${e.value}'};

Future<void> resetText(String key) => _site('DELETE', '/website/texts/$key');

Future<List<Map<String, dynamic>>> siteLeads() async => _rows((await _site('GET', '/website/leads'))['leads']);

Future<void> setLeadStatus(Object id, String status) => _site('POST', '/website/leads/$id/status', {'status': status});
