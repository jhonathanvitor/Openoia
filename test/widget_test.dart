import 'package:flutter_test/flutter_test.dart';
import 'package:openoia/main.dart';

void main() {
  testWidgets('Openoia smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const VpnOpenoiaApp());
    expect(find.text('Openoia'), findsWidgets);
  });
}
