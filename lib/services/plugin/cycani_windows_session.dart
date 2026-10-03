import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/storage/storage.dart';

/// Uses a dedicated persistent website profile; never stores a password.
class CycaniWindowsSession {
  CycaniWindowsSession._();
  static final instance = CycaniWindowsSession._();
  static const home = 'https://www.cycani.org/';
  static const loginUrl = '${home}login';
  static Future<WindowsWebViewEnvironment>? _environment;

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

  static Future<WindowsWebViewEnvironment> configureEnvironment() async {
    final pending = _environment;
    if (pending != null) return pending;
    final operation = _createEnvironment();
    _environment = operation;
    try {
      return await operation;
    } catch (_) {
      _environment = null;
      rethrow;
    }
  }

  static Future<WindowsWebViewEnvironment> _createEnvironment() async {
    if (!Platform.isWindows) throw StateError('此登录功能目前支持 Windows');
    // Keep scripts and their returned authentication data out of plugin logs.
    PlatformInAppWebViewController.debugLoggingSettings =
        DebugLoggingSettings(enabled: false);
    PlatformInAppBrowser.debugLoggingSettings = DebugLoggingSettings(enabled: false);
    PlatformWebViewEnvironment.debugLoggingSettings =
        DebugLoggingSettings(enabled: false);
    final bool enabled = GStorage.getSetting(SettingsKeys.proxyEnable);
    final proxy = enabled
        ? ProxyUtils.getFormattedProxyUrl(
            GStorage.getSetting(SettingsKeys.proxyUrl))
        : null;
    final directory = Directory(
        '${(await getApplicationSupportDirectory()).path}/cycani_webview');
    await directory.create(recursive: true);
    return WindowsWebViewEnvironment.static().create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: directory.path,
        additionalBrowserArguments: proxy == null ? null : '--proxy-server=$proxy',
      ),
    );
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
    return _withSavedPage((controller) async {
      // The site's app validates/refreshes its own saved session after loading.
      for (var attempt = 0; attempt < 8; attempt++) {
        if (epoch != _epoch) return null;
        if (accept(await controller.evaluateJavascript(source: readScript),
            expectedEpoch: epoch)) {
          return _token;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return null;
    });
  }

  static Future<T> _withSavedPage<T>(
      Future<T> Function(PlatformInAppWebViewController controller) action) async {
    final environment = await configureEnvironment();
    final loaded = Completer<void>();
    final view = WindowsHeadlessInAppWebView(
      WindowsHeadlessInAppWebViewCreationParams(
        webViewEnvironment: environment,
        initialUrlRequest: URLRequest(url: WebUri(home)),
        onLoadStop: (controller, url) {
          if (!loaded.isCompleted) loaded.complete();
        },
      ),
    );
    try {
      await view.run();
      await loaded.future.timeout(const Duration(seconds: 20));
      final controller = view.webViewController;
      if (controller == null) throw StateError('次元城登录存储尚未就绪');
      return await action(controller);
    } finally {
      await view.dispose();
    }
  }

  Future<void> clearSavedSession() async {
    invalidate();
    await _withSavedPage((controller) async {
      final cleared = await controller.evaluateJavascript(source: clearScript);
      if (cleared != true) throw StateError('无法清除次元城登录存储');
    });
  }

  void invalidate() {
    _epoch++;
    _token = null;
    _expiresAt = null;
    persistent = false;
  }
}
