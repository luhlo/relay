# Relay — Data safety and review working notes

Audit date: 2026-11-01. Audit source: app code and declared dependencies. No production users were read. Final declarations must cover provider-side processing and all active Play versions too.

## Confirmed app data flows

| Information | Where and why | Suggested Play form category |
|---|---|---|
| Account email, invited caregiver emails | Supabase Auth/account setup/invites; Resend authentication emails | Personal info → Email address |
| Supabase account ID and household membership | Supabase Auth and relational household membership | Personal info → User IDs |
| Display name, household/child names or aliases | Supabase household tables; child names also appear in own saved state and Android widget | Personal info → Name; household and caregiver configuration may also fall under Other info/Other user-generated content |
| Shift start/end times and type | parent_records JSON; schedules and user-chosen calendar draft export | Calendar → Calendar events is conservative for the planned shift events; verify wording in current form |
| Focus, childcare, interruption, check-in timestamps and stop reasons | parent_records JSON; time calculations and Insights | App activity → Other actions; evaluate App interactions for timer/check-in actions |
| Preferences (colors/reminders/personal time) | parent_records JSON when signed in, local store when device-only | App activity → Other user-generated content/Other actions as appropriate; do not label developer analytics just because users see Insights |
| Household members/social links and invite contacts | household_members, household_invites | Evaluate Contacts because Google's definition includes contact names and social-graph information, even without READ_CONTACTS; no device address-book access |
| Google identity data | Supabase Auth may retain Google basic profile metadata | Audit actual provider metadata and declare any additional profile data stored, including profile image if applicable |

- Cloud/account flows count as collection; do not answer No data collected simply because local use is available.
- Collection is not ephemeral: time history is persistently stored.
- Choosing local use avoids account/cloud record storage, but app initialization may contact Supabase to check a saved session and website hosting sees requests.
- Select App functionality and Account management for the relevant types. No advertising or marketing use exists in audited code. User-facing Insights are app functionality; no developer analytics SDK exists in this version.
- Optional vs required: sign-in/cloud are optional for the app overall; name fields for cloud household setup are required (aliases allowed), real child names optional. Evaluate each type against Google's current definition rather than making all Required.
- HTTPS is used for Supabase, Google OAuth and calendar draft endpoints. Select encrypted in transit only after confirming provider emails/other integrations under the actual form scope.
- Supabase and Resend can qualify as service providers if processing solely on the developer's behalf. Under Google's definition these transfers are generally exempt from sharing. Household sharing and Google Calendar export are user-initiated and disclosed; verify actual in-app disclosure meets that exception before declaring No sharing.
- Email content is authentication email, not reading users' inboxes. No Gmail API access is requested.
- No app advertising ID collection, ad SDK, crash-reporting SDK or billing SDK in pubspec. Native widget request IDs are random operation deduplication IDs, not stable device identifiers. Infrastructure security/request logs still need provider review.
- Do not declare location, audio, video, health/fitness, financial data, or external files based solely on the childcare context; audited features do not collect them.

## Account creation/deletion answers

Current creation methods: email/password and Google OAuth (both Supabase Auth). Device-local use does not remove deletion obligations.

The deletion Edge Function is deployed. Its handler passed 19 tests, and the database deletion behavior passed an isolated Postgres test suite, including ownership transfer and last-member cleanup. The client confirmation is covered by Flutter tests. Verify the deployed public website flow and a disposable account on the Play testing build before submitting account-deletion answers. Include stale/deleted sessions, retry/failure, and separate local-record behavior in that test.

## Permissions

The release targets Android 16/API 36. The app requests INTERNET, POST_NOTIFICATIONS, SCHEDULE_EXACT_ALARM and RECEIVE_BOOT_COMPLETED. Unused inherited foreground-service declarations are removed from the release manifest; verify the final AAB manifest and Play Console permission report before submitting declarations.

SCHEDULE_EXACT_ALARM is user-granted special access with broader use cases than restricted USE_EXACT_ALARM. Relay does not request USE_EXACT_ALARM. Keep it that way unless a documented need arises. Explain exact alarms as precise shift/handoff and timer check-in reminders. Notification permission is optional on Android13+, so reviewers should grant it to evaluate reminders. Neither permission guarantees immediate background execution under all device states.

No broad storage, contacts, location, microphone, camera, SMS/call permissions found. No background location/foreground-service declaration found in main manifest; inspect final merged manifest for dependency additions.

## App content and reviewer access

Intended product users are adults (parents/caregivers), while entered child information concerns children. A childcare utility is not automatically a child-directed app. Target audience should reflect actual intended users and store assets; adult-only18+ recommendation requires owner confirmation. IARC age rating is a separate questionnaire, answer factually.

No ads in current implementation. No payment/subscription integration yet. Family/UGC questions need deliberate answers: members share named user-created schedules/timing inside an invitation-only household, with no public feed or messaging. Do not simply declare no user data sharing; explain restricted household sharing.

Give reviewers a working test account/household with fictional records and explain email verification, Google sign-in, household setup, local-use fallback, widget placement and permission opt-ins. Do not require reviewers to use a personal Google account or disclose real family information to exercise app features. Store test credentials privately in Play Console App access.

## Release preparation status and remaining checks

- Confirmed public developer: luhlo; support/privacy contact: luhlostudios@gmail.com.
- Store listing: Relay: Parent Time Management, free download; subscriptions later.
- Privacy and external deletion pages, in-app privacy/deletion controls, and store image assets are prepared.
- Release uses a private upload key and version 1.14.0+15; the signed AAB and native compatibility checks are documented separately.
- Remaining: verify public Pages deployment and production web deletion route; review provider/log retention language and all final Data safety answers; complete reviewer app access and Play-distributed login/timer/widget tests; satisfy the account's testing and verification requirements before production release.

## Official sources reviewed

- Data safety categories, collection, sharing/service-provider and user-action exceptions: https://support.google.com/googleplay/android-developer/answer/10787469?hl=en
- Privacy policy contents and public accessibility: https://support.google.com/googleplay/android-developer/answer/10144311?hl=en
- In-app and external account deletion: https://support.google.com/googleplay/android-developer/answer/13327111?hl=en
- Exact-alarm choice and user grant behavior: https://developer.android.com/develop/background-work/services/alarms
- Android notification runtime permission: https://developer.android.com/develop/ui/views/notifications/notification-permission
- Target audience: https://support.google.com/googleplay/android-developer/answer/9867159?hl=en
- Families scope: https://support.google.com/googleplay/android-developer/answer/9893335?hl=en
- Store setup: https://support.google.com/googleplay/android-developer/answer/9859152?hl=en
