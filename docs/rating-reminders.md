# Rating invitations — prepared for the next Android update

Relay offers a neutral rating invitation after a successfully saved manual
**End shift**, when no timer or other page is active and the app is foregrounded.
It never interrupts work, childcare, an interruption, onboarding, or an automatic
timer stop. Widget and lock-screen actions do not open the app to request a review.

The invitation becomes eligible after three completed in-app sessions of at
least one minute each and at least 72 hours since the first qualifying completion.
These counters begin with this feature; shared household history is not counted.

- **Rate now** opens the existing Google Play listing and stops automatic
  invitations on this device. The manual Settings rating link also stops them.
- **Remind me later**, dismissing the dialog, or **Send feedback** pauses
  invitations for seven days. Another qualifying session must end before a
  subsequent invitation can appear; no scheduled notification is sent.
- **Don’t ask again** persists on this device across normal app updates.
- **Send feedback** opens the existing private problem/idea/question form.
  No sentiment question or star score gates access to public reviews.

Google does not tell Relay whether a review was submitted, so it treats choosing
Rate now as the final answer. Clearing app storage or reinstalling resets local
preferences. Nothing is added to household sync. Automatic Google Play rating
invitations are Android-only; the PWA retains its manual rating and feedback links.

Feedback is stored in the existing support backend and visible in the private
Support dashboard for confirmed `luhlostudios@gmail.com`. No owner email or push
notification is sent automatically.

Implementation uses a direct store link rather than Google's quota-controlled
in-app review API, following its guidance for an explicit rating button:
https://developer.android.com/guide/playcore/in-app-review#quotas

Release status: included in the prepared 1.19.0+24 Android debug build.
No Play release has been changed for this update. The PWA keeps manual store
and feedback links; automatic rating invitations remain Android-only.
