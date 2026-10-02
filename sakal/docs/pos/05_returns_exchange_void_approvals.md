# Returns, Exchange, Void & Approvals

## 0. Two kinds of approval — don't conflate them

Every restricted action in this document (discount override, price override,
return without receipt, high-value refund, payout over threshold) needs a
decision **at the moment the cashier is mid-transaction, at that same till**.
This is handled as a **blocking modal on the cashier's own device**: the
supervisor physically comes to that counter and enters **their own manager
PIN** on the same numeric keypad the till login screen already uses (never a
password — consistent with the till having no password UI anywhere, per
`06_access_security.md` §4), verified instantly, scoped to managers/
supervisors with `approve_allowed` for the relevant feature, against their
own `ric_user_sales_controls`/`ric_user_menus` permissions — the PIN-based
equivalent of `fn_verify_discount_override`, generalized here. A badge/QR
scan as an alternative to typing the PIN is a reasonable Phase 2 add once a
barcode scanner is in the loop, not built in v1. Nothing is queued, nothing
waits for a separate screen, and nobody approves it remotely — if the
supervisor isn't physically there, the action simply doesn't happen yet.

A **separate, async "Manager Review" screen** (§4 below) exists only for
decisions that genuinely can wait: a shift that closed with a cash variance,
or a manager glancing back over today's at-counter overrides for the record.
It is opened from a manager's own device (office PC, their own tablet), never
from the till the sale happened on, and it never blocks a cashier — by the
time anything reaches it, the transaction it relates to has already been
resolved one way or the other at the counter.

## 1. POS return — reuses the existing Sales Return engine, not new logic
Migration 099's `fn_save_sales_return`/`fn_approve_sales_return` already do
exactly what a POS return needs: one return always references exactly one
already-approved invoice, cumulative-returned-qty is capped per invoice line
under a row lock, and it posts `CRN` (reverses sales/tax/charges) +
optionally `COS` (if the original dispatch was immediate, reversed at the
**original historical per-unit cost**, never current average) + optionally
`CPV` (cash refund, capped against what was actually collected). The only
POS-specific additions:
- **Refund tender lines** mirror `rid_pos_tender_lines` — a refund can itself
  split across methods (e.g. refund 70% to the original card, 30% as store
  credit), using a new `rid_pos_refund_tender_lines` table of the identical
  shape, linked to the Sales Return header instead of a Sales Invoice.
- **Loyalty reversal** (`RETURN_REVERSAL` ledger entry) is posted by the
  extended `fn_approve_sales_return`, per `02_pricing_promotions_loyalty.md`
  §4.
- **Return reason is mandatory** — `rid_sales_return_lines` already has a
  reason field pattern consistent with Purchase Return's own
  `reason`-as-audit-label convention; the POS return screen just surfaces the
  standard reason list (Damaged, Wrong product, Changed mind, Quality issue,
  Expired, Duplicate purchase, Pricing issue, Other) as a
  `rim_common_masters` picklist (type `SALES_RETURN_REASON`, new).
- **Return without the original receipt** is permission-controlled
  (`SL-RET-NOREF`, a new `feature_code`, `approve_allowed` gates it) — when
  used, the return has no source invoice line to cap against, so refund value
  follows a configured policy (current selling price, manager-entered price,
  or blocked entirely) rather than the invoice's own historical price — this
  is one of `11_open_decisions.md`'s open items (DEC-05).

## 2. Exchange
Modeled as **one Sales Return + one new Sales Invoice in the same screen
flow**, not a new transaction type — exactly matching how the reference BRD
describes it and how SAKAL already composes multi-step flows elsewhere
(Purchase Bill composing two vouchers). The screen: pick the original
invoice and the returned line(s) (Sales Return engine), then add replacement
line(s) (Quick Invoice engine) in the same session; the net difference is
collected or refunded as one more tender/refund-tender line. The two
documents stay linked only informationally (`rih_sales_invoices.exchange_of_invoice_no`,
a new nullable soft link, same non-FK convention as `quotation_no`/`order_no`)
— each remains independently auditable, immutable once approved.

## 3. Void / cancel / manager approval
No transaction in this schema is ever hard-deleted once it leaves DRAFT —
unchanged principle. The authorization matrix:

| Action | Cashier | Supervisor | Manager |
|---|---|---|---|
| Cancel a DRAFT/HELD sale | Yes | Yes | Yes |
| Void a COMPLETED sale | No (no reversal path exists post-approve, per Sales Invoice's own documented immutability — a void is modeled as a full Sales Return instead) | — | — |
| Price override | Within `ric_user_sales_controls` limit | Yes | Yes |
| Discount above cashier limit | No | Within approval limit | Yes |
| Return without receipt | No | Configured | Yes |
| High-value refund | No | Configured | Yes |
| Manual loyalty adjustment | No | Configured | Yes |
| Payout above threshold | No | Configured | Yes |

A "void" request on an already-approved sale is deliberately **routed to the
Return flow** rather than a distinct VOID status — this keeps SAKAL's single
immutability rule (no in-place edits, no destructive reversal, only a new
offsetting document) uniform across every module rather than introducing a
second reversal mechanism specific to POS.

## 4. Approval record
Every restricted action above writes one row to a new `rih_pos_approval_requests`
table (not reusing `rid_finance_lines`' own approval columns, since this
needs to cover non-financial actions like a loyalty adjustment too):
```
id, client_id, company_id, shift_id -> rih_pos_shifts NULL,
action_code TEXT,              -- e.g. DISCOUNT_OVERRIDE, RETURN_NO_RECEIPT, PAYOUT_OVER_LIMIT, LOYALTY_ADJUSTMENT
requested_by -> rim_users, requested_at,
reason TEXT,
original_value JSONB, requested_value JSONB,
approver_id -> rim_users NULL, approved_at NULL,
outcome TEXT CHECK (PENDING, APPROVED, REJECTED) DEFAULT 'PENDING'
```
Verification itself reuses the exact `fn_verify_discount_override` pattern
(supervisor types their own username/password at the till, checked server-
side against their own `ric_user_sales_controls`/`ric_user_menus`
`approve_allowed` for the relevant `feature_code`) — this table is the
**record** of that event, not a second authentication mechanism.
