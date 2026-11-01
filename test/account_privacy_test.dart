import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/account_privacy.dart';

void main() {
  test('only an explicit deletion action opens the web deletion flow', () {
    expect(
      accountDeletionRequested(
        Uri.parse('https://relay.luhlo.com/?action=delete-account'),
      ),
      isTrue,
    );
    expect(
      accountDeletionRequested(
        Uri.parse('https://relay.luhlo.com/?action=delete'),
      ),
      isFalse,
    );
    expect(
      accountDeletionRequested(Uri.parse('https://relay.luhlo.com/')),
      isFalse,
    );
  });

  testWidgets(
    'deletion needs exact confirmation and a final explicit approval',
    (tester) async {
      var deletions = 0, cleanups = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AccountDeletionPage(
            onDeleted: () async {
              cleanups++;
            },
            onDone: () {},
            deleteAccount: () async {
              deletions++;
            },
          ),
        ),
      );
      final button = find.text('Delete my account');
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<FilledButton>(
              find
                  .ancestor(
                    of: button,
                    matching: find.byWidgetPredicate((w) => w is FilledButton),
                  )
                  .first,
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), 'delete');
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find
                  .ancestor(
                    of: button,
                    matching: find.byWidgetPredicate((w) => w is FilledButton),
                  )
                  .first,
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(deletions, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(deletions, 0);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();
      expect(deletions, 1);
      expect(cleanups, 1);
      expect(find.text('Your account was deleted'), findsOneWidget);
      expect(find.text('Delete my account'), findsNothing);
    },
  );

  testWidgets(
    'a failed deletion keeps the account signed in and permits retry',
    (tester) async {
      var attempts = 0, cleanups = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AccountDeletionPage(
            onDeleted: () async {
              cleanups++;
            },
            onDone: () {},
            deleteAccount: () async {
              attempts++;
              throw StateError('offline');
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      final button = find.text('Delete my account');
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();
      expect(attempts, 1);
      expect(cleanups, 0);
      expect(
        find.textContaining('Could not confirm account deletion'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find
                  .ancestor(
                    of: button,
                    matching: find.byWidgetPredicate((w) => w is FilledButton),
                  )
                  .first,
            )
            .onPressed,
        isNotNull,
      );
      expect(find.text('Your account was deleted'), findsNothing);
    },
  );

  testWidgets(
    'confirmed backend deletion remains successful if device cleanup fails',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AccountDeletionPage(
            onDeleted: () async {
              throw StateError('OS cleanup failed');
            },
            onDone: () {},
            deleteAccount: () async {},
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'DELETE');
      await tester.pump();
      final button = find.text('Delete my account');
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();
      expect(find.text('Your account was deleted'), findsOneWidget);
      expect(find.textContaining('Close and reopen Relay'), findsOneWidget);
      expect(find.text('Delete my account'), findsNothing);
    },
  );
}
