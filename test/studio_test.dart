import 'package:flutter_test/flutter_test.dart';
import 'package:print_studio/studio/studio.dart';

void main() {
  test('money matches the server (server/test_studio.py)', () {
    expect(money(18000, 2, 18), (net: 36000, vat: 6480, total: 42480));
    expect(money(1, 1, 18).vat, 0); // 0.18 agora
    expect(money(3, 1, 18).vat, 1); // 0.54 agora rounds up
    expect(money(18000, 2, 0), (net: 36000, vat: 0, total: 36000)); // VAT off
    expect(money(0, 5, 18).total, 0);
  });

  test('shekel formats agorot', () {
    expect(shekel(42480), '₪424.80');
    expect(shekel(5), '₪0.05');
    expect(shekel(123456789), '₪1,234,567.89');
    expect(shekel(-100), '-₪1.00');
  });

  test('parseShekel reads what people type, refuses the rest', () {
    expect(parseShekel('180'), 18000);
    expect(parseShekel('180.5'), 18050);
    expect(parseShekel('1,234.50'), 123450);
    expect(parseShekel('₪ 99'), 9900);
    expect(parseShekel(shekel(42480).replaceAll(RegExp('[₪,]'), '')), 42480); // the quote dialog's round trip
    for (final bad in ['', 'abc', '1.234', '-5', '1e3']) {
      expect(parseShekel(bad), isNull, reason: bad);
    }
  });

  test('portal tokens: 22 URL-safe characters, never the same', () {
    final a = newPortalToken(), b = newPortalToken();
    expect(a.length, 22);
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(a), isTrue);
    expect(a, isNot(b));
  });

  test('WhatsApp gets the number in international form', () {
    expect(whatsapp('052-123-4567', 'שלום').toString(), startsWith('https://wa.me/972521234567?text='));
    expect(whatsapp('+972 52 123 4567', 'x').path, '/972521234567');
    expect(whatsapp('', 'x').path, '/');
  });

  test('picked files map to the upload fields the Pi expects', () {
    expect(uploadField('flag_v557.PNG'), 'preview');
    expect(uploadField('flag.3mf'), 'model');
    expect(uploadField('flag.json'), 'recipe');
    expect(uploadField('flag_plate.glb'), null); // meshes never reach the client
    expect(uploadField('notes.txt'), isNull);
  });

  test('every status has a label', () {
    for (final s in statuses) {
      expect(statusLabels[s], isNotEmpty);
    }
  });

  test('what is owed: only after approval, never below zero', () {
    expect(owes('draft'), isFalse);
    expect(owes('waiting'), isFalse);
    for (final st in ['approved', 'printing', 'ready', 'delivered', 'paid']) {
      expect(owes(st), isTrue, reason: st);
    }
    expect(leftToPay(42480, 10000), 32480);
    expect(leftToPay(42480, 42480), 0);
    expect(leftToPay(42480, 50000), 0); // overpaid
  });

  test('real profit: the approved price before VAT minus Gift Factory\'s actual cost', () {
    const quote = {'unit': 27100, 'qty': 105, 'vatPercent': 18};
    Map<String, dynamic> request(String status, Object? cost) => {
          'status': status,
          if (cost != null) 'production': {'actualCost': {'total': cost}},
        };
    expect(profit(request('delivered', 2272000), quote), 2845500 - 2272000); // VAT is not profit
    expect(profit(request('paid', 3000000), quote), -154500); // a loss shows as one
    expect(profit(request('delivered', null), quote), isNull); // no report yet: "—"
    expect(profit(request('delivered', 1000), null), isNull);
    expect(profit(request('waiting', 1000), quote), isNull); // an offer, not a sale
    expect(productionOf({}), isEmpty);
  });

  test("a customer's balance: approved orders only, a deposit counts as paid, overpaying one order doesn't pay another", () {
    final b = balance([
      (status: 'approved', total: 42480, paid: 10000),
      (status: 'delivered', total: 20000, paid: 25000), // overpaid by 50
      (status: 'waiting', total: 99900, paid: 5000), // an offer with a deposit
      (status: 'printing', total: null, paid: 0), // no price yet
    ]);
    expect(b, (billed: 62480, paid: 40000, left: 32480));
    expect(balance(const []), (billed: 0, paid: 0, left: 0));
  });

  test('deadlines: a day, counted in calendar days, gone once delivered', () {
    final today = DateTime(2026, 10, 29, 23, 30); // late in the day still counts as the 29th
    expect(isoDate(DateTime(2026, 3, 5)), '2026-03-05');
    expect(daysLeft({'deadline': '2026-11-01', 'status': 'printing'}, today), 3);
    expect(daysLeft({'deadline': '2026-10-29', 'status': 'approved'}, today), 0);
    expect(daysLeft({'deadline': '2026-10-27', 'status': 'ready'}, today), -2);
    expect(daysLeft({'deadline': '2026-10-27', 'status': 'delivered'}, today), isNull);
    expect(daysLeft({'status': 'draft'}, today), isNull);
    expect(daysLeft({'deadline': null, 'status': 'draft'}, today), isNull);
    // Across the clocks going back (25.10.2026 in Israel) still whole days.
    expect(daysLeft({'deadline': '2026-10-26', 'status': 'draft'}, DateTime(2026, 10, 24)), 2);
    expect([for (final n in [0, 1, 4, -1, -3]) daysLeftText(n)], ['היום', 'מחר', 'בעוד 4 ימים', 'עבר אתמול', 'עבר לפני 3 ימים']);
  });

  test("print days ahead from Gift Factory's numbers, as the Pi counts them", () {
    Map<String, dynamic> r(num? hours, {int done = 0, int total = 0}) => {
          'production': {'quote': {'printHours': hours}, 'progress': {'platesDone': done, 'platesTotal': total}},
        };
    expect(printDaysLeft({}), 1); // a microphone flag
    expect(printDaysLeft(r(7 * 24)), 7);
    expect(remindDays(r(7 * 24)), 9); // a phone stand: 9 days before
    expect(printDaysLeft(r(70.5)), 3);
    expect(printDaysLeft(r(7 * 24, done: 4, total: 7)), 3);
    expect(printDaysLeft(r(7 * 24, done: 7, total: 7)), 0);
  });

  test('isoDay shows a contract date the way the app writes days', () {
    expect(isoDay('2026-11-12'), '12.11');
    expect(isoDay(null), '');
    expect(isoDay('soon'), '');
  });

  test('names from a request title: the Hebrew "and" is not part of a name', () {
    expect(namesFrom('שרון וגל'), ['שרון', 'גל']);
    expect(namesFrom('שרון ו גל'), ['שרון', 'גל']);
    expect(namesFrom('דנה, רון ויעל'), ['דנה', 'רון', 'יעל']);
    expect(namesFrom('דנה וויקי'), ['דנה', 'ויקי']);
    expect(namesFrom('אנה מריה וגל'), ['אנה מריה', 'גל']);
    expect(namesFrom('Dan & Noa'), ['Dan', 'Noa']);
    expect(namesFrom('ורד'), ['ורד']);
  });

  test('spin sheet: one long row of turns, or Gift Factory views a row per height', () {
    expect(spinSheetOf(null), (6, 6, 36, 0));
    expect(spinSheetOf({'spinGrid': 10}), (10, 10, 100, 0));
    expect(
        spinSheetOf({
          'views': {
            'cols': 24,
            'pitches': [75, 50, 25, 0, -25, -50, -75],
            'start': [2, 0],
            'tabs': ['Plate 1'],
          }
        }),
        (24, 7, 24, 48));
  });
}
