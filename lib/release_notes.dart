/// Change this ID only when a release has something useful to announce.
/// Patch builds and time passing do not make the announcement appear again.
const relayFeatureReleaseId = '2026-11-offline-tracking';
const relayFeatureReleaseVersion = '1.18.0';

class RelayReleaseNote {
  const RelayReleaseNote(this.title, this.detail, {this.androidOnly = false});
  final String title;
  final String detail;
  final bool androidOnly;
}

const relayReleaseNotes = [
  RelayReleaseNote(
    'Keep tracking when you’re offline',
    'After connecting your account on this device, timers and schedules save here first and sync when a connection is available. A status message shows what is waiting to sync. If two devices make conflicting changes, you can review them without losing the saved copies.',
  ),
  RelayReleaseNote(
    'Control your timer from the lock screen',
    'See Work Time or your child’s name, then interrupt, resume or end the timer. Turn the lock-screen timer on or off in Settings.',
    androidOnly: true,
  ),
  RelayReleaseNote(
    'A look that suits you',
    'Choose Light, Dark or Follow System in Appearance & help. Your widget keeps its own color settings.',
  ),
  RelayReleaseNote(
    'Easier sign-in',
    'Show or hide your password while typing, and confirm before signing out.',
  ),
  RelayReleaseNote(
    'Help when you need it',
    'Find answers, replay the introduction, or send a question, problem or feature idea from Settings.',
  ),
  RelayReleaseNote(
    'Share Relay with your people',
    'Use Share Relay to send the app’s link, or open its Google Play listing to leave a review.',
  ),
  RelayReleaseNote(
    'Optional technical reports',
    'You can help improve reliability by enabling technical reports in Settings. This choice is off until you turn it on.',
  ),
];
