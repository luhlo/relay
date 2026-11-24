import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/rating_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final start = DateTime.utc(2026, 11, 21, 12);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<RelayRatingPreferences> preferences({String scope = 'local'}) async =>
      RelayRatingPreferences(
        await SharedPreferences.getInstance(),
        scope: scope,
      );

  Future<void> establishExperience(RelayRatingPreferences ratings) async {
    expect(await ratings.recordCompletion(start, completionId: 'one'), isFalse);
    expect(
      await ratings.recordCompletion(
        start.add(const Duration(days: 1)),
        completionId: 'two',
      ),
      isFalse,
    );
  }

  test(
    'requires both three completions and three days of experience',
    () async {
      final ratings = await preferences();
      await establishExperience(ratings);
      expect(
        await ratings.recordCompletion(
          start.add(const Duration(days: 3) - const Duration(milliseconds: 1)),
          completionId: 'three',
        ),
        isFalse,
      );
      expect(
        await ratings.recordCompletion(
          start.add(const Duration(days: 3)),
          completionId: 'four',
        ),
        isTrue,
      );
    },
  );

  test('elapsed time alone cannot trigger an invitation', () async {
    final ratings = await preferences();
    await ratings.recordCompletion(start, completionId: 'one');
    expect(
      await ratings.recordCompletion(
        start.add(const Duration(days: 30)),
        completionId: 'two',
      ),
      isFalse,
    );
  });

  test('an immediately retried completion is not counted again', () async {
    final ratings = await preferences();
    await ratings.recordCompletion(start, completionId: 'one');
    final later = start.add(const Duration(days: 3));
    await ratings.recordCompletion(later, completionId: 'two');
    expect(await ratings.recordCompletion(later, completionId: 'two'), isFalse);
    final saved = jsonDecode(
      ratings.preferences.getString(ratings.storageKey)!,
    );
    expect(saved['completedCount'], 2);
  });

  test('progress and suppression survive recreating the preferences', () async {
    await establishExperience(await preferences());
    final ratings = await preferences();
    expect(
      await ratings.recordCompletion(
        start.add(const Duration(days: 3)),
        completionId: 'three',
      ),
      isTrue,
    );
    await ratings.stopAsking();
    final reopened = await preferences();
    expect(reopened.stopped, isTrue);
    expect(
      await reopened.recordCompletion(
        start.add(const Duration(days: 365)),
        completionId: 'four',
      ),
      isFalse,
    );
  });

  test(
    'remind later waits seven full days, including across restarts',
    () async {
      final ratings = await preferences();
      await establishExperience(ratings);
      final shown = start.add(const Duration(days: 3));
      await ratings.recordCompletion(shown, completionId: 'three');
      await ratings.remindLater(shown);
      final reopened = await preferences();
      expect(
        await reopened.recordCompletion(
          shown.add(const Duration(days: 7) - const Duration(milliseconds: 1)),
          completionId: 'four',
        ),
        isFalse,
      );
      expect(
        await reopened.recordCompletion(
          shown.add(const Duration(days: 7)),
          completionId: 'five',
        ),
        isTrue,
      );
    },
  );

  test(
    'reserving a prompt prevents repeat invitations after dismissal',
    () async {
      final ratings = await preferences();
      await establishExperience(ratings);
      final shown = start.add(const Duration(days: 3));
      expect(
        await ratings.recordCompletion(shown, completionId: 'three'),
        isTrue,
      );
      await ratings.reservePrompt(shown);
      expect(
        await (await preferences()).recordCompletion(
          shown.add(const Duration(minutes: 1)),
          completionId: 'four',
        ),
        isFalse,
      );
    },
  );

  test(
    'another account and the guest scope keep independent choices',
    () async {
      final first = await preferences(scope: 'cloud:one');
      final second = await preferences(scope: 'cloud:two');
      final guest = await preferences();
      await first.stopAsking();
      await establishExperience(second);
      expect(first.stopped, isTrue);
      expect(second.stopped, isFalse);
      expect(guest.stopped, isFalse);
      expect(
        await guest.recordCompletion(
          start.add(const Duration(days: 3)),
          completionId: 'three',
        ),
        isFalse,
      );
      expect(
        await second.recordCompletion(
          start.add(const Duration(days: 3)),
          completionId: 'three',
        ),
        isTrue,
      );
    },
  );

  test(
    'never asking remains permanent after snooze or clock changes',
    () async {
      final ratings = await preferences();
      await ratings.stopAsking();
      await ratings.remindLater(start);
      await ratings.reservePrompt(start);
      expect(ratings.stopped, isTrue);
      expect(
        await ratings.recordCompletion(
          start.add(const Duration(days: 1000)),
          completionId: 'one',
        ),
        isFalse,
      );
    },
  );

  test('damaged or incorrectly typed preferences restart quietly', () async {
    final ratings = await preferences();
    for (final corrupt in ['invalid json', '[]', '{"completedCount":1000}']) {
      await ratings.preferences.setString(ratings.storageKey, corrupt);
      expect(ratings.stopped, isFalse);
      expect(
        await ratings.recordCompletion(start, completionId: 'one'),
        isFalse,
      );
    }
    await ratings.preferences.setBool(ratings.storageKey, true);
    expect(await ratings.recordCompletion(start, completionId: 'one'), isFalse);
  });

  test(
    'an empty completion ID is rejected without changing preferences',
    () async {
      final ratings = await preferences();
      await expectLater(
        ratings.recordCompletion(start, completionId: ''),
        throwsArgumentError,
      );
      expect(ratings.preferences.getString(ratings.storageKey), isNull);
    },
  );
}
