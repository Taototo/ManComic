import 'package:sqlite3/sqlite3.dart';

/// ManComi 使用 sqlite3 2.x（方法名为 dispose），而移植来的库引擎按
/// sqlite3 3.x 的 API 调用 close。这里提供兼容扩展，避免改动引擎代码。
extension RemoteSqliteClose on Database {
  void close() => dispose();
}

extension RemotePreparedStatementClose on PreparedStatement {
  void close() => dispose();
}

final _asciiUppercase = RegExp(r'[A-Z]');

/// 与 SQLite 的 NOCASE 排序规则一致，只合并 ASCII 大小写。
String sqliteNoCaseKey(String value) =>
    value.replaceAllMapped(_asciiUppercase, (match) => match[0]!.toLowerCase());

Database openSqliteDatabase(String path) {
  final db = sqlite3.open(path);
  try {
    // Connection setup can also contend with an existing database lock.
    db.execute('PRAGMA busy_timeout = 5000;');
    db.execute('PRAGMA journal_mode = DELETE;');
    db.execute('PRAGMA synchronous = NORMAL;');
    return db;
  } catch (_) {
    db.dispose();
    rethrow;
  }
}

/// Execute a function with a temporary database connection, ensuring cleanup.
/// Use this in Isolate operations to avoid manual open/dispose boilerplate.
Future<T> withDatabase<T>(
  String path,
  Future<T> Function(Database db) fn,
) async {
  final db = openSqliteDatabase(path);
  try {
    return await fn(db);
  } finally {
    db.dispose();
  }
}
