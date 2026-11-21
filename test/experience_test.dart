import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/app_theme.dart';
import 'package:relay/experience.dart';
import 'package:relay/release_notes.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'release announcements follow feature IDs rather than a time interval',
    () async {
      final prefs = RelayExperiencePreferences(
        await SharedPreferences.getInstance(),
      );
      expect(prefs.hasSeenRelease('feature-a'), isFalse);
      await prefs.markReleaseSeen('feature-a');
      expect(prefs.hasSeenRelease('feature-a'), isTrue);
      expect(prefs.hasSeenRelease('feature-b'), isFalse);
      await prefs.completeIntroduction();
      expect(prefs.introductionComplete, isTrue);
    },
  );

  testWidgets('first-time introduction is skippable and appears only once', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    Widget app() => MaterialApp(
      home: RelayExperienceHost(
        preferences: prefs,
        hasExistingActivity: () async => false,
        child: const Scaffold(body: Text('Relay home')),
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Make room for your time'), findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(prefs.getBool(RelayExperiencePreferences.introductionKey), isTrue);
    expect(
      prefs.getString(RelayExperiencePreferences.announcementKey),
      relayFeatureReleaseId,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Make room for your time'), findsNothing);
    expect(find.text('What’s new in Relay'), findsNothing);
  });

  testWidgets(
    'an existing user gets a small release notice without a blocking dialog',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        MaterialApp(
          home: RelayExperienceHost(
            preferences: prefs,
            hasExistingActivity: () async => true,
            child: Scaffold(
              body: FilledButton(
                onPressed: () {},
                child: const Text('Timer control'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('What’s new in Relay'), findsOneWidget);
      expect(find.text('Timer control').hitTestable(), findsOneWidget);
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      expect(find.byType(RelayWhatsNewDialog), findsOneWidget);
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 13));
    },
  );

  testWidgets('a release already announced stays quiet on later launches', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      RelayExperiencePreferences.introductionKey: true,
      RelayExperiencePreferences.announcementKey: relayFeatureReleaseId,
    });
    await tester.pumpWidget(
      MaterialApp(
        home: RelayExperienceHost(
          child: const Scaffold(body: Text('Timer running')),
          hasExistingActivity: () async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('What’s new in Relay'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'web release notes do not advertise native lock-screen controls',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: RelayWhatsNewDialog(androidSupported: false)),
        ),
      );
      expect(
        find.text('Control your timer from the lock screen'),
        findsNothing,
      );
      expect(find.text('A look that suits you'), findsOneWidget);
    },
  );

  testWidgets(
    'the introduction explains native controls only on its Android path',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RelayIntroductionDialog(androidSupported: false),
          ),
        ),
      );
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('See your daily rhythm'), findsOneWidget);
      expect(find.textContaining('native Android app'), findsOneWidget);
    },
  );

  for (final size in [const Size(320, 568), const Size(1185, 800)]) {
    for (final scale in [1.0, 2.0]) {
      for (final android in [false, true]) {
        testWidgets(
          'all introduction pages fit $size at ${scale}x text, Android $android',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await tester.pumpWidget(
              MaterialApp(
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: FilledButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) =>
                            RelayIntroductionDialog(androidSupported: android),
                      ),
                      child: const Text('Open introduction'),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('Open introduction'));
            await tester.pumpAndSettle();
            for (var page = 0; page < 3; page++) {
              final content = tester.getRect(
                find.byKey(const ValueKey('relay-introduction-content')),
              );
              // AlertDialog reduces horizontal padding at large text scales,
              // so the body may fill more than its preferred 440px width.
              expect(content.width, lessThanOrEqualTo(488));
              expect(content.left, greaterThanOrEqualTo(0));
              expect(content.right, lessThanOrEqualTo(size.width));
              final label = page == 2 ? 'Get started' : 'Next';
              final button = find.widgetWithText(FilledButton, label);
              expect(button.hitTestable(), findsOneWidget);
              final bounds = tester.getRect(button);
              expect(bounds.left, greaterThanOrEqualTo(0));
              expect(bounds.right, lessThanOrEqualTo(size.width));
              expect(bounds.top, greaterThanOrEqualTo(0));
              expect(bounds.bottom, lessThanOrEqualTo(size.height));
              expect(tester.takeException(), isNull);
              await tester.tap(button);
              await tester.pumpAndSettle();
            }
            expect(find.byType(RelayIntroductionDialog), findsNothing);
          },
        );
      }
    }
  }

  testWidgets(
    'feedback validates, submits trimmed fields once and waits for confirmation',
    (tester) async {
      final completion = Completer<void>();
      final calls = <Map<String, String?>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: RelayFeedbackPage(
            sendFeedback:
                ({required category, required message, replyEmail}) async {
                  calls.add({
                    'category': category,
                    'message': message,
                    'replyEmail': replyEmail,
                  });
                  await completion.future;
                },
          ),
        ),
      );
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Send feedback'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Send feedback'));
      await tester.pumpAndSettle();
      expect(find.text('Please add at least 10 characters.'), findsOneWidget);
      expect(calls, isEmpty);

      await tester.enterText(
        find.byType(TextFormField).at(0),
        '  Please add a larger schedule view.  ',
      );
      await tester.enterText(
        find.byType(TextFormField).at(1),
        ' parent@example.com ',
      );
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Send feedback'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Send feedback'));
      await tester.pump();
      expect(find.text('Sending…'), findsOneWidget);
      expect(
        find.text('Your feedback was sent to Relay support.'),
        findsNothing,
      );
      expect(calls, [
        {
          'category': 'problem',
          'message': 'Please add a larger schedule view.',
          'replyEmail': 'parent@example.com',
        },
      ]);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Sending…'))
            .onPressed,
        isNull,
      );
      completion.complete();
      await tester.pumpAndSettle();
      expect(
        find.text('Your feedback was sent to Relay support.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed feedback keeps the draft and permits retry', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RelayFeedbackPage(
          sendFeedback:
              ({required category, required message, replyEmail}) async {
                attempts++;
                if (attempts == 1) throw StateError('offline');
              },
        ),
      ),
    );
    await tester.enterText(
      find.byType(TextFormField).first,
      'The timer button did not respond.',
    );
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Send feedback'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send feedback'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Your message is still here.'), findsOneWidget);
    expect(find.text('The timer button did not respond.'), findsOneWidget);
    expect(find.text('Your feedback was sent to Relay support.'), findsNothing);
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Send feedback'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send feedback'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(
      find.text('Your feedback was sent to Relay support.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'feedback accepts a blank reply email and rejects an invalid one',
    (tester) async {
      final calls = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: RelayFeedbackPage(
            sendFeedback: ({
              required category,
              required message,
              replyEmail,
            }) async => calls.add(replyEmail),
          ),
        ),
      );
      await tester.enterText(
        find.byType(TextFormField).first,
        'Please help with my schedule.',
      );
      await tester.enterText(find.byType(TextFormField).at(1), 'invalid');
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Send feedback'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Send feedback'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a valid email address, or leave this blank.'),
        findsOneWidget,
      );
      expect(calls, isEmpty);
      await tester.enterText(find.byType(TextFormField).at(1), '');
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Send feedback'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Send feedback'));
      await tester.pumpAndSettle();
      expect(calls, [null]);
    },
  );

  testWidgets('rating opens the official listing and reports launch failure', (
    tester,
  ) async {
    final urls = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: RelayExperienceSettings(
          canViewReports: () async => false,
          openUrl: (uri) async {
            urls.add(uri);
            return false;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Rate Relay on Google Play'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rate Relay on Google Play'));
    await tester.pumpAndSettle();
    expect(urls, [Uri.parse(relayPlayUrl)]);
    expect(find.textContaining('Could not open Google Play.'), findsOneWidget);
  });

  testWidgets(
    'share fallback offers an explicit copy action and confirms clipboard result',
    (tester) async {
      var clipboard = '';
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: RelayExperienceSettings(
            canViewReports: () async => false,
            share: () async =>
                throw UnsupportedError('browser share unavailable'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Share Relay'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share Relay'));
      await tester.pumpAndSettle();
      expect(clipboard, isEmpty);
      expect(find.text('Copy link'), findsOneWidget);
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();
      expect(clipboard, relayPublicUrl);
      expect(find.text('Relay link copied.'), findsOneWidget);
    },
  );

  testWidgets('settings exposes only the authorized support dashboard', (
    tester,
  ) async {
    await RelayThemeController.instance.load();
    await tester.pumpWidget(
      MaterialApp(
        home: RelayExperienceSettings(canViewReports: () async => false),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Support dashboard'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        home: RelayExperienceSettings(canViewReports: () async => true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Support dashboard'), 300);
    expect(find.text('Support dashboard'), findsOneWidget);
    expect(
      find.textContaining(
        'No family names, emails, timer records or usage analytics',
      ),
      findsOneWidget,
    );
  });
}
