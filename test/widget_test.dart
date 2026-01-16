import 'package:flutter_test/flutter_test.dart';

import 'package:sirius_porteria/main.dart';

void main() {
  testWidgets('App starts with loading screen', (WidgetTester tester) async {
    await tester.pumpWidget(const SiriusPorteriaApp());

    expect(find.text('Cargando...'), findsOneWidget);
  });
}
