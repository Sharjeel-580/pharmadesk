import 'package:flutter/material.dart';

import '../utils/pagination.dart';

/// Previous / Next page controls (Week 3 Day 3, D107).
///
/// One control for every paged list — report tables, sales history —
/// so paging looks and behaves the same on desktop and mobile: two
/// small buttons with a "Page x of y" label between them. The buttons
/// disable at the boundaries (no wrap-around, no dead tap).
class PagedListControls extends StatelessWidget {
  const PagedListControls({
    super.key,
    required this.page,
    required this.totalPages,
    required this.onPrevious,
    required this.onNext,
  });

  /// 1-based current page.
  final int page;

  /// Total pages.
  final int totalPages;

  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    // Week 6 Day 5 (D170): a Wrap, not a Row — at 390px the three
    // controls overflowed by 120px in the test font (the daily
    // sales table is only 310px wide inside its card). On desktop
    // it renders identically (one right-aligned line); on a phone
    // the Next button flows below instead of overflowing.
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton.icon(
          key: const ValueKey('page-previous'),
          onPressed: page > 1 ? onPrevious : null,
          icon: const Icon(Icons.chevron_left_outlined, size: 18),
          label: const Text('Previous'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            'Page $page of $totalPages',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        TextButton.icon(
          key: const ValueKey('page-next'),
          onPressed: page < totalPages ? onNext : null,
          icon: const Icon(Icons.chevron_right_outlined, size: 18),
          label: const Text('Next'),
        ),
      ],
    );
  }
}

/// A paged list section: renders [itemBuilder] for the current page
/// of [items] and the [PagedListControls] below it, owning the page
/// state. Use when the screen does not already hold page state;
/// screens that page several sections (the reports screen) hold the
/// page numbers themselves and use [PagedListControls] directly.
class PagedList<T> extends StatefulWidget {
  const PagedList({
    super.key,
    required this.items,
    required this.itemBuilder,
    this.pageSize = reportPageSize,
    this.emptyMessage,
  });

  final List<T> items;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final int pageSize;
  final String? emptyMessage;

  @override
  State<PagedList<T>> createState() => _PagedListState<T>();
}

class _PagedListState<T> extends State<PagedList<T>> {
  int _page = 1;

  @override
  Widget build(BuildContext context) {
    // The page clamps into range when the list shrinks (filter /
    // branch change) — no reset needed, and no surprise jump to
    // page 1 on an unrelated rebuild (the provider rebuilds the
    // list identity on every refresh).
    final page = paginateList(
      widget.items,
      page: _page,
      pageSize: widget.pageSize,
    );
    if (widget.items.isEmpty) {
      return Text(widget.emptyMessage ?? 'Nothing to show.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in page.items) widget.itemBuilder(context, item),
        if (page.totalPages > 1) ...[
          const SizedBox(height: 8),
          PagedListControls(
            page: page.page,
            totalPages: page.totalPages,
            onPrevious: () => setState(() => _page = page.page - 1),
            onNext: () => setState(() => _page = page.page + 1),
          ),
        ],
      ],
    );
  }
}
