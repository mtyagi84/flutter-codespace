Status: Approved 2026-08-28, not yet implemented — development starts next session.

# Email & WhatsApp Integration — plan

## Context
Came out of an advisory question ("what's the best and cheap way to do email/WhatsApp integration").
Researched the provider landscape, confirmed no messaging infrastructure exists in this app today, and
worked through two real design questions with the user before finalizing scope: (1) which use cases
actually matter, and (2) since this is a multi-tenant SaaS product, whose email address/WhatsApp number
should messages actually send from — the platform's or each tenant's own.

## Confirmed via schema/code search
- **No email/SMTP/WhatsApp infrastructure exists anywhere in this app today** — clean slate.
- **A proven, production-confirmed async job queue pattern already exists**: `ric_report_jobs` +
  `pg_cron` (migration 156, built for Product Movement Analysis, CONFIRMED running in Supabase). This is
  the natural foundation to extend for outbound messaging — a generic queue table any module can enqueue
  into, processed asynchronously, same "generic and reusable" design already proven in production.
- **A real architectural wrinkle**: every document PDF (Sales Invoice, PO, GRN, etc.) is currently
  rendered CLIENT-SIDE in Flutter at print time (`lib/core/printing/PrintEngine`) — no PDF bytes exist
  server-side. "Email this invoice as a PDF attachment" therefore isn't a trivial "queue a send job" —
  either (a) the Flutter app generates the PDF and uploads/attaches it at the moment the user clicks
  Send (works fine, online-only action, mirrors how Approve already requires connectivity), or (b) the
  PrintEngine's logic gets duplicated server-side (a real, separate undertaking, not recommended as a
  first step), or (c) a first version sends a plain-text/HTML summary instead of a PDF for the use cases
  that don't strictly need one. This is why document-sending is its own later phase, not Phase 1.

## Provider landscape (cheap + legitimate, no ban-risk shortcuts)

**Email** — cheapest legitimate options, in rough order of simplicity:
- Resend or Brevo (Sendinblue) — generous free tiers (Resend: 3,000/month; Brevo: 300/day), single REST
  API call, easy domain verification. Best "cheap and simple" starting point.
- Amazon SES — cheapest at real scale (~$0.10/1000 emails) but more setup (AWS account, domain/DKIM
  verification) — worth it only once volume outgrows the free tiers above.
- Existing company SMTP (Google Workspace/Office 365) if a tenant already pays for one — zero marginal
  cost for that tenant, offered as their own optional upgrade, not the primary platform-wide path.

**WhatsApp** — only one legitimate route exists:
- **Meta's own WhatsApp Business Platform (Cloud API), called DIRECTLY** — official, ToS-compliant, no
  ban risk. Calling it directly (not through a BSP wrapper like Twilio/360dialog/Gupshup) avoids that
  middleman's markup on top of Meta's own usage cost — the actual "cheapest" legitimate path. Free tier
  covers a meaningful volume of business-initiated conversations before per-conversation/per-message
  charges kick in (check Meta's current pricing at build/setup time — it's revised periodically).
- Unofficial libraries (browser-automation-based WhatsApp clients, e.g. Baileys-style tools) — free, but
  violate WhatsApp's Terms of Service and carry real risk of the business's own number being banned.
  **Not recommended**, flagged explicitly rather than presented as a valid "cheap" option.

## Critical WhatsApp constraint (must be understood before any build)
Meta's WhatsApp Business Cloud API requires every BUSINESS-INITIATED message (a payment reminder, an
invoice notice — anything not a live reply to a customer's own incoming message) to use a **pre-approved
Message Template**. Templates are submitted in Meta Business Manager and typically approved within
minutes to a day — a manual step in Meta's own UI, not automatable from this codebase. Every new
reminder/notice wording needs its own approved template before it can be sent. This directly affects
timeline: the WhatsApp channel cannot send anything for a given tenant until they have (a) a verified
Meta Business/WhatsApp Business Account and phone number, and (b) at least one approved template — both
outside my control, the tenant's own setup steps (I can guide, not perform them).

## Multi-tenancy model (this is a SaaS product — tenants are separate businesses)
- **WhatsApp: per-tenant ONLY, no shared/platform option.** A WhatsApp number is tied to one verified
  business identity — a shared platform number sending on behalf of many unrelated shops would look
  suspicious to end customers AND risks Meta's own quality-rating system throttling/banning the shared
  number for everyone at once. Every tenant configures their OWN Meta Business Account + WhatsApp Phone
  Number + access token in `ric_messaging_settings` (row per client_id+company_id) before this channel
  works for them. No platform default exists for WhatsApp — the UI says so plainly rather than implying
  it "just works."
