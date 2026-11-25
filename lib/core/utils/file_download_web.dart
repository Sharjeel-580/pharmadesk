import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// True: the web demo can trigger a browser download.
bool get canDownloadFile => true;

/// Downloads [contents] as a text file via a Blob + anchor click.
void downloadTextFile(String filename, String contents, String mimeType) {
  final blob = web.Blob(
    [contents.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  _downloadBlob(filename, blob);
}

/// Downloads [bytes] as a binary file via a Blob + anchor click.
void downloadBytesFile(String filename, Uint8List bytes, String mimeType) {
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  _downloadBlob(filename, blob);
}

void _downloadBlob(String filename, web.Blob blob) {
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..setAttribute('download', filename);
  anchor.click();
  web.URL.revokeObjectURL(url);
}
