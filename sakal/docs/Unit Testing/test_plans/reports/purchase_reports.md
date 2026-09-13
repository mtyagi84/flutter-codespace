# Purchase Reports — Test Plan
Module: PR — Purchase | Group: Reports | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

Report template: **Load with no filters (smoke) / Every filter individually / Data
accuracy vs. a real transaction / Currency & Dr-Cr display (CCC #1/#2) / Export &
Print / Permission-denied / CCC**.

---
## PR-RPT-POR / PPO — Purchase Order Register / Pending Purchase Orders
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| POR-01 | Approved PO appears in Register | Approve a PO | Appears correctly | High | Not Started | |
| POR-02 | Fully-received PO drops off Pending | Fully receive via GRN | Drops off Pending Purchase Orders | High | Not Started | |
| POR-03 | Partially-received PO shows correct remaining qty | Partially receive | Remaining qty/value correct | Med | Not Started | |

## PR-RPT-GRN / GPB — GRN Register / GRN Pending to Bill
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| GRNR-01 | Approved GRN appears | Approve a GRN | Appears with correct value | High | Not Started | |
| GRNR-02 | Billed GRN drops off Pending to Bill | Bill it via Purchase Invoice | Drops off correctly | High | Not Started | |

## PR-RPT-PIR / PRR — Purchase Invoice / Return Register
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PIR-01 | Purchase Bill (PUR+EXC vouchers) appears correctly | Post a foreign-currency Purchase Bill with an FX gap | Register shows the real invoice total; drill down confirms both PUR and EXC vouchers exist | High | Not Started | |
| PRR-01 | Mixed billed/unbilled return | Return against one billed and one unbilled GRN in the same document | Register correctly shows both the JV (unbilled) and SDN (billed) postings | Med | Not Started | |

## PR-RPT-CHG — Purchase Charges Register
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CHGR-01 | ADD/DEDUCT charges shown correctly | Post a GRN with both charge natures | Both directions correct | Med | Not Started | |

## PR-RPT-SUP / ITM — Supplier-wise Purchase Analysis / Item-wise Purchase History
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SUPA-01 | Matches actual GRN/Bill totals for a supplier | Sum manually, compare | Match | Med | Not Started | |

## PR-RPT-ROR — Reorder / Replenishment
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| ROR-01 | Below-reorder-point products flagged | Set stock below a configured reorder point | Product appears on the report | Med | Not Started | |

## PR-RPT-OTD — Vendor On-Time Delivery
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| OTD-01 | Late vs on-time GRN classified correctly | Receive one GRN late vs. PO's expected date | Classified correctly | Low | Not Started | |

## PR-RPT-PPV — Purchase Price Variance
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PPV-01 | PO price vs. actual GRN/Bill price variance | Receive at a different price than the PO | Variance computed and shown correctly | Med | Not Started | |

## PR-RPT-TAX — Purchase Tax Summary
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PTAX-01 | Input VAT matches Purchase Bill's real posted amount | Compare to the PUR voucher's Input VAT line | Match exactly | High | Not Started | |