- **Email: hybrid — platform default + tenant override.** A tenant who hasn't configured their own
  provider gets messages sent via the PLATFORM's own Resend account (Rigevedam's), with the tenant's
  business name as the display name and the tenant's own email as Reply-To — e.g. `"ABC Traders"
  <notifications@sakal-erp.com>`, Reply-To `abc@theirdomain.com` — so it works immediately with zero
  setup, and replies land with the tenant, not the platform. A tenant can later add their own Resend/
  SMTP credentials in `ric_messaging_settings` for full branding (their own domain in the From address)
  — `ric_messaging_settings.email_provider` distinguishes `PLATFORM_DEFAULT` (row may not even need to
  exist — absence = use platform default, same "missing row = default" convention already used for
  `ric_user_sales_controls`) vs `TENANT_SMTP`/`TENANT_RESEND` (their own credentials populated).
- One platform-level settings source (env/secrets, NOT a per-tenant table row) holds the shared Resend
  API key + platform sending domain — this is Rigevedam's own credential, not tenant data.

## Phased build plan

**Phase 1 — Foundation (next session)**
- `ric_outbound_messages` — generic queue table: channel (EMAIL/WHATSAPP), recipient, subject/
  template_key, payload JSONB, status (PENDING/SENT/FAILED), retry_count, error_message,
  related_doc_type/no (traceability back to the Sales Invoice/Bill/etc. that triggered it). Mirrors the
  proven `ric_report_jobs` pattern (migration 156, confirmed running in production).
- `ric_messaging_settings` — per-company (client_id+company_id) provider config: email_provider
  (PLATFORM_DEFAULT/TENANT_SMTP/TENANT_RESEND) + optional own API key/from-address/SMTP host; WhatsApp
  Business Account ID + Phone Number ID + access token (always tenant-owned, no default). Credentials-
  bearing — locked behind a restrictive RLS policy (company-admin-only read/write), separate from the
  general `auth_rw_<table>` convention, since these are real API secrets, not ordinary business data.
- `fn_enqueue_message` — generic function any module calls to queue a send (mirrors `fn_post_voucher`'s
  "one shared entry point" philosophy). Resolves EMAIL routing (platform default vs tenant's own) at
  send time by checking `ric_messaging_settings` for that tenant — missing row or `PLATFORM_DEFAULT`
  falls through to the platform credential; WhatsApp with no configured row simply fails clearly
  ("WhatsApp not configured for this company") rather than silently doing nothing.
- pg_cron worker using Supabase's `pg_net` extension to call Resend/Meta Graph API directly from
  Postgres — no Edge Function needed for plain text/HTML sends.
- Messaging Settings screen (company-admin-only, Setup module) — shows Email as "using platform default"
  with an optional "Connect your own email" upgrade path, and WhatsApp as a required setup with clear
  guidance (link out to Meta Business Manager, fields for Business Account ID/Phone Number ID/token once
  the tenant has them) — plus a Message Log report (reuses the existing generic reporting engine) to see
  sent/failed messages.
- **User's own setup steps, in parallel**: ONE platform-level Resend account (Rigevedam's, used as the
  email fallback for every tenant) + verified sending domain. WhatsApp setup is per-tenant and happens
  later, whenever a specific tenant wants that channel — not a Phase-1 blocker since Email can ship
  working for everyone immediately via the platform default. A short setup guide will be written for
  both, but the actual Meta/Resend account creation and verification steps are the user's/tenant's own.

**Phase 2 — Payment/Collection Reminders (first real use case, likely same session as Phase 1)**
- A "Send Reminder" action from the existing Pending Bills by Customer report/screen — enqueues a
  templated message (Email and/or WhatsApp) per overdue bill. Text-only, no PDF — the simplest real use
  case, proves the whole pipeline end-to-end before tackling document attachments.

**Phase 3 — Send Invoice/Quotation documents (future session)**
- Needs the PDF-attachment story resolved: Flutter generates the PDF via the existing PrintEngine at
  send-time and uploads it (Supabase Storage — a new integration point) rather than duplicating print
  logic server-side. WhatsApp additionally requires media to be uploaded to Meta's own media endpoint
  before it can be attached to a template message — real added complexity specific to this channel.
  Deferred, not built in Phase 1/2.

**Phase 4 — Internal staff alerts as extra channels (future session)**
- Extends the existing `ric_user_notifications` event system (migration 156) to also enqueue into
  `ric_outbound_messages` for users who opt into email/WhatsApp delivery — an additional channel for
  events that already exist, not a new event system. Deferred, not built in Phase 1/2.

## Verification (once Phase 1/2 are built)
1. A tenant with no `ric_messaging_settings` row can still send a Payment Reminder by Email (via
   platform default) — confirm the customer sees the tenant's own business name as sender and any reply
   goes to the tenant's own address.
2. A tenant WITHOUT WhatsApp configured gets a clear "WhatsApp not set up for this company" error, never
   a silent no-op, when trying to send via that channel.
3. A tenant WITH their own Resend credentials configured sends from their own domain, not the platform's.
4. The Message Log report shows PENDING → SENT (or FAILED with a real error message) status transitions
   correctly for both channels.
5. `flutter analyze`/`flutter test` clean; migrations run cleanly in Supabase.
