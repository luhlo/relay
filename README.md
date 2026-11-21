# Relay

Relay is a one-handed family shift tracker for focus time, childcare handoffs, interruptions, schedules, and shared household insights.

The Flutter app targets Android and the web. Supabase provides authentication and household data storage. The production PWA is deployed to GitHub Pages at [relay.luhlo.com](https://relay.luhlo.com/).

## Validate locally

```sh
flutter analyze
flutter test
flutter build web --release --base-href / --pwa-strategy=none
python3 tool/finish_web_build.py
node tool/test_service_worker.mjs build/web
```

Pushing `main` runs the Pages workflow and deploys the PWA.
The finish step validates every precached file and retains the legacy Flutter
service-worker URL so installed PWAs can migrate to Relay's offline shell safely.

## Android home-screen widget

Install the native Relay APK, open it once, and sign in or choose local use.
Long-press the Android home screen, choose **Widgets**, then add Relay's
**4 × 1** or **2 × 1** widget. Long-press the placed widget and drag its
handles to resize it horizontally or vertically.
The widget offers **Work Time** and **Baby Time**. Baby Time shows the family's
saved children and **All babies**; Work Time shows **Interruption / Resume**.
The timer pauses during interruptions and survives returning to the home screen.
Use **End** to finish the current session.

Tracking actions save in the background without opening Relay. The flat bar
uses equal colored sections, with the timer centered above End and Interruption
or Resume. Baby Time shows one child's name alone; two or three children share
equal sections with All babies. For four or more children, use the wider arrows
to choose a child or All babies, then tap that choice to start Baby Time.
Signed-in timers and schedules save on the device immediately and work offline
after the account and household have been loaded online once. Android queues
network-constrained background sync after local widget and lock-screen actions;
the foreground app retries on resume and periodically. The PWA retries while
open or when reopened. A status row shows local, pending, synced and review states.
Disjoint changes merge; competing edits require a choice in **Sync & saved copies**,
with both versions retained on that device. No pending history is uploaded to a
different account or household. Signing in, joining/inviting caregivers and shared
household settings still require a connection.

The web app caches its public app shell and renderer after a successful online
visit. Browser storage must remain available. Signing out retains pending records
privately for the same account; signing back in reconnects them. Clearing app/site
storage removes unsynced changes and saved copies. Confirmed account deletion
clears that account's cache on the device completing deletion; clear storage on
other devices separately. The cloud never receives recovery copies themselves.
The browser-installed PWA does not include the native Android widget.

### Widget appearance and timer check-ins

Open the account menu and choose **Widget appearance** to change Work Time,
Baby Time, Interruption, Resume, and End colors, or restore the app defaults.
The interruption stopwatch runs separately while actual work time stays paused.
Signed-in Settings shows the account's email address.

Relay checks in every three hours for work, interruptions, and childcare.
**Yes, keep going** starts the next three-hour interval; **Stop** ends tracking.
An unanswered check-in stops tracking after 15 minutes. A twelve-hour
unconfirmed limit covers missed/deferred checks, and no session can exceed
twenty hours, including interruptions. Late jobs save the original stop deadline
and notify the user why the timer stopped.

In Settings, enable **Check-in notifications** and **Allow precise timer alerts**.
If exact alarms are not allowed, Android may defer alerts; stored stop deadlines
still bound recorded time when the job or app next runs. Cloud tracking and
guard saves commit locally while offline and sync when connected.

## Appearance, help, and release announcements (1.17.0)

Open Settings → **App preferences & help** for Light, Dark, or Follow System
appearance; Help & FAQ; Replay introduction; What's new; Rate Relay; Share Relay;
and Send feedback. Password fields can reveal the typed password, and signing
out asks for confirmation. The native lock-screen timer remains available.

New installations receive a short skippable introduction. Existing users receive
one small **What's new** notice for a feature release, with a View button. This
uses `relayFeatureReleaseId` in `lib/release_notes.dart`, not a calendar schedule:
change that ID and the notes only when there is something new to announce.
Patch builds with the same ID do not repeat the notice. The notes can always be
opened again from Settings, and Android-only features are omitted on the web.
When preparing a build, keep `relaySupportVersion` in `lib/support_service.dart`
aligned with `pubspec.yaml` so technical reports identify the installed build.
Update `relayFeatureReleaseVersion` only with the corresponding feature notes.

**Help improve reliability** is opt-in and off by default. Only sanitized
Flutter errors and unusually slow startup, record operations, or frames are
reported. Exception messages, names, records, account identifiers and full URLs
are excluded. Reports are bounded and queued without delaying timer saves.
This is technical monitoring, not feature-usage analytics; it does not capture
Android OS-level Java crashes or ANRs.

Feedback and technical reports use the `relay-support` Supabase function. The
private **Support dashboard** appears only for a server-authorized, confirmed
support login, initially `luhlostudios@gmail.com`. The server checks authorization
on every dashboard request. See `supabase/functions/relay-support/README.md`
for backend deployment, limits, retention and verification.

## Branding

App and PWA icons use the supplied vector master in `assets/branding/relay-logo.pdf`, whose purple is `#5626FC`. The feature graphic uses the separately supplied rounded tile in `assets/branding/relay-logo-rounded.pdf`, whose purple is `#5429F3`. Both source PDFs are preserved unchanged.
