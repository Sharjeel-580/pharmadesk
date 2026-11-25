import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'receipt_print.dart' as receipt_print;

/// Receipt printer integration (Week 2 Day 4, FR-POS-07).
///
/// [ReceiptPrinter] is the seam every print / cash-drawer action
/// goes through:
///
/// - **Web (working today):** [WebReceiptPrinter] prints through the
///   browser print dialog — the existing Day 6 web print path
///   ([printReceipt] / [printText] in `receipt_print.dart`). The
///   receipt screen's Print button and the Settings test print both
///   use this.
/// - **Network / USB (documented stubs):** [NetworkReceiptPrinter]
///   and [UsbReceiptPrinter] hold the configuration and report
///   "not configured" until the hardware integration lands — they
///   never pretend a print succeeded. See the class docs for what
///   the real implementation sends.
///
/// Printer settings live in [printerSettingsProvider] (session-only
/// in the demo, like the other Settings — production persists them
/// per organization in Firestore, SRS FR-SYS-05). [receiptPrinterProvider]
/// builds the printer for the configured type, so the Settings test
/// print and the receipt screen always agree on which printer is
/// active.

/// What kind of printer the counter uses.
enum PrinterType { browser, network, usb }

String printerTypeLabel(PrinterType type) => switch (type) {
  PrinterType.browser => 'Browser print (web)',
  PrinterType.network => 'Network printer (ESC/POS over TCP)',
  PrinterType.usb => 'USB printer',
};

/// Printer configuration, edited on the Settings → General tab.
class PrinterSettings {
  const PrinterSettings({
    this.name = 'Browser print',
    this.type = PrinterType.browser,
    this.networkHost = '',
    this.networkPort = 9100,
  });

  /// Display name shown on receipts and in Settings.
  final String name;

  final PrinterType type;

  /// Network printer IP / hostname (network type only).
  final String networkHost;

  /// Network printer TCP port (ESC/POS printers listen on 9100).
  final int networkPort;

  PrinterSettings copyWith({
    String? name,
    PrinterType? type,
    String? networkHost,
    int? networkPort,
  }) {
    return PrinterSettings(
      name: name ?? this.name,
      type: type ?? this.type,
      networkHost: networkHost ?? this.networkHost,
      networkPort: networkPort ?? this.networkPort,
    );
  }
}

/// The result of one printer action: did it happen, and what should
/// the user be told. Actions never throw for "printer not available"
/// — they return a failed result with the reason, so the UI can show
/// it instead of crashing.
class PrinterResult {
  const PrinterResult({required this.success, required this.message});

  final bool success;
  final String message;
}

/// A receipt printer: print text, kick the cash drawer, report
/// whether printing is possible at all.
abstract class ReceiptPrinter {
  /// Human-readable availability: can this printer print right now,
  /// and if not, why.
  PrinterStatus get status;

  /// Prints [text] (plain-text receipt). Returns success/failure —
  /// never throws for an unavailable printer.
  Future<PrinterResult> printText(String text);

  /// Sends the open-cash-drawer signal. Returns success/failure —
  /// the browser print path cannot send a drawer kick, so the web
  /// printer reports that honestly.
  Future<PrinterResult> openCashDrawer();
}

/// Availability of a printer.
class PrinterStatus {
  const PrinterStatus({required this.available, required this.message});

  final bool available;
  final String message;
}

/// Web printer (working): the browser print dialog.
///
/// Receipts print through the existing Day 6 path. The drawer kick
/// is NOT available here — a browser cannot send an ESC/POS drawer
/// signal — so [openCashDrawer] returns a failed result that says so
/// instead of silently doing nothing.
class WebReceiptPrinter implements ReceiptPrinter {
  const WebReceiptPrinter({this.name = 'Browser print'});

  final String name;

  @override
  PrinterStatus get status => PrinterStatus(
    available: receipt_print.canPrintReceipt,
    message: receipt_print.canPrintReceipt
        ? '$name — ready (browser print dialog)'
        : '$name — printing is not available on this platform',
  );

  @override
  Future<PrinterResult> printText(String text) async {
    if (!receipt_print.canPrintReceipt) {
      return const PrinterResult(
        success: false,
        message:
            'Printing is not available on this platform — use Share to copy the receipt text.',
      );
    }
    receipt_print.printText(text);
    return const PrinterResult(
      success: true,
      message: 'Sent to the browser print dialog.',
    );
  }

  @override
  Future<PrinterResult> openCashDrawer() async {
    return const PrinterResult(
      success: false,
      message:
          'Cash drawer kick needs a receipt printer — the browser print path cannot send a drawer signal. Connect a network/USB printer for drawer control.',
    );
  }
}

