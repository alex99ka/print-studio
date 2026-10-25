import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'app_info.dart';
import 'errors.dart';

/// A published build for this platform.
@immutable
class Release {
  const Release({
    required this.version,
    required this.notes,
    required this.url,
    required this.size,
    required this.sha256,
    required this.prerelease,
  });

  final String version;
  final String notes;
  final String url;
  final int size;

  /// Lower-case hex. From the asset's GitHub digest, else SHA256SUMS.
  final String sha256;
  final bool prerelease;
}

/// The asset each platform installs, as the release workflow names it.
bool assetFor(String platform, String name) => switch (platform) {
      'android' => name.endsWith('.apk'),
      'windows' => name.contains('-setup-') && name.endsWith('.exe'),
      _ => false,
    };

/// Picks the newest release this user should get from GitHub's
/// `/releases` list: drafts never, prereleases only for early users.
/// Pure, so it is tested without a network (test/update_test.dart).
Map<String, dynamic>? pickRelease(List<dynamic> releases, {required bool early}) {
  Map<String, dynamic>? best;
  for (final r in releases.cast<Map<String, dynamic>>()) {
    if (r['draft'] == true) continue;
    if (r['prerelease'] == true && !early) continue;
    final tag = '${r['tag_name']}';
    if (best == null || isNewer(tag, '${best['tag_name']}')) best = r;
  }
  return best;
}

/// sha256 for [asset] from a SHA256SUMS text (`<hex>  <name>` per line).
String? digestFromSums(String sums, String asset) {
  for (final line in const LineSplitter().convert(sums)) {
    final parts = line.trim().split(RegExp(r'\s+\*?'));
    if (parts.length == 2 && parts[1] == asset) return parts[0].toLowerCase();
  }
  return null;
}

abstract interface class UpdateSource {
  Future<Release?> latest(String platform, {required bool early});
}

class GitHubUpdateSource implements UpdateSource {
  static const _limit = Duration(seconds: 30);

  Future<String> _get(String url) async {
    final res = await http.get(Uri.parse(url), headers: {
      'Accept': 'application/vnd.github+json',
    }).timeout(_limit);
    if (res.statusCode != 200) throw Errors.updateCheckFailed;
    return res.body;
  }

  @override
  Future<Release?> latest(String platform, {required bool early}) async {
    final list = jsonDecode(await _get(
        'https://api.github.com/repos/${AppConfig.githubRepo}/releases?per_page=10'));
    final r = pickRelease(list as List, early: early);
    if (r == null) return null;
    final assets = (r['assets'] as List).cast<Map<String, dynamic>>();
    final asset =
        assets.where((a) => assetFor(platform, '${a['name']}')).firstOrNull;
    if (asset == null) return null;
    var digest = '${asset['digest'] ?? ''}'.replaceFirst('sha256:', '');
    if (digest.isEmpty) {
      final sums = assets.where((a) => a['name'] == 'SHA256SUMS').firstOrNull;
      if (sums == null) return null; // nothing to check it against: not offered
      digest = digestFromSums(
              await _get('${sums['browser_download_url']}'), '${asset['name']}') ??
          '';
      if (digest.isEmpty) return null;
    }
    return Release(
      version: '${r['tag_name']}'.replaceFirst(RegExp(r'^v'), ''),
      notes: '${r['body'] ?? ''}',
      url: '${asset['browser_download_url']}',
      size: (asset['size'] as num).toInt(),
      sha256: digest.toLowerCase(),
      prerelease: r['prerelease'] == true,
    );
  }
}

/// Hands a downloaded build to the operating system.
abstract interface class UpdateInstaller {
  /// Android asks once per app before it installs anything from it.
  Future<bool> canInstall();
  Future<void> allowInstalls();
  Future<Directory> folder();

  /// Installs now, with the system's own screens.
  Future<void> install(File file);

