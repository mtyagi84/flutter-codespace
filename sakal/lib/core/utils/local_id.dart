import 'dart:math';

/// Generates a temporary document id for a transaction saved while offline
/// (e.g. `LOCAL-1735900000000-a1b2c3`). Used as the document's key until the
/// server assigns a real one on sync — SyncEngine tracks pending docs by this
/// id, and it's also the composite-key value written into the local Drift
/// cache so the document is readable while still offline.
String generateLocalId() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final rng   = Random.secure();
  final ts    = DateTime.now().millisecondsSinceEpoch.toString();
  final rand  = List.generate(6, (_) => chars[rng.nextInt(chars.length)]).join();
  return 'LOCAL-$ts-$rand';
}
