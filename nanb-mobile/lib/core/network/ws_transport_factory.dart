export 'ws_transport_io.dart'
    if (dart.library.js_interop) 'ws_transport_web.dart' show createWsTransport;
