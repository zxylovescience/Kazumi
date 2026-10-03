import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Shares Kazumi's persistent WebView2 profile; never stores a password.
class CycaniWindowsSession {
  CycaniWindowsSession._();
  static final instance = CycaniWindowsSession._();
  static const home = 'https://www.cycani.org/';

  // Only the first-party origin can supply a session. Read the site's current
  // v2 schema, with v1 compatibility, without enumerating unrelated storage.
  static const readScript = r'''
(() => {
  if (location.origin !== 'https://www.cycani.org') return null;
  for (const store of [localStorage, sessionStorage]) {
    for (const key of ['cycweb:auth:v2', 'cycweb:auth:v1']) {
      try {
        const session = JSON.parse(store.getItem(key) || 'null');
        if (session && typeof session.token === 'string' && session.token.trim()) {
          return JSON.stringify({token: session.token.trim(),
            expiresAt: session.expiresAt || null,
            persistent: store === localStorage});
        }
      } catch (_) {}
    }
  }
  return null;
})()
''';

  static const clearScript = r'''
(() => {
  if (location.origin !== 'https://www.cycani.org') return false;
  for (const store of [localStorage, sessionStorage]) {
    for (const key of ['cycweb:auth:v2', 'cycweb:auth:v1']) store.removeItem(key);
  }
  location.reload();
  return true;
})()
''';

  String? _token;
  DateTime? _expiresAt;
  bool persistent = false;
  Future<String?>? _restoring;
  int _epoch = 0;

  static Future<void> configureEnvironment() async {
    if (!Platform.isWindows) throw StateError('此登录功能目前支持 Windows');
    final enabled = GStorage.getSetting(SettingsKeys.proxyEnable) as bool;
    final proxy = enabled
        ? ProxyUtils.getFormattedProxyUrl(
            GStorage.getSetting(SettingsKeys.proxyUrl) as String)
        : null;
    // The existing fork defaults to LocalAppData/flutter_webview_windows/
    // <exe stem>, shared by visible and headless controllers across restarts.
    try {
      await WebviewController.initializeEnvironment(
        additionalArguments: proxy == null ? null : '--proxy-server=$proxy',
      );
    } on PlatformException catch (error) {
      // A headless player may have initialized the shared native environment
      // before WebviewController's Dart-side flag was set. Reuse it.
      if (error.code != 'environment_already_initialized') rethrow;
    }
  }

  bool accept(Object? result, {int? expectedEpoch}) {
    if (expectedEpoch != null && expectedEpoch != _epoch) return false;
    if (expectedEpoch == null) _epoch++;
    _token = null;
    _expiresAt = null;
    persistent = false;
    if (result is! String) return false;
    try {
      final value = jsonDecode(result);
      if (value is! Map || value['token'] is! String) return false;
      final token = (value['token'] as String).trim();
      if (token.isEmpty || token.contains('\r') || token.contains('\n')) {
        return false;
      }
      final expiry = DateTime.tryParse(value['expiresAt']?.toString() ?? '');
      if (expiry != null && !expiry.isAfter(DateTime.now())) return false;
      _token = token;
      _expiresAt = expiry;
      persistent = value['persistent'] == true;
      return true;
    } on FormatException {
      return false;
    }
  }

  Future<String?> token() async {
    if (_token != null &&
        (_expiresAt == null || _expiresAt!.isAfter(DateTime.now()))) {
      return _token;
    }
    final pending = _restoring;
    if (pending != null) return pending;
    final operation = _restore();
    _restoring = operation;
    try {
      return await operation;
    } finally {
      _restoring = null;
    }
  }

  Future<String?> _restore() async {
    final epoch = _epoch;
    await configureEnvironment();
    final view = HeadlessWebview();
    StreamSubscription? subscription;
    var initialized = false;
    try {
      await view.run();
      initialized = true;
      await view.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      final loaded = Completer<void>();
      subscription = view.loadingState.listen((state) {
        if (state == LoadingState.navigationCompleted && !loaded.isCompleted) {
          loaded.complete();
        }
      });
      await view.loadUrl(home);
      await loaded.future.timeout(const Duration(seconds: 20));
      // The site's app validates/refreshes its own saved session after loading.
      for (var attempt = 0; attempt < 8; attempt++) {
        if (epoch != _epoch) return null;
        if (accept(await view.executeScript(readScript), expectedEpoch: epoch)) {
          return _token;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return null;
    } finally {
      await subscription?.cancel();
      if (initialized) await view.dispose();
    }
  }

  void invalidate() {
    _epoch++;
    _token = null;
    _expiresAt = null;
    persistent = false;
  }
}
