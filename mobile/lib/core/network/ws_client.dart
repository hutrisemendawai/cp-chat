import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_config.dart';

enum ChatSocketState { disconnected, connecting, connected }

/// Resilient WebSocket client for the Chat Gateway.
///
/// Reconnects with exponential backoff and a 30-second cap, and sends a
/// heartbeat every [heartbeatInterval]. Events are exposed as decoded JSON
/// maps; see `docs/ws-protocol.md` for the event contract.
class ChatSocket {
  ChatSocket(
    this._accessToken, {
    this.heartbeatInterval = const Duration(seconds: 25),
  });

  final Future<String?> Function() _accessToken;
  final Duration heartbeatInterval;

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<ChatSocketState> _state =
      StreamController<ChatSocketState>.broadcast();
  final Random _random = Random();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnect;
  int _attempt = 0;
  bool _disposed = false;

  Stream<Map<String, dynamic>> get events => _events.stream;

  Stream<ChatSocketState> get state => _state.stream;

  bool get isConnected => _channel != null;

  Future<void> connect() async {
    if (_disposed || _channel != null) return;
    _reconnect?.cancel();
    _state.add(ChatSocketState.connecting);

    final token = await _accessToken();
    if (token == null) {
      _state.add(ChatSocketState.disconnected);
      return;
    }

    try {
      final channel = WebSocketChannel.connect(AppConfig.wsUri(token));
      _channel = channel;
      _subscription = channel.stream.listen(
        _onData,
        onDone: _onDisconnected,
        onError: (Object error) {
          debugPrint('ChatSocket error: $error');
          _onDisconnected();
        },
        cancelOnError: true,
      );
      _attempt = 0;
      _state.add(ChatSocketState.connected);
      _startHeartbeat();
    } catch (error) {
      debugPrint('ChatSocket connect failed: $error');
      _onDisconnected();
    }
  }

  void send(Map<String, dynamic> event) {
    final channel = _channel;
    if (channel == null) {
      throw StateError('ChatSocket is not connected');
    }
    channel.sink.add(jsonEncode(event));
  }

  void _onData(dynamic raw) {
    if (raw is! String) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['type'] == 'pong') return;
      if (!_events.isClosed) _events.add(decoded);
    } catch (error) {
      debugPrint('ChatSocket dropped malformed frame: $error');
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      try {
        send({'type': 'ping'});
      } catch (_) {
        _onDisconnected();
      }
    });
  }

  void _onDisconnected() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    if (_disposed) return;

    _state.add(ChatSocketState.disconnected);
    final exponential = min(30, pow(2, _attempt).toInt());
    final jitterMs = _random.nextInt(1000);
    _attempt++;
    _reconnect?.cancel();
    _reconnect = Timer(
      Duration(seconds: exponential, milliseconds: jitterMs),
      connect,
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    _heartbeat?.cancel();
    _reconnect?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    await _events.close();
    await _state.close();
  }
}
