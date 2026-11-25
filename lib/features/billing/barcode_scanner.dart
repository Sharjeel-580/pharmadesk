import '../../core/services/repositories.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../inventory/inventory_logic.dart';

/// Barcode scanning for the POS (Week 2 Day 4, FR-POS-02).
///
/// Two layers:
///
/// 1. **Pure lookup** ([scanBarcode]) over the already-loaded
///    catalogue + branch inventory — what the POS screen calls. It
///    reuses the Day 5 shared guard ([canSellMedicine] /
///    [fefoBatchFor], D30): a code that matches a medicine whose
///    batches are all expired (or out of stock) is `notSellable`,
///    never added to the cart.
/// 2. **[BarcodeScanner]**, the seam a real scanner plugs into.
///    Today the only implementation is [SimulatedBarcodeScanner]
///    (typed / pasted codes + the POS "Simulate scan" demo action,
///    which feeds a catalogue barcode through the same path).
///
/// ## Hardware integration point (for later)
///
/// Most counter scanners are **HID keyboard wedges**: they type the
/// barcode as keystrokes followed by Enter. That path needs no code
/// at all — the POS scan field already has autofocus handling and
/// Enter-to-add, so a wedge scanner works the moment it is plugged
/// in. A scanner with its own SDK (Bluetooth / camera-based) plugs
/// in here instead: implement [BarcodeScanner.scan] to call the SDK
/// and return the scanned code, then hand the result to
/// [scanBarcode] exactly like the simulated implementation does.
/// [HardwareBarcodeScanner] is the documented stub for that work.

/// What a scan found.
enum BarcodeScanOutcome {
  /// The code matched a medicine with at least one sellable batch.
  found,

  /// No medicine in the catalogue carries this barcode.
  notFound,

  /// The code matched a medicine, but none of its batches can be
  /// sold right now (all expired / quarantined / out of stock).
  notSellable,
}

/// The result of one scan: the outcome, and — when found — the
/// medicine, the FEFO batch that would be picked, and the sellable
/// quantity at the branch.
class BarcodeScanResult {
  const BarcodeScanResult({
    required this.outcome,
    required this.code,
    this.medicine,
    this.fefoBatch,
    this.sellableQuantity = 0,
  });

  final BarcodeScanOutcome outcome;
  final String code;
  final Medicine? medicine;
  final InventoryItem? fefoBatch;
  final int sellableQuantity;

  bool get isFound => outcome == BarcodeScanOutcome.found;
}

/// Finds a medicine by exact barcode (trimmed). Barcodes are the
/// catalogue's sample EAN-13 values (Day 5) — fictional demo values,
/// never real GTINs.
Medicine? findMedicineByBarcode(
  List<Medicine> medicines,
  String code,
) {
  final needle = code.trim();
  if (needle.isEmpty) return null;
  for (final medicine in medicines) {
    if (medicine.barcode == needle) return medicine;
  }
  return null;
}

/// Pure scan lookup: barcode → medicine → FEFO batch pick.
///
/// Never returns `found` for expired stock: the sellable guard
/// decides, so a scan of an expired-only medicine reports
/// `notSellable` with the medicine attached (the POS shows which
/// medicine it was and why it cannot be added).
BarcodeScanResult scanBarcode({
  required List<Medicine> medicines,
  required Map<String, List<InventoryItem>> batchesByMedicine,
  required String code,
  DateTime? now,
}) {
  final trimmed = code.trim();
  final medicine = findMedicineByBarcode(medicines, trimmed);
  if (medicine == null) {
    return BarcodeScanResult(outcome: BarcodeScanOutcome.notFound, code: trimmed);
  }
  final batches = batchesByMedicine[medicine.id] ?? const [];
  if (!canSellMedicine(batches, now: now)) {
    return BarcodeScanResult(
      outcome: BarcodeScanOutcome.notSellable,
      code: trimmed,
      medicine: medicine,
    );
  }
  return BarcodeScanResult(
    outcome: BarcodeScanOutcome.found,
    code: trimmed,
    medicine: medicine,
    fefoBatch: fefoBatchFor(batches, now: now),
    sellableQuantity: sellableStockFor(batches, now: now),
  );
}

/// A barcode scanner: one scanned code in, one lookup result out.
///
/// Implementations decide *how* the code arrives (typed, pasted,
/// wedge keystrokes, SDK callback); the lookup itself is always
/// [scanBarcode], so every scanner enforces the same expired-stock
/// guard.
abstract class BarcodeScanner {
  Future<BarcodeScanResult> scan(String code);
}

/// Simulated scanner (demo): looks the typed / pasted code up in the
/// catalogue + branch inventory through the repositories. The POS
/// "Simulate scan" action feeds a real catalogue barcode through
/// this class, so the demo exercises the exact path a hardware scan
/// would take.
class SimulatedBarcodeScanner implements BarcodeScanner {
  SimulatedBarcodeScanner({
    required this.medicines,
    required this.inventory,
  });

  final MedicineRepository medicines;
  final InventoryRepository inventory;

  @override
  Future<BarcodeScanResult> scan(String code) async {
    final medicine = await medicines.getByBarcode(code);
    if (medicine == null) {
      return BarcodeScanResult(
        outcome: BarcodeScanOutcome.notFound,
        code: code.trim(),
      );
    }
    final batches = await inventory.getInventory();
    final byMedicine = groupBatchesByMedicine(batches);
    return scanBarcode(
      medicines: [medicine],
      batchesByMedicine: byMedicine,
      code: code,
    );
  }
}

/// Hardware-scanner integration point (not implemented — no scanner
/// hardware exists in this build).
///
/// A wedge scanner needs no implementation: it types into the POS
/// scan field like a keyboard. A scanner with an SDK implements
/// [BarcodeScanner.scan] against that SDK and returns the code it
/// read; until then this stub throws [UnsupportedError] with the
/// explanation instead of pretending to scan.
class HardwareBarcodeScanner implements BarcodeScanner {
  const HardwareBarcodeScanner();

  @override
  Future<BarcodeScanResult> scan(String code) {
    throw UnsupportedError(
      'No hardware barcode scanner is connected. A HID keyboard-wedge '
      'scanner works with the POS scan field as-is (it types the code '
      'and presses Enter); an SDK scanner needs a BarcodeScanner '
      'implementation for its SDK — see barcode_scanner.dart.',
    );
  }
}
