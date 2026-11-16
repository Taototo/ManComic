/// If window width is less than this value, it is considered as mobile.
const changePoint = 600;

/// If window width is less than this value, it is considered as tablet.
///
/// If it is more than this value, it is considered as desktop.
const changePoint2 = 1300;

/// Default user agent for http requests.
const webUA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36";

/// Pages for all comics is started from this value.
const firstPage = 1;

/// Chapters for all comics is started from this value.
const firstChapter = 1;

/// 应用自身的发布版本号。
///
/// 必须与 `android/app/build.gradle` 中的 `appVersionName` 完全一致；与
/// `pubspec.yaml` 的 `version` 的一致性只能是「前缀相等」——pub 的语义化
/// 版本只允许三段，像 `1.5.2.001` 这种补丁号写不进 pubspec，只能放在这里
/// 和 gradle 里（`+353` 是版本号，不是版本名）。
/// 一旦漂移，「关于」页显示的版本号与更新检查都会出错。
/// 该一致性由 `test/app_version_test.dart` 校验。
///
/// **跨版本时必须动前三段**：版本比较是跑在用户**已装的那个旧包**里的。
/// 1.5.2 那版只比较前三段，所以发 `1.5.2.001` 时它判成「不高于自己」，
/// 一个提示都没有——补丁段只有对「已经能识别第四段的版本」才有意义，
/// 拿它当跨版本升级的锚点等于把包发给已经装了的人。
///
/// 注意：`App.version` 是 Venera 上游的兼容版本号（漫画源 / UA 使用），
/// 不是本应用的发布版本，不要混用。
const appVersionName = "1.5.4";

/// 应用仓库信息（「关于」页面与更新检查使用）。
const appRepoOwner = "Taototo";
const appRepoName = "ManComic";
const appRepoUrl = "https://github.com/$appRepoOwner/$appRepoName";
const appReleasesUrl = "$appRepoUrl/releases";
