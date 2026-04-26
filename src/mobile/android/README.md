# MYRA AI — Android App

WebView wrapper for [ai.myra.eu](https://ai.myra.eu).

## Requirements

- Android Studio Hedgehog (2023.1.1) or newer
- Android SDK 35, minSdk 26 (Android 8.0+)
- Gradle 8.4 / AGP 8.3.1 / Kotlin 1.9.22

## First-time setup

The `gradle/wrapper/gradle-wrapper.jar` is not committed. Open the project in
Android Studio — it will download Gradle and generate the JAR automatically.

Alternatively, if Gradle is installed on your machine:

```sh
cd src/mobile/android
gradle wrapper --gradle-version 8.4
./gradlew assembleRelease
```

## Build

```sh
cd src/mobile/android

# Debug APK (for sideloading / development)
./gradlew assembleDebug
# → app/build/outputs/apk/debug/app-debug.apk

# Release AAB (required for Google Play)
./gradlew bundleRelease
# → app/build/outputs/bundle/release/app-release.aab
```

Sign the release AAB with your Play Store upload key before uploading.

## Android App Links

The app opens `https://ai.myra.eu` URLs directly (no browser chooser) via
Android App Links. The Digital Asset Links JSON file must be served at:

```
https://ai.myra.eu/.well-known/assetlinks.json
```

See `src/mobile/android/assetlinks.json` for the template. Replace
`YOUR_SHA256_CERT_FINGERPRINT` with the SHA-256 of your release signing
certificate:

```sh
keytool -list -v -keystore your-release-key.jks | grep SHA256
```

## Features

- Loads `https://ai.myra.eu` in a full-screen WebView
- Session cookies persist across app restarts
- File upload via the OS file picker (`<input type="file">`)
- Edge-to-edge display; keyboard pushes the WebView up
- Offline error screen with Retry button
- App Links: tapping `https://ai.myra.eu` links opens the app directly
- Custom User-Agent: appends `MYRAai-Android/1.0`
- Splash screen (AndroidX SplashScreen API) with MYRA flame logo
