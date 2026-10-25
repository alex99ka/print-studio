import 'package:flutter_test/flutter_test.dart';
import 'package:print_studio/studio/studio.dart';

void main() {
  test('money matches the server (server/test_studio.py)', () {
    expect(money(18000, 2, 18), (net: 36000, vat: 6480, total: 42480));
    expect(money(1, 1, 18).vat, 0); // 0.18 agora
    expect(money(3, 1, 18).vat, 1); // 0.54 agora rounds up
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
    expect(uploadField('flag_plate.glb'), 'plate');
    expect(uploadField('flag_assembled.glb'), 'assembled');
    expect(uploadField('notes.txt'), isNull);
  });

  test('every status has a label', () {
    for (final s in statuses) {
      expect(statusLabels[s], isNotEmpty);
    }
  });
}
