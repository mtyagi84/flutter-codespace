# Bank Accounts

## Screen Name
Bank Accounts (`/finance/bank-accounts`)

## Description
Links a Bank-nature `rim_accounts` ledger to its real-world bank identity (bank name, account number,
branch, IFSC/SWIFT) and a default statement format — the bridge between "an account in the Chart of
Accounts" and "a real bank account whose statement can be reconciled." Every Bank Reconciliation screen
(Statement Upload, Matching, the Reconciliation report) operates on a Bank Account row from here, not
directly on the underlying ledger account.

## Layout
A plain master list (`SakalAdaptiveList`) — Ledger Account (code + name), Bank Name, Account Number,
Default Format, Status, row actions. "New Bank Account" button top-right, gated on `canAdd`. Entry is a
dialog, same lightweight pattern as the Format Master and Sales Executives Master.

## Functionality
- Chart of Accounts — Bank Ledger (required, dropdown of `rim_accounts` rows with
  `account_nature='Bank'` and `posting_allowed=true`, not editable once set — the account this row
  belongs to is fixed at creation, same "identity fields lock after first save" convention used
  elsewhere in this schema). A one-to-one relationship is enforced server-side (`UNIQUE
  (client_id, company_id, account_id)`); attempting to link an account twice surfaces as a save error.
- Bank Name (required, free text).
- Account Number, Branch, IFSC/SWIFT Code — all optional reference fields.
- Default Statement Format — optional dropdown of active `rim_bank_statement_formats` rows; pre-selects
  the format on the Upload & Review screen but can always be overridden per upload.

## Data Flow
Direct DioClient CRUD against `rim_bank_accounts`, joined to `rim_accounts` (for code/name display) and
`rim_bank_statement_formats` (for the default format's name) via PostgREST embeds. No approval
workflow, no GL impact. Consumed by Bank Statement Upload & Review (which bank/format to parse against)
and Bank Reconciliation Matching (which ledger account's book lines to show).
