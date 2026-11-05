/// 「现在该不该自动查更新」的判断。
///
/// 抽成纯函数是因为这里有三条容易写错、又都没法靠肉眼验证的规则：
/// 刚升级完必须查（哪怕一分钟前才查过）、失败要按自己的间隔退避、以及
/// 节流窗口不能太长——太长了刚发布的版本用户重启也看不到提示。
library;

/// 自动检查的节流间隔。
///
/// 语义上「启动时检查更新」就该是每次进前台都查，这里只拦掉「几分钟内来回
/// 切好几次」的重复请求。不用按天节流：这个分支常常一天发两三版，早上装的
/// 版本下午就过期了，按天算等于当天再也发现不了新版本。
///
/// 原先是 30 分钟，踩过一次坑：用户 00:38 检查过，01:00 发了新版，01:05
/// 重启时被 `now - lastSuccess = 27 分钟 < 30 分钟` 挡住，界面上就是「没有
/// 更新提示」，得手动去设置里点。缩到 5 分钟，请求量仍然远低于未认证 API
/// 的 60 次/小时。
const kUpdateCheckInterval = Duration(minutes: 5);

/// 检查失败后的重试间隔。
///
/// 失败（断网、GitHub 被墙）不能占用成功的额度，否则一次开机时的网络抖动
/// 就会让「启动时检查更新」在接下来的整段时间里失效；但也不能每次都去撞墙。
const kUpdateCheckRetryInterval = Duration(minutes: 5);

/// [updateCheckSkipReason] 的结论。
enum UpdateCheckSkip {
  /// 该查。
  none,

  /// 「启动时检查更新」开关没开。
  disabled,

  /// 刚查过，还没过节流窗口。
  tooSoon,

  /// 刚失败过，正在退避。
  afterFailure,
}

/// 判断这次启动 / 回到前台要不要自动查更新。
///
/// [versionChanged] 表示上次检查记录的版本号和当前不同，也就是「刚装了新版」。
/// 这种情况必须查：新版本里可能带了更新检查本身的修复，不该被上一版留下的
/// 节流额度挡住。
UpdateCheckSkip updateCheckSkipReason({
  required bool enabled,
  required bool versionChanged,
  required DateTime now,
  required int lastSuccessMs,
  required int lastFailureMs,
}) {
  if (!enabled) {
    return UpdateCheckSkip.disabled;
  }
  var nowMs = now.millisecondsSinceEpoch;
  if (!versionChanged &&
      nowMs - lastSuccessMs < kUpdateCheckInterval.inMilliseconds) {
    return UpdateCheckSkip.tooSoon;
  }
  if (nowMs - lastFailureMs < kUpdateCheckRetryInterval.inMilliseconds) {
    return UpdateCheckSkip.afterFailure;
  }
  return UpdateCheckSkip.none;
}
