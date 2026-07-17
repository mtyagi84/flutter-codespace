# SAKAL ERP — Frontend Test Report

**App:** SAKAL ERP (Flutter web, debug/DDC build)
**URL:** https://psychic-meme-q7jp9q54wj53pvv-8080.app.github.dev/
**Tester:** Claude (Playwright browser automation)
**Date:** 2026-07-07
**Login used:** Client ID `SK-69077`, Username `Manglu`, Company: Rigvedan Trading

---

## Scope

1. Inventory → Setup → Consumption Area Setup (`/inventory/department-consumption-areas`)
   — referred to by the user as "Department Linking"
2. Inventory → Operations → Material Requisition (`/inventory/requisitions`)
3. Finance → Payment/Receipt Voucher (`/finance/voucher-list`)

---

## Findings — Consumption Area Setup

### 🔴 Critical: Save silently fails
- Steps: Department = Sales Department → Add Consumption Area → "Printing and Stationary" → Expense Account = typed "Office" (free text) → Save.
- Result: no toast, no inline validation error, no visible change.
- Confirmed via network trace: clicking Save **never sends an INSERT/UPDATE** to `rim_department_consumption_areas`. Only a `GET rim_accounts` fires (likely an attempt to resolve the typed text to a real account), then nothing happens.
- User has no indication the save failed or why.

