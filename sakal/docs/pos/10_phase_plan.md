# Delivery Phases

Adapted from the reference BRD's Phase 0-8, re-sequenced around what SAKAL
already has. "Already built" phases are listed for completeness/traceability,
not as work to schedule.

| Phase | Name | Status in SAKAL | Net-new work |
|---|---|---|---|
| 0 | Foundation | **Mostly already built** — tenancy, RLS, auth/JWT, roles/menus, stores (locations), RLS policy convention | `ric_pos_terminals`, `ric_pos_devices`, `ric_user_pos_terminal_access`, POS feature codes |
| 1 | Product + Sale Core | **Mostly already built** — products, barcodes, pack/loose, prices, tax, cart math, invoice, receipt via Quick Invoice | Wire the POS "New Sale" screen onto the existing engine, tag `pos_shift_id`, larger-tap-target UI |
| 2 | Payments + Shift | Partially built (cash/credit sale, CRV posting) | `rid_pos_tender_lines` (split multi-tender), `rih_pos_shifts`, cash-up, payouts, denomination counts |
| 3 | Returns + Exceptions | **Mostly already built** — Sales Return engine | POS Return/Exchange screen, void routing, approval-request table + screen |
| 4 | Promotions + Loyalty | Net new | `rim_pos_schemes`/rules, loyalty tables + ledger, scheme-aware pricing in `fn_save_sales_invoice` |
| 5 | Bundles | Net new | `rim_product_bundles`/components, bundle explosion at sale |
| 6 | Offline + Sync | Partially built (`SyncEngine`, Quick Invoice's own offline save) | Shift open/close offline, new `SyncEngine` document-type cases |
| 7 | Reporting + Audit | **Mostly already built** — generic reporting engine | New views/report rows per `08_reporting_audit.md`; new `rih_pos_audit_log` |
| 8 | Hardware/Integrations | Net new | 58/80mm default receipt template (data plumbing already exists), real ESC/POS driver, cash-drawer kick, card/mobile-money terminal API, customer-facing display — explicitly Phase 2, not a v1 blocker |

## Five items folded into v1 (user decision, 2026-10-02)
Till idle-lock, weighted products (barcode parsing + manual entry; a
connected scale is still Phase 2 hardware), minimum selling price floor,
age-restricted/controlled-sale confirmation, and the quick-pick grid — all
previously flagged as gaps in `12_feature_checklist.md`, now in scope for
Phase 1/2 above (none of them need their own new phase; they slot into the
New Sale screen and the access-security work already planned there). See
`01_data_model.md` §1a and `02_pricing_promotions_loyalty.md` for the design.

## Recommended build order for v1 (Supermarket)
1. Terminals/devices/access (Phase 0 net-new) + Shift lifecycle (Phase 2) —
   nothing else can be tested end-to-end without a shift to post against.
2. New Sale screen on top of the existing Quick Invoice engine, with
   `pos_shift_id` + multi-tender (`rid_pos_tender_lines`) — this alone gives
   a usable, sellable v1 slice.
3. Cash-up/close + payouts — closes the daily operating loop.
4. Hold/Resume, Return/Exchange, Price Check — the remaining cashier-day
   screens.
5. Promotions + Loyalty + Bundles — the retention/margin-shaping layer.
6. Offline widening (shift open/close), reporting/audit rollout, Admin screen.
7. Hardware integrations (receipt printer, cash drawer, card terminal).
