# Shanju Investment Limited — Onboarding Runbook

Companion to `Shanju_Staging.xlsx` (cleaned data, ready to upload) and the
approved plans in this session's history. Follow these steps in order.

## Status
- [x] **Step 1 — Registration.** Already done by you via the real
  Registration wizard. Confirmed: Base=ZMW, Local=USD, Accounting
  Std=ZAMBIA, client_no `SK-49003`.
- [x] **Migrations 189/190/191 deployed.** The Zambia COA gained 3 new
  lines (Office Equipment `1245`, Accumulated Depreciation `1295`,
  Depreciation Expense `5260`) — Shanju's own already-seeded COA got these
  3 lines added directly (small, one-off, since the seed function only
  runs once per company). Chart of Accounts got bulk Excel upload.
  **Product Master's bulk upload was superseded by a dedicated screen**
  (Master → Bulk Upload Products, `MST-BUP`) — see Step 5 below.
- [x] **`Shanju_Staging.xlsx` prepared** — all data-quality issues found
  in the source Tally export resolved (see its own `Flagged Issues` tab
  for the full list). **The `Products` tab's columns were updated** to
  match the new dedicated screen's template — if you have an older copy
  open, close it and re-open the latest version before using Step 5.
- [ ] Everything below is yours to run through the real app.

## Step 2 — Create the 2 additional users
Screen: Settings → User Management → New User.
- **Anjali** — Data Operator role.
- **Jay** — Data Operator role.

You'll need a real email/phone for each — not in the source file, so use
whatever the tenant actually wants for these (a placeholder works if you
plan to update it later; the app doesn't send a verification email).

## Step 3 — Bulk-upload the 138 new Chart of Accounts leaf accounts
Screen: Master → Chart of Accounts → toolbar → **Upload Excel**.
1. Click **Download Template** first to confirm the column headers match
   (`Parent Account Code`, `Account Code`, `Account Name`, `Nature`,
   `Currency`, ...).
2. Open `Shanju_Staging.xlsx`'s `Accounts` tab, copy its 138 data rows
   (everything except the last 3 reference-only columns — Opening Balance
   Amount/Type/Original Tally Group are for Step 6, not this upload) into
   the downloaded template, matching column order.
3. Upload the filled file. You'll see a summary ("N accounts created, M
   skipped") — if anything is skipped, a dialog lists exactly why (an
   unresolved parent code or currency, most likely a typo).

## Step 4 — Enter the 8 "Reuse Existing" opening balances' accounts
No account creation needed here — `Shanju_Staging.xlsx`'s `Reuse Existing
Accounts` tab lists 8 rows that map directly onto accounts the Zambia COA
seed already created (Capital Account, VAT Payable, Office Cabin, Salary &
Wages Payable, Provisions, Direct Labour, Warehouse Rent, Bank Charges).
Nothing to do here except note their Account Codes for Step 6.

## Step 5 — Bulk-upload the 487 products (new dedicated screen)
Screen: **Master → Bulk Upload Products** (its own menu item now, not a
button on the Products list screen).
1. Click **Download Template**, then copy `Shanju_Staging.xlsx`'s
   `Products` tab rows in (ignore the trailing "Opening Stock Qty" column
   — that's reference-only for Step 7, this upload doesn't use it).
2. Click **Upload Excel** — the rows load into an editable grid on screen.
   You can fix anything by hand right there before saving.
3. Click **Save**. This screen does more than the old simple upload:
   - **Category/Sub-Category/Item Size/Item Color/Unit are all
     auto-created if they don't exist yet** — you do NOT need to
     pre-create the Item Category tree or the 6 UOM entries by hand
     first, unlike the earlier version of this runbook. Every product's
     Brand auto-creates as `N/A` too (already set in the staging file).
   - **Sales/Purchase Tax Group are left blank** in Shanju's data (not in
     the source Tally file) — since nothing was typed there, no
     confirmation dialog appears and every product is simply created
     with no tax group set. You can set these later per-product via the
     regular Product Master screen once Tax Groups are configured, or
     re-upload with those columns filled once they exist.
   - A summary at the end reports how many products were created, how
     many masters were auto-created, and whether anything was skipped
     (with reasons).

## Step 6 — Opening Balances
Screen: Master → Opening Balance Entry → toolbar → **Upload Excel**
(this screen already supports bulk upload — no new build was needed).
- For the 138 new accounts: use their new Account Codes (now visible in
  Chart of Accounts after Step 3) with the Amount/Type from
  `Shanju_Staging.xlsx`'s `Accounts` tab.
- For the 8 reuse-existing accounts: use the Account Codes from Step 4's
  `Reuse Existing Accounts` tab.
- **Currency note**: every `-USD`-suffixed account's amount in the staging
  file is ALREADY converted to real USD (divided by 19.66, per your own
  confirmation) — enter it as-is, don't convert again.

## Step 7 — Opening Stock
Screen: Inventory → Opening Stock → toolbar → **Upload Excel** (also
already existing, no new build needed).
Use `Shanju_Staging.xlsx`'s `Products` tab's trailing "Opening Stock Qty"
column — all 26 originally-negative quantities are already clamped to 0.

## Step 8 — Verify
Run Trial Balance (Finance → Reports → Trial Balance). It must balance to
zero. Cross-check the total against the excluded "Profit & Loss A/c"
balance (1,137,189.12 Cr) from the source Tally file — if everything else
was entered correctly, that figure is what your combined opening entries
should net to as the starting retained-earnings position.

## If something doesn't match
The `Flagged Issues` tab in `Shanju_Staging.xlsx` records every
data-quality decision made this session (negative stock clamped, category
duplicates merged, the 2 ambiguous "Current Assets" accounts, etc.) — check
there first before assuming something in the app itself is wrong.
