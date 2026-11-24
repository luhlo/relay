/// Change this ID only when a release has something useful to announce.
/// Patch builds and time passing do not make the announcement appear again.
const relayFeatureReleaseId = '2026-11-household-controls';
const relayFeatureReleaseVersion = '1.19.0';

class RelayReleaseNote {
  const RelayReleaseNote(this.title, this.detail, {this.androidOnly = false});
  final String title;
  final String detail;
  final bool androidOnly;
}

const relayReleaseNotes = [
  RelayReleaseNote(
    'Keep your household up to date',
    'Household owners can change children’s names and count, revoke pending invitations, and remove a caregiver’s household access from Settings.',
  ),
  RelayReleaseNote(
    'Cancel a baby selection',
    'Changed your mind in the widget? Tap Cancel to return to your timer without starting or ending a session. Timer and lock-screen controls also recover more clearly when a save needs checking.',
    androidOnly: true,
  ),
  RelayReleaseNote(
    'A look that suits you',
    'Controls and chart labels fit better when you use larger text. Choose Light, Dark or Follow System in Appearance & help; widget colors remain customizable.',
  ),
  RelayReleaseNote(
    'Clearer Insights',
    'Long date ranges load faster. Another caregiver’s Insights shows when it was fetched, with Refresh to check for new activity.',
  ),
  RelayReleaseNote(
    'Your saved time stays yours',
    'Removing household access keeps personal time records. You can view your saved history privately, including earlier household snapshots.',
  ),
  RelayReleaseNote(
    'Help shape Relay',
    'After you have used Relay, an optional invitation lets you leave an honest review, send private feedback, ask again later, or turn reminders off.',
  ),
  RelayReleaseNote(
    'Optional technical reports',
    'You can help improve reliability by enabling technical reports in Settings. This choice is off until you turn it on.',
  ),
];
