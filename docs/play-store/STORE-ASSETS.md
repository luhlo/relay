# Relay store assets

Prepared and visually reviewed:
- `assets/app-icon-512.png`: existing Relay icon, 512 × 512.
- `assets/feature-graphic.png`: feature graphic, 1024 × 500; editable source in `assets/feature-graphic.svg`.
- `assets/phone-01-focus.png`: actual Relay Focus UI, 1170 × 2532.
- `assets/phone-02-schedule.png`: actual Relay Schedule UI, 1170 × 2532.
- `assets/phone-03-insights.png`: actual Relay Insights bar charts, 1170 × 2532.

The phone images were rendered directly from RelayHome using a temporary in-memory fixture with fictional children and time records, the actual logo, and the app's Manrope font. No private family records were used. The capture fixture was removed from the product checkout after generation.

Developer: **luhlo**. Public support: **luhlostudios@gmail.com**. The store listing name is **Relay: Parent Time Management**, free to download; this release has no subscriptions.

Privacy and account-deletion pages are included in `web/privacy/` and `web/delete-account/`. Verify their deployed HTTPS URLs and the authenticated deletion flow before submitting the Data safety form.

Before production submission, provide reviewer access instructions and a working test account with fictional data privately in Play Console. Validate email/Google sign-in, household setup, reminders, timers, widgets and account deletion on the Play testing build. Never commit or publish test credentials or signing secrets.
