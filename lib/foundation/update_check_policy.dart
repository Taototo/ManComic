/// 「现在该不该自动查更新」的判断。
///
/// 抽成纯函数是因为这里有几条容易写错、又都没法靠肉眼验证的规则：
/// 冷启动一律查、刚升级完必须查、失败要按自己的间隔退避，以及给「切回前台」
/// 留一个短窗口——窗口一长，刚发布的版本用户重启也看不到提示。
library;

/// 切回前台时的节流间隔。
///
/// 只作用于 [UpdateCheckSkip] 里 `fromResume = true` 那条路：用户可能一小时内
/// 进出十几次，没必要每次都发请求。**冷启动不受它约束**——用户点开 App 就是
/// 想看最新状态。
///
/// 原先是 30 分钟且对冷启动也生效，踩过两次坑：
/// 1. 00:38 检查过、01:00 发版、01:05 重启被 `27 分钟 < 30 分钟` 挡住；
/// 2. 缩到 5 分钟后同一个坑还在——提示过一次、点了取消、立刻重启，5 分钟内
///    依旧什么都不弹。
/// 现在彻底不给冷启动设窗口，5 分钟只用来挡「来回切前台」。
const kUpdateCheckInterval = Duration(minutes: 5);

/// 检查失败后的重试间隔（同样只作用于切回前台）。
///
/// 失败（断网、GitHub 被墙）不能占用成功的额度，否则一次网络抖动就会让后台
/// 检查在接下来的整段时间里失效；但也不能每次切回都去撞墙。冷启动不看这条，
/// 用户主动打开 App 时宁可再试一次。
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

/// 同一个版本在**同一进程内**重新弹提示的最小间隔。
///
/// 「取消」在用户那里的意思通常是「现在不想装」，不是「以后都别再问」。
/// 所以进程内也不能永久静音：隔一段时间再回到前台，应该重新提示一次。
/// 但也不能一回到前台就弹（用户可能频繁切换应用），给 10 分钟缓冲。
const kUpdatePromptRepeatInterval = Duration(minutes: 10);

/// 自动检查发现同一个版本时，该不该再弹一次提示。
///
/// [promptedVersion] / [promptedAt] 是上一次自动弹窗记下的版本与时间，
/// 冷启动时都是空的，所以每次重启都会重新提示（只要节流允许检查）。
bool shouldPromptUpdateAgain({
  required String version,
  required String? promptedVersion,
  required DateTime? promptedAt,
  required DateTime now,
}) {
  if (promptedVersion == null || promptedVersion != version) {
    return true;
  }
  if (promptedAt == null) {
    return true;
  }
  return now.difference(promptedAt) >= kUpdatePromptRepeatInterval;
}

/// 判断这次启动 / 回到前台要不要自动查更新。
///
/// [fromResume] 区分两种情况：冷启动（用户主动点开 App）和从后台切回前台。
/// **冷启动一律检查**——用户点开就是想看最新状态，被上一次检查留下的「额度」
/// 挡住，表现出来的就是「明明有新版本却不提示」，而这正是这个函数最初要修的
/// 缺陷。切回前台才需要节流：用户可能在一小时内进出十几次，没必要每次都发
/// 请求。
///
/// [versionChanged] 表示上次检查记录的版本号和当前不同，也就是「刚装了新版」。
/// 这种情况必须查：新版本里可能带了更新检查本身的修复，不该被上一版留下的
/// 节流额度挡住。
UpdateCheckSkip updateCheckSkipReason({
  required bool enabled,
  required bool fromResume,
  required bool versionChanged,
  required DateTime now,
  required int lastSuccessMs,
  required int lastFailureMs,
}) {
  if (!enabled) {
    return UpdateCheckSkip.disabled;
  }
  if (!fromResume) {
    // 冷启动不做任何时间窗判断，也不因「刚才失败过」而退避：
    // 现在网络恢复了却因为一分钟前的一次失败跳过，等于又是一次漏提示。
    return UpdateCheckSkip.none;
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
