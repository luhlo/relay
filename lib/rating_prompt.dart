import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'experience.dart';
import 'model.dart';
import 'rating_preferences.dart';

enum RelayRatingChoice { rate, later, never, feedback }

/// A store-link invitation, not Google's quota-controlled in-app review card.
/// Feedback and public reviews are offered independently to every user.
class RelayRatingPrompter {
  RelayRatingPrompter({
    this.preferences,
    this.supported,
    this.openUrl,
    this.feedbackPageBuilder,
    this.clock = DateTime.now,
  });

  final SharedPreferences? preferences;
  final bool? supported;
  final Future<bool> Function(Uri)? openUrl;
  final WidgetBuilder? feedbackPageBuilder;
  final DateTime Function() clock;
  bool _checking = false;

  Future<void> afterSession(
    BuildContext context, {
    required Session session,
    required bool Function() canShow,
  }) async {
    final end = session.end;
    if (_checking ||
        !(supported ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)) ||
        end == null ||
        session.autoStopReason != null ||
        end.difference(session.start) < const Duration(minutes: 1)) {
      return;
    }
    _checking = true;
    try {
      final saved = RelayRatingPreferences(
        preferences ?? await SharedPreferences.getInstance(),
      );
      final now = clock();
      final eligible = await saved.recordCompletion(
        now,
        completionId:
            '${session.start.toUtc().toIso8601String()}/${end.toUtc().toIso8601String()}',
      );
      if (!eligible || !context.mounted || !canShow()) return;
      // Reserve before opening: a restart or dismissal must not prompt again.
      await saved.reservePrompt(now);
      if (!context.mounted || !canShow()) return;
      final choice = await showDialog<RelayRatingChoice>(
        context: context,
        builder: (_) => const RelayRatingInvitation(),
      );
      switch (choice) {
        case RelayRatingChoice.rate:
          // Google cannot confirm a posted review. Treat choosing Rate now as
          // the user's final answer, even if external navigation is interrupted.
          try {
            await saved.stopAsking();
          } catch (_) {
            // Opening the listing still works if a device preference fails.
          }
          if (!context.mounted || !canShow()) return;
          try {
            final opened =
                await (openUrl ??
                    (uri) => launchUrl(
                      uri,
                      mode: LaunchMode.externalApplication,
                    ))(Uri.parse(relayPlayUrl));
            if (!opened) throw StateError('Google Play did not open.');
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(
                  content: Text(
                    'Could not open Google Play. You can try again from Appearance & help.',
                  ),
                ),
              );
            }
          }
        case RelayRatingChoice.never:
          try {
            await saved.stopAsking();
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(
                  content: Text(
                    'Could not save your choice. Reminders are paused for a week.',
                  ),
                ),
              );
            }
          }
        case RelayRatingChoice.feedback:
          if (!context.mounted || !canShow()) return;
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: feedbackPageBuilder ?? (_) => const RelayFeedbackPage(),
            ),
          );
        case RelayRatingChoice.later:
        case null:
          // The reservation already saved the seven-day reminder delay.
          break;
      }
    } catch (_) {
      // Rating preferences and prompts must never affect saved timer records.
    } finally {
      _checking = false;
    }
  }
}

class RelayRatingInvitation extends StatelessWidget {
  const RelayRatingInvitation({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.rate_review_outlined),
    title: const Text('Rate Relay'),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Relay is built by a small, independent developer in the U.S. Your honest review helps other parents discover Relay, and your feedback helps me improve it.',
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.pop(context, RelayRatingChoice.rate),
              child: const Text('Rate now'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () =>
                  Navigator.pop(context, RelayRatingChoice.feedback),
              child: const Text('Send feedback'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context, RelayRatingChoice.later),
              child: const Text('Remind me later'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, RelayRatingChoice.never),
              child: const Text('Don’t ask again'),
            ),
          ],
        ),
      ),
    ),
  );
}
