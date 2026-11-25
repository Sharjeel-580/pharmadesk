// Receipt printing — conditional import.
//
// On the web the browser's print dialog is used; on every other
// target printing is unavailable in the Day 6 demo and the receipt
// screen says so (Share / copy still works everywhere).
library;

export 'receipt_print_stub.dart'
    if (dart.library.html) 'receipt_print_web.dart';
