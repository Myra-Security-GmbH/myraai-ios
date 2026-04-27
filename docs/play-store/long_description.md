# MYRA AI — Play Store + App Store listing copy

Reference text for the Google Play Console and Apple App Store Connect
listing fields. The same copy is fine for both stores; trim for App Store
character limits where noted.

---

## Short description (≤80 characters, Play Console)

A secure AI gateway for your business — bring your own provider, keep your data in Europe.

## Subtitle (≤30 characters, App Store)

Your team's AI gateway

## Promotional text (App Store, ≤170 chars, can be edited without resubmission)

Bring your own model provider keys. Conversations stay tied to your tenant. EU-hosted, audit-ready.

---

## Long description (≤4000 characters, Play Console)

MYRA AI is a hosted gateway for businesses that want to use generative AI
on their own terms. Your administrator configures which model providers
(Anthropic, OpenAI, Google, Mistral, Cohere, or self-hosted open-weight
models) the app can route to, and which models, policies, and rate
limits apply to your account.

### What you can do

- Chat with the model your administrator selected, on the topics and
  documents you care about.
- Upload files (text, PDF, images, spreadsheets, …) for processing —
  retention is governed by your tenant's policy.
- Pick up where you left off — your conversations are saved to your
  account and synchronised between web, iOS, and Android.
- Get push notifications when a long-running response completes or a
  team-mate adds you to a project.
- Long-press any assistant message to **report** offensive, unsafe, or
  inaccurate output. Reports go straight to our moderation team.

### What MYRA AI is not

- It is **not** a consumer chatbot. You need a tenant invitation from
  your organisation's administrator to sign in.
- It is **not** ad-supported. We do not sell or share your data for
  third-party advertising. We do not train models on your conversations.
- It is **not** a replacement for human judgement. Generative AI output
  can be wrong, incomplete, or biased. Treat it as a starting point —
  not a final answer — for medical, legal, financial, or safety-critical
  decisions.

### Privacy & security

- All connections use TLS 1.2 or higher.
- Provider API keys, OAuth secrets, and other credentials are encrypted
  at rest with a master key held outside the application database.
- Your prompts and uploads are forwarded to the model provider your
  administrator selected — listed by name in our privacy policy.
- The app collects only what is required for the service to work:
  account email, conversation content, push tokens, and basic device
  information for diagnostics. There are no advertising SDKs or
  third-party analytics in the app.
- You can delete your account from the app at any time. Permanent
  erasure (GDPR Art. 17) is available on request — see our privacy
  policy.

Privacy policy: https://ai.myra.eu/privacy
Account deletion: https://ai.myra.eu/privacy#delete

Operated by Myra Security GmbH, Munich, Germany.

---

## What's new (release notes — Play Console + App Store)

Stub — replace per release.

---

## Account-deletion field (Play Console listing → "Account deletion")

URL where users can request deletion: https://ai.myra.eu/privacy#delete

(In-app path: open Profile → Delete Account.)

---

## Data Safety / App Privacy reference

Use this when filling the Play Console "Data Safety" section and the
App Store Connect "App Privacy" section. Each row must be consistent
with the privacy policy.

| Data type | Collected? | Shared with third parties? | Required / optional | Purpose |
|---|---|---|---|---|
| Email address | Yes | No | Required | Account |
| User ID | Yes | No | Required | Account, app functionality |
| Messages (in app) | Yes | Yes — model providers (see policy §5.1) | Required | App functionality |
| Files & docs | Yes | Yes — model providers | Optional | App functionality |
| Device or other IDs (push tokens) | Yes | Yes — Apple APNs / Google FCM (delivery) | Optional | App functionality (notifications) |
| Crash logs | No | — | — | — |
| Diagnostics | No | — | — | — |
| Advertising data | No | — | — | — |
| Location | No | — | — | — |

**Encryption in transit:** Yes
**Data deletion mechanism:** Yes — in-app + email request
