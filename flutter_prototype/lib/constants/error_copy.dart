class ErrorCopy {
  static String mapError(String? errorCode, [String? technicalMessage]) {
    if (errorCode == null) return technicalMessage ?? 'An unknown error occurred';

    switch (errorCode) {
      case 'SYSTEM:INTERNAL_ERROR':
        return 'Internal server error. Please try again later.';
      case 'SYSTEM:NOT_IMPLEMENTED':
        return 'This feature is not yet implemented.';
      case 'SYSTEM:INVALID_PARAMS':
        return 'Invalid request parameters. Please check your input.';

      case 'BRIDGE:TIMEOUT':
        return 'Connection timeout. Please check if your Bridge is running.';
      case 'BRIDGE:DISCONNECTED':
        return 'Bridge disconnected. Attempting to reconnect...';
      case 'BRIDGE:UNAVAILABLE':
        return 'Bridge is currently unavailable. Please try again later.';

      case 'AUTH:UNAUTHORIZED':
        return 'Unauthorized. Please check your User ID and Token.';
      case 'AUTH:FORBIDDEN':
        return 'Access denied. You do not have permission for this operation.';

      case 'PROJECT:NOT_FOUND':
        return 'The selected project could not be found.';
      case 'PROJECT:ALREADY_EXISTS':
        return 'A project with this name already exists.';

      case 'CARD:NOT_FOUND':
        return 'The selected card could not be found.';
      case 'CARD:ACCESS_DENIED':
        return 'You do not have access to this card.';

      case 'SESSION:NOT_FOUND':
        return 'Session not found. Please reconnect to the card.';
      case 'SESSION:BUSY':
        return 'Session is busy. Please wait for the current operation to complete.';
      case 'SESSION:EXPIRED':
        return 'Session has expired. Please refresh and try again.';

      case 'PROVIDER:ERROR':
        return 'AI provider encountered an error. Please check provider configuration.';
      case 'PROVIDER:TIMEOUT':
        return 'AI provider request timed out. Please try again.';
      case 'PROVIDER:QUOTA_EXCEEDED':
        return 'AI provider quota exceeded. Please check your account.';

      default:
        return technicalMessage ?? 'An unexpected error occurred. Please try again.';
    }
  }

  static const String networkError = 'Network error. Please check your internet connection.';
  static const String serverUnavailable = 'Server is currently unavailable. Please try again later.';
  static const String timeoutError = 'Request timed out. Please check your network or server status.';
}
