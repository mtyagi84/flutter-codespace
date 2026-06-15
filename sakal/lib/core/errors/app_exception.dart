class AppException implements Exception {
  final String message;
  final int? statusCode;
  const AppException(this.message, {this.statusCode});

  @override
  String toString() => 'AppException($statusCode): $message';
}

class NetworkException extends AppException {
  const NetworkException(super.message, {super.statusCode});
}

class AuthException extends AppException {
  const AuthException(super.message);
}

class DatabaseException extends AppException {
  const DatabaseException(super.message);
}

class ServerException extends AppException {
  const ServerException(super.message, {super.statusCode});
}
