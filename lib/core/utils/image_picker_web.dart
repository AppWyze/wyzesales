import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

/// Maximum size for a picked logo file, before any cropping/encoding this
/// app does itself — generous enough for any reasonable logo image, small
/// enough that Settings > Company's upload stays quick and the
/// `client-logos` bucket doesn't fill up with accidental full-resolution
/// photos.
const int kMaxLogoUploadBytes = 2 * 1024 * 1024;

/// Opens the browser's native file picker restricted to common image types
/// and returns the picked file's raw bytes, or null if the user dismissed
/// the picker without choosing a file.
///
/// Plain `dart:html`, not a `image_picker`/`file_picker` package — WyzeSales
/// has no android/ios/macos/windows/linux runner directories at all (see
/// pubspec.yaml/README: this is a Netlify web deploy only), so there is no
/// other platform this ever also needs to compile for, and no reason to pull
/// in a federated plugin (with its own version to track and its own web
/// implementation to trust sight-unseen) just to do what the browser's own
/// `<input type=file>` already does directly.
///
/// Throws an [Exception] with a user-facing message for a file over
/// [kMaxLogoUploadBytes] or one the browser fails to read — callers show
/// that message directly (matching the rest of this app's
/// `catch (e) { ...'$e'... }` convention, e.g. `_EditCompanyDialogState._save`
/// in settings_screen.dart) rather than needing their own translation.
Future<Uint8List?> pickImageFileBytes() {
  final completer = Completer<Uint8List?>();
  final input = html.FileUploadInputElement()..accept = 'image/png,image/jpeg,image/jpg,image/webp';
  input.click();
  input.onChange.listen((_) {
    final files = input.files;
    if (files == null || files.isEmpty) {
      completer.complete(null);
      return;
    }
    final file = files.first;
    if (file.size > kMaxLogoUploadBytes) {
      completer.completeError(Exception('That file is larger than 2 MB — please choose a smaller image.'));
      return;
    }
    final reader = html.FileReader();
    reader.readAsArrayBuffer(file);
    reader.onLoadEnd.listen((_) {
      final result = reader.result;
      if (result is Uint8List) {
        completer.complete(result);
      } else {
        completer.completeError(Exception('Could not read that file.'));
      }
    });
    reader.onError.listen((_) {
      completer.completeError(Exception('Could not read that file.'));
    });
  });
  return completer.future;
}
