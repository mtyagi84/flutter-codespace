// Required boilerplate for running integration_test suites on Web via
// `flutter drive` -- `flutter test integration_test/... -d web-server`
// (the mobile/desktop path) is NOT supported on web ("Web devices are not
// supported for integration tests yet"). Web integration tests must go
// through `flutter drive --driver=test_driver/integration_test.dart
// --target=integration_test/<test>.dart -d web-server`, which needs this
// file to exist and a chromedriver instance running (see
// sakal/integration_test/README.md for the exact commands).
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
