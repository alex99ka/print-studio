import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:print_studio/core/errors.dart';
import 'package:print_studio/studio/website.dart';
import 'package:print_studio/ui/theme.dart';
import 'package:print_studio/ui/website_view.dart';

void main() {
  test('a slug is lowercase letters, digits and dashes, up to 60', () {
    expect(validSlug('cart-coin'), isTrue);
    expect(validSlug('a' * 60), isTrue);
    for (final bad in ['', 'Cart-Coin', 'cart coin', 'cart_coin', 'מטבע', '../x', 'a' * 61]) {
      expect(validSlug(bad), isFalse, reason: bad);
    }
  });

  test('an override that drops a placeholder is noticed; an empty one follows the code', () {
    expect(placeholders('View {n} of {total}'), {'{n}', '{total}'});
    expect(missingPlaceholders('ברוכים השבים, {name}', 'שלום {name}!'), isEmpty);
    expect(missingPlaceholders('ברוכים השבים, {name}', 'שלום!'), {'{name}'});
    expect(missingPlaceholders('View {n} of {total}', 'תמונה {n}'), {'{total}'});
    expect(missingPlaceholders('ברוכים השבים, {name}', '  '), isEmpty);
    expect(missingPlaceholders('בלי כלום', 'משהו אחר'), isEmpty);
  });

  test('texts group by the first part of their key', () {
    expect(textGroup('how.steps.0.t'), 'how');
    expect(textGroup('statement'), 'statement');
  });

  test('a picture URL carries its version', () {
    expect(pictureUrl('tulip', 'photo.jpg', 1763200000), endsWith('/gifts/tulip/photo.jpg?v=1763200000'));
    expect(pictureUrl('tulip', 'still.jpg', null), endsWith('/gifts/tulip/still.jpg'));
  });

  test('a lead fills the new request: guests, wedding day, notes', () {
    final today = DateTime(2026, 11, 15, 13);
    final r = requestFromLead(
        {'guests': 200, 'wedding_date': '2027-04-01', 'gifts': ['tulip', 'cart-coin'], 'call_time': 'evening'}, today);
    expect(r.qty, 200);
    expect(r.deadline, DateTime(2027, 4, 1));
    expect(r.notes, 'פנייה מהאתר · חתונה ב-1.4.2027 · אהבו: tulip, cart-coin · נוח לדבר: בערב');
    // A wedding today still fits the calendar; one that passed, or too far, stays in the notes only.
    expect(requestFromLead({'wedding_date': '2026-11-15', 'call_time': 'any'}, today).deadline, DateTime(2026, 11, 15));
    final past = requestFromLead({'guests': null, 'wedding_date': '2026-01-01', 'gifts': [], 'call_time': 'any'}, today);
    expect((past.qty, past.deadline), (1, null));
    expect(past.notes, contains('1.1.2026'));
    expect(requestFromLead({'wedding_date': '2029-01-01', 'call_time': 'any'}, today).deadline, isNull);
    expect(r.gift, isNull);
  });

  test('a lead sent from a product brings its slug and amount (B3)', () {
    final r = requestFromLead({'guests': 200, 'qty': 120, 'gift': 'cart-coin', 'call_time': 'any'}, DateTime(2026, 11, 17));
    expect((r.qty, r.gift), (120, 'cart-coin'));
    expect(r.notes, 'פנייה מהאתר · 200 אורחים · נוח לדבר: לא משנה מתי');
    expect(requestFromLead({'gift': 'Not A Slug', 'qty': 0, 'call_time': 'any'}, DateTime(2026, 11, 17)).gift, isNull);
  });

  test('lead days from the measured print time (B13)', () {
    expect(suggestedLeadDays(30, 7.5), 3); // 225 minutes: one day + 2
    expect(suggestedLeadDays(500, 12), 7); // 100 hours: 5 days + 2
  });

  test('the server\'s answers become website codes, with its words', () {
    String code(int status, [String body = '{"detail":"x"}']) => siteError(ServerException(status, body)).code;
    expect(code(422), 'W1');
    expect(code(409), 'W2');
    expect(code(413), 'W3');
    expect(code(415), 'W3');
    expect(code(503), 'W4');
    expect(code(502), 'W5');
    expect(code(404), 'W6');
    // Not our server's JSON: the Pi or the tunnel is down, the usual codes.
    expect(code(503, '<html>'), 'S1');
    expect(code(502, ''), 'S1');
    expect(code(403), 'A1');
    expect(siteError(const ServerException(422, '{"detail":"למוצר עוד אין תמונה"}')).why, contains('למוצר עוד אין תמונה'));
    expect(
        siteError(const ServerException(422, '{"detail":[{"loc":["body","name","ru"],"msg":"Field required"}]}')).why,
        contains('name.ru: Field required'));
  });

  Widget app(Widget home) => MaterialApp(
      theme: appTheme(Brightness.light), home: Directionality(textDirection: TextDirection.rtl, child: home));

  testWidgets('the website tab says why it is empty when the build has no server', (t) async {
    await t.pumpWidget(app(const Scaffold(body: WebsiteView())));
    await t.pump();
    expect(find.text('פניות'), findsOneWidget);
    expect(find.textContaining('קוד F1'), findsOneWidget);
    expect(find.text('ניסיון נוסף'), findsOneWidget);
  });

  testWidgets('a new product saves only once every field is right; on a phone nothing overflows', (t) async {
    await t.binding.setSurfaceSize(const Size(360, 2400)); // a phone's width, tall enough to build the whole form
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app(const GiftPage()));
    FilledButton save() => t.widget(find.widgetWithText(FilledButton, 'הוספה לאתר'));
    expect(save().onPressed, isNull);
    expect(find.textContaining('מזהה: אותיות אנגליות'), findsOneWidget);
    final fields = find.byType(TextField);
    await t.enterText(fields.at(0), 'Cart Coin');
    for (var i = 1; i <= 6; i++) {
      await t.enterText(fields.at(i), 'x');
    }
    await t.pump();
    expect(save().onPressed, isNull); // the slug is still wrong
    await t.enterText(fields.at(0), 'cart-coin');
    await t.pump();
    expect(save().onPressed, isNotNull);
    // No picture yet: it cannot be shown on the site.
    final shown = t.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'מוצג באתר'));
    expect((shown.value, shown.onChanged), (false, null));
  });

  testWidgets('an existing product shows the renderer\'s fields and its pictures, read-only', (t) async {
    await t.binding.setSurfaceSize(const Size(360, 2400));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app(GiftPage(gift: {
      'slug': 'tulip', 'kind': 'table', 'min_qty': 30, 'lead_days': 14, 'sort': 100, 'published': true, 'feature': false,
      'name': {'he': 'צבעוני', 'en': 'Tulip', 'ru': 'Тюльпан'}, 'text': {'he': 'א', 'en': 'a', 'ru': 'я'},
      'size_mm': [27, 42, 5], 'spin': {'cols': 24, 'rows': 7, 'start': [1, 0], 'tile': 640},
      'images': {'photo.jpg': 1763200000, 'still.jpg': 1763200000, 'spin-0.jpg': 1763200000},
    })));
    await t.pump();
    expect(find.textContaining('27 × 42 × 5'), findsOneWidget);
    expect(find.text('החלפה'), findsOneWidget);
    expect(find.text('הסרה'), findsOneWidget);
    expect(find.textContaining('spin-0.jpg'), findsOneWidget);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'שמירה')).onPressed, isNotNull);
  });
}
