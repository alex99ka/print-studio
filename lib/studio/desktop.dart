import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/errors.dart';

/// What only the PC does: hand an approved 3MF to Bambu Studio and open a
/// version in the Flag Maker (a Windows app). Phone and web download instead.
bool get isWindows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// Downloads the 3MF and opens it with whatever opens .3mf files: Bambu Studio.
Future<void> openInSlicer(Uint8List bytes, String fileName) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}print-studio')
    ..createSync(recursive: true);
  final safe = fileName.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  final file = File('${dir.path}${Platform.pathSeparator}$safe')..writeAsBytesSync(bytes);
  if (!await launchUrl(Uri.file(file.path))) throw Errors.slicerFailed;
}

const _exeKey = 'flagMakerExe';

/// The Flag Maker's EXE, asked for once (it is a portable folder, so there is
/// no install location to find). [choose] asks again.
Future<String?> flagMakerExe({bool choose = false}) async {
  final prefs = await SharedPreferences.getInstance();
  var path = prefs.getString(_exeKey);
  if (choose || path == null || !File(path).existsSync()) {
    final f = await openFile(
      confirmButtonText: 'בחירה',
      acceptedTypeGroups: const [XTypeGroup(label: 'Interview Flag Maker', extensions: ['exe'])],
    );
    if (f == null) return null;
    path = f.path;
    await prefs.setString(_exeKey, path);
  }
  return path;
}

/// Starts the Flag Maker on a new design for this request, the names already
/// filled in; "Send to CRM" then has this request chosen.
Future<bool> newInFlagMaker(String requestId, List<String> names) async {
  final exe = await flagMakerExe();
  if (exe == null) return false;
  await Process.start(exe, ['--crm-request', requestId, '--names', ...names],
      mode: ProcessStartMode.detached, workingDirectory: File(exe).parent.path);
  return true;
}

/// Starts the Flag Maker on this version's recipe; it fetches the recipe from
/// the Pi with its own paired key.
Future<bool> openInFlagMaker(String versionId) async {
  final exe = await flagMakerExe();
  if (exe == null) return false;
  await Process.start(exe, ['--crm-version', versionId],
      mode: ProcessStartMode.detached, workingDirectory: File(exe).parent.path);
  return true;
}
