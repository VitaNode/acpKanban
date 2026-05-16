import 'ui_copy.dart';

class ErrorCopy {
  static String mapError(String? errorCode, [String? technicalMessage]) {
    if (errorCode == null) return technicalMessage ?? 'An unknown error occurred';

    switch (errorCode) {
      case 'BRIDGE:TIMEOUT':
        return 'Connection timeout. Please check if your Bridge is running.';
      case 'BRIDGE:DISCONNECTED':
        return 'Bridge disconnected. Attempting to reconnect...';
      case 'AUTH:UNAUTHORIZED':
        return 'Unauthorized. Please check your User ID and Token.';
      case 'PROJECT:NOT_FOUND':
        return 'The selected project could not be found.';
      case 'CARD:NOT_FOUND':
        return 'The selected card could not be found.';
      case 'PROVIDER:QUOTA_EXCEEDED':
        return 'AI provider quota exceeded. Please check your account.';
      case 'SYSTEM:INTERNAL_ERROR':
        return 'Internal server error. Please try again later.';
      default:
        return technicalMessage ?? 'Error: $errorCode';
    }
  }

  static const String networkError = 'Network error. Please check your internet connection.';
  static const String serverUnavailable = 'Server is currently unavailable. Please try again later.';
  static const String timeoutError = 'Request timed out. Please check your network or server status.';
}
