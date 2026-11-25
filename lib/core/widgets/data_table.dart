import 'package:flutter/material.dart';

import 'empty_state.dart';

/// One column of a [PharmaDataTable].
///
/// [cell] builds the cell widget for a row; [sortValue] (optional)
/// supplies the [Comparable] used when the column is sortable.
class PharmaDataColumn<T> {
  const PharmaDataColumn({
    required this.label,
    required this.cell,
    this.sortValue,
    this.numeric = false,
  });

  final String label;
  final Widget Function(T row) cell;
  final Comparable<Object>? Function(T row)? sortValue;
  final bool numeric;

  bool get sortable => sortValue != null;
}

/// Sortable data table with an empty state, wrapped in a scrollable card.
///
/// Sorting is handled internally: tapping a sortable column header sorts
/// the rows (ascending, then descending). When [rows] is empty the
/// [emptyTitle]/[emptyMessage] state is shown instead of the table.
class PharmaDataTable<T> extends StatefulWidget {
  const PharmaDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.emptyTitle = 'Nothing here yet',
    this.emptyMessage = 'There are no rows to show.',
    this.emptyIcon = Icons.inbox_outlined,
  });

  final List<PharmaDataColumn<T>> columns;
  final List<T> rows;
  final String emptyTitle;
  final String emptyMessage;
  final IconData emptyIcon;

  @override
  State<PharmaDataTable<T>> createState() => _PharmaDataTableState<T>();
}

class _PharmaDataTableState<T> extends State<PharmaDataTable<T>> {
  int? _sortColumnIndex;
  bool _sortAscending = true;

  List<T> get _sortedRows {
    if (_sortColumnIndex == null) return widget.rows;
    final column = widget.columns[_sortColumnIndex!];
    final sortValue = column.sortValue;
    if (sortValue == null) return widget.rows;
    final sorted = List<T>.of(widget.rows);
    sorted.sort((a, b) {
      final aValue = sortValue(a);
      final bValue = sortValue(b);
      if (aValue == null && bValue == null) return 0;
      if (aValue == null) return 1;
      if (bValue == null) return -1;
      final result = aValue.compareTo(bValue);
      return _sortAscending ? result : -result;
    });
    return sorted;
  }

  void _onSort(int columnIndex, bool ascending) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _sortAscending = ascending;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.rows.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: PharmaEmptyState(
            icon: widget.emptyIcon,
            title: widget.emptyTitle,
            message: widget.emptyMessage,
          ),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          sortColumnIndex: _sortColumnIndex,
          sortAscending: _sortAscending,
          columns: [
            for (var i = 0; i < widget.columns.length; i++)
              DataColumn(
                label: Text(
                  widget.columns[i].label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                numeric: widget.columns[i].numeric,
                onSort: widget.columns[i].sortable
                    ? (columnIndex, ascending) =>
                          _onSort(columnIndex, ascending)
                    : null,
              ),
          ],
          rows: [
            for (final row in _sortedRows)
              DataRow(
                cells: [
                  for (final column in widget.columns)
                    DataCell(column.cell(row)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
