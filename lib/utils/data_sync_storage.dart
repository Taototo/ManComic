import 'dart:io';

import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/webdav_url.dart' show normalizeWebdavUrl;
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cloud_storage/remote_storage.dart';
import 'package:webdav_client/webdav_client.dart' hide File;

/// 应用数据同步（.venera 文件）的存放位置。
///
/// 同步本身只关心「列文件、写文件、读文件、删文件」四件事，具体落在坚果云
/// 还是夸克由实现决定——这样两个网盘可以共用同一套版本比较、清理和导入逻辑。
abstract class DataSyncStorage {
  bool get isConfigured;

  Future<List<String>> list();

  Future<void> write(String name, File file);

  Future<void> read(String name, String localPath);

  Future<void> delete(String name);

  Future<void> close();
}

/// 同步方式，存在 implicitData 里（账号 id 是本机的，不能跟着设置同步走）。
const syncProviderKey = 'syncProvider';
const quarkSyncAccountKey = 'quarkSyncAccountId';
const quarkSyncDirectoryKey = 'quarkSyncDirectory';

const syncProviderWebdav = 'webdav';
const syncProviderQuark = 'quark';
const syncProviderOff = 'off';

/// 当前生效的同步方式；null 表示没配置。
///
/// 老版本只有坚果云：没有显式写入方式时，按「有没有填过 WebDAV」推断，
/// 已配置的用户升级后不需要重新设置。
String? resolveSyncProvider() => syncProviderFromConfig(
  stored: appdata.implicitData[syncProviderKey] as String?,
  webdavConfigured: _webdavConfig() != null,
);

/// 纯函数版本，便于单测：`stored` 为空时按是否已配置 WebDAV 回退。
String? syncProviderFromConfig({
  required String? stored,
  required bool webdavConfigured,
}) {
  if (stored != null && stored.isNotEmpty) {
    return stored == syncProviderOff ? null : stored;
  }
  return webdavConfigured ? syncProviderWebdav : null;
}

List<String>? _webdavConfig() {
  final config = appdata.settings['webdav'];
  if (config is! List ||
      config.length != 3 ||
      config.whereType<String>().length != 3) {
    return null;
  }
  final values = List<String>.from(config);
  if (values[0].trim().isEmpty) return null;
  return values;
}

/// 当前同步目标是否已经配置完整（不发起任何网络请求）。
bool get hasSyncDestination {
  switch (resolveSyncProvider()) {
    case syncProviderWebdav:
      return _webdavConfig() != null;
    case syncProviderQuark:
      final accountId = appdata.implicitData[quarkSyncAccountKey];
      final directory = appdata.implicitData[quarkSyncDirectoryKey];
      if (accountId is! String || accountId.isEmpty) return false;
      if (directory is! String || directory.trim().isEmpty) return false;
      final account = RemoteStorageAccounts.instance.account(accountId);
      return account != null && account.backend == StorageBackend.openlist;
  }
  return false;
}

/// 按当前设置构造同步存储；未配置时返回 null。
DataSyncStorage? createDataSyncStorage() {
  switch (resolveSyncProvider()) {
    case syncProviderWebdav:
      final config = _webdavConfig();
      if (config == null) return null;
      return WebDavDataSyncStorage(config[0], config[1], config[2]);
    case syncProviderQuark:
      final accountId = appdata.implicitData[quarkSyncAccountKey];
      final directory = appdata.implicitData[quarkSyncDirectoryKey];
      if (accountId is! String || accountId.isEmpty) return null;
      if (directory is! String || directory.trim().isEmpty) return null;
      return QuarkDataSyncStorage(
        accountId: accountId,
        directory: normalizeRemoteDirectory(directory),
      );
  }
  return null;
}

class WebDavDataSyncStorage implements DataSyncStorage {
  WebDavDataSyncStorage(this.url, this.user, this.password);

  final String url;
  final String user;
  final String password;

  Client? _client;

  Client get _webdav => _client ??= newClient(
    normalizeWebdavUrl(url),
    user: user,
    password: password,
    adapter: RHttpAdapter(),
  );

  @override
  bool get isConfigured => url.trim().isNotEmpty;

  @override
  Future<List<String>> list() async {
    final files = await _webdav.readDir('/');
    return [
      for (final file in files)
        if (file.name != null && file.isDir != true) file.name!,
    ];
  }

  @override
  Future<void> write(String name, File file) async =>
      _webdav.write(name, await file.readAsBytes());

  @override
  Future<void> read(String name, String localPath) =>
      _webdav.read2File(name, localPath);

  @override
  Future<void> delete(String name) => _webdav.remove(name);

  @override
  Future<void> close() async {
    _client?.c.close(force: true);
    _client = null;
  }
}

/// 夸克网盘：复用「网盘账号」里的夸克授权，走内核的文件读写。
///
/// `.venera` 不在内核的 MIME 表里，上传时内核会报 `format_type is null`，
/// `OpenListFileStore.upload` 会自动改走应用侧的夸克分片上传，这里不用特判。
class QuarkDataSyncStorage implements DataSyncStorage {
  QuarkDataSyncStorage({required this.accountId, required this.directory});

  final String accountId;
  final String directory;

  RemoteFileStore? _store;

  RemoteStorageAccounts get _accounts => RemoteStorageAccounts.instance;

  RemoteFileStore get _fileStore => _store ??= _accounts.storeFor(accountId);

  String get _normalizedDirectory => normalizeRemoteDirectory(directory);

  @override
  bool get isConfigured {
    final account = _accounts.account(accountId);
    return account != null && account.backend == StorageBackend.openlist;
  }

  @override
  Future<List<String>> list() async {
    final entries = await _fileStore.list(_normalizedDirectory, refresh: true);
    return [
      for (final entry in entries)
        if (!entry.isDirectory) entry.name,
    ];
  }

  @override
  Future<void> write(String name, File file) async {
    try {
      await _fileStore.mkdir(_normalizedDirectory);
    } catch (_) {
      // 目录已存在时部分驱动会报错；真的建不出来，后面的上传会给出明确失败。
    }
    await _fileStore.upload(file.path, '$_normalizedDirectory$name');
  }

  @override
  Future<void> read(String name, String localPath) =>
      _fileStore.download('$_normalizedDirectory$name', localPath);

  @override
  Future<void> delete(String name) =>
      _fileStore.delete('$_normalizedDirectory$name');

  @override
  Future<void> close() async {
    final store = _store;
    _store = null;
    if (store != null) _accounts.release(store);
  }
}
