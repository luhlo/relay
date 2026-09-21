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
