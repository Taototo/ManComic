import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app_page_route.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/cloud_storage/remote_storage.dart';
import 'package:venera/utils/data_sync_storage.dart';

import 'token_import.dart';
import 'openlist_login.dart';
import 'quark_login.dart';

enum StorageAccountPurpose { library, sync, archive }

/// 把内部驱动名转成中文显示名。
String _providerLabel(String driver) => switch (driver) {
  'Quark' => '夸克网盘',
  'WebDAV' => 'WebDAV',
  _ => driver,
};

/// 账号对应的显示名（夸克 / WebDAV），供备份、库列表等页面复用。
String storageProviderLabel(StorageAccount? account) {
  if (account == null) return '账号不可用';
  if (account.backend == StorageBackend.webdav) return 'WebDAV';
  return switch (account.driver) {
    'Quark' || 'QuarkOpen' => '夸克网盘',
    final driver => driver.isEmpty ? '网盘' : driver,
  };
}

Future<StorageAccount?> showStorageAccountEditor(
  BuildContext context, {
  StorageAccount? initial,
  RemoteStorageAccounts? accounts,
  bool useRootNavigator = true,
  ValueChanged<StorageAccount>? onSaved,
}) async {
  final storage = accounts ?? RemoteStorageAccounts.instance;
  final page = initial == null
      ? _StorageProviderPage(accounts: storage)
      : _StorageAccountPage(
          initial: initial,
          accounts: storage,
          driver: initial.backend == StorageBackend.webdav
              ? 'WebDAV'
              : initial.driver == 'QuarkOpen'
              ? 'Quark'
              : initial.driver,
        );
  final result = useRootNavigator
      ? await Navigator.of(
          context,
          rootNavigator: true,
        ).push<StorageAccount>(AppPageRoute(builder: (_) => page))
      : await context.to<StorageAccount>(() => page);
  if (result == null) return null;
  StorageAccount saved;
  try {
    saved = await storage.save(result);
  } catch (error) {
    // 重名、驱动冲突或原生写入异常都在这里转成可展示的提示，
    // 避免异常一路冒泡导致界面静默无反应。
    throw FormatException(
      error is ArgumentError
          ? '保存账号失败：${error.message}'
          : '保存账号失败：${describeCloudError(error)}',
    );
  }
  if (saved.statusMessage != null) return saved;
  // 账号已经落盘，先让调用方刷新列表——后面的连接测试即使很慢，
  // 用户也能立刻看到账号出现，而不是盯着进度条猜发生了什么。
  onSaved?.call(saved);
  final store = storage.storeFor(saved.id);
  try {
    await _testWithRetry(store);
    saved = saved.copyWith(
      status: StorageAuthorizationStatus.valid,
      clearStatusMessage: true,
    );
  } on RemoteStorageException catch (error) {
    saved = saved.copyWith(
      status: error.isAuthorizationFailure
          ? StorageAuthorizationStatus.invalid
          : StorageAuthorizationStatus.unknown,
      statusMessage: await _withKernelLog(
        storage,
        _cleanCoreMessage(error.message),
      ),
    );
  } catch (error) {
    // 原生初始化/网络探测可能抛出非 RemoteStorageException 的异常。
    // 这里必须兜住，否则调用方的 setState 与提示都执行不到，看起来「什么都没发生」。
    saved = saved.copyWith(
      status: StorageAuthorizationStatus.unknown,
      statusMessage: await _withKernelLog(
        storage,
        '连接测试失败：${describeCloudError(error)}',
      ),
    );
  } finally {
    storage.release(store);
  }
  try {
    await storage.updateStatus(saved);
  } catch (_) {
    // 状态回写失败不影响账号本身已保存的事实。
  }
  return saved;
}

class StorageAccountsPage extends StatefulWidget {
  StorageAccountsPage({
    super.key,
    RemoteStorageAccounts? accounts,
    this.selectPurposeOnAdd = false,
  }) : accounts = accounts ?? RemoteStorageAccounts.instance;
  final RemoteStorageAccounts accounts;
  final bool selectPurposeOnAdd;
  @override
  State<StorageAccountsPage> createState() => _StorageAccountsPageState();
}

