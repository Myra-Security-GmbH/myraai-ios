/**
 * PrivacyPolicy.tsx — Public, unauthenticated privacy policy for the MYRA AI
 * mobile apps and web app. Linked from the Google Play Store listing, the
 * Apple App Store listing, and the in-app login screen.
 *
 * Reachable at /privacy. Must remain reachable without authentication —
 * Play Store and App Store reviewers will not log in.
 */

import { Link } from "react-router-dom";

const EFFECTIVE_DATE = "27 April 2026";
const CORPORATE_POLICY_URL = "https://www.myrasecurity.com/en/privacy-policy/";
const CONTACT_EMAIL = "info@myrasecurity.com";

export default function PrivacyPolicy() {
  return (
    <div style={containerStyle}>
      <header style={headerStyle}>
        <h1 style={titleStyle}>MYRA AI — Privacy Policy</h1>
        <p style={metaStyle}>Effective {EFFECTIVE_DATE}</p>
      </header>

      <section style={sectionStyle}>
        <p>
          This policy describes how Myra Security GmbH ("we", "us") processes
          personal data when you use the <strong>MYRA AI</strong> product —
          the web application at <code>ai.myra.eu</code> and the MYRA AI
          mobile apps for iOS and Android. It supplements our{" "}
          <a href={CORPORATE_POLICY_URL} target="_blank" rel="noopener noreferrer">
            corporate privacy policy
          </a>
          , which covers our public website, sales process, and
          DDoS-protection, WAF, CDN, and bot-management products. Where the
          two policies overlap, this policy prevails for MYRA AI.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2 style={h2Style}>1. Who we are</h2>
        <p>
          Myra Security GmbH<br />
          Landsberger Str. 187, 80687 München, Germany<br />
          Phone: +49 89 41 41 41 – 345<br />
          Email: <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>
        </p>
        <p>
          Our Data Protection Officer can be reached at the same address by
          letter marked "Data Protection Officer" or by email to{" "}
          <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2 style={h2Style}>2. What MYRA AI is</h2>
        <p>
          MYRA AI is a hosted gateway that routes conversational inference
          requests from end users to large language model providers selected
          by your organisation's administrator. Your administrator configures
          which providers, models, and policies apply to your account.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2 style={h2Style}>3. Data we process</h2>

        <h3 style={h3Style}>3.1 Account data</h3>
        <p>
          Email address, display name, organisation (tenant), role, language
          preference, and authentication state. We use email for login
          (one-time code) and for service-related notifications.
        </p>

        <h3 style={h3Style}>3.2 Conversation content</h3>
        <p>
          The prompts you send, the assistant responses you receive, files
          you upload for processing, and any project-level instructions
          configured by your administrator. Conversations are stored in our
          database under your account so you can return to them.
        </p>

        <h3 style={h3Style}>3.3 Mobile app data</h3>
        <p>
          When you use the iOS or Android app we additionally process:
        </p>
        <ul>
          <li>
            <strong>Push notification token</strong> (Apple Push Notification
            service token on iOS; Firebase Cloud Messaging token on Android),
            so we can deliver notifications to your device. Tokens are bound
            to your signed-in account and revoked server-side when you sign
            out or uninstall.
          </li>
          <li>
            <strong>Device information</strong>: operating system, OS
            version, app version, device model, and language. Used to
            diagnose compatibility issues.
          </li>
        </ul>

        <h3 style={h3Style}>3.4 Technical and security data</h3>
        <p>
          IP address, request timestamps, user-agent, gateway and model
          selected per request, error codes, and rate-limit counters. Server
          access logs are anonymised after seven days.
        </p>

        <h3 style={h3Style}>3.5 Reports and feedback</h3>
        <p>
          If you flag a model response as offensive, inaccurate, or unsafe,
          we record the reported message, the conversation ID, your account
          ID, and the time of the report so we can review it and improve
          our content filtering.
        </p>

        <h3 style={h3Style}>3.6 What we do <em>not</em> collect</h3>
        <p>
          We do not collect contacts, calendar, photos, microphone input,
          camera input, precise or approximate location, or advertising IDs.
          The mobile apps contain no third-party advertising or analytics
          SDKs.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2 style={h2Style}>4. Why we process this data (legal bases)</h2>
        <ul>
          <li>
            <strong>Performance of the contract</strong> (Art. 6(1)(b) GDPR)
            — to authenticate you, run your inference requests, store and
            display your conversations, and deliver notifications you
            enabled.
          </li>
          <li>
            <strong>Legitimate interest</strong> (Art. 6(1)(f) GDPR) — to
            secure the service against abuse and fraud, to debug errors, and
            to improve content moderation.
          </li>
          <li>
            <strong>Legal obligation</strong> (Art. 6(1)(c) GDPR) — to comply
            with retention, tax, and law-enforcement requirements where they
            apply.
          </li>
          <li>
            <strong>Consent</strong> (Art. 6(1)(a) GDPR) — for push
            notifications. You may withdraw consent at any time in your
            device settings.
          </li>
        </ul>
      </section>

      <section style={sectionStyle}>
        <h2 style={h2Style}>5. Who we share data with</h2>

        <h3 style={h3Style}>5.1 AI model providers</h3>
        <p>
          When you send a prompt, MYRA AI forwards it to the model provider
          selected for your gateway. Depending on what your administrator
          has configured, this may include:
        </p>
        <ul>
          <li>Anthropic, PBC (United States)</li>
          <li>OpenAI, L.L.C. (United States)</li>
          <li>Google LLC / Google Cloud (United States, EU regions)</li>
          <li>Mistral AI SAS (France)</li>
          <li>Cohere Inc. (Canada / United States)</li>
          <li>
            Self-hosted open-weight models (e.g. vLLM) operated by Myra
            Security GmbH or by your organisation
          </li>
        </ul>
        <p>
          Each provider processes prompts and responses under its own terms.
          Your administrator can confirm which providers are enabled for
          your gateway. We have data processing agreements with each
          provider we expose by default.
        </p>

        <h3 style={h3Style}>5.2 Mobile push delivery</h3>
        <p>
          Push notifications are delivered through Apple Push Notification
          service (Apple Inc., United States) on iOS and Firebase Cloud
          Messaging (Google LLC, United States) on Android. Notification
          payloads contain only what is needed to render the notification
          and to open the relevant conversation.
        </p>

        <h3 style={h3Style}>5.3 Email delivery</h3>
        <p>
          Login codes and service emails are dispatched via Mailjet (Mailgun
          Technologies / Sinch, France / United States).
        </p>

        <h3 style={h3Style}>5.4 Hosting</h3>
        <p>
          Application servers and databases are operated on Microsoft Azure
          infrastructure (Microsoft Ireland Operations Ltd., EU regions).
        </p>

        <h3 style={h3Style}>5.5 Authorities</h3>
        <p>
          We disclose data to law-enforcement or regulatory authorities only
          where we are legally required to do so.
        </p>
        <p>
          We do not sell personal data, and we do not share it for
          third-party advertising.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2 style={h2Style}>6. International transfers</h2>
        <p>
          Several recipients listed in section 5 are based outside the
          European Economic Area, primarily in the United States. Transfers
          are safeguarded by the EU–US Data Privacy Framework where
          applicable, and otherwise by the European Commission's Standard
          Contractual Clauses (SCCs) together with supplementary technical
          measures.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2 style={h2Style}>7. Retention</h2>
        <ul>
          <li>
            <strong>Account</strong>: retained for as long as you have an
            account with us. If you delete your account from inside the app
            (see section 9), the account record is preserved so an
            administrator can restore it on request; you are signed out and
            cannot sign in again until an administrator restores it. To
            request permanent erasure, see section 9.
          </li>
          <li>
            <strong>Conversations and uploaded files</strong>: kept until you
            or your administrator delete them individually. They are not
            removed when you delete your account in the app; on restore,
            they remain available.
          </li>
          <li>
            <strong>Push tokens</strong>: removed on sign-out (which includes
            in-app account deletion), on uninstall detection, and on token
            rotation.
          </li>
          <li>
            <strong>Server access logs</strong>: anonymised after 7 days.
          </li>
          <li>
            <strong>Content reports</strong>: retained for up to 24 months
            for moderation review and abuse-pattern analysis, then deleted.
          </li>
          <li>
            <strong>Billing records and contracts</strong>: retained for the
            period required by German tax and commercial law (typically
            10 years).
          </li>
        </ul>
      </section>

      <section style={sectionStyle}>
        <h2 style={h2Style}>8. Your rights</h2>
        <p>
          Subject to GDPR you have the right to access, rectify, erase, or
          port your personal data, the right to restrict or object to
          processing, and the right to withdraw consent. To exercise any of
          these, contact{" "}
          <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>. You also
          have the right to lodge a complaint with a supervisory authority;
          our lead authority is the Bayerisches Landesamt für
          Datenschutzaufsicht (BayLDA).
        </p>
      </section>

      <section style={sectionStyle}>
        <h2 style={h2Style}>9. Deleting your account or requesting permanent erasure</h2>

        <p>
          MYRA AI offers two distinct paths, with different effects on your
          data.
        </p>

        <h3 style={h3Style}>9.1 Deleting your account in the app (reversible by an administrator)</h3>
        <p>
          In the app, open Profile → "Delete Account" and confirm. This
          immediately:
        </p>
        <ul>
          <li>signs you out and prevents further sign-in attempts;</li>
          <li>removes your registered push notification tokens so we no longer send notifications to your devices.</li>
        </ul>
        <p>
          Your conversations, uploaded files, feedback, content reports, and
          the account record itself are <strong>retained</strong> so an
          administrator can restore your account on request. Restoration is
          performed only by an administrator on your written request to{" "}
          <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>; you cannot
          reactivate the account yourself.
        </p>

        <h3 style={h3Style}>9.2 Permanent erasure (GDPR Art. 17)</h3>
        <p>
          To have your personal data permanently erased, write to{" "}
          <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a> from your
          registered address with the subject "Erase my MYRA AI data". We
          will confirm completion within 30 days. Permanent erasure is
          <strong>irreversible</strong>: your conversations, uploaded files,
          feedback, content reports, and account record are removed and
          cannot be restored. Records that we are legally required to retain
          (for example billing and tax records, see section 7) are kept for
          the statutory period.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2 style={h2Style}>10. Generative AI — what you should know</h2>
        <p>
          MYRA AI surfaces output from large language models. Model output
          can be inaccurate, incomplete, biased, or otherwise inappropriate.
          Do not rely on it for medical, legal, financial, or safety-critical
          decisions without independent review. Do not enter information you
          would not want stored or processed by the model providers listed in
          section 5.
        </p>
        <p>
          Each assistant message can be reported from inside the app
          (long-press or overflow menu → "Report"). Reports are reviewed by
          our team and used to improve filtering. Reports do not generate
          automated responses.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2 style={h2Style}>11. Security</h2>
        <p>
          All connections to MYRA AI use TLS 1.2 or higher. Provider API
          keys, OAuth secrets, and other credentials are encrypted at rest
          using authenticated symmetric encryption and a master key held
          outside the application database. Access to production systems is
          restricted to authorised personnel and audited.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2 style={h2Style}>12. Children</h2>
        <p>
          MYRA AI is not directed to children. The service is intended for
          users aged 18 and over. We do not knowingly process personal data
          from children. If you believe a child has used the service,
          contact{" "}
          <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a> and we will
          delete the account.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2 style={h2Style}>13. Changes to this policy</h2>
        <p>
          When we make material changes we will update the effective date at
          the top of this page and, where appropriate, notify you in the
          app.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2 style={h2Style}>14. Contact</h2>
        <p>
          Questions about this policy or your data:{" "}
          <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>.
        </p>
      </section>

      <footer style={footerStyle}>
        <Link to="/login" style={linkStyle}>← Back to sign in</Link>
        <span style={{ margin: "0 12px", color: "var(--text-secondary, #888)" }}>·</span>
        <a
          href={CORPORATE_POLICY_URL}
          target="_blank"
          rel="noopener noreferrer"
          style={linkStyle}
        >
          Corporate privacy policy
        </a>
      </footer>
    </div>
  );
}

