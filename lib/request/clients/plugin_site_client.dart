import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:kazumi/utils/http_headers.dart';
import 'package:kazumi/services/plugin/cycani_api.dart';

class PluginSiteClient {
  PluginSiteClient._();

  static final PluginSiteClient instance = PluginSiteClient._();

  Future<String> requestText(
    String url, {
    required String method,
    Map<String, dynamic> headers = const {},
    Map<String, dynamic> queryParameters = const {},
    Object? data,
    CancelToken? cancelToken,
  }) async {
    if (CycaniApi.handlesRule(url)) {
      if (method.toUpperCase() != 'GET') {
        throw ArgumentError('次元城内置规则只支持 GET');
      }
      return CycaniApi.instance.requestRule(url, queryParameters,
          cancelToken: cancelToken);
    }
    try {
      final response = await DioFactory.pluginDio.request<String>(
        url,
        queryParameters: queryParameters,
        data: data,
        options: Options(
          method: method,
          responseType: ResponseType.plain,
          headers: _headers(headers),
        ),
        cancelToken: cancelToken,
      );
      return response.data ?? '';
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Map<String, dynamic> _headers(Map<String, dynamic> headers) {
    return {
      'user-agent': getRandomUA(),
      'Accept-Language': getRandomAcceptedLanguage(),
      'Connection': 'keep-alive',
      ...headers,
    };
  }
}
