/// Shared pagination helpers (Week 3 Day 3, D107).
///
/// One page size and one paging rule for every paged list in the
/// app — report tables, sales history, and the Firestore counter
/// pages — so a page means the same thing on desktop and mobile and
/// in the mock and Firestore implementations alike.
///
/// Two shapes, because the two sides page differently:
/// - **In-memory lists** ([paginateList]): index-based pages for
///   lists the screen already holds (report tables, sales history).
/// - **Cursor pages** ([paginate]): id-based pages for repository
///   reads, mirroring the transport's `startAfterId` cursor
///   ([FirestoreTransport.queryCollection]) — the mock counter repo
///   pages this way so its page boundaries match the Firestore
///   repo's exactly.
library;

/// The one page size used everywhere (report tables, sales history,
/// counter pages).
const reportPageSize = 10;

/// One index-based page of an in-memory list.
class ListPage<T> {
  const ListPage({
    required this.items,
    required this.page,
    required this.totalPages,
    required this.totalItems,
  });

  /// Items on this page.
  final List<T> items;

  /// 1-based page number.
  final int page;

  /// Total pages for the list at [reportPageSize].
  final int totalPages;

  /// Total items across all pages.
  final int totalItems;

  bool get hasPrevious => page > 1;
  bool get hasNext => page < totalPages;
}

/// Pages [items] (1-based [page], clamped into range). An empty list
/// is one empty page — the screen still renders its empty state and
/// the controls show "Page 1 of 1".
ListPage<T> paginateList<T>(
  List<T> items, {
  required int page,
  int pageSize = reportPageSize,
}) {
  final size = pageSize < 1 ? reportPageSize : pageSize;
  final totalPages = items.isEmpty ? 1 : (items.length / size).ceil();
  final current = page.clamp(1, totalPages);
  final start = (current - 1) * size;
  final end = (start + size).clamp(0, items.length);
  return ListPage<T>(
    items: start >= items.length
        ? const []
        : items.sublist(start, end),
    page: current,
    totalPages: totalPages,
    totalItems: items.length,
  );
}

/// One cursor-based page, mirroring the transport's paged fetch.
class CursorPage<T> {
  const CursorPage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });

  /// Items on this page.
  final List<T> items;

  /// Opaque cursor for the next page (`null` when [hasMore] is
  /// false) — the last item's id.
  final String? nextCursor;

  /// True when another page follows.
  final bool hasMore;
}

/// Pages [items] (already in page order) by id cursor: the page
/// starts AFTER the item whose id is [startAfterId] (`null` = first
/// page). Returns at most [pageSize] items; [nextCursor] is the last
/// returned item's id when more items follow.
CursorPage<T> paginate<T>(
  List<T> items, {
  required int pageSize,
  required String Function(T item) idOf,
  String? startAfterId,
}) {
  final size = pageSize < 1 ? reportPageSize : pageSize;
  var start = 0;
  if (startAfterId != null) {
    final index = items.indexWhere((item) => idOf(item) == startAfterId);
    if (index != -1) start = index + 1;
  }
  final end = (start + size).clamp(0, items.length);
  final pageItems = start >= items.length
      ? <T>[]
      : items.sublist(start, end);
  final hasMore = end < items.length;
  return CursorPage<T>(
    items: pageItems,
    nextCursor: hasMore && pageItems.isNotEmpty
        ? idOf(pageItems.last)
        : null,
    hasMore: hasMore,
  );
}
