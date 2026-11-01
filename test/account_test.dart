import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/account.dart';
import 'package:relay/model.dart';
import 'package:relay/storage.dart';
import 'package:relay/widget_appearance.dart';

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
  testWidgets('signed-in email is labelled and read-only', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SignedInAccountEmail(email: 'parent@example.com')),
      ),
    );
    expect(find.text('Signed in as'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      'parent@example.com',
    );
    expect(find.byType(TextField), findsNothing);
  });

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

  testWidgets(
    'appearance is available without discarding unsaved child names',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = SettingsStore();
      await tester.pumpWidget(
        MaterialApp(
          home: LocalAccountSettings(
            store: store,
            initialChildNames: store.state.childNames,
            initialPersonalTimeEnabled: false,
            initialDailyPersonalHours: 3,
            onSignIn: () {},
          ),
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'Unsaved name');
      await tester.ensureVisible(find.text('Widget appearance'));
      await tester.tap(find.text('Widget appearance'));
      await tester.pumpAndSettle();
      expect(find.byType(WidgetAppearance), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Unsaved name',
      );
      expect(store.state.childNames.first, 'Baby 1');
    },
  );
}
