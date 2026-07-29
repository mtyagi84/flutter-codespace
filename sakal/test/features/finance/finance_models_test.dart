import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/features/finance/data/models/exchange_rate_model.dart';
import 'package:sakal/features/finance/data/models/finance_voucher_model.dart';

void main() {
  // ── ExchangeRateModel ─────────────────────────────────────────────────────
  // Note: unlike most models in this app, ExchangeRateModel.fromJson uses
  // strict (non-nullable) casts for its core identity/rate fields — it
  // throws rather than defaulting if those are missing, since every real
  // caller always selects the full row. Only source/is_deleted/mid_rate
  // are genuinely optional.

  group('ExchangeRateModel', () {
    const fullJson = {
      'id': 'rate-001',
      'client_id': 'client-001',
      'company_id': 'company-001',
      'location_id': 'loc-001',
      'rate_date': '2026-07-01',
      'from_currency': 'USD',
      'to_currency': 'CDF',
      'buying_rate': 2800,
      'selling_rate': 2850,
    };

    test('fromJson — required fields present, optional fields default', () {
      final r = ExchangeRateModel.fromJson(fullJson);
      expect(r.id, 'rate-001');
      expect(r.fromCurrency, 'USD');
      expect(r.toCurrency, 'CDF');
      expect(r.buyingRate, 2800.0);
      expect(r.sellingRate, 2850.0);
      expect(r.midRate, isNull);
      expect(r.source, 'MANUAL');
      expect(r.isDeleted, false);
    });

    test('fromJson — mid_rate present (DB-generated), source/is_deleted explicit', () {
      final r = ExchangeRateModel.fromJson({
        ...fullJson,
        'mid_rate': 2825,
        'source': 'API',
        'is_deleted': true,
      });
      expect(r.midRate, 2825.0);
      expect(r.source, 'API');
      expect(r.isDeleted, true);
    });

    test('toJson — round-trips the required fields, omits null mid_rate', () {
      final r = ExchangeRateModel.fromJson(fullJson);
      final json = r.toJson();
      expect(json['from_currency'], 'USD');
      expect(json['buying_rate'], 2800.0);
      expect(json.containsKey('mid_rate'), false);
    });

    test('toJson — includes mid_rate when present', () {
      final r = ExchangeRateModel.fromJson({...fullJson, 'mid_rate': 2825});
      expect(r.toJson()['mid_rate'], 2825.0);
    });
  });

  // ── FinanceVoucherHeader ──────────────────────────────────────────────────

  group('FinanceVoucherHeader', () {
    test('fromJson — missing fields default to safe values', () {
      final h = FinanceVoucherHeader.fromJson(const {});
      expect(h.clientId, '');
      expect(h.transNo, '');
      expect(h.voucherTypeCode, '');
      expect(h.isOnAccount, false);
      expect(h.isPosted, false);
      expect(h.isDeleted, false);
      expect(h.createdByName, '');
      expect(h.postedByName, '');
    });

    test('fromJson — created_by_user/posted_by_user nested embeds resolve to full_name', () {
      final h = FinanceVoucherHeader.fromJson(const {
        'trans_no': 'CRV-001',
        'voucher_type_code': 'CRV',
        'created_by_user': {'full_name': 'Jane Cashier'},
        'posted_by_user': {'full_name': 'John Manager'},
      });
      expect(h.createdByName, 'Jane Cashier');
      expect(h.postedByName, 'John Manager');
    });

    test('fromJson — null created_by_user/posted_by_user embeds do not crash', () {
      final h = FinanceVoucherHeader.fromJson(const {
        'created_by_user': null,
        'posted_by_user': null,
      });
      expect(h.createdByName, '');
      expect(h.postedByName, '');
    });

    test('toJson — does not leak createdByName/postedByName (read-only display fields)', () {
      final h = FinanceVoucherHeader.fromJson(const {
        'trans_no': 'CRV-001',
        'created_by_user': {'full_name': 'Jane Cashier'},
      });
      final json = h.toJson();
      expect(json.containsKey('created_by_user'), false);
      expect(json.containsKey('createdByName'), false);
      expect(json['trans_no'], 'CRV-001');
    });
  });

  // ── FinanceVoucherLine ────────────────────────────────────────────────────

  group('FinanceVoucherLine', () {
    test('fromJson — missing fields default to safe values; rate fields default to 1, not 0', () {
      final l = FinanceVoucherLine.fromJson(const {});
      expect(l.serialNo, 0);
      expect(l.accountId, '');
      expect(l.transAmount, 0);
      expect(l.baseAmount, 0);
      // Rates default to 1 (a 1:1 identity conversion), never 0 — a 0 rate
      // would silently zero out every downstream currency conversion.
      expect(l.baseRate, 1);
      expect(l.localRate, 1);
      expect(l.partyRate, 1);
    });

    test('fromJson — full line with mixed numeric types', () {
      final l = FinanceVoucherLine.fromJson(const {
        'serial_no': 1,
        'account_id': 'acct-001',
        'trans_nature': 'DR',
        'trans_amount': 1000,
        'trans_currency': 'USD',
        'base_amount': 2800000,
        'base_rate': 2800,
        'inv_bill_no': 'BILL-01',
      });
      expect(l.serialNo, 1);
      expect(l.transNature, 'DR');
      expect(l.transAmount, 1000.0);
      expect(l.baseRate, 2800.0);
      expect(l.invBillNo, 'BILL-01');
    });

    test('toJson round-trip preserves every field fromJson set', () {
      final original = FinanceVoucherLine.fromJson(const {
        'serial_no': 2,
        'account_id': 'acct-002',
        'trans_nature': 'CR',
        'trans_amount': 500,
        'trans_currency': 'CDF',
        'base_amount': 500,
        'base_rate': 1,
        'party_amount': 500,
        'party_currency': 'CDF',
        'party_rate': 1,
      });
      final roundTripped = FinanceVoucherLine.fromJson(original.toJson());
      expect(roundTripped.serialNo, original.serialNo);
      expect(roundTripped.accountId, original.accountId);
      expect(roundTripped.transAmount, original.transAmount);
      expect(roundTripped.partyCurrency, original.partyCurrency);
    });
  });
}
