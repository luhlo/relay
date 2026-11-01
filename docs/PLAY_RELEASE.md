# Google Play release

Relay uses package name `app.relay.relay`. Keep this package name for all updates.
The release configuration requires a real upload key; there is no debug-signing fallback.

## Private upload key

The initial upload key and credentials are stored locally in:

`/Users/alejo/Documents/Codex/Relay private signing/`

This directory is outside the Git repository, is readable only by the local user,
and must be backed up in encrypted private storage. Do not upload the keystore,
passwords, or signing properties to GitHub, screenshots, issue comments, or Play's
store-listing assets. The keystore is an upload key: Google Play App Signing
holds the separate app-signing key used for store installations.

To build on this computer, set `RELAY_SIGNING_PROPERTIES` to the private
`signing.properties` file. On another machine, create a private properties file
with these four entries (use an absolute path for `storeFile`):

```properties
storeFile=/absolute/private/path/relay-upload.p12
storePassword=YOUR_PRIVATE_PASSWORD
keyAlias=relay-upload
keyPassword=YOUR_PRIVATE_PASSWORD
```

Alternatively put these entries in ignored `android/key.properties`. Never commit
that file or any keystore. Debug builds and unit tests do not need the release key.

## Build and verify

Increment the `version` build number in `pubspec.yaml` for each upload. Then run:

```sh
export RELAY_SIGNING_PROPERTIES="/Users/alejo/Documents/Codex/Relay private signing/signing.properties"
flutter analyze
flutter test
flutter build appbundle --release
```

The upload file is `build/app/outputs/bundle/release/app-release.aab`.
Use `jarsigner -verify` to confirm its signature. Check the package, version code,
target SDK, native library alignment, and Play Console's App Bundle Explorer
before promoting a release. The current Flutter toolchain targets Android 16
(API 36), with Android Gradle Plugin 9.1 and NDK 28.2.

The installed development APK uses a different signing certificate. A Play-signed
installation cannot update that APK directly. Preserve any local-only records
before replacing the development installation; cloud records remain associated
with the same Supabase login. Do not uninstall a user's development build just to
test the Play build.

## Phone widget testing

Use an optimized release APK for normal phone/widget testing:
`flutter build apk --release --target-platform android-arm64`.
Debug APKs run a JIT kernel and make each fresh headless widget engine slower;
versions 1.15.0/1.15.1 exposed this regression on the connected phone.

Match the certificate of the installed development APK when updating it. For a
phone signed with the development key, point `RELAY_SIGNING_PROPERTIES` at a
private temporary file for that same key while building the release-mode test
APK. Keep the production upload-key configuration separate. Confirm the APK has
`libapp.so`, no `kernel_blob.bin`, the expected certificate and a higher version
code, then use `adb install -r --user 0` to retain the phone's app data.

## Play Console

1. Create/select Relay and use Play App Signing. Upload the AAB to an internal
   testing release first.
2. Finish the store listing, target audience and content rating, app access,
   Data safety form, privacy-policy URL, and external account-deletion URL.
   Give reviewers a working test login if account-only features require one.
3. Complete the account's required testing and verification. New personal
   developer accounts may need at least 12 opted-in testers for 14 continuous
   days before applying for production access.
4. Review Play's pre-launch report, fix failures, then submit the production
   release after the store listing and application are ready.

The app requests `SCHEDULE_EXACT_ALARM` with user-granted access for shift and
timer alerts; it does not request the restricted `USE_EXACT_ALARM` permission.
Notification permission is optional. Timers must continue to behave reasonably
when notifications or exact alarms are denied.

References:
- https://support.google.com/googleplay/android-developer/answer/9859152
- https://support.google.com/googleplay/android-developer/answer/9842756
- https://support.google.com/googleplay/android-developer/answer/14151465
- https://developer.android.com/guide/practices/page-sizes
