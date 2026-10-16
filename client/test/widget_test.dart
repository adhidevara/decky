import 'package:decky_client/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('layar awal tampil tanpa plugin platform', (tester) async {
    // Di lingkungan test, secure storage dan mDNS tidak tersedia. Aplikasi
    // harus tetap menggambar sesuatu yang masuk akal, bukan layar putih.
    await tester.pumpWidget(const DeckyApp());
    await tester.pump();

    expect(find.text('Decky'), findsOneWidget);
  });
}