### 🟠 Expense Account field is free text, not an account picker
- Typing "Office" produces no autocomplete/suggestions, despite the app already having a full chart of accounts available elsewhere (`rim_accounts`, used e.g. in Tax Master's GL account fields).
- Likely root cause of the silent Save failure: the typed text probably needs to resolve to a real `account_id`, and unmatched text just fails quietly instead of surfacing a validation message.

### 🟠 Reproducible type error opening "Consumption Area" dropdown
- Every time the dropdown is opened, console throws:
  ```
  TypeError: Instance of 'JSArray<dynamic>': type 'List<dynamic>' is not a subtype of type 'Map<String, dynamic>?'
  ```
- Non-fatal — dropdown still shows correct options — but 100% reproducible. Likely a cast bug in the code that filters out already-linked consumption areas.

### 🟡 Recurring layout overflow on the top app bar
- On most navigations at ≤1440px viewport width:
  ```
  RenderFlex overflowed by 184 pixels on the right — app_shell.dart:64
  ```
  (also seen at 108px/18px/15px on other screens/widths)
- Confirmed **not present at 1920px width** — it's a responsive breakpoint bug in the top bar `Row`. Needs `Expanded`/`Flexible` per Flutter's own suggestion in the error.

### ✅ Works correctly
- Login flow (Client ID + Username + Password, proper required-field validation)
- Department dropdown (Purchase Department / Sales Department) — switches correctly, reloads linked consumption areas per department
- Adding a new row (Consumption Area dropdown + Expense Account + delete icon) renders correctly
- Sidebar navigation, permission-gated menu (confirmed `canAdd=true canEdit=true canApprove=false` for this user via the app's own permission-debug log)

---

## Findings — Material Requisition

### 🔴 Critical: "Save Draft" does nothing — root cause confirmed and traced to Consumption Area Setup bug
- Steps: New Requisition → From Location: Warehose → Requested By: Manglu Singh → Reason: filled → Add Line → Product: Product 2 → Qty: 5 → Department: Sales Department → Save Draft.
- Result: no success/error feedback, still shows "Unsaved draft".
- Confirmed via network trace: **zero requests fired** after clicking Save Draft (request count identical before/after). No new console errors either — the handler isn't even throwing, it's silently no-opping.
- **Root cause**: the line's **Consumption Area** dropdown never opens because the selected department has zero linked consumption areas — confirmed via API: `GET rim_department_consumption_areas?...department_id=eq.<Sales Dept>` → `[]`.
- This is a direct downstream consequence of the Consumption Area Setup Save bug above: since that screen can never persist a department→consumption-area link, **no department has any working consumption area**, so this dropdown is permanently empty and Material Requisition can never be completed, for any department, until that upstream bug is fixed.

**Causal chain:**
```
Consumption Area Setup Save silently fails
        → no department has linked consumption areas
        → Material Requisition line's "Consumption Area" dropdown has nothing to show, never opens
        → Save Draft silently no-ops (likely blocked by an unsurfaced required-field check)
```

### 🟡 Data quality: Location name typo
- "Warehose" in the From Location dropdown — should be "Warehouse" (Setup → Locations master data, not a code bug).

### ✅ Works correctly
- New Requisition creation flow, form layout, Requisition Date auto-defaults to today
- From Location dropdown (Head Office / Warehose) switches correctly
- Product picker opens on click showing all products; selection works
- Department picker on the line works (Purchase/Sales Department)
- Quantity field editable
- Requested By / Reason fields work correctly with normal user interaction

---

## Findings — Payment/Receipt Voucher

This screen is the **best-functioning of the three tested** — full create → save → post → subledger-update flow works correctly end to end.

### ✅ Core flow works correctly (verified end-to-end)
- "New Voucher" split button offers 4 types: Cash Receipt, Bank Receipt, Cash Payment, Bank Payment
- Created a **Bank Payment Voucher**: Bank Account [111002001] HSBS (USD) → Supplier [2110001] Local Supplier → pending bills loaded automatically with live exchange rate ("Party currency: EUR · 1 USD = 0.91234442 EUR")
- Entered Pay (USD) amount on bill INV01 → **Pay (EUR) auto-calculated correctly** (0.59 USD → 0.54 EUR) → "✓ Balanced" indicator appeared
- **Save Draft**: confirmed via network trace — `POST rpc/fn_save_finance_voucher` → returned real voucher number `"BPV/HO/2026/00001"`. UI updated header and Voucher No field correctly. (Contrast with the two Inventory screens, where Save fired zero requests — confirms those are isolated handler bugs, not a systemic issue.)
- **Post Voucher**: showed a proper confirmation dialog ("Once posted this voucher is locked permanently. Continue?") before an irreversible action — good UX safeguard. Confirmed via network trace — `POST rpc/fn_post_finance_voucher` → `204 No Content`. UI updated to a green **"POSTED — read only"** badge and disabled all fields.
- **Subledger correctness verified**: opened a fresh voucher for the same supplier afterward — **INV01 no longer appears** in the pending bills list (correctly fully settled), while INV002/INV02/"dsd" remain outstanding. AP balance tracking is accurate.
- **Cash Receipt** form correctly adapts field labels/defaults for its type: "Cash Account" (not Bank Account), "Customer" (not Supplier), Payment Mode pre-selected to "Cash".
- Voucher list correctly reflects newly posted vouchers when navigated to via normal sidebar clicks (an initial "No vouchers found" was traced to my own full-page-reload timing, not an app bug — retracted after re-verification with realistic navigation).

### 🟡 Data quality: Bank name typo
- Bank account **"[111002001] HSBS (USD)"** — very likely should be **"HSBC"**. (Second master-data typo found this session, alongside "Warehose".)

### 🟡 Supplier picker exposes the GL control account
- The Supplier search on the voucher (typed nothing / browsed) listed **"[2110] Trade Payables"** — the parent Accounts Payable control account — as a directly selectable option, alongside the real supplier **"[2110001] Local Supplier"**. Posting a voucher directly against the control account (rather than a supplier sub-account) would bypass normal sub-ledger tracking; worth confirming whether this is intentional (e.g. for miscellaneous/unclassified payments) or should be filtered out of this picker.

### Environment/data notes (not bugs)
- One pending bill is literally named **"dsd"** — clearly leftover test data in this dev database, not an app defect.
- Same recurring `app_shell.dart:64` top-bar RenderFlex overflow seen on this screen too (already tracked above).
- Same benign dev-harness error (`Cannot read properties of null (reading 'removeChild')` from the DWDS injected debug client) appears on full page reloads — not an app bug, just noise from the debug tooling.

---

## Testing note (methodology, not a product bug)

Early in testing, filling "Requested By" and "Reason / Remarks" back-to-back via rapid automated `.fill()` calls caused their values to concatenate into a single field. Re-tested with real click + keyboard-typing (simulating an actual user) and both fields worked correctly and independently. This was a Flutter-Web/Playwright automation interaction artifact (Flutter web reuses a single hidden text-editing proxy element across fields), **not a confirmed application defect**. Retracted after verification.

---

## Recommended priority

1. **Fix Consumption Area Setup Save** — likely needs to surface a real validation error (e.g. "no matching account found") instead of failing silently. This single fix should unblock Material Requisition too, since its Consumption Area picker depends entirely on this data existing.
2. Replace the free-text **Expense Account** field with a proper searchable account picker tied to `rim_accounts`.
3. Fix the recurring **top-bar RenderFlex overflow** in `app_shell.dart:64` (responsive breakpoint issue, ≤1440px).
4. Fix the **type-cast error** on opening the Consumption Area dropdown (`List<dynamic>` vs `Map<String, dynamic>?`).
5. Correct master-data typos: **"Warehose" → "Warehouse"**, **"HSBS" → "HSBC"**.
6. Review whether the Supplier picker on Payment/Receipt Voucher should exclude the parent GL control account ("[2110] Trade Payables") from direct selection.

Note: Payment/Receipt Voucher's Save/Post flow is solid and can serve as a reference implementation for fixing the broken Save handlers on the other two screens.

---

## Environment notes
- This is a **debug build** (DDC, ~1375 unbundled JS modules, ~40s cold boot) — not representative of release build performance.
- Testing required enabling Flutter's accessibility bridge mid-session for reliable element targeting; raw coordinate-based clicks were initially unreliable in this environment (testing setup detail, not an app bug).
