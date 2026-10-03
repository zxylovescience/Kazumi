import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/services/plugin/cycani_windows_session.dart';

class CycaniLoginRequired implements Exception {
  const CycaniLoginRequired();
  @override
  String toString() => '请到规则管理 → 次元城账号中登录或重新登录';
}

/// First-party API adapter. Session data never enters exported rule JSON,
/// shared Dio interceptors, CDN requests, or redirect targets.
class CycaniApi {
  CycaniApi({required this.dio, required this.tokenProvider});
  final Dio dio;
  final Future<String?> Function() tokenProvider;
  static final instance = CycaniApi(
    dio: Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 25),
      followRedirects: false,
      headers: {
        'Accept': 'application/json',
        'X-App-Name': 'cyc_web',
        'X-App-Version': 'cycweb',
        'X-Time-Zone': 'Asia/Shanghai',
        'Referer': CycaniWindowsSession.home,
      },
    )),
    tokenProvider: CycaniWindowsSession.instance.token,
  );

  static bool _firstParty(Uri uri) =>
      uri.scheme == 'https' && uri.host == 'www.cycani.org' &&
      uri.port == 443 && uri.userInfo.isEmpty;

  static bool handlesRule(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && _firstParty(uri) &&
        (uri.path == '/_kazumi/cycani/search' ||
         uri.path == '/_kazumi/cycani/chapters');
  }

  static bool handlesPlayback(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && _firstParty(uri) &&
        RegExp(r'^/api/v2/sections/[1-9][0-9]*/play-url$').hasMatch(uri.path) &&
        !uri.hasQuery && !uri.hasFragment;
  }

  Future<Map<String, dynamic>> _get(String path, {
    Map<String, dynamic> query = const {},
    String? token,
    CancelToken? cancelToken,
  }) async {
    // Relative paths are constructed here, never taken from a rule or redirect.
    try {
      final response = await dio.get<Map<String, dynamic>>(
        'https://www.cycani.org/api$path',
        queryParameters: query,
        options: Options(followRedirects: false, headers: {
          if (token != null)
            'Authorization': token.startsWith('Bearer ') ? token : 'Bearer $token',
        }),
        cancelToken: cancelToken,
      );
      final result = response.data;
      if (result == null || result['code'] != 0) {
        if (result?['code'] == 401) throw const CycaniLoginRequired();
        throw StateError('次元城暂时无法返回数据，请稍后再试');
      }
      return result;
    } on DioException catch (error) {
      // Do not propagate Dio RequestOptions, which may contain Authorization.
      if (CancelToken.isCancel(error)) rethrow;
      if (error.response?.statusCode == 401) {
        throw const CycaniLoginRequired();
      }
      throw StateError('次元城请求失败，请检查网络或网站状态');
    }
  }

  Future<String> requestRule(String url, Map<String, dynamic> query,
      {CancelToken? cancelToken}) async {
    if (!handlesRule(url)) throw ArgumentError('无效的次元城规则地址');
    final uri = Uri.parse(url);
    final parameters = {...uri.queryParameters, ...query};
    if (uri.path.endsWith('/search')) {
      return jsonEncode(await _get('/videos/search', query: {
        'q': parameters['q']?.toString() ?? '',
        'page': 1, 'page_size': 24,
      }, cancelToken: cancelToken));
    }
    final id = parameters['id']?.toString() ?? '';
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(id)) {
      throw ArgumentError('无效的番剧编号');
    }
    final episodes = <Map<String, dynamic>>[];
    for (var page = 1; page <= 100; page++) {
      final result = await _get('/videos/$id/sections', query: {
        'player_code': 'cychub', 'page': page, 'page_size': 100,
      }, cancelToken: cancelToken);
      final data = result['data'] as Map<String, dynamic>;
      final list = data['list'] as List;
      for (final value in list) {
        final episode = Map<String, dynamic>.from(value as Map);
        final section = episode['id'].toString();
        if (!RegExp(r'^[1-9][0-9]*$').hasMatch(section)) continue;
        episode['kazumi_url'] =
            'https://www.cycani.org/api/v2/sections/$section/play-url';
        episodes.add(episode);
      }
      final total = (data['pager'] as Map?)?['total'] as int?;
      if (list.isEmpty || (total != null && page * 100 >= total) ||
          (total == null && list.length < 100)) {
        return jsonEncode({'code': 0, 'data': {'list': episodes}});
      }
    }
    throw StateError('次元城剧集分页异常，请稍后重试');
  }

  Future<String> resolvePlayback(String entry) async {
    if (!handlesPlayback(entry)) throw ArgumentError('无效的次元城播放地址');
    final token = await tokenProvider();
    if (token == null || token.isEmpty) throw const CycaniLoginRequired();
    final path = Uri.parse(entry).path.substring('/api'.length);
    final result = await _get(path, token: token);
    final value = (result['data'] as Map?)?['url'];
    final media = value is String ? Uri.tryParse(value) : null;
    if (media == null || (media.scheme != 'https' && media.scheme != 'http') ||
        media.host.isEmpty || media.userInfo.isNotEmpty) {
      throw StateError('次元城没有返回可用的播放地址');
    }
    return media.toString();
  }

  Future<void> validateSession() async {
    final token = await tokenProvider();
    if (token == null || token.isEmpty) throw const CycaniLoginRequired();
    await _get('/user/me', token: token);
  }
}
