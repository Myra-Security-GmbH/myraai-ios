# Firebase / FCM setup for the Android app

The Android source ships with all the code wired for Firebase Cloud Messaging
(FCM) push, but **two secrets must be supplied before pushes will actually
deliver in production**. The build, the APK, and the app itself work fine
without them — FCM just stays disabled at runtime.

## What you need to provide

### 1. `google-services.json` — for the Android client

1. Open the [Firebase Console](https://console.firebase.google.com/) and
   create or open the project (recommended name: `myraai-prod`).
2. Add an Android app with package name **`eu.myra.myraai`**.
3. Add the SHA-1 of the release signing key:
   ```
   keytool -list -v -keystore release.jks -alias <your-alias> | grep SHA1
   ```
4. Download `google-services.json` and drop it into:
   ```
   src/mobile/android/app/google-services.json
   ```
5. **Do not commit it.** It's not strictly secret (the file is fingerprint-
   bound) but we keep it out of git for cleanliness. Inject via CI variable
   `ANDROID_GOOGLE_SERVICES_BASE64` (`base64 -w0 google-services.json`) and
   decode in the `android:build` job before running gradle.

If the file is missing, `app/build.gradle` skips the Google Services plugin
and prints a warning — the build succeeds, but the running app cannot fetch
an FCM token, so `getDeviceToken` returns null and no pushes are received.

### 2. Service account JSON — for the backend FCM dispatcher

1. In the Firebase Console: **Project settings → Service accounts →
   Generate new private key**.
2. The downloaded JSON contains `client_email`, `private_key`, and
   `project_id`. Treat this like a database password.
3. Place the file on the **production host** at:
   ```
   /etc/myra-fcm-service-account.json
   ```
   (owner `www-data`, mode `0600`).
4. Create `/etc/myra-fcm.env`:
   ```
   FCM_PROJECT_ID=myraai-prod
   FCM_SERVICE_ACCOUNT=/etc/myra-fcm-service-account.json
   ```
5. Install the systemd unit:
   ```
   sudo cp src/push/myra-fcm.service /etc/systemd/system/
   sudo mkdir -p /opt/myra-fcm
   sudo cp src/push/fcm_service.py /opt/myra-fcm/
   sudo python3 -m venv /opt/myra-fcm/venv
   sudo /opt/myra-fcm/venv/bin/pip install httpx[http2] PyJWT[crypto]
   sudo systemctl daemon-reload
   sudo systemctl enable --now myra-fcm.service
   ```
6. Verify:
   ```
   sudo systemctl status myra-fcm.service
   curl -sf -X POST http://127.0.0.1:8011/send -H 'Content-Type: application/json' \
     -d '{"device_token":"invalid","title":"x","body":"x"}'
   # expect 410 with {"dead":true} or 502 — both prove the service is up.
   ```

## How the code uses these

- `src/push.lua` routes by `device_token.platform`:
  iOS rows → `127.0.0.1:8010` (existing APNs service).
  Android rows → `127.0.0.1:8011` (this FCM service).
- The FCM service handles the OAuth2 access-token exchange (RS256 JWT,
  cached for ~55 min) and calls
  `https://fcm.googleapis.com/v1/projects/<id>/messages:send`.
- It always sends **data-only** payloads — `MyraFirebaseMessagingService`
  on the device builds the displayed notification, so foreground and
  background behaviour are identical and we control the channel +
  click target.
- On FCM `UNREGISTERED` / `INVALID_ARGUMENT` / `NOT_FOUND` the service
  returns HTTP 410 with `{"dead": true}`; `push.lua` then DELETEs the
  token row to stop hammering dead endpoints.

## Channel design

| Channel id     | Importance | When to use                                              |
|----------------|------------|----------------------------------------------------------|
| `chat_replies` | HIGH       | Long-running response is ready, teammate replied         |
| `general`      | DEFAULT    | Project invitations, account events, generic announcements |

The default channel id (used when a payload doesn't specify) is `general`,
declared in `AndroidManifest.xml` via
`com.google.firebase.messaging.default_notification_channel_id`.

## Permission UX

`MainActivity.NativeBridge.requestNotificationPermission(cb)`:

- **Android < 13**: notifications auto-allowed; callback fires `true`
  immediately.
- **Android 13+**: shows our rationale dialog
  (`R.string.notification_rationale_*`), then on confirm triggers the
  system `POST_NOTIFICATIONS` prompt, then calls the JS callback with the
  outcome.

The web app calls this **after a successful sign-in**
(`AuthContext.tsx → registerPushTokenIfAvailable`) so the prompt has
context. Cold-start prompts have ~30% acceptance vs ~60–70% with context.
