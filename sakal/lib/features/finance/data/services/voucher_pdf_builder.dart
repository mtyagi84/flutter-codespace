import 'dart:convert';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

class VoucherPdfBuilder {
  // SAKAL brand colours converted to PDF colour space (0.0–1.0 per channel)
  static const _primary   = PdfColor(0.106, 0.227, 0.420); // #1B3A6B
  static const _totalBg   = PdfColor(0.910, 0.961, 0.914); // light green

  static const _typeLabels = {
    'CRV': 'CASH RECEIPT VOUCHER',
    'BRV': 'BANK RECEIPT VOUCHER',
    'CPV': 'CASH PAYMENT VOUCHER',
    'BPV': 'BANK PAYMENT VOUCHER',
  };

  /// Builds and prints/shares the voucher PDF.
  ///
  /// [lines]  — On Account lines: keys: account_name, amount, party_amount,
  ///            party_currency, is_cross_currency, remarks
  /// [bills]  — Against Bill lines: keys: bill_no, bill_date, bill_amount,
  ///            balance_amount, pay_trans, pay_party, party_currency
  static Future<void> print({
    required Map<String, dynamic> company,
    required String voucherType,
    required String voucherNo,
    required String transDate,
    required String transCurrency,
    required String baseCurrency,
    required double displayRate,
    required String cashBankAccount,
    required String paymentMode,
    required String refNo,
    required String? refDate,
    required String remarks,
    required bool isOnAccount,
    required List<Map<String, dynamic>> lines,
    required List<Map<String, dynamic>> bills,
    required String? partyName,
    required String? partyCurrency,
    required double partyRate,
    required double totalTrans,
    required String preparedBy,
    required String authorisedBy,
  }) async {
    // Decode logo (base64, optional data-URI prefix)
    pw.MemoryImage? logoImage;
    final logoB64 = company['logo'] as String?;
    if (logoB64 != null && logoB64.isNotEmpty) {
      try {
        final raw = logoB64.contains(',') ? logoB64.split(',').last : logoB64;
        logoImage = pw.MemoryImage(base64Decode(raw));
      } catch (_) {}
    }

    final tc        = transCurrency.isNotEmpty ? transCurrency : baseCurrency;
    final showRate  = transCurrency.isNotEmpty && transCurrency != baseCurrency;
    final typeLabel = _typeLabels[voucherType] ?? voucherType;
    final isCash    = voucherType == 'CRV' || voucherType == 'CPV';

    // Build info rows — only include non-empty fields
    final infoRows = <(String, String)>[
      ('Voucher No',  voucherNo),
      ('Date',        transDate),
      ('${isCash ? 'Cash' : 'Bank'} Account', cashBankAccount),
      if (paymentMode.isNotEmpty) ('Payment Mode', paymentMode),
      if (refNo.isNotEmpty)       ('Ref No',       refNo),
      if (refDate != null)        ('Ref Date',     refDate),
      if (showRate)               ('Currency',     tc),
      if (showRate)               ('Exchange Rate',
                                  '1 $baseCurrency = ${_fmtRate(displayRate)} $tc'),
      if (remarks.isNotEmpty)     ('Remarks',      remarks),
    ];

    final doc = pw.Document();
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(20 * PdfPageFormat.mm),
        build: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            _buildHeader(company, logoImage),
            pw.SizedBox(height: 6),
            pw.Divider(color: PdfColors.grey400, thickness: 0.5),
            pw.SizedBox(height: 6),
            pw.Center(
              child: pw.Text(
                typeLabel,
                style: pw.TextStyle(
                  fontSize: 13,
                  fontWeight: pw.FontWeight.bold,
                  color: _primary,
                ),
              ),
            ),
            pw.SizedBox(height: 10),
            _buildInfoGrid(infoRows),
            pw.SizedBox(height: 12),
            if (isOnAccount)
              _buildOnAccountTable(lines, tc)
            else
              _buildAgainstBillTable(bills, partyName ?? '', partyCurrency ?? tc, tc),
            pw.SizedBox(height: 8),
            _buildTotalsRow(totalTrans, tc, isOnAccount, partyCurrency, partyRate),
            pw.Spacer(),
            pw.Divider(color: PdfColors.grey300, thickness: 0.5),
            pw.SizedBox(height: 12),
            _buildSignatureRow(preparedBy, authorisedBy),
          ],
        ),
      ),
    );

    final bytes    = await doc.save();
    final filename = '$voucherType-$voucherNo.pdf';

    final isMobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
         defaultTargetPlatform == TargetPlatform.iOS);

    if (isMobile) {
      await Printing.sharePdf(bytes: bytes, filename: filename);
    } else {
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: filename);
    }
  }

  // ── Company header ─────────────────────────────────────────────────────────

  static pw.Widget _buildHeader(
    Map<String, dynamic> co,
    pw.MemoryImage? logo,
  ) {
    final name    = co['company_name'] as String? ?? '';
    final address = co['address']      as String? ?? '';
    final phone   = co['landline_no']  as String? ?? '';
    final email   = co['email']        as String? ?? '';
    final city    = co['city_name']    as String? ?? '';
    final state   = co['state_name']   as String? ?? '';
    final zip     = co['pin_zip_code'] as String? ?? '';
    final country = co['country']      as String? ?? '';

    final cityLine = [city, state, zip, country]
        .where((s) => s.isNotEmpty).join(', ');
    final contactLine = [
      if (phone.isNotEmpty) 'Ph: $phone',
      if (email.isNotEmpty) email,
    ].join('  |  ');

    final taxRows = <pw.Widget>[];
    for (var i = 1; i <= 4; i++) {
      final lbl = co['tax_${i}_label'] as String? ?? '';
      final val = co['tax_${i}_value'] as String? ?? '';
      if (lbl.isNotEmpty && val.isNotEmpty) {
        taxRows.add(pw.Text('$lbl: $val',
            style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700)));
      }
    }

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        // Left: logo (60mm × 18mm). Falls back to company name in primary colour.
        pw.SizedBox(
          width:  60 * PdfPageFormat.mm,
          height: 18 * PdfPageFormat.mm,
          child: logo != null
              ? pw.Image(logo,
                  fit: pw.BoxFit.contain,
                  alignment: pw.Alignment.centerLeft)
              : pw.Text(
                  name,
                  style: pw.TextStyle(
                    fontSize: 15,
                    fontWeight: pw.FontWeight.bold,
                    color: _primary,
                  ),
                ),
        ),
        pw.SizedBox(width: 8),
        // Right: company details (right-aligned)
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(name,
                  style: pw.TextStyle(
                      fontSize: 12, fontWeight: pw.FontWeight.bold)),
              if (address.isNotEmpty)
                pw.Text(address,
                    style: const pw.TextStyle(fontSize: 9)),
              if (cityLine.isNotEmpty)
                pw.Text(cityLine,
                    style: const pw.TextStyle(fontSize: 9)),
              if (contactLine.isNotEmpty)
                pw.Text(contactLine,
                    style: const pw.TextStyle(fontSize: 9)),
              ...taxRows,
            ],
          ),
        ),
      ],
    );
  }

  // ── Info grid (2-column key: value layout) ─────────────────────────────────

  static pw.Widget _buildInfoGrid(List<(String, String)> items) {
    final rows = <pw.TableRow>[];
    for (var i = 0; i < items.length; i += 2) {
      final left  = items[i];
      final right = i + 1 < items.length ? items[i + 1] : null;
      rows.add(pw.TableRow(children: [
        _kvCell(left.$1, left.$2),
        right != null ? _kvCell(right.$1, right.$2) : pw.Container(),
      ]));
    }
    return pw.Table(
      columnWidths: const {
        0: pw.FlexColumnWidth(),
        1: pw.FlexColumnWidth(),
      },
      children: rows,
    );
  }

  static pw.Widget _kvCell(String key, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      child: pw.RichText(
        text: pw.TextSpan(children: [
          pw.TextSpan(
            text: '$key: ',
            style: pw.TextStyle(
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.grey700),
          ),
          pw.TextSpan(
            text: value,
            style: const pw.TextStyle(fontSize: 9),
          ),
        ]),
      ),
    );
  }

  // ── On Account lines table ─────────────────────────────────────────────────

  static pw.Widget _buildOnAccountTable(
    List<Map<String, dynamic>> lines,
    String tc,
  ) {
    return pw.Table(
      columnWidths: const {
        0: pw.FixedColumnWidth(22),
        1: pw.FlexColumnWidth(3),
        2: pw.FlexColumnWidth(2),
        3: pw.FlexColumnWidth(1.5),
        4: pw.FlexColumnWidth(2),
      },
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: _primary),
          children: [
            _th('#'),
            _th('Account', left: true),
            _th('Amount ($tc)', right: true),
            _th('Party Amt',    right: true),
            _th('Remarks',      left: true),
          ],
        ),
        ...lines.asMap().entries.map((e) {
          final i    = e.key;
          final line = e.value;
          final isCross = line['is_cross_currency'] as bool? ?? false;
          final pAmt    = (line['party_amount'] as num? ?? 0).toDouble();
          final pCurr   = line['party_currency'] as String? ?? tc;
          final partyStr = isCross && pAmt > 0
              ? '${_fmtAmt(pAmt)} $pCurr'
              : '—';
          return pw.TableRow(
            decoration: pw.BoxDecoration(
                color: i.isOdd ? PdfColors.grey50 : PdfColors.white),
            children: [
              _td('${i + 1}'),
              _td(line['account_name'] as String? ?? '', left: true),
              _td(_fmtAmt((line['amount'] as num? ?? 0).toDouble()),   right: true),
              _td(partyStr,                                             right: true),
              _td(line['remarks'] as String? ?? '',                    left: true),
            ],
          );
        }),
      ],
    );
  }

  // ── Against Bill table ─────────────────────────────────────────────────────

  static pw.Widget _buildAgainstBillTable(
    List<Map<String, dynamic>> bills,
    String partyName,
    String partyCurrency,
    String tc,
  ) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.RichText(
          text: pw.TextSpan(children: [
            pw.TextSpan(
              text: 'Party: ',
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold,
                  color: PdfColors.grey700),
            ),
            pw.TextSpan(
              text: partyName,
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            ),
          ]),
        ),
        pw.SizedBox(height: 4),
        pw.Table(
          columnWidths: const {
            0: pw.FlexColumnWidth(1.5),
            1: pw.FixedColumnWidth(55),
            2: pw.FlexColumnWidth(1.5),
            3: pw.FlexColumnWidth(1.5),
            4: pw.FlexColumnWidth(1.5),
            5: pw.FlexColumnWidth(1.5),
          },
          border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: _primary),
              children: [
                _th('Bill No',              left: true),
                _th('Date',                 left: true),
                _th('Bill Amt\n($partyCurrency)', right: true),
                _th('Balance\n($partyCurrency)',  right: true),
                _th('Pay\n($tc)',           right: true),
                _th('Pay\n($partyCurrency)', right: true),
              ],
            ),
            ...bills.asMap().entries.map((e) {
              final i    = e.key;
              final bill = e.value;
              final dateStr = (bill['bill_date'] as String? ?? '').length >= 10
                  ? (bill['bill_date'] as String).substring(0, 10)
                  : (bill['bill_date'] as String? ?? '');
              return pw.TableRow(
                decoration: pw.BoxDecoration(
                    color: i.isOdd ? PdfColors.grey50 : PdfColors.white),
                children: [
                  _td(bill['bill_no']          as String? ?? '', left:  true),
                  _td(dateStr,                                    left:  true),
                  _td(_fmtAmt((bill['bill_amount']    as num? ?? 0).toDouble()), right: true),
                  _td(_fmtAmt((bill['balance_amount'] as num? ?? 0).toDouble()), right: true),
                  _td(_fmtAmt((bill['pay_trans']      as num? ?? 0).toDouble()), right: true),
                  _td(_fmtAmt((bill['pay_party']      as num? ?? 0).toDouble()), right: true),
                ],
              );
            }),
          ],
        ),
      ],
    );
  }

  // ── Totals bar ─────────────────────────────────────────────────────────────

  static pw.Widget _buildTotalsRow(
    double total,
    String tc,
    bool isOnAccount,
    String? partyCurrency,
    double partyRate,
  ) {
    final showParty = !isOnAccount &&
        partyCurrency != null &&
        partyCurrency.isNotEmpty &&
        partyCurrency != tc;

    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: pw.BoxDecoration(
        color: _totalBg,
        border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.end,
        children: [
          pw.Text('TOTAL: ',
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
          pw.Text('${_fmtAmt(total)} $tc',
              style: pw.TextStyle(
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold,
                  color: _primary)),
          if (showParty) ...[
            pw.Text(
              '  =  ${_fmtAmt(total * partyRate)} $partyCurrency',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
          ],
        ],
      ),
    );
  }

  // ── Signature row ──────────────────────────────────────────────────────────

  static pw.Widget _buildSignatureRow(String preparedBy, String authorisedBy) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        _sigBox('Prepared by',         name: preparedBy),
        _sigBox('Checked by'),
        _sigBox('Authorised Signatory', name: authorisedBy),
      ],
    );
  }

  // Shows the name (if any) above the signature line, label below.
  static pw.Widget _sigBox(String label, {String name = ''}) => pw.Column(
    children: [
      if (name.isNotEmpty)
        pw.Text(name,
            style: pw.TextStyle(
                fontSize: 9, fontWeight: pw.FontWeight.bold))
      else
        pw.SizedBox(height: 12),
      pw.SizedBox(height: name.isNotEmpty ? 6 : 10),
      pw.Container(width: 110, height: 0.5, color: PdfColors.grey700),
      pw.SizedBox(height: 3),
      pw.Text(label,
          style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700)),
    ],
  );

  // ── Cell helpers ───────────────────────────────────────────────────────────

  static pw.Widget _th(String text, {bool left = false, bool right = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
        child: pw.Text(
          text,
          textAlign: left
              ? pw.TextAlign.left
              : right
                  ? pw.TextAlign.right
                  : pw.TextAlign.center,
          style: pw.TextStyle(
              fontSize: 8.5,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white),
        ),
      );

  static pw.Widget _td(String text, {bool left = false, bool right = false}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        child: pw.Text(
          text,
          textAlign: left
              ? pw.TextAlign.left
              : right
                  ? pw.TextAlign.right
                  : pw.TextAlign.center,
          style: const pw.TextStyle(fontSize: 8.5),
        ),
      );

  // ── Format helpers ─────────────────────────────────────────────────────────

  static String _fmtAmt(double a) {
    final parts   = a.toStringAsFixed(2).split('.');
    final intPart = parts[0];
    final buf     = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    return '${buf.toString()}.${parts[1]}';
  }

  static String _fmtRate(double r) {
    if (r >= 1000) return r.toStringAsFixed(2);
    if (r >= 1)    return r.toStringAsFixed(4);
    return r.toStringAsFixed(8);
  }
}
