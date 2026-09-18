# Shanju Investment Limited — Onboarding Runbook

Companion to `Shanju_Staging.xlsx` (cleaned data, ready to upload) and the
approved plan in this session's history. Follow these steps in order.

## Status
- [x] **Step 1 — Registration.** Already done by you via the real
  Registration wizard. Confirmed: Base=ZMW, Local=USD, Accounting
  Std=ZAMBIA, client_no `SK-49003`.
- [x] **Migrations 189/190 deployed.** The Zambia COA gained 3 new lines
  (Office Equipment `1245`, Accumulated Depreciation `1295`, Depreciation
  Expense `5260`) and Chart of Accounts + Product Master now support
  bulk Excel upload. Shanju's own already-seeded COA got these 3 lines
  added directly (small, one-off, since the seed function only runs once
  per company).
- [x] **Bulk-upload features built** on Chart of Accounts and Product
  Master screens (Template / Upload Excel buttons, top toolbar).
- [x] **`Shanju_Staging.xlsx` prepared** — all data-quality issues found
  in the source Tally export resolved (see its own `Flagged Issues` tab
  for the full list).
- [ ] Everything below is yours to run through the real app.

## Step 2 — Create the 2 additional users
Screen: Settings → User Management → New User.
- **Anjali** — Data Operator role.
- **Jay** — Data Operator role.

You'll need a real email/phone for each — not in the source file, so use
whatever the tenant actually wants for these (a placeholder works if you
plan to update it later; the app doesn't send a verification email).

## Step 3 — Create the "N/A" Brand entry
Screen: Master → Common Masters → select type "Brand" → Add.
- Description: `N/A`
- This is what every uploaded product's Brand will resolve to (the
  source data's own Brand column turned out to be unusable — see the
  Flagged Issues tab).

## Step 4 — Create the 6 UOM entries
Same Common Masters screen, type "Unit" → Add, one at a time:
`Box`, `Kgs`, `Pcs`, `Pkts`, `Roll`, `mtrs`.

## Step 5 — Create the Item Category tree
Screen: Master → Item Categories.
Create these 18 top-level groups first (level 1), then their sub-groups
(level 2) as listed. Names are already cleaned in `Shanju_Staging.xlsx`'s
`Products` tab — use exactly what's there so the Product upload's
name-matching resolves correctly (matching is case/whitespace-insensitive,
but matching the exact intended name avoids any ambiguity).

Open the `Products` tab, and for each distinct value in the **Category**
column, create a level-1 node; for each distinct (Category, Sub Category)
pair, create the matching level-2 child under its parent.

## Step 6 — Bulk-upload the 138 new Chart of Accounts leaf accounts
Screen: Master → Chart of Accounts → toolbar → **Upload Excel**.
1. Click **Download Template** first to confirm the column headers match
   (`Parent Account Code`, `Account Code`, `Account Name`, `Nature`,
   `Currency`, ...).
2. Open `Shanju_Staging.xlsx`'s `Accounts` tab, copy its 138 data rows
   (everything except the last 3 reference-only columns — Opening Balance
   Amount/Type/Original Tally Group are for Step 9, not this upload) into
   the downloaded template, matching column order.
3. Upload the filled file. You'll see a summary ("N accounts created, M
   skipped") — if anything is skipped, a dialog lists exactly why (an
   unresolved parent code or currency, most likely a typo).

## Step 7 — Enter the 8 "Reuse Existing" opening balances' accounts
No account creation needed here — `Shanju_Staging.xlsx`'s `Reuse Existing
Accounts` tab lists 8 rows that map directly onto accounts the Zambia COA
seed already created (Capital Account, VAT Payable, Office Cabin, Salary &
Wages Payable, Provisions, Direct Labour, Warehouse Rent, Bank Charges).
Nothing to do here except note their Account Codes for Step 9.

## Step 8 — Bulk-upload the 487 products
Screen: Master → Products → toolbar → **Upload Excel**.
Same pattern: Download Template, copy `Shanju_Staging.xlsx`'s `Products`
tab rows in, upload. Every row's Brand is `N/A`; Opening Stock Qty is
**not** part of this upload (see Step 10).

## Step 9 — Opening Balances
Screen: Master → Opening Balance Entry → toolbar → **Upload Excel**
(this screen already supports bulk upload — no new build was needed).
- For the 138 new accounts: use their new Account Codes (now visible in
  Chart of Accounts after Step 6) with the Amount/Type from
  `Shanju_Staging.xlsx`'s `Accounts` tab.
- For the 8 reuse-existing accounts: use the Account Codes from Step 7's
  `Reuse Existing Accounts` tab.
- **Currency note**: every `-USD`-suffixed account's amount in the staging
  file is ALREADY converted to real USD (divided by 19.66, per your own
  confirmation) — enter it as-is, don't convert again.

## Step 10 — Opening Stock
Screen: Inventory → Opening Stock → toolbar → **Upload Excel** (also
already existing, no new build needed).
Use `Shanju_Staging.xlsx`'s `Products` tab's Opening Stock Qty column —
all 26 originally-negative quantities are already clamped to 0.

## Step 11 — Verify
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
