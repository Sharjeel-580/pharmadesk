import 'dart:typed_data';

/// False: this platform cannot trigger a file download.
bool get canDownloadFile => false;

/// No-op on non-web targets.
void downloadTextFile(String filename, String contents, String mimeType) {}

/// No-op on non-web targets.
void downloadBytesFile(String filename, Uint8List bytes, String mimeType) {}
