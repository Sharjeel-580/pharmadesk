/// File download — conditional import.
///
/// On the web a real download is triggered (Blob + anchor click);
/// on every other target downloads are unavailable in the demo and
/// the caller shows the content (or a note) instead.
library;

export 'file_download_stub.dart'
    if (dart.library.html) 'file_download_web.dart';