  /// Readies a build to install without a tap. True when it will: on Android
  /// 12+ once the app has been out of sight 10 minutes (UpdateReceiver.kt),
  /// on Windows when the window closes ([installOnExit]).
  Future<bool> stage(File file);
  Future<void> unstage();
  Future<void> installOnExit(File file);

  /// Fetching without a tap waits for a network that isn't mobile data.
  Future<bool> onFreeNetwork();
}

class AndroidUpdateInstaller implements UpdateInstaller {
  static const _channel = MethodChannel('app/update');

  @override
  Future<bool> canInstall() async =>
      await _channel.invokeMethod<bool>('canInstall') ?? false;

  @override
  Future<void> allowInstalls() => _channel.invokeMethod('allowInstalls');

  // Must match res/xml/update_paths.xml, which FileProvider shares.
  @override
  Future<Directory> folder() async =>
      Directory('${(await getTemporaryDirectory()).path}/updates');

  @override
  Future<void> install(File file) =>
      _channel.invokeMethod('install', {'path': file.path});

  @override
  Future<bool> stage(File file) async =>
      await _channel.invokeMethod<bool>('stage', {'path': file.path}) ?? false;

  @override
  Future<void> unstage() => _channel.invokeMethod('unstage');

  @override
  Future<void> installOnExit(File file) async {}

  @override
  Future<bool> onFreeNetwork() async =>
      await _channel.invokeMethod<bool>('unmetered') ?? false;
}

class WindowsUpdateInstaller implements UpdateInstaller {
  @override
  Future<bool> canInstall() async => true;

  @override
  Future<void> allowInstalls() async {}

  @override
  Future<Directory> folder() async => Directory(
      '${(await getTemporaryDirectory()).path}\\${AppConfig.githubRepo.split('/').last}-updates');

  /// Runs the installer with a progress window and no questions; it closes
  /// this app and opens the new version (installer/app.iss, [Run]).
  @override
  Future<void> install(File file) async {
    await Process.start(file.path,
        const ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached);
    exit(0);
  }

  @override
  Future<bool> stage(File file) async => true;

  @override
  Future<void> unstage() async {}

  /// The window is closing anyway: no window at all, and /nolaunch=1 keeps
  /// it from reopening what was just closed.
  @override
  Future<void> installOnExit(File file) async {
    await Process.start(file.path,
        const ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/nolaunch=1'],
        mode: ProcessStartMode.detached);
  }

  @override
  Future<bool> onFreeNetwork() async => true;
}

/// Knows whether a newer build is published, downloads it in the background,
/// and installs it by itself where the platform allows, or on a tap.
/// The web updates by reloading (see web_update.dart); this is null there.
class AppUpdater extends ChangeNotifier {
  AppUpdater({
    required this.source,
    required this.installer,
    required this.platform,
    required this.currentVersion,
  });

  final UpdateSource source;
  final UpdateInstaller installer;
  final String platform;
  final String currentVersion;

  static final AppUpdater? instance = switch (AppInfo.platform) {
    'android' => AppUpdater(
        source: GitHubUpdateSource(),
        installer: AndroidUpdateInstaller(),
        platform: 'android',
        currentVersion: AppInfo.version),
    'windows' => AppUpdater(
        source: GitHubUpdateSource(),
        installer: WindowsUpdateInstaller(),
        platform: 'windows',
        currentVersion: AppInfo.version),
    _ => null,
  };

  /// Set by the shell from RemoteConfig.earlyUser.
  bool early = false;

  Release? available;
  bool checking = false;
  DateTime? lastChecked;
  String? lastResult;
  AppError? error;

  /// 0–1 while downloading, null otherwise.
  double? progress;
  bool needsPermission = false;

  /// "Later" on the banner: for this run only.
  bool dismissed = false;

  File? _file;
  String? _fileVersion;
  bool get ready => _file != null && _fileVersion == available?.version;
  bool installsByItself = false;
  bool get busy => checking || progress != null;

