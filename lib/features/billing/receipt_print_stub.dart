// Receipt printing on non-web targets: unavailable in the Day 6
// demo (no thermal-printer integration yet). The receipt screen
// shows a note and offers Share / copy instead.
library;

/// False: this platform cannot print the receipt.
bool get canPrintReceipt => false;

/// No-op on non-web targets.
void printReceipt() {}
