import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'billing_logic.dart';

/// Parked (held) sales for the POS (Week 2 Day 4, FR-POS-06).
///
/// A held sale is a snapshot of the cart — lines, customer, notes —
/// parked so the cashier can serve the next customer and resume it
/// later. Held carts are **session-only** (they do not survive a
/// restart) and they **never touch stock**: nothing is reserved,
/// decremented or held on park — the stock check runs again, against
/// live stock, when the sale is finally completed. A held sale that
/// can no longer be fulfilled (stock sold meanwhile) fails validation
/// at completion like any other sale, it does not silently short-ship.
///
/// State lives in [ParkedSalesNotifier] (in-memory, one list for the
/// session); the POS screen parks / resumes / discards through it.

/// One parked sale: the cart as it was when held.
class ParkedSale {
  const ParkedSale({
    required this.id,
    required this.branchId,
    required this.lines,
    this.customerId,
    this.notes = '',
    required this.cashierName,
    required this.parkedAt,
  });

  final String id;
  final String branchId;

  /// Cart lines as held (a copy — later cart edits do not rewrite
  /// the parked sale).
  final List<CartLine> lines;

  /// The customer picked for a khata sale, if any.
  final String? customerId;

  /// Free-text note the cashier left with the held sale.
  final String notes;
  final String cashierName;
  final DateTime parkedAt;

  /// Cart subtotal at park time (int paisa) — display only; the
  /// totals are recomputed from the lines on resume.
  int get subtotalMinor => cartSubtotalMinor(lines);

  ParkedSale copyWith({
    String? id,
    String? branchId,
    List<CartLine>? lines,
    String? customerId,
    String? notes,
    String? cashierName,
    DateTime? parkedAt,
  }) {
    return ParkedSale(
      id: id ?? this.id,
      branchId: branchId ?? this.branchId,
      lines: lines ?? this.lines,
      customerId: customerId ?? this.customerId,
      notes: notes ?? this.notes,
      cashierName: cashierName ?? this.cashierName,
      parkedAt: parkedAt ?? this.parkedAt,
    );
  }
}

/// Holds the parked sales for the session.
class ParkedSalesNotifier extends Notifier<List<ParkedSale>> {
  int _sequence = 0;

  @override
  List<ParkedSale> build() => const [];

  /// Parks the current cart. Returns the parked sale, or `null` when
  /// there is nothing to park (empty cart) — the POS disables the
  /// Hold button for an empty cart, so this is a guard, not a path
  /// the UI normally hits.
  ParkedSale? park({
    required String branchId,
    required List<CartLine> lines,
    String? customerId,
    String notes = '',
    required String cashierName,
  }) {
    if (lines.isEmpty) return null;
    _sequence++;
    final parked = ParkedSale(
      id: 'held-$_sequence',
      branchId: branchId,
      lines: List.of(lines),
      customerId: customerId,
      notes: notes,
      cashierName: cashierName,
      parkedAt: DateTime.now(),
    );
    state = [...state, parked];
    return parked;
  }

  /// Resumes a parked sale: removes it from the held list and returns
  /// it so the POS can load its lines + customer + notes back into
  /// the cart. Returns `null` when the id is not held (already
  /// resumed / discarded).
  ParkedSale? resume(String id) {
    final index = state.indexWhere((sale) => sale.id == id);
    if (index == -1) return null;
    final parked = state[index];
    state = List.of(state)..removeAt(index);
    return parked;
  }

  /// Discards a parked sale without completing it. Nothing was ever
  /// reserved, so discarding touches no stock — the cart is simply
  /// gone.
  void discard(String id) {
    state = state.where((sale) => sale.id != id).toList();
  }
}

final parkedSalesProvider =
    NotifierProvider<ParkedSalesNotifier, List<ParkedSale>>(
      ParkedSalesNotifier.new,
    );

/// Parked sales for one branch, oldest first.
final branchParkedSalesProvider = Provider.family<List<ParkedSale>, String>((
  ref,
  branchId,
) {
  final parked = ref.watch(parkedSalesProvider);
  return parked.where((sale) => sale.branchId == branchId).toList();
});
