import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/plugin/cycani_api.dart';
import 'package:kazumi/services/plugin/cycani_rule.dart';
import 'package:kazumi/services/plugin/cycani_windows_session.dart';

/// Native WebView2 window: Windows handles text, IME, and mouse focus directly.
class CycaniLoginPage extends StatefulWidget {
  const CycaniLoginPage({super.key, required this.plugins});
  final PluginsController plugins;

  @override
  State<CycaniLoginPage> createState() => _CycaniLoginPageState();
}

class _CycaniLoginPageState extends State<CycaniLoginPage> {
  WindowsInAppBrowser? _browser;
  Timer? _poll;
  bool _ready = false;
  bool _opening = false;
  bool _reading = false;
  bool _busy = false;
  bool _closing = false;
  bool _saved = false;
  DateTime _nextCheck = DateTime.fromMillisecondsSinceEpoch(0);
  String _message = '正在打开次元城登录窗口…';
  String _url = CycaniWindowsSession.loginUrl;

  @override
  void initState() {
    super.initState();
    unawaited(_openLogin());
  }

  Future<void> _openLogin() async {
    if (_opening || _busy || _closing) return;
    setState(() {
      _opening = true;
      _saved = false;
      _nextCheck = DateTime.fromMillisecondsSinceEpoch(0);
      _message = '正在打开次元城登录窗口…';
    });
    try {
      final existing = _browser;
      if (existing != null && _ready) {
        await existing.webViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri(CycaniWindowsSession.loginUrl)),
        );
        await existing.show();
        if (mounted) setState(() => _opening = false);
        return;
      }
      final environment = await CycaniWindowsSession.configureEnvironment();
      if (_closing) return;
      final browser = WindowsInAppBrowser(
        WindowsInAppBrowserCreationParams(webViewEnvironment: environment),
      );
      _browser = browser;
      browser.eventHandler = _CycaniBrowserEvents(
        created: () {
          if (_closing) {
            unawaited(browser.close().catchError((Object _) {}));
            return;
          }
          _poll?.cancel();
          _poll = Timer.periodic(const Duration(seconds: 1), (_) {
            unawaited(_save(automatic: true));
          });
          if (mounted) setState(() {
            _ready = true;
            _opening = false;
            _message = '请在弹出的次元城窗口登录，选择保持登录。确认成功后会自动返回并启用规则。';
          });
        },
        closed: () {
          if (!identical(_browser, browser)) return;
          _poll?.cancel();
          _browser = null;
          if (mounted) setState(() {
            _ready = false;
            _opening = false;
            if (!_saved) {
              _message = '登录窗口已关闭。已选择保持登录时，可以点击检查登录；也可重新打开登录窗口。';
            }
          });
        },
        navigated: (url) {
          if (_closing) return;
          final uri = Uri.tryParse(url?.toString() ?? '');
          if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http') &&
              uri.hasAuthority && mounted) {
            setState(() => _url = uri.origin + uri.path);
          }
          unawaited(_save(automatic: true));
        },
      );
      await browser.openUrlRequest(
        urlRequest: URLRequest(url: WebUri(CycaniWindowsSession.loginUrl)),
        settings: InAppBrowserClassSettings(
          browserSettings: InAppBrowserSettings(
            toolbarTopFixedTitle: '次元城账号 — 登录成功后自动保存',
          ),
        ),
      );
      if (_closing) await browser.close();
    } catch (_) {
      _poll?.cancel();
      final browser = _browser;
      _browser = null;
      if (browser != null) {
        unawaited(browser.close().catchError((Object _) {}));
      }
      if (mounted) setState(() {
        _ready = false;
        _opening = false;
        _message = '无法打开登录窗口，请检查网络及 Microsoft Edge WebView2 Runtime，然后重试。';
      });
    }
  }

  Future<void> _save({bool automatic = false}) async {
    if (_closing || _busy || _reading || _saved) return;
    if (automatic && (!_ready || DateTime.now().isBefore(_nextCheck))) return;
    _reading = true;
    final session = CycaniWindowsSession.instance;
    try {
      final controller = _browser?.webViewController;
      if (controller != null) {
        final result = await controller.evaluateJavascript(
          source: CycaniWindowsSession.readScript,
        );
        if (result is! String || !session.accept(result)) {
          if (!automatic && mounted) setState(() {
            _message = '尚未检测到有效登录，请先在次元城窗口完成登录。';
          });
          return;
        }
      } else {
        if (automatic) return;
        if (await session.token() == null) {
          if (mounted) setState(() => _message = '尚未检测到保存的登录，请先打开登录窗口。');
          return;
        }
      }
      if (_closing) return;
      setState(() => _busy = true);
      await CycaniApi.instance.validateSession();
      if (_closing) return;
      await widget.plugins.updatePlugin(buildCycaniRule());
      _saved = true;
      _poll?.cancel();
      if (mounted) setState(() {
        _message = session.persistent
            ? '已登录并启用次元城规则。下次启动会恢复网站保存的登录状态。'
            : '已登录并启用次元城规则。本次为临时登录，关闭软件后需要重新登录。';
      });
      final browser = _browser;
      if (browser != null) {
        await browser.close().catchError((Object _) {});
      }
    } on CycaniLoginRequired {
      session.invalidate();
      _nextCheck = DateTime.now().add(const Duration(seconds: 15));
      if (mounted) setState(() => _message = '登录状态已失效，请在次元城窗口重新登录。');
    } catch (_) {
      _nextCheck = DateTime.now().add(const Duration(seconds: 15));
      if (mounted) setState(() => _message = '无法确认登录或保存规则，请检查网络后重试。');
    } finally {
      _reading = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    if (_busy || _reading || _opening) return;
    setState(() => _busy = true);
    _poll?.cancel();
    final session = CycaniWindowsSession.instance;
    try {
      final controller = _browser?.webViewController;
      if (controller != null) {
        final cleared = await controller.evaluateJavascript(
          source: CycaniWindowsSession.clearScript,
        );
        if (cleared != true) {
          throw StateError('请先返回次元城网站，再清除登录状态');
        }
        session.invalidate();
      } else {
        await session.clearSavedSession();
      }
      _saved = false;
      if (mounted) setState(() => _message = '已清除本机保存的次元城登录状态。');
    } catch (_) {
      if (mounted) setState(() => _message = '清除失败，请打开次元城登录窗口后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _closing = true;
    _poll?.cancel();
    final browser = _browser;
    if (browser != null) {
      unawaited(browser.close().catchError((Object _) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('次元城账号')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(_message),
        const SizedBox(height: 12),
        Text(_url, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 20),
        Wrap(spacing: 12, runSpacing: 8, children: [
          FilledButton.icon(
            onPressed: !_opening && !_busy ? _openLogin : null,
            icon: const Icon(Icons.login),
            label: Text(_opening ? '正在打开…' : '打开次元城登录窗口'),
          ),
          OutlinedButton.icon(
            onPressed: !_opening && !_busy && !_saved ? () => _save() : null,
            icon: const Icon(Icons.check_circle_outline),
            label: Text(_busy ? '正在处理…' : '检查登录并启用次元城'),
          ),
          TextButton(
            onPressed: !_opening && !_busy ? _logout : null,
            child: const Text('清除登录状态'),
          ),
        ]),
        const SizedBox(height: 24),
        const Text('在次元城窗口输入账号和密码，完成网站要求的验证。登录成功后稍等片刻，窗口会自动关闭，规则会自动启用。'),
      ]),
    ),
  );
}

class _CycaniBrowserEvents extends PlatformInAppBrowserEvents {
  _CycaniBrowserEvents({
    required this.created, required this.closed, required this.navigated,
  });
  final void Function() created;
  final void Function() closed;
  final void Function(WebUri?) navigated;

  @override
  void onBrowserCreated() => created();
  @override
  void onExit() => closed();
  @override
  void onLoadStop(WebUri? url) => navigated(url);
  @override
  void onUpdateVisitedHistory(WebUri? url, bool? isReload) => navigated(url);
}
