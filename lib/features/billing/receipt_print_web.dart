// Receipt printing on the web: the browser's print dialog, called
// through dart:js_interop (no dart:html — deprecated). This file is
// reached solely through the conditional import in
// `receipt_print.dart`, so other targets never compile it.
library;

import 'dart:js_interop';

@JS('window.print')
external void _windowPrint();

@JS('window.open')
external _PopupWindow? _windowOpen(String url, String target);

/// A popup window opened for printing. With `@staticInterop` the
/// instance members live in the extension below, not in the class
/// body — declaring them in the class fails the web build.
@JS()
@staticInterop
class _PopupWindow {}

extension _PopupWindowMembers on _PopupWindow {
  external _PopupDocument get document;
  external void focus();
  external void print();
}

@JS()
@staticInterop
class _PopupDocument {}

extension _PopupDocumentMembers on _PopupDocument {
  external void open();
  external void write(String text);
  external void close();
}

/// True: the web demo can print via the browser dialog.
bool get canPrintReceipt => true;

/// Opens the browser print dialog for the receipt preview.
void printReceipt() => _windowPrint();

/// Prints arbitrary text (e.g. the printer test receipt) in a popup
/// window: the text is written into a blank document as preformatted
/// text and the popup's print dialog is opened. When the popup is
/// blocked, falls back to printing the current page.
void printText(String text) {
  final popup = _windowOpen('', '_blank');
  if (popup == null) {
    _windowPrint();
    return;
  }
  popup.document.open();
  popup.document.write(_printHtml(text));
  popup.document.close();
  popup.focus();
  popup.print();
}

String _printHtml(String text) {
  final escaped = text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  return '<!DOCTYPE html><html><head><title>PharmaDesk print</title>'
      '<style>body{font-family:monospace;font-size:14px;}</style>'
      '</head><body><pre>$escaped</pre></body></html>';
}
