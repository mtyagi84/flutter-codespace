/// Centralizes the "flat limit/offset paging" shape already hand-rolled
/// independently in `product_list_screen.dart` and
/// `common_masters_screen.dart` (`_offset`/`_pageSize`/`_hasMore`/
/// `_loadingMore` fields) — see CLAUDE.md's "Pagination" mandatory pattern.
/// Pairs with `SakalAdaptiveList`'s `onLoadMore`/`hasMore`/`loadingMore`
/// params for a scroll-triggered "load more" instead of a manual button.
///
/// A screen owns one instance, calls `loadFirstPage()` once (e.g. in
/// `initState`) and wires `loadMore`/`hasMore`/`isLoadingMore` straight into
/// `SakalAdaptiveList`. `fetchPage` is whatever the screen's own repository
/// already exposes — this class adds no new data-access logic, only the
/// bookkeeping around calling it repeatedly.
class PagedListController<T> {
  PagedListController({required this.fetchPage, this.pageSize = 50});

  final Future<List<T>> Function({required int limit, required int offset}) fetchPage;
  final int pageSize;

  List<T> items = [];
  bool isLoading = false;
  bool isLoadingMore = false;
  bool hasMore = true;

  /// Exceptions propagate to the caller — this class owns paging state
  /// only, not error presentation. Wrap the call in the screen's own
  /// try/catch (AppLogger.error + ErrorPresenter.format), same as every
  /// other repository call in this app.
  Future<void> loadFirstPage() async {
    isLoading = true;
    try {
      final result = await fetchPage(limit: pageSize, offset: 0);
      items = result;
      hasMore = result.length == pageSize;
    } finally {
      isLoading = false;
    }
  }

  Future<void> loadMore() async {
    if (!hasMore || isLoadingMore || isLoading) return;
    isLoadingMore = true;
    try {
      final result = await fetchPage(limit: pageSize, offset: items.length);
      items = [...items, ...result];
      hasMore = result.length == pageSize;
    } finally {
      isLoadingMore = false;
    }
  }
}