const containerStyle: React.CSSProperties = {
  maxWidth: 820,
  margin: "0 auto",
  padding: "48px 24px 96px",
  fontFamily: "inherit",
  fontSize: 15,
  lineHeight: 1.65,
  color: "var(--text-primary, #111)",
  backgroundColor: "var(--content-bg, #fff)",
  minHeight: "100vh",
};

const headerStyle: React.CSSProperties = {
  borderBottom: "1px solid var(--card-border, #e5e5e5)",
  paddingBottom: 16,
  marginBottom: 32,
};

const titleStyle: React.CSSProperties = {
  margin: 0,
  fontSize: 28,
  fontWeight: 700,
  color: "var(--text-primary, #111)",
};

const metaStyle: React.CSSProperties = {
  margin: "8px 0 0",
  color: "var(--text-secondary, #666)",
  fontSize: 14,
};

const sectionStyle: React.CSSProperties = {
  marginBottom: 28,
};

const h2Style: React.CSSProperties = {
  fontSize: 20,
  fontWeight: 600,
  margin: "0 0 12px",
  color: "var(--text-primary, #111)",
};

const h3Style: React.CSSProperties = {
  fontSize: 16,
  fontWeight: 600,
  margin: "20px 0 8px",
  color: "var(--text-primary, #111)",
};

const footerStyle: React.CSSProperties = {
  marginTop: 48,
  paddingTop: 24,
  borderTop: "1px solid var(--card-border, #e5e5e5)",
  textAlign: "center",
  fontSize: 14,
  color: "var(--text-secondary, #666)",
};

const linkStyle: React.CSSProperties = {
  color: "var(--accent, #2563eb)",
  textDecoration: "none",
};
