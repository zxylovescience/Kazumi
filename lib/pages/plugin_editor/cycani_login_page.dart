import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/plugin/cycani_api.dart';
import 'package:kazumi/services/plugin/cycani_rule.dart';
import 'package:kazumi/services/plugin/cycani_windows_session.dart';

/// The account and verification UI belong to the website. Kazumi only reads
/// that website's saved session after the user chooses to enable the source.
class CycaniLoginPage extends StatefulWidget {
  const CycaniLoginPage({super.key, required this.plugins});
  final PluginsController plugins;
  @override
  State<CycaniLoginPage> createState() => _CycaniLoginPageState();
}

class _CycaniLoginPageState extends State<CycaniLoginPage> {
  final _webview = WebviewController();
  StreamSubscription<String>? _urlSubscription;
  bool _initialized = false;
  bool _ready = false;
  bool _busy = false;
  bool _closing = false;
  String _message = '正在打开次元城登录页面…';
  String _url = CycaniWindowsSession.home;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await CycaniWindowsSession.configureEnvironment();
      if (_closing) return;
      await _webview.initialize();
      _initialized = true;
      if (_closing) {
        await _webview.dispose();
        return;
      }
      await _webview.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      _urlSubscription = _webview.url.listen((url) {
        if (mounted) setState(() => _url = url);
      });
      await _webview.loadUrl(CycaniWindowsSession.home);
      if (mounted) setState(() {
        _ready = true;
        _message = '在下方网站中登录。需要下次自动登录时，请选择网站的保持登录选项。';
      });
    } catch (_) {
      if (mounted) setState(() {
        _message = '无法打开登录页面，请检查网络及 Microsoft Edge WebView2 Runtime。';
      });
    }
  }

  Future<void> _save() async {
    if (!_ready || _busy) return;
    setState(() => _busy = true);
    final session = CycaniWindowsSession.instance;
    try {
      if (!session.accept(await _webview.executeScript(
          CycaniWindowsSession.readScript))) {
        if (mounted) setState(() {
          _message = '尚未检测到有效登录，请先在下方次元城网站完成登录。';
        });
        return;
      }
      // Storage presence alone is not proof that the server accepts a session.
      await CycaniApi.instance.validateSession();
      await widget.plugins.updatePlugin(buildCycaniRule());
      if (mounted) setState(() {
        _message = session.persistent
            ? '已登录并启用次元城规则。下次启动会恢复网站保存的登录状态。'
            : '已登录并启用次元城规则。本次为临时登录，关闭软件后需要重新登录。';
      });
    } on CycaniLoginRequired {
      session.invalidate();
      if (mounted) setState(() => _message = '登录状态已失效，请在网站中重新登录。');
    } catch (_) {
      if (mounted) setState(() {
        _message = '无法确认登录或保存规则，请检查网络后重试。';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    if (!_ready || _busy) return;
    setState(() => _busy = true);
    try {
      final cleared = await _webview.executeScript(
          CycaniWindowsSession.clearScript);
      if (cleared != true) {
        if (mounted) setState(() {
          _message = '请先返回次元城网站，再清除登录状态。';
        });
        return;
      }
      CycaniWindowsSession.instance.invalidate();
      if (mounted) setState(() => _message = '已清除本机保存的次元城登录状态。');
    } catch (_) {
      if (mounted) setState(() => _message = '清除失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _closing = true;
    unawaited(_urlSubscription?.cancel());
    if (_initialized) unawaited(_webview.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('次元城账号')),
    body: Column(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_message),
          const SizedBox(height: 8),
          Text(_url, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 8, children: [
            FilledButton.icon(onPressed: _ready && !_busy ? _save : null,
              icon: const Icon(Icons.check_circle_outline),
              label: Text(_busy ? '正在处理…' : '保存登录并启用次元城')),
            TextButton(onPressed: _ready && !_busy
                ? () => _webview.loadUrl(CycaniWindowsSession.home) : null,
              child: const Text('返回次元城首页')),
            TextButton(onPressed: _ready && !_busy ? _logout : null,
              child: const Text('清除登录状态')),
          ]),
        ]),
      ),
      const Divider(height: 1),
      Expanded(child: _ready ? Webview(_webview)
          : const Center(child: Text('登录页面尚未就绪'))),
    ]),
  );
}
