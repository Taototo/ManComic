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
/// 必须与 `pubspec.yaml` 的 `version`（`+` 之前的部分）以及
/// `android/app/build.gradle` 中的 `appVersionName` 保持一致，
/// 否则「关于」页显示的版本号与更新检查都会出错。
/// 该一致性由 `test/app_version_test.dart` 校验。
///
/// 注意：`App.version` 是 Venera 上游的兼容版本号（漫画源 / UA 使用），
/// 不是本应用的发布版本，不要混用。
const appVersionName = "1.4.20";

/// 应用仓库信息（「关于」页面与更新检查使用）。
const appRepoOwner = "Taototo";
const appRepoName = "ManComic";
const appRepoUrl = "https://github.com/$appRepoOwner/$appRepoName";
const appReleasesUrl = "$appRepoUrl/releases";
