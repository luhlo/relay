# Relay

Relay is a one-handed family shift tracker for focus time, childcare handoffs, interruptions, schedules, and shared household insights.

The Flutter app targets Android and the web. Supabase provides authentication and household data storage. The production PWA is deployed to GitHub Pages at [relay.luhlo.com](https://relay.luhlo.com/).

## Validate locally

```sh
flutter analyze
flutter test
flutter build web --release --base-href /
```

Pushing `main` runs the Pages workflow and deploys the PWA.

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
Signed-in tracking needs a connection; local tracking works offline. Cloud changes from another device appear
after refreshing Relay; the widget shows the most recently loaded device state.
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
guard saves require a connection, as with other cloud writes.

## Branding

App and PWA icons use the supplied vector master in `assets/branding/relay-logo.pdf`, whose purple is `#5626FC`. The feature graphic uses the separately supplied rounded tile in `assets/branding/relay-logo-rounded.pdf`, whose purple is `#5429F3`. Both source PDFs are preserved unchanged.
