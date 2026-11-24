import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/experience.dart';
import 'package:relay/home_widget.dart';
import 'package:relay/main.dart';
import 'package:relay/model.dart';
import 'package:relay/rating_preferences.dart';
import 'package:relay/rating_prompt.dart';
import 'package:relay/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStore extends RelayStore {
  RelayState state = RelayState();
  bool failSave = false;
  @override
  Future<RelayState> load() async => RelayState.fromJson(state.toJson());
  @override
  Future<void> save(RelayState state) async {
    if (failSave) throw StateError('disk full');
    this.state = RelayState.fromJson(state.toJson());
  }
}

class _NoWidgetBridge extends RelayHomeWidget {
  @override
  bool get supported => false;
}

void main() {
  final now = DateTime(2026, 11, 21, 12);
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    final saved = RelayRatingPreferences(prefs);
    await saved.recordCompletion(
      now.subtract(const Duration(days: 4)),
      completionId: 'first',
    );
    await saved.recordCompletion(
      now.subtract(const Duration(days: 2)),
      completionId: 'second',
    );
  });

  Session session({bool autoStopped = false, int minutes = 20}) => Session(
    shiftId: 1,
    kind: ShiftKind.focus,
    start: now.subtract(Duration(minutes: minutes)),
    end: now,
    autoStopReason: autoStopped ? 'Timer stopped after the time limit.' : null,
  );

  Future<void> openPrompt(
    WidgetTester tester, {
    Future<bool> Function(Uri)? openUrl,
    bool supported = true,
    bool canShow = true,
    Session? finished,
    RelayRatingPrompter? prompter,
  }) async {
    final invitation =
        prompter ??
        RelayRatingPrompter(
          preferences: prefs,
          supported: supported,
          clock: () => now,
          openUrl: openUrl,
          feedbackPageBuilder: (_) =>
              const Scaffold(body: Text('Private feedback form')),
        );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => invitation.afterSession(
                context,
                session: finished ?? session(),
                canShow: () => canShow,
              ),
              child: const Text('Finish session'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Finish session'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'rate now opens Play once and stops future automatic invitations',
    (tester) async {
      final urls = <Uri>[];
      await openPrompt(
        tester,
        openUrl: (url) async {
          urls.add(url);
          return true;
        },
      );
      expect(find.text('Send feedback'), findsOneWidget);
      await tester.tap(find.text('Rate now'));
      await tester.pumpAndSettle();
      expect(urls, [Uri.parse(relayPlayUrl)]);
      expect(
        await RelayRatingPreferences(prefs).recordCompletion(
          now.add(const Duration(days: 90)),
          completionId: 'later',
        ),
        isFalse,
      );
    },
  );

  testWidgets('never persists and does not open Google Play', (tester) async {
    await openPrompt(
      tester,
      openUrl: (_) async => throw StateError('must not open'),
    );
    await tester.tap(find.text('Don’t ask again'));
    await tester.pumpAndSettle();
    expect(
      await RelayRatingPreferences(prefs).recordCompletion(
        now.add(const Duration(days: 90)),
        completionId: 'later',
      ),
      isFalse,
    );
  });

  for (final choice in ['Remind me later', 'dismiss']) {
    testWidgets('$choice waits seven days after reopening preferences', (
      tester,
    ) async {
      await openPrompt(tester);
      if (choice == 'dismiss') {
        await tester.tapAt(const Offset(2, 2));
      } else {
        await tester.tap(find.text(choice));
      }
      await tester.pumpAndSettle();
      final saved = RelayRatingPreferences(prefs);
      expect(
        await saved.recordCompletion(
          now.add(const Duration(days: 6)),
          completionId: 'next',
        ),
        isFalse,
      );
      expect(
        await saved.recordCompletion(
          now.add(const Duration(days: 7)),
          completionId: 'a-week-later',
        ),
        isTrue,
      );
    });
  }

  testWidgets('feedback is available without rating and remains optional', (
    tester,
  ) async {
    await openPrompt(
      tester,
      openUrl: (_) async => throw StateError('must not open'),
    );
    await tester.tap(find.text('Send feedback'));
    await tester.pumpAndSettle();
    expect(find.text('Private feedback form'), findsOneWidget);
    expect(find.text('Rate now'), findsNothing);
    expect(
      await RelayRatingPreferences(prefs).recordCompletion(
        now.add(const Duration(days: 7)),
        completionId: 'later',
      ),
      isTrue,
    );
  });

  testWidgets(
    'failed Play launch explains the manual retry and stays suppressed',
    (tester) async {
      await openPrompt(tester, openUrl: (_) async => false);
      await tester.tap(find.text('Rate now'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not open Google Play.'),
        findsOneWidget,
      );
      expect(
        await RelayRatingPreferences(prefs).recordCompletion(
          now.add(const Duration(days: 90)),
          completionId: 'later',
        ),
        isFalse,
      );
    },
  );

  testWidgets('unsupported platforms and active screens are not covered', (
    tester,
  ) async {
    await openPrompt(tester, supported: false);
    expect(find.byType(RelayRatingInvitation), findsNothing);
    await openPrompt(tester, canShow: false);
    expect(find.byType(RelayRatingInvitation), findsNothing);
  });

  testWidgets('auto-stops and accidental short sessions do not qualify', (
    tester,
  ) async {
    await openPrompt(tester, finished: session(autoStopped: true));
    expect(find.byType(RelayRatingInvitation), findsNothing);
    await openPrompt(tester, finished: session(minutes: 0));
    expect(find.byType(RelayRatingInvitation), findsNothing);
    await openPrompt(tester);
    expect(find.byType(RelayRatingInvitation), findsOneWidget);
    await tester.tap(find.text('Remind me later'));
    await tester.pumpAndSettle();
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('all invitation choices fit a small phone at ${scale}x text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
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
                  builder: (_) => const RelayRatingInvitation(),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      for (final label in [
        'Rate now',
        'Send feedback',
        'Remind me later',
        'Don’t ask again',
      ]) {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        expect(find.text(label).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('Don’t ask again'));
      await tester.pumpAndSettle();
    });
  }

  for (final failSave in [false, true]) {
    testWidgets(
      'home offers rating only after a confirmed save (fail=$failSave)',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final store = _MemoryStore();
        store.state.start(
          ShiftKind.focus,
          DateTime.now().subtract(const Duration(minutes: 20)),
        );
        store.failSave = failSave;
        await tester.pumpWidget(
          MaterialApp(
            home: RelayHome(
              store: store,
              homeWidget: _NoWidgetBridge(),
              ratingPrompter: RelayRatingPrompter(
                preferences: prefs,
                supported: true,
                clock: () => now,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(RelayRatingInvitation), findsNothing);
        await tester.ensureVisible(find.text('End shift'));
        await tester.tap(find.text('End shift'));
        await tester.pumpAndSettle();
        expect(
          find.byType(RelayRatingInvitation),
          failSave ? findsNothing : findsOneWidget,
        );
        expect(store.state.active == null, !failSave);
        if (!failSave) {
          await tester.tap(find.text('Remind me later'));
          await tester.pumpAndSettle();
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
