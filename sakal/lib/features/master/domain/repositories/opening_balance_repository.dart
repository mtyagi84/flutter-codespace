abstract class OpeningBalanceRepository {
  /// All opening-balance lines for one financial year, optionally scoped to
  /// one location group (INTER_ENTITY mode). [locationGroupId] == null
  /// under SIMPLE accounting, or when browsing the company-wide set.
  Future<List<Map<String, dynamic>>> getLines({
    required String clientId,
    required String companyId,
    required String fyId,
    String? locationGroupId,
  });

  /// Full delete-and-reinsert for the given FY (+ location group) scope —
  /// same line-replacement convention every other line-grid save in this
  /// app already uses. [lines] is the complete desired set; anything not
  /// included is removed.
  Future<void> saveLines({
    required String clientId,
    required String companyId,
    required String fyId,
    String? locationGroupId,
    required List<Map<String, dynamic>> lines,
    required String userId,
  });
}