  /// At launch and on coming back; at most every 6 hours (GitHub allows 60
  /// unauthenticated calls an hour per IP).
  Future<void> checkIfDue({Duration minInterval = const Duration(hours: 6)}) {
    final last = lastChecked;
    if (last != null && DateTime.now().difference(last) < minInterval) {
      return Future.value();
    }
    return check();
  }

  Future<void> check() async {
    if (busy) return;
    checking = true;
    error = null;
    notifyListeners();
    try {
      final r = await source.latest(platform, early: early);
      available = r != null && isNewer(r.version, currentVersion) ? r : null;
      lastResult = available == null
          ? 'הגרסה עדכנית'
          : 'נמצאה גרסה ${available!.version}';
      if (available == null) {
        await _clearFolder();
        await installer.unstage();
      }
    } catch (e) {
      error = e is AppError ? e : Errors.updateCheckFailed;
      lastResult = 'הבדיקה נכשלה (קוד ${error!.code})';
    } finally {
      lastChecked = DateTime.now();
      checking = false;
      _saveLastCheck();
      notifyListeners();
    }
    if (available != null && !ready && await installer.onFreeNetwork()) {
      await _prepare();
    }
  }

  Future<void> _saveLastCheck() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('update_last_check',
          '${lastChecked!.toIso8601String()}|${lastResult ?? ''}');
    } catch (_) {}
  }

  Future<void> _prepare() async {
    final r = available;
    if (r == null || busy) return;
    progress = 0;
    notifyListeners();
    try {
      final file = await download(r);
      _file = file;
      _fileVersion = r.version;
      installsByItself = await installer.stage(file);
    } catch (e) {
      error = e is AppError ? e : classify(e);
    } finally {
      progress = null;
      notifyListeners();
    }
  }

  /// Windows, when the window closes.
  Future<void> installOnExit() async {
    if (ready && installsByItself) await installer.installOnExit(_file!);
  }

  void dismiss() {
    dismissed = true;
    notifyListeners();
  }

  /// "עדכון עכשיו".
  Future<void> install() async {
    if (available == null || busy) return;
    error = null;
    if (!await installer.canInstall()) {
      needsPermission = true;
      notifyListeners();
      await installer.allowInstalls();
      return;
    }
    needsPermission = false;
    if (!ready) await _prepare();
    if (!ready) return;
    try {
      await installer.install(_file!);
    } catch (e) {
      error = classify(e);
      notifyListeners();
    }
  }

  /// Streams the build to disk, proving it is byte for byte what was
  /// published before anything installs it.
  @visibleForTesting
  Future<File> download(Release r) async {
    final dir = await installer.folder();
    final file = File('${dir.path}${Platform.pathSeparator}'
        'update-${r.version}.${platform == 'windows' ? 'exe' : 'apk'}');
    if (await _holds(file, r)) return file;
    await _clearFolder();
    await dir.create(recursive: true);

    final client = http.Client();
    final sink = file.openWrite();
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    var received = 0;
    try {
      final res = await client
          .send(http.Request('GET', Uri.parse(r.url)))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw Errors.updateCheckFailed;
      await for (final bytes
          in res.stream.timeout(const Duration(seconds: 60))) {
        sink.add(bytes);
        hasher.add(bytes);
        received += bytes.length;
        progress = r.size == 0 ? 1 : (received / r.size).clamp(0, 1).toDouble();
        notifyListeners();
      }
    } finally {
      await sink.close();
      client.close();
    }
    hasher.close();
    if (received != r.size || digest.value.toString() != r.sha256) {
      await file.delete();
      throw Errors.updateCorrupt;
    }
    return file;
  }

  static Future<bool> _holds(File f, Release r) async =>
      await f.exists() &&
      await f.length() == r.size &&
      (await sha256.bind(f.openRead()).first).toString() == r.sha256;

  Future<void> _clearFolder() async {
    try {
      final dir = await installer.folder();
      if (!await dir.exists()) return;
      await for (final f in dir.list()) {
        if (f is File) await f.delete();
      }
    } catch (_) {} // a file the installer still holds goes next time
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
