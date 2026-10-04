import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/account.dart';
import 'package:relay/model.dart';
import 'package:relay/storage.dart';

class SettingsStore extends RelayStore {
  RelayState state = RelayState();

  @override
  Future<RelayState> load() async => RelayState.fromJson(state.toJson());

  @override
  Future<void> save(RelayState value) async {
    state = RelayState.fromJson(value.toJson());
  }
}

void main() {
  testWidgets('sign-in offers Google and email choices on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(home: AuthForm(onLocal: () {})));

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('or use email'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local family settings save names and numbered defaults', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = SettingsStore();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => LocalAccountSettings(
                  store: store,
                  initialChildNames: store.state.childNames,
                  initialPersonalTimeEnabled: store.state.personalTimeEnabled,
                  initialDailyPersonalHours: store.state.dailyPersonalHours,
                  onSignIn: () {},
                ),
              ),
            ),
            child: const Text('Open settings'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '3'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Ava');
    await tester.enterText(fields.at(1), '');
    await tester.enterText(fields.at(2), 'Noah');
    await tester.ensureVisible(find.text('Daily personal-time agreement'));
    await tester.tap(find.text('Daily personal-time agreement'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('3 hours'));
    await tester.tap(find.text('3 hours'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 hours').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save settings'));
    await tester.tap(find.text('Save settings'));
    await tester.pumpAndSettle();

    expect(store.state.childNames, ['Ava', 'Baby 2', 'Noah']);
    expect(store.state.personalTimeEnabled, isTrue);
    expect(store.state.dailyPersonalHours, 5);
    expect(tester.takeException(), isNull);
  });

  test('personal-time agreement uses the selected number of hours', () {
    expect(personalTimeAgreement(1), contains('1 hour of personal time'));
    expect(personalTimeAgreement(3), contains('3 hours of personal time'));
    expect(personalTimeAgreement(3), contains('time bank'));
  });
}
