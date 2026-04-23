#!/usr/bin/env python3
"""
yt.py — YouTrack CLI helper for the AI Gateway project.

Usage:
  python3 yt.py list     [QUERY]              # list open issues (default: #AGF #Unresolved)
  python3 yt.py get      ISSUE-ID             # full issue details
  python3 yt.py comments ISSUE-ID             # list all comments on an issue
  python3 yt.py comment  ISSUE-ID TEXT        # post a comment (TEXT or - to read from stdin)
  python3 yt.py stage    ISSUE-ID STAGE       # set Stage field (Done, Backlog, "Feedback needed", etc.)
  python3 yt.py field    ISSUE-ID NAME VALUE  # set any single-enum custom field
  python3 yt.py create   PROJECT SUMMARY [DESCRIPTION]  # create a new issue
  python3 yt.py update   ISSUE-ID SUMMARY [DESCRIPTION] # update summary / description

Environment / config:
  YT_TOKEN  — permanent token (or hardcoded fallback below)
  YT_BASE   — base URL (default: https://youtrack.myra.security)
"""

import sys, os, json, textwrap
import urllib.request, urllib.error

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TOKEN = os.environ.get("YT_TOKEN", "perm-c2FzY2hhLnNjaHVtYW5u.NDgtNjI=.1g0TjPv2DcgXYQKmVSyte699aICulb")
BASE  = os.environ.get("YT_BASE",  "https://youtrack.myra.security")

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

def _req(method: str, path: str, body=None):
    url  = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req  = urllib.request.Request(
        url, data=data, method=method,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept":        "application/json",
            **({"Content-Type": "application/json"} if data else {}),
        },
    )
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        body_txt = e.read().decode(errors="replace")
        print(f"HTTP {e.code} {e.reason}: {body_txt}", file=sys.stderr)
        sys.exit(1)

def get(path):    return _req("GET",    path)
def post(path, body): return _req("POST",   path, body)

# ---------------------------------------------------------------------------
# Field helpers
# ---------------------------------------------------------------------------

def _cfs(issue: dict) -> dict:
    """Return {name: value_name} for all custom fields that have a value."""
    out = {}
    for f in issue.get("customFields", []):
        v = f.get("value")
        if isinstance(v, dict):
            out[f["name"]] = v.get("name", "")
        elif isinstance(v, list):
            out[f["name"]] = ", ".join(x.get("name", str(x)) for x in v)
        elif v is not None:
            out[f["name"]] = str(v)
    return out


def _fmt_issue(d: dict, verbose=False) -> str:
    cfs   = _cfs(d)
    stage  = cfs.get("Stage", "—")
    effort = cfs.get("Estimated Effort", "—")
    lines  = [f"{d['idReadable']:<10} [{stage:<18}] [{effort:<4}]  {d['summary']}"]
    if verbose:
        if d.get("description"):
            wrapped = textwrap.indent(textwrap.fill(d["description"], 88), "    ")
            lines.append(wrapped)
        # Show all non-empty custom fields
        for k, v in cfs.items():
            if k not in ("Stage", "Estimated Effort") and v:
                lines.append(f"    {k}: {v}")
    return "\n".join(lines)

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_list(args):
    query = args[0] if args else "#AGF #Unresolved"
    issues = get(
        f"/api/issues?query={urllib.parse.quote(query)}"
        f"&fields=idReadable,summary,customFields(name,value(name))"
        f"&%24top=100"
    )
    if not issues:
        print("No issues found.")
        return
    for d in issues:
        print(_fmt_issue(d))
    print(f"\nTotal: {len(issues)}")


def cmd_get(args):
    if not args:
        print("Usage: yt.py get ISSUE-ID", file=sys.stderr); sys.exit(1)
    issue_id = args[0]
    d = get(
        f"/api/issues/{issue_id}"
        f"?fields=idReadable,summary,description,customFields(name,value(name,presentation))"
    )
    print(_fmt_issue(d, verbose=True))


