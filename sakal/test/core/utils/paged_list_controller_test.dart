import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sakal/core/utils/paged_list_controller.dart';

void main() {
  group('PagedListController', () {
    test('loadFirstPage — a full page (length == pageSize) sets hasMore true', () async {
      final calls = <Map<String, int>>[];
      final controller = PagedListController<int>(
        pageSize: 3,
        fetchPage: ({required limit, required offset}) async {
          calls.add({'limit': limit, 'offset': offset});
          return List.generate(limit, (i) => offset + i);
        },
      );

      await controller.loadFirstPage();

      expect(controller.items, [0, 1, 2]);
      expect(controller.hasMore, true);
      expect(controller.isLoading, false);
      expect(calls, [
        {'limit': 3, 'offset': 0},
      ]);
    });

    test('loadFirstPage — a short page (length < pageSize) sets hasMore false (last page)', () async {
      final controller = PagedListController<int>(
        pageSize: 10,
        fetchPage: ({required limit, required offset}) async => [1, 2, 3], // only 3, fewer than pageSize
      );

      await controller.loadFirstPage();

      expect(controller.items, [1, 2, 3]);
      expect(controller.hasMore, false);
    });

    test('loadFirstPage — an empty first page sets hasMore false, not stuck true', () async {
      final controller = PagedListController<int>(
        fetchPage: ({required limit, required offset}) async => [],
      );

      await controller.loadFirstPage();

      expect(controller.items, isEmpty);
      expect(controller.hasMore, false);
    });

    test('loadMore — appends to existing items and requests the correct next offset', () async {
      final calls = <Map<String, int>>[];
      final controller = PagedListController<int>(
        pageSize: 2,
        fetchPage: ({required limit, required offset}) async {
          calls.add({'limit': limit, 'offset': offset});
          return List.generate(limit, (i) => offset + i);
        },
      );

      await controller.loadFirstPage(); // items: [0, 1], offset 0
      await controller.loadMore();      // should request offset 2 (== items.length so far)

      expect(controller.items, [0, 1, 2, 3]);
      expect(calls[1], {'limit': 2, 'offset': 2});
    });

    test('loadMore — a no-op once hasMore is already false (already on the last page)', () async {
      var fetchCallCount = 0;
      final controller = PagedListController<int>(
        pageSize: 10,
        fetchPage: ({required limit, required offset}) async {
          fetchCallCount++;
          return [1]; // fewer than pageSize -> hasMore becomes false
        },
      );

      await controller.loadFirstPage();
      expect(controller.hasMore, false);
      expect(fetchCallCount, 1);

      await controller.loadMore(); // must not call fetchPage again
      expect(fetchCallCount, 1);
      expect(controller.items, [1]); // unchanged
    });

    test('loadMore — guards against a concurrent call while one is already in flight', () async {
      var fetchCallCount = 0;
      final gate = Completer<void>();
      final controller = PagedListController<int>(
        pageSize: 5,
        fetchPage: ({required limit, required offset}) async {
          fetchCallCount++;
          if (offset > 0) await gate.future; // only the loadMore fetch waits on the gate
          return List.generate(limit, (i) => offset + i);
        },
      );

      await controller.loadFirstPage(); // completes immediately (offset 0, no gate wait)

      final firstLoadMore = controller.loadMore();  // starts, blocks on gate, sets isLoadingMore=true
      final secondLoadMore = controller.loadMore(); // should immediately no-op due to isLoadingMore guard

      await secondLoadMore; // this one returns right away, doesn't touch fetchCallCount
      // 2, not 1: loadFirstPage's own fetchPage call already counted once,
      // plus the in-flight first loadMore's call — the guarded second
      // loadMore call must NOT have added a third.
      expect(fetchCallCount, 2);

      gate.complete();     // release the first loadMore's fetch
      await firstLoadMore; // let it finish

      expect(fetchCallCount, 2); // still exactly 2 — no extra call snuck in
      expect(controller.isLoadingMore, false);
    });

    test('isLoading resets to false even if fetchPage throws (finally block)', () async {
      final controller = PagedListController<int>(
        fetchPage: ({required limit, required offset}) async => throw Exception('network error'),
      );

      await expectLater(controller.loadFirstPage(), throwsException);
      expect(controller.isLoading, false);
    });

    test('isLoadingMore resets to false even if fetchPage throws on loadMore', () async {
      final controller = PagedListController<int>(
        pageSize: 2,
        fetchPage: ({required limit, required offset}) async {
          if (offset == 0) return [1, 2]; // first page succeeds, hasMore stays true
          throw Exception('network error'); // loadMore's fetch fails
        },
      );

      await controller.loadFirstPage();
      await expectLater(controller.loadMore(), throwsException);
      expect(controller.isLoadingMore, false);
      expect(controller.items, [1, 2]); // unchanged by the failed loadMore
    });
  });
}
