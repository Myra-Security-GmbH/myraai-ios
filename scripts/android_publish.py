#!/usr/bin/env python3
"""
android_publish.py — Upload a signed Android AAB to Google Play and assign it to a track.

Usage:
    python3 scripts/android_publish.py [--track TRACK] [--aab PATH] [--release-notes TEXT]

Options:
    --track       internal | alpha | beta | production  (default: internal)
    --aab         path to .aab file  (default: src/mobile/android/app/build/outputs/bundle/release/app-release.aab)
    --release-notes  plain-text release notes (optional)
    --key         path to service account JSON key  (default: /home/sas/myraaigw-c2c6cbba0403.json)
    --package     Android package name  (default: eu.myra.myraai)
    --dry-run     validate and upload but do not commit the edit

Requires:
    pip install google-api-python-client google-auth
"""

import argparse
import json
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULTS = {
    "key":     "/home/sas/myraaigw-c2c6cbba0403.json",
    "aab":     os.path.join(REPO_ROOT, "src/mobile/android/app/build/outputs/bundle/release/app-release.aab"),
    "package": "eu.myra.myraai",
    "track":   "internal",
}


def build_service(key_file: str):
    from googleapiclient.discovery import build
    from google.oauth2 import service_account
    creds = service_account.Credentials.from_service_account_file(
        key_file,
        scopes=["https://www.googleapis.com/auth/androidpublisher"],
    )
    return build("androidpublisher", "v3", credentials=creds)


def _do_upload(service, package: str, edit_id: str, aab_path: str,
               track: str, release_notes: str | None, status: str) -> int:
    from googleapiclient.http import MediaFileUpload

    media = MediaFileUpload(aab_path, mimetype="application/octet-stream", resumable=False)
    bundle = service.edits().bundles().upload(
        packageName=package, editId=edit_id, media_body=media,
    ).execute()
    version_code = int(bundle["versionCode"])
    print(f"AAB uploaded — versionCode: {version_code}")

    release: dict = {"versionCodes": [str(version_code)], "status": status}
    if release_notes:
        release["releaseNotes"] = [{"language": "en-US", "text": release_notes}]
    service.edits().tracks().update(
        packageName=package, editId=edit_id, track=track,
        body={"track": track, "releases": [release]},
    ).execute()
    print(f"Assigned versionCode {version_code} to track '{track}' (status={status})")
    return version_code


def upload(service, package: str, aab_path: str, track: str,
           release_notes: str | None, dry_run: bool) -> int:
    print(f"Package  : {package}")
    print(f"AAB      : {aab_path}")
    print(f"Track    : {track}")
    print(f"Dry-run  : {dry_run}")
    print()

    # Try completed status first; fall back to draft if the app is still in draft state.
    for status in ("completed", "draft"):
        edit = service.edits().insert(packageName=package, body={}).execute()
        edit_id = edit["id"]
        print(f"Edit created: {edit_id}")
        try:
            version_code = _do_upload(service, package, edit_id, aab_path,
                                      track, release_notes, status)
        except Exception:
            service.edits().delete(packageName=package, editId=edit_id).execute()
            raise

        if dry_run:
            service.edits().delete(packageName=package, editId=edit_id).execute()
            print("Dry-run: edit abandoned (not committed)")
            return version_code

        try:
            committed = service.edits().commit(packageName=package, editId=edit_id).execute()
            print(f"Edit committed: {committed.get('id')}")
            print(f"\nDone — versionCode {version_code} is live on the '{track}' track.")
            return version_code
        except Exception as e:
            if "draft" in str(e).lower() and status == "completed":
                print("App is in draft state — retrying with status=draft")
                continue
            raise

    raise RuntimeError("Upload failed: app remains in draft state")


def main():
    p = argparse.ArgumentParser(description="Upload Android AAB to Google Play")
    p.add_argument("--track",         default=DEFAULTS["track"],
                   choices=["internal", "alpha", "beta", "production"])
    p.add_argument("--aab",           default=DEFAULTS["aab"])
    p.add_argument("--key",           default=DEFAULTS["key"])
    p.add_argument("--package",       default=DEFAULTS["package"])
    p.add_argument("--release-notes", default=None)
    p.add_argument("--dry-run",       action="store_true")
    args = p.parse_args()

    if not os.path.isfile(args.aab):
        print(f"ERROR: AAB not found: {args.aab}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(args.key):
        print(f"ERROR: Service account key not found: {args.key}", file=sys.stderr)
        sys.exit(1)

    try:
        service = build_service(args.key)
    except Exception as e:
        print(f"ERROR: Failed to build Play API service: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        upload(
            service,
            package=args.package,
            aab_path=args.aab,
            track=args.track,
            release_notes=args.release_notes,
            dry_run=args.dry_run,
        )
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
