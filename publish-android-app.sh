#!/usr/bin/env bash
# publish-android-app.sh — Build, sign, and publish the MYRA AI Android app to Google Play.
#
# Usage:
#   bash publish-android-app.sh [TRACK] [RELEASE_NOTES]
#
# TRACK (optional, default: internal):
#   internal    Internal testing (fastest, no review)
#   alpha       Closed testing
#   beta        Open testing
#   production  Live release
#
# RELEASE_NOTES (optional):
#   Short description shown in Play Console for this release.
#   Default: auto-generated from git log.
#
# Examples:
#   bash publish-android-app.sh
#   bash publish-android-app.sh internal
#   bash publish-android-app.sh production "Bug fixes and performance improvements"

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SA_KEY="/home/sas/myraaigw-c2c6cbba0403.json"
PACKAGE_NAME="eu.myra.myraai"
ANDROID_DIR="$SCRIPT_DIR/src/mobile/android"
BUILD_GRADLE="$ANDROID_DIR/app/build.gradle"
AAB_OUT="$ANDROID_DIR/app/build/outputs/bundle/release/app-release.aab"
APK_OUT="$ANDROID_DIR/app/build/outputs/apk/release/app-release.apk"
PUBLIC_APK="$SCRIPT_DIR/frontend/public/android.apk"

TRACK="${1:-internal}"
RELEASE_NOTES="${2:-}"

# ── Colour helpers ─────────────────────────────────────────────────────────────
green()  { echo -e "\033[32m✓ $*\033[0m"; }
blue()   { echo -e "\033[34m▶ $*\033[0m"; }
yellow() { echo -e "\033[33m⚠ $*\033[0m"; }
red()    { echo -e "\033[31m✗ $*\033[0m"; exit 1; }

# ── Validate ──────────────────────────────────────────────────────────────────
blue "Validating prerequisites..."
[[ -f "$SA_KEY" ]]         || red "Service account key not found: $SA_KEY"
[[ -f "$BUILD_GRADLE" ]]   || red "build.gradle not found: $BUILD_GRADLE"
python3 -c "from googleapiclient.discovery import build; from google.oauth2.service_account import Credentials" \
  2>/dev/null               || red "Python deps missing — run: pip3 install google-auth google-api-python-client"
case "$TRACK" in internal|alpha|beta|production) ;; *)
  red "Invalid track '$TRACK'. Use: internal | alpha | beta | production" ;;
esac
green "Prerequisites OK"

# ── Auto-increment versionCode ────────────────────────────────────────────────
blue "Incrementing versionCode..."
CURRENT_VC=$(grep 'versionCode' "$BUILD_GRADLE" | grep -oP '\d+')
NEW_VC=$((CURRENT_VC + 1))
sed -i "s/versionCode $CURRENT_VC/versionCode $NEW_VC/" "$BUILD_GRADLE"
green "versionCode $CURRENT_VC → $NEW_VC"

# ── Auto-generate release notes if not provided ───────────────────────────────
if [[ -z "$RELEASE_NOTES" ]]; then
  RELEASE_NOTES="$(git -C "$SCRIPT_DIR" log --oneline -5 2>/dev/null | head -5 || echo "Release $NEW_VC")"
fi

# ── Build AAB + APK ──────────────────────────────────────────────────────────
blue "Building release AAB and APK (versionCode $NEW_VC)..."
cd "$ANDROID_DIR"
./gradlew assembleRelease bundleRelease 2>/dev/null | grep -E "^(BUILD|Task|>)" | tail -8
green "Build successful"

# ── Copy APK to frontend/public for sideload download ────────────────────────
blue "Copying APK to frontend/public/android.apk..."
cp "$APK_OUT" "$PUBLIC_APK"
green "APK available at frontend/public/android.apk ($(du -h "$PUBLIC_APK" | cut -f1))"

# ── Upload AAB to Google Play ─────────────────────────────────────────────────
blue "Uploading AAB to Google Play track '$TRACK'..."
UPLOAD_RESULT=$(python3 - <<PYEOF
import sys, json
try:
    from googleapiclient.discovery import build
    from googleapiclient.http import MediaFileUpload
    from google.oauth2.service_account import Credentials
except ImportError:
    print("ERROR: pip3 install google-auth google-api-python-client")
    sys.exit(1)

SA_KEY      = "$SA_KEY"
PACKAGE     = "$PACKAGE_NAME"
AAB_PATH    = "$AAB_OUT"
TRACK       = "$TRACK"
NOTES       = """$RELEASE_NOTES"""

creds   = Credentials.from_service_account_file(SA_KEY,
            scopes=["https://www.googleapis.com/auth/androidpublisher"])
service = build("androidpublisher", "v3", credentials=creds, cache_discovery=False)

# Open edit
edit    = service.edits().insert(packageName=PACKAGE, body={}).execute()
edit_id = edit["id"]

try:
    # Upload AAB
    media  = MediaFileUpload(AAB_PATH, mimetype="application/octet-stream", resumable=True)
    bundle = service.edits().bundles().upload(
                packageName=PACKAGE, editId=edit_id, media_body=media).execute()
    vc = bundle["versionCode"]

    # Build release object
    release = {"versionCodes": [str(vc)], "status": "completed"}
    if NOTES.strip():
        release["releaseNotes"] = [{"language": "en-US", "text": NOTES.strip()[:500]}]

    # Update track
    service.edits().tracks().update(
        packageName=PACKAGE, editId=edit_id, track=TRACK,
        body={"releases": [release]}).execute()

    # Commit
    service.edits().commit(packageName=PACKAGE, editId=edit_id).execute()
    print(f"OK versionCode={vc} track={TRACK}")

except Exception as exc:
    # Rollback edit on error
    try: service.edits().delete(packageName=PACKAGE, editId=edit_id).execute()
    except: pass
    print(f"ERROR {exc}", file=sys.stderr)
    sys.exit(1)
PYEOF
)

if [[ "$UPLOAD_RESULT" == ERROR* ]]; then
    red "Play Store upload failed: $UPLOAD_RESULT"
fi
green "$UPLOAD_RESULT"

# ── Commit versionCode change ─────────────────────────────────────────────────
blue "Committing versionCode bump to master..."
cd "$SCRIPT_DIR"
git add src/mobile/android/app/build.gradle frontend/public/android.apk
git commit -m "chore(android): bump versionCode to $NEW_VC, publish to $TRACK" \
  --no-verify 2>/dev/null || yellow "Nothing new to commit (already up to date)"
git push origin master 2>/dev/null && green "Pushed to master" || yellow "Push skipped"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
green "Published MYRA AI versionCode $NEW_VC to Play Store"
echo "  Track:   $TRACK"
echo "  Package: $PACKAGE_NAME"
echo "  AAB:     $(du -h "$AAB_OUT" | cut -f1)"
echo "  Console: https://play.google.com/console/developers"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
