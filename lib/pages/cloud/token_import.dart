import 'dart:convert';

/// Only drivers compiled into the bundled OpenList core are exposed.
/// The pinned core registers quark_uc / onedrive (plus 115/123/baidu/google),
/// but the app intentionally offers just these two to users.
const openListSupportedDrivers = <String>{
  'Quark',
  'Onedrive',
};

const openListLoginDrivers = <String, String>{
  'Onedrive': 'onedrive_pr',
};

Uri openListLoginUri(
  String driver, {
  String clientId = '',
  String clientSecret = '',
}) {
  final loginDriver = openListLoginDrivers[driver];
  if (loginDriver == null) {
    throw ArgumentError.value(driver, 'driver', 'Unsupported login provider');
  }
  return Uri.https(
    'api.oplist.org',
    '/${loginDriver.split('_').first}/requests',
    {
      'driver_txt': loginDriver,
      'server_use': 'true',
      'client_uid': '',
      'client_key': '',
    },
  );
}

Map<String, dynamic>? parseOpenListLoginCallback(
  String url, {
  required String driver,
  String clientId = '',
  String clientSecret = '',
}) {
  final uri = Uri.tryParse(url);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'api.oplist.org' ||
      uri.port != 443 ||
      uri.path != '/' ||
      uri.fragment.isEmpty) {
    return null;
  }
  final value = parseOpenListAuthorization(url, driver: driver);
  final error = value.remove('message_err');
  if (error != null && '$error'.isNotEmpty) {
    throw FormatException('$error');
  }
  if (value['driver_txt'] != openListLoginDrivers[driver]) {
    throw const FormatException(
      'Authorization does not match the selected provider',
    );
  }
  final refreshToken = value['refresh_token'];
  if (refreshToken is! String || refreshToken.trim().isEmpty) {
    throw const FormatException('Refresh Token is required');
  }
  value['server_use'] = true;
  value['client_id'] = '';
  value['client_secret'] = '';
  value['use_online_api'] = true;
  value['api_url_address'] = Uri.https(
    'api.oplist.org',
    '/${openListLoginDrivers[driver]!.split('_').first}/renewapi',
  ).toString();
  if (driver == 'Onedrive') value['region'] = 'global';
  return value;
}

Map<String, dynamic> parseOpenListAuthorization(
  String text, {
  required String driver,
}) {
  return normalizeOpenListAuthorization(
    _decodePayload(text.trim()),
    driver: driver,
  );
}

Map<String, dynamic> buildOpenListAuthorization({
  required String driver,
  required String accessToken,
  required String refreshToken,
  String clientId = '',
  String clientSecret = '',
  String cookie = '',
  Map<String, dynamic> authorization = const {},
}) {
  if (driver == 'Quark') {
    return normalizeOpenListAuthorization({
      ...authorization,
      'cookie': cookie.trim(),
    }, driver: driver);
  }
  final value = <String, dynamic>{...authorization}
    ..remove('AccessToken')
    ..remove('RefreshToken');
  return normalizeOpenListAuthorization({
    ...value,
    'access_token': accessToken.trim(),
    'refresh_token': refreshToken.trim(),
  }, driver: driver);
}

/// Maps api.oplist.org callback fields and saved authorization to OpenList's
/// actual driver addition field names, with a single canonical token per key.
Map<String, dynamic> normalizeOpenListAuthorization(
  Map<String, dynamic> source, {
  required String driver,
}) {
  final value = <String, dynamic>{...source};
  if (driver == 'Quark') {
    _move(value, 'Cookie', 'cookie');
    return value;
  }
  if (!openListSupportedDrivers.contains(driver)) {
    // Unknown accounts from an older build must not crash startup; they are
    // simply no longer offered in the UI.
    return value;
  }
  final callbackDriver = value.remove('driver') ?? value['driver_txt'];
  if (callbackDriver is String && callbackDriver.isNotEmpty) {
    value['driver_txt'] = callbackDriver;
  }
  _move(value, 'AccessToken', 'access_token');
  _move(value, 'RefreshToken', 'refresh_token');
  _move(value, 'ClientID', 'client_id');
  _move(value, 'ClientSecret', 'client_secret');
  _move(value, 'client_uid', 'client_id');
  _move(value, 'client_key', 'client_secret');
  value['use_online_api'] ??= true;
  return value;
}

Map<String, dynamic> _decodePayload(String value) {
  final hash = value.indexOf('#');
  if (hash >= 0) {
    value = value.substring(hash + 1);
  }
  value = Uri.decodeFull(value);
  try {
    final result = jsonDecode(value);
    if (result is Map) return result.map((key, item) => MapEntry('$key', item));
  } catch (_) {}
  try {
    final result = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(value))),
    );
    if (result is Map) return result.map((key, item) => MapEntry('$key', item));
  } catch (_) {}
  throw const FormatException('Invalid authorization response');
}

void _move(Map<String, dynamic> value, String source, String destination) {
  if (source == destination) {
    return;
  }
  final token = value.remove(source);
  if (token != null &&
      token != '' &&
      (value[destination] == null || value[destination] == '')) {
    value[destination] = token;
  }
}