/// Network printer (documented stub — no hardware in this build).
///
/// The real implementation opens a TCP socket to
/// ([networkHost]:[networkPort]) and sends ESC/POS bytes: the receipt
/// text followed by the drawer-kick command (`0x1B 0x70 0x00 0x19
/// 0xFA`) and a cut command. Until that lands, every action reports
/// "not configured" — the settings screen shows the same message, so
/// nobody mistakes the stub for a working printer.
class NetworkReceiptPrinter implements ReceiptPrinter {
  const NetworkReceiptPrinter({
    required this.networkHost,
    this.networkPort = 9100,
  });

  final String networkHost;
  final int networkPort;

  @override
  PrinterStatus get status => PrinterStatus(
    available: false,
    message: networkHost.isEmpty
        ? 'Network printer — no printer IP configured yet. Set the printer IP in Settings.'
        : 'Network printer ($networkHost:$networkPort) — ESC/POS over TCP is not implemented in this build yet.',
  );

  @override
  Future<PrinterResult> printText(String text) async {
    return PrinterResult(
      success: false,
      message: status.message,
    );
  }

  @override
  Future<PrinterResult> openCashDrawer() async {
    return PrinterResult(
      success: false,
      message: status.message,
    );
  }
}

/// USB printer (documented stub — no hardware in this build).
///
/// The real implementation talks to the printer over USB
/// (platform channel / `usb_serial` on Android, WebUSB on web) and
/// sends the same ESC/POS bytes as the network printer. Until that
/// lands, every action reports "not implemented" honestly.
class UsbReceiptPrinter implements ReceiptPrinter {
  const UsbReceiptPrinter();

  @override
  PrinterStatus get status => const PrinterStatus(
    available: false,
    message:
        'USB printer — USB printing is not implemented in this build yet.',
  );

  @override
  Future<PrinterResult> printText(String text) async {
    return PrinterResult(success: false, message: status.message);
  }

  @override
  Future<PrinterResult> openCashDrawer() async {
    return PrinterResult(success: false, message: status.message);
  }
}

/// Builds the printer for the configured settings: browser →
/// [WebReceiptPrinter], network → [NetworkReceiptPrinter], USB →
/// [UsbReceiptPrinter].
ReceiptPrinter printerForSettings(PrinterSettings settings) =>
    switch (settings.type) {
      PrinterType.browser => WebReceiptPrinter(name: settings.name),
      PrinterType.network => NetworkReceiptPrinter(
        networkHost: settings.networkHost,
        networkPort: settings.networkPort,
      ),
      PrinterType.usb => const UsbReceiptPrinter(),
    };

/// The test receipt the Settings test-print action sends: printer
/// name + type, a sample receipt body, and the date/time. The web
/// printer opens it in the browser print dialog, so the cashier sees
/// exactly what a real receipt print looks like.
String testReceiptText(PrinterSettings settings, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final day = at.day.toString().padLeft(2, '0');
  final month = at.month.toString().padLeft(2, '0');
  final hour = at.hour.toString().padLeft(2, '0');
  final minute = at.minute.toString().padLeft(2, '0');
  return '''PharmaDesk — TEST PRINT
Printer: ${settings.name} (${printerTypeLabel(settings.type)})
$day/$month/${at.year}, $hour:$minute
--------------------------------
Panadol Extra 500mg x1 — Rs 120.00
Augmentin 625mg x2 — Rs 1,700.00
--------------------------------
TOTAL: Rs 1,820.00
Payment: Cash
--------------------------------
If you can read this, the printer works.
DEMO — test print, not a real receipt.''';
}

/// Printer settings state (session-only in the demo).
class PrinterSettingsNotifier extends Notifier<PrinterSettings> {
  @override
  PrinterSettings build() => const PrinterSettings();

  void setName(String name) {
    state = state.copyWith(name: name.trim().isEmpty ? 'Browser print' : name);
  }

  void setType(PrinterType type) {
    state = state.copyWith(type: type);
  }

  void setNetworkHost(String host) {
    state = state.copyWith(networkHost: host.trim());
  }

  void setNetworkPort(int port) {
    state = state.copyWith(networkPort: port);
  }
}

final printerSettingsProvider =
    NotifierProvider<PrinterSettingsNotifier, PrinterSettings>(
      PrinterSettingsNotifier.new,
    );

/// The active receipt printer for the configured settings. Override
/// in tests with a fake printer to capture what would be printed.
final receiptPrinterProvider = Provider<ReceiptPrinter>(
  (ref) => printerForSettings(ref.watch(printerSettingsProvider)),
);
