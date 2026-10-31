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
Long-press the Android home screen, choose **Widgets**, then add **Relay**.
The widget offers **Work Time** and **Baby Time**. Baby Time shows the family's
saved children and **All babies**; Work Time shows **Interruption / Resume**.
The timer pauses during interruptions and survives returning to the home screen.
Use **End** to finish the current session.

Selecting a tracking action opens Relay to confirm the normal local/cloud save.
Signed-in tracking needs a connection. Cloud changes from another device appear
after refreshing Relay; the widget shows the most recently loaded device state.
The browser-installed PWA does not include the native Android widget.
