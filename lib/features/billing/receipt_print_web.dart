// Receipt printing on the web: the browser's print dialog, called
// through dart:js_interop (no dart:html — deprecated). This file is
// reached solely through the conditional import in
// `receipt_print.dart`, so other targets never compile it.
library;

import 'dart:js_interop';

@JS('window.print')
external void _windowPrint();

/// True: the web demo can print via the browser dialog.
bool get canPrintReceipt => true;

/// Opens the browser print dialog for the receipt preview.
void printReceipt() => _windowPrint();
