/// Application error types.
///
/// Repositories throw these; presentation layers map them to user-facing
/// messages. Never surface raw platform/Firebase exception text to users.
class AppException implements Exception {
  final String message;
  final String? code;

  const AppException(this.message, {this.code});

  @override
  String toString() => 'AppException(${code ?? 'unknown'}): $message';
}

/// No network / backend unreachable (including Firestore offline exhaustion).
class NetworkException extends AppException {
  const NetworkException(super.message, {super.code = 'network'});
}

/// Signed-in user lacks the role/permission for this action.
class PermissionException extends AppException {
  const PermissionException(super.message, {super.code = 'permission'});
}

/// Authentication failed or the session expired.
class AuthException extends AppException {
  const AuthException(super.message, {super.code = 'auth'});
}

/// Requested record does not exist (or is outside the user's branch scope).
class NotFoundException extends AppException {
  const NotFoundException(super.message, {super.code = 'not-found'});
}

/// Input failed validation (forms, quantities, prices).
class ValidationException extends AppException {
  const ValidationException(super.message, {super.code = 'validation'});
}