def cmd_comments(args):
    if not args:
        print("Usage: yt.py comments ISSUE-ID", file=sys.stderr); sys.exit(1)
    issue_id = args[0]
    import urllib.parse
    comments = get(
        f"/api/issues/{issue_id}/comments"
        f"?fields=id,text,author(login,fullName),created,updated,deleted"
        f"&%24top=100"
    )
    if not comments:
        print("No comments.")
        return
    import datetime
    for i, c in enumerate(comments, 1):
        if c.get("deleted"):
            continue
        ts = c.get("created", 0)
        dt = datetime.datetime.fromtimestamp(ts / 1000, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if ts else "?"
        author = c.get("author") or {}
        who = author.get("login") or author.get("fullName") or "unknown"
        print(f"--- Comment {i} [{dt}] by {who} (id: {c.get('id','?')}) ---")
        print(c.get("text", "").rstrip())
        print()


def cmd_comment(args):
    if len(args) < 2:
        print("Usage: yt.py comment ISSUE-ID TEXT  (or TEXT=- to read stdin)", file=sys.stderr)
        sys.exit(1)
    issue_id, text = args[0], args[1]
    if text == "-":
        text = sys.stdin.read()
    r = post(f"/api/issues/{issue_id}/comments", {"text": text})
    print(f"Comment posted: {r.get('id','?')}")


def cmd_stage(args):
    if len(args) < 2:
        print("Usage: yt.py stage ISSUE-ID STAGE", file=sys.stderr); sys.exit(1)
    issue_id, stage = args[0], args[1]
    r = post(f"/api/issues/{issue_id}", {
        "customFields": [{
            "name": "Stage",
            "$type": "StateIssueCustomField",
            "value": {"name": stage, "$type": "StateBundleElement"},
        }]
    })
    print(f"Stage set on {issue_id} → {stage}  (id: {r.get('id','?')})")


def cmd_field(args):
    if len(args) < 3:
        print("Usage: yt.py field ISSUE-ID FIELD-NAME VALUE", file=sys.stderr); sys.exit(1)
    issue_id, name, value = args[0], args[1], args[2]
    r = post(f"/api/issues/{issue_id}", {
        "customFields": [{
            "name": name,
            "$type": "SingleEnumIssueCustomField",
            "value": {"name": value, "$type": "EnumBundleElement"},
        }]
    })
    print(f"Field '{name}' set on {issue_id} → {value}  (id: {r.get('id','?')})")


def cmd_create(args):
    if len(args) < 2:
        print("Usage: yt.py create PROJECT SUMMARY [DESCRIPTION]", file=sys.stderr); sys.exit(1)
    project_id, summary = args[0], args[1]
    description = args[2] if len(args) > 2 else None
    body = {
        "summary": summary,
        "project": {"id": project_id},
        **({"description": description} if description else {}),
    }
    r = post("/api/issues?fields=idReadable,summary", body)
    print(f"Created: {r.get('idReadable','?')} — {r.get('summary','')}")


def cmd_update(args):
    if len(args) < 2:
        print("Usage: yt.py update ISSUE-ID SUMMARY [DESCRIPTION]", file=sys.stderr); sys.exit(1)
    issue_id, summary = args[0], args[1]
    body = {"summary": summary}
    if len(args) > 2:
        body["description"] = args[2]
    r = post(f"/api/issues/{issue_id}?fields=idReadable,summary", body)
    print(f"Updated: {r.get('idReadable', issue_id)}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

COMMANDS = {
    "list":     cmd_list,
    "get":      cmd_get,
    "comments": cmd_comments,
    "comment":  cmd_comment,
    "stage":    cmd_stage,
    "field":    cmd_field,
    "create":   cmd_create,
    "update":   cmd_update,
}

if __name__ == "__main__":
    import urllib.parse  # needed for cmd_list

    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(__doc__)
        sys.exit(0 if len(sys.argv) < 2 else 1)

    COMMANDS[sys.argv[1]](sys.argv[2:])