class _StorageAccountsPageState extends State<StorageAccountsPage> {
  /// 添加/保存账号期间为 true，用于在列表页显示进度并防止重复提交。
  bool _busy = false;

  String _usage(StorageAccount account) {
    final libraries = widget.accounts.libraries
        .where((library) => library.accountId == account.id)
        .length;
    final savedBackups = switch (appdata.settings[backupDestinationsSetting]) {
      final List items =>
        items
            .where((item) => item is Map && item['accountId'] == account.id)
            .length,
      _ => 0,
    };
    final activeBackup =
        appdata.settings['backupRemoteLocation'] is Map &&
        appdata.settings['backupRemoteLocation']['accountId'] == account.id;
    final quarkSyncAccount = appdata.implicitData[quarkSyncAccountKey];
    final uses = <String>[
      if (libraries > 0) '$libraries 个漫画库',
      if (appdata.settings['syncRemoteLocation'] is Map &&
          appdata.settings['syncRemoteLocation']['accountId'] == account.id)
        '应用数据同步',
      if (resolveSyncProvider() == syncProviderQuark &&
          quarkSyncAccount == account.id)
        '应用数据同步',
      if (savedBackups > 0)
        activeBackup ? '漫画备份（当前）' : '漫画备份（$savedBackups 个位置）'
      else if (activeBackup)
        '漫画备份',
    ];
    return uses.isEmpty ? '未使用' : uses.join(' · ');
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _test(StorageAccount account) async {
    var result = account;
    RemoteFileStore? store;
    try {
      store = widget.accounts.storeFor(account.id);
      await _testWithRetry(store);
      result = account.copyWith(
        status: StorageAuthorizationStatus.valid,
        clearStatusMessage: true,
      );
    } on RemoteStorageException catch (error) {
      result = account.copyWith(
        status: error.isAuthorizationFailure
            ? StorageAuthorizationStatus.invalid
            : StorageAuthorizationStatus.unknown,
        statusMessage: await _withKernelLog(
          widget.accounts,
          _cleanCoreMessage(error.message),
        ),
      );
    } catch (error) {
      result = account.copyWith(
        status: StorageAuthorizationStatus.unknown,
        statusMessage: await _withKernelLog(
          widget.accounts,
          '连接测试失败：${describeCloudError(error)}',
        ),
      );
    } finally {
      if (store != null) widget.accounts.release(store);
    }
    try {
      await widget.accounts.updateStatus(result);
    } catch (_) {}
    if (mounted) setState(() {});
    _notify(
      result.status == StorageAuthorizationStatus.valid
          ? '“${result.name}”连接正常'
          : '“${result.name}”连接失败：${result.statusMessage ?? "未知错误"}',
    );
  }

  Future<void> _edit([StorageAccount? initial]) async {
    if (_busy) return;
    setState(() => _busy = true);
    StorageAccount? saved;
    Object? error;
    try {
      saved = await showStorageAccountEditor(
        context,
        initial: initial,
        accounts: widget.accounts,
        useRootNavigator: false,
        onSaved: (account) {
          // 账号已落盘：先把列表刷出来，再慢慢验证连接。
          if (mounted) setState(() {});
          _notify('账号“${account.name}”已保存，正在验证连接…');
        },
      );
    } catch (e) {
      error = e;
    } finally {
      // 成功、失败或中途抛异常都必须刷新：账号可能已经写进设置，
      // 只是后续的原生注册/连接测试失败了，不刷新就会看起来「什么都没发生」。
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (error != null) {
      _notify(error is FormatException ? error.message : '添加账号失败：$error');
      return;
    }
    if (saved == null) return;
    _notify(
      saved.status == StorageAuthorizationStatus.valid
          ? '账号“${saved.name}”已添加并连接成功'
          : '账号“${saved.name}”已保存，但连接验证未通过：${saved.statusMessage ?? "请检查授权信息"}',
    );
    if (initial != null ||
        saved.status != StorageAuthorizationStatus.valid ||
        !widget.selectPurposeOnAdd) {
      return;
    }
    final purpose = await showDialog<StorageAccountPurpose>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('此账号用于'),
        children: [
          for (final (value, label) in [
            (StorageAccountPurpose.library, '在线漫画库'),
            (StorageAccountPurpose.sync, '应用数据同步'),
            (StorageAccountPurpose.archive, '漫画备份'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, value),
              child: Text(label),
            ),
        ],
      ),
    );
    if (mounted && purpose != null) Navigator.pop(context, (saved, purpose));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: Appbar(title: Text('网盘账号')),
    floatingActionButton: FloatingActionButton(
      onPressed: _busy ? null : _edit,
      child: const Icon(Icons.add),
    ),
    body: Column(
      children: [
        if (_busy) const LinearProgressIndicator(),
        Expanded(
          child: ListView(
            children: [
              for (final account in widget.accounts.accounts)
                ListTile(
                  title: Text(account.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.statusMessage ??
                            '${storageProviderLabel(account)} · ${switch (account.status) {
                              StorageAuthorizationStatus.valid => '已连接',
                              StorageAuthorizationStatus.invalid => '授权失效',
                              StorageAuthorizationStatus.unknown => '连接未验证',
                            }}',
                      ),
                      Text(_usage(account)),
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await widget.accounts.remove(account.id);
                      if (mounted) setState(() {});
                    },
                  ),
                  leading: IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: '测试连接',
                    onPressed: () => _test(account),
                  ),
                  onTap: () => _edit(account),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _StorageProviderPage extends StatelessWidget {
  const _StorageProviderPage({required this.accounts});

  final RemoteStorageAccounts accounts;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: Appbar(title: Text('添加网盘账号')),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            children: [
              for (final driver in [...openListSupportedDrivers, 'WebDAV'])
                ListTile(
                  title: Text(_providerLabel(driver)),
                  subtitle: Text(switch (driver) {
                    'WebDAV' => '通过服务器地址、账号和密码连接（坚果云等）。',
                    _ => '登录后自动保存授权。',
                  }),
                  trailing: const Icon(Icons.arrow_right),
                  onTap: () async {
                    final result = await context.to<StorageAccount>(
                      () => _StorageAccountPage(
                        accounts: accounts,
                        driver: driver,
                      ),
                    );
                    if (context.mounted && result != null) {
                      Navigator.pop(context, result);
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _StorageAccountPage extends StatefulWidget {
  const _StorageAccountPage({
    this.initial,
    required this.accounts,
    required this.driver,
  });
  final StorageAccount? initial;
  final RemoteStorageAccounts accounts;
  final String driver;
  @override
  State<_StorageAccountPage> createState() => _StorageAccountPageState();
}

class _StorageAccountPageState extends State<_StorageAccountPage> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?.name,
  );
  late Map<String, dynamic> _authorization =
      widget.initial?.driver == 'QuarkOpen'
      ? {
          'root_folder_id':
              widget.initial?.authorization['root_folder_id'] ?? '0',
        }
      : {...?widget.initial?.authorization};
  late final TextEditingController _url = TextEditingController(
    text: widget.initial?.authorization['url'] as String?,
  );
  late final TextEditingController _user = TextEditingController(
    text: widget.initial?.authorization['user'] as String?,
  );
  late final TextEditingController _password = TextEditingController(
    text: widget.initial?.authorization['password'] as String?,
  );
  late final TextEditingController _accessToken = TextEditingController(
    text: _tokenValue('access_token', 'AccessToken'),
  );
  late final TextEditingController _refreshToken = TextEditingController(
    text: _tokenValue('refresh_token', 'RefreshToken'),
  );
  late final TextEditingController _cookie = TextEditingController(
    text: widget.initial?.authorization['cookie'] as String?,
  );
  String get _driver => widget.driver;
  bool get _hasProviderLogin =>
      _driver == 'Quark' || openListLoginDrivers.containsKey(_driver);
  bool get _autoSaveAfterLogin => widget.initial == null && _hasProviderLogin;
  String? _error;
  bool _loggingIn = false;
  bool _showManualCookie = false;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _user.dispose();
    _password.dispose();
    _accessToken.dispose();
    _refreshToken.dispose();
    _cookie.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final webdav = _driver == 'WebDAV';
    final quark = _driver == 'Quark';
    return Scaffold(
      appBar: Appbar(
        title: Text(
          '${widget.initial == null ? '添加' : '编辑'} ${_providerLabel(_driver)} 账号',
        ),
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _name,
                    decoration: InputDecoration(labelText: '名称'),
                  ),
                  const SizedBox(height: 16),
                  if (webdav) ...[
                    TextField(
                      controller: _url,
                      decoration: InputDecoration(labelText: '服务器地址'),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _user,
                      decoration: InputDecoration(labelText: '用户名'),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: InputDecoration(labelText: '密码'),
                    ),
                  ] else ...[
                    if (_hasProviderLogin) ...[
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        style: actionButtonStyle,
                        onPressed: _loggingIn ? null : _login,
                        icon: const Icon(Icons.login),
                        label: Text('登录并授权'),
                      ),
                      if (quark) ...[
                        const SizedBox(height: 4),
                        TextButton(
                          onPressed: () => setState(
                            () => _showManualCookie = !_showManualCookie,
                          ),
                          child: Text(
                            _showManualCookie
                                ? '收起手动 Cookie'
                                : '登录失败？手动填写 Cookie',
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                    ],
                    if (quark && _showManualCookie) ...[
                      TextField(
                        controller: _cookie,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        maxLines: 3,
                        decoration: InputDecoration(
                          labelText: 'Cookie',
                          hintText: '__pus=...; __puus=...',
                          helperText:
                              'Copy the full cookie from pan.quark.cn in a browser.',
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          style: actionButtonStyle,
                          onPressed: _loggingIn ? null : _save,
                          child: Text('保存并测试连接'),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ] else if (!_autoSaveAfterLogin) ...[
                      TextField(
                        controller: _refreshToken,
                        onChanged: (_) => _accessToken.clear(),
                        decoration: InputDecoration(labelText: '刷新令牌'),
                      ),
                    ],
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (!_autoSaveAfterLogin &&
                      !(quark && _showManualCookie)) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: actionButtonStyle,
                        onPressed: _loggingIn ? null : _save,
                        child: Text('保存并测试连接'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _save() {
    final webdav = _driver == 'WebDAV';
    final quark = _driver == 'Quark';
    try {
      final name = _validatedName();
      if (quark) {
        if (_cookie.text.trim().isEmpty) {
          throw const FormatException('请填写 Cookie');
        }
      } else if (!webdav && !quark && _refreshToken.text.trim().isEmpty) {
        throw const FormatException('请填写刷新令牌');
      }
      final auth = webdav
          ? <String, dynamic>{
              'url': _url.text.trim(),
              'user': _user.text.trim(),
              'password': _password.text,
            }
          : buildOpenListAuthorization(
              driver: _driver,
              accessToken: _accessToken.text,
              refreshToken: _refreshToken.text,
              cookie: _cookie.text,
              authorization: _authorization,
            );
      Navigator.pop(
        context,
        StorageAccount(
          id: widget.initial?.id ?? '',
          backend: webdav ? StorageBackend.webdav : StorageBackend.openlist,
          driver: webdav ? widget.initial?.driver ?? 'webdav' : _driver,
          name: name,
          oauthCallbackUrl: widget.initial?.oauthCallbackUrl ?? '',
          authorization: auth,
        ),
      );
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  String _validatedName() {
    final name = _name.text.trim().isEmpty
        ? _providerLabel(_driver)
        : _name.text.trim();
    if (widget.accounts.isNameInUse(name, excludingId: widget.initial?.id)) {
      throw const FormatException('已存在同名账号');
    }
    return name;
  }

  Future<void> _login() async {
    if (_autoSaveAfterLogin) {
      final name = _name.text.trim().isEmpty
          ? _providerLabel(_driver)
          : _name.text.trim();
      if (widget.accounts.isNameInUse(name)) {
        setState(() => _error = '已存在同名账号');
        return;
      }
    }
    setState(() {
      _loggingIn = true;
      _error = null;
    });
    try {
      final authorization = _driver == 'Quark'
          ? await showQuarkLogin(context)
          : await showOpenListLogin(context, driver: _driver);
      if (mounted && authorization != null) {
        _applyAuthorization({..._authorization, ...authorization});
        if (_autoSaveAfterLogin) _save();
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException ? error.message : '$error',
        );
      }
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  void _applyAuthorization(Map<String, dynamic> authorization) {
    setState(() {
      _authorization = authorization;
      _cookie.text = authorization['cookie'] as String? ?? '';
      _accessToken.text =
          authorization['access_token'] as String? ??
          authorization['AccessToken'] as String? ??
          '';
      _refreshToken.text =
          authorization['refresh_token'] as String? ??
          authorization['RefreshToken'] as String? ??
          '';
      _error = null;
    });
  }

  String _tokenValue(String primary, String alternate) =>
      widget.initial?.authorization[primary] as String? ??
      widget.initial?.authorization[alternate] as String? ??
      '';
}

/// 把底层异常转成一句能读的中文提示。
/// 原生桥的错误是 `PlatformException`，直接 `toString()` 会变成
/// `PlatformException(openlist, 内核进程已崩溃…, null, null)`，
/// 用户看到的就是这串噪音。这里只取真正的原因。
String describeCloudError(Object error) {
  if (error is PlatformException) {
    final message = error.message?.trim();
    if (message != null && message.isNotEmpty) {
      return _cleanCoreMessage(message);
    }
    return error.code;
  }
  if (error is FormatException) return _cleanCoreMessage(error.message);
  return _cleanCoreMessage('$error');
}

/// 去掉内核的包装前缀，留下真正有用的那句。
///
/// 内核初始化失败一次后，再次初始化会回 `failed init storage but storage is
/// already created: failed init storage: <真正原因>`——前半段是它自己的状态机噪音，
/// 直接把整串丢给用户只会更难读。
String _cleanCoreMessage(String message) {
  var text = message.trim();
  for (final prefix in [
    'failed init storage but storage is already created: ',
    'failed init storage: ',
    'Exception: ',
  ]) {
    while (text.startsWith(prefix)) {
      text = text.substring(prefix.length).trimLeft();
    }
  }
  return text;
}

/// 这类错误重试一次往往就好了（链路被掐、握手抖动），别急着让用户去改配置。
bool _isTransientNetworkError(Object error) {
  final text = describeCloudError(error).toLowerCase();
  return text.contains('eof') ||
      text.contains('connection reset') ||
      text.contains('broken pipe') ||
      text.contains('timeout') ||
      text.contains('超时');
}

/// 连接测试：瞬时网络错误自动重试一次。
Future<void> _testWithRetry(RemoteFileStore store) async {
  Future<void> attempt() => store.test().timeout(
    const Duration(seconds: 45),
    onTimeout: () =>
        throw const RemoteStorageException('连接测试超时，请检查网络', code: 'timeout'),
  );
  try {
    await attempt();
  } catch (error) {
    if (!_isTransientNetworkError(error)) rethrow;
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await attempt();
  }
}

/// 失败提示后面补上内核日志尾部。
///
/// RPC 只回一句 `Get "…": EOF`，真正的原因（有没有走代理、停在哪一步）在内核
/// 自己的日志里。附上最后几行，用户截图就能定位，不用再来回猜。
Future<String> _withKernelLog(
  RemoteStorageAccounts storage,
  String message,
) async {
  final tail = await storage.kernelLogTail();
  if (tail == null || tail.trim().isEmpty) return message;
  return '$message\n内核日志：$tail';
}
