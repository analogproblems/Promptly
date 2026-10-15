import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/engine.dart' as rust;

/// What the app needs from the Rust engine, as a plain interface so screens
/// can be tested with a fake and so the generated bridge stays in one place.
abstract class Engine {
  String version();
  String ping(String name);
  EndpointParse parseEndpoint(String input);
}

sealed class EndpointParse {
  const EndpointParse();
}

class EndpointOk extends EndpointParse {
  const EndpointOk({required this.user, required this.host, required this.port});
  final String user;
  final String host;
  final int port;

  String get display => port == 22 ? '$user@$host' : '$user@$host:$port';
}

class EndpointError extends EndpointParse {
  const EndpointError(this.message);
  final String message;
}

/// The real engine, through flutter_rust_bridge.
class RustEngine implements Engine {
  const RustEngine();

  @override
  String version() => rust.engineVersion();

  @override
  String ping(String name) => rust.ping(name: name);

  @override
  EndpointParse parseEndpoint(String input) {
    try {
      final p = rust.parseEndpoint(input: input);
      return EndpointOk(user: p.user, host: p.host, port: p.port);
    } catch (e) {
      // The engine returns a plain message meant for the UI.
      return EndpointError(e is String ? e : e.toString());
    }
  }
}

final engineProvider = Provider<Engine>((_) => const RustEngine());
