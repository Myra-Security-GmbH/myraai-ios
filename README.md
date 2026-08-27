# MYRA AI — iOS App

WKWebView wrapper for `https://ai.myra.eu`. Swift + SwiftUI, iOS 16+, universal (iPhone + iPad).

## Requirements

- macOS 14+ (Sonoma) or macOS 13+ (Ventura)
- Xcode 15+
- Apple Developer account: Team `A4C54HLPJ7`

## Open and run

```bash
open src/mobile/ios/MYRAai.xcodeproj
```

Select the `MYRAai` scheme → choose an iPhone 16 simulator → **Cmd+R**.

## Build from command line

```bash
xcodebuild \
  -project src/mobile/ios/MYRAai.xcodeproj \
  -scheme MYRAai \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -configuration Debug \
  clean build
```

Expected: `** BUILD SUCCEEDED **`

## Archive for TestFlight / App Store

In Xcode: **Product → Archive** → Xcode Organizer opens → **Distribute App** → **App Store Connect** → upload.

Or via CLI:

```bash
xcodebuild \
  -project src/mobile/ios/MYRAai.xcodeproj \
  -scheme MYRAai \
  -sdk iphoneos \
  -configuration Release \
  archive \
  -archivePath /tmp/MYRAai.xcarchive

xcodebuild \
  -exportArchive \
  -archivePath /tmp/MYRAai.xcarchive \
  -exportPath /tmp/MYRAai-export \
  -exportOptionsPlist src/mobile/ios/ExportOptions.plist
```

## App Store submission checklist

- [ ] Active Apple Developer Program membership (Team A4C54HLPJ7, expires Feb 2027) ✓
- [ ] App created in App Store Connect: bundle ID `eu.myra.myraai`, name "MYRA AI" ✓
- [ ] Distribution certificate + provisioning profile (created automatically by Xcode with Automatic Signing) 
- [ ] Privacy Manifest (`PrivacyInfo.xcprivacy`) included ✓
- [ ] App Privacy nutrition label filled in App Store Connect (no data collected)
- [ ] Privacy policy URL: `https://www.myrasecurity.com/en/privacy-policy/` ✓
- [ ] App screenshots (iPhone 6.7", iPhone 5.5", iPad 12.9") — take from Simulator
- [ ] 1024×1024 App Store icon (no alpha) — generated at `src/mobile/ios/MYRAai/Assets.xcassets/AppIcon.appiconset/icon-1024.png` ✓
- [ ] Upload build to TestFlight and invite internal testers
- [ ] Submit for App Store review

## Universal Links

The `apple-app-site-association` file is served at `https://ai.myra.eu/.well-known/apple-app-site-association`. Tapping any `https://ai.myra.eu/*` link opens directly in the app.

Enable in Xcode: **Signing & Capabilities → + Capability → Associated Domains** → add `applinks:ai.myra.eu`.
