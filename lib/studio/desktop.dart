import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/errors.dart';

/// What only the PC does: hand an approved 3MF to Bambu Studio, open a
/// version in the Flag Maker and a request in Gift Factory (Windows apps).
/// Phone and web download instead.
bool get isWindows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// Downloads the 3MF and opens it with whatever opens .3mf files: Bambu Studio.
Future<void> openInSlicer(Uint8List bytes, String fileName) async {
  if (!await openLocal(bytes, fileName)) throw Errors.slicerFailed;
}

/// Saves [bytes] in a temp folder and opens the file with its Windows app; false when none opens it.
Future<bool> openLocal(Uint8List bytes, String fileName) async {
  final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}print-studio')
    ..createSync(recursive: true);
  final safe = fileName.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  final file = File('${dir.path}${Platform.pathSeparator}$safe')..writeAsBytesSync(bytes);
  return launchUrl(Uri.file(file.path));
}

const _exeKey = 'flagMakerExe';
// Since Flag Maker 5.7.0 one app folder is updated in place (older builds sat in "Interview Flag Maker vX.Y.Z").
const _flagMakerDefault = r'C:\claude projects\3d\Flag Maker\dist\Interview Flag Maker\Interview Flag Maker.exe';

/// The Flag Maker's EXE: the one app folder, else asked for once (it is a
/// portable folder, so there is no install location to find). [choose] asks again.
/// A running Flag Maker opens each start as a new tab.
Future<String?> flagMakerExe({bool choose = false}) async {
  final prefs = await SharedPreferences.getInstance();
  var path = prefs.getString(_exeKey);
  // A path chosen before 5.7.0 points at a frozen versioned folder: move to the one app.
  if (!choose && (path == null || path.contains(r'\Interview Flag Maker v')) && File(_flagMakerDefault).existsSync()) {
    path = _flagMakerDefault;
    await prefs.setString(_exeKey, path);
  }
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

const _giftFactoryKey = 'giftFactoryExe'; // was 'giftFactoryCommand' (pythonw + main.py of the old Python app)
// Gift Factory 1.1.0, the Bambu Studio fork, installed on Alex's PC.
const _giftFactoryDefault = r'C:\claude projects\3d\gift-factory-bambu\build-bambu-clean\dist-stage\bambu-studio.exe';

/// Gift Factory's EXE: the installed one, else asked for once. [choose] asks again.
Future<String?> giftFactoryExe({bool choose = false}) async {
  final prefs = await SharedPreferences.getInstance();
  var path = prefs.getString(_giftFactoryKey) ?? _giftFactoryDefault;
  if (choose || !File(path).existsSync()) {
    final f = await openFile(
      confirmButtonText: 'בחירה',
      acceptedTypeGroups: const [XTypeGroup(label: 'Gift Factory (bambu-studio.exe)', extensions: ['exe'])],
    );
    if (f == null) return null;
    path = f.path;
  }
  await prefs.setString(_giftFactoryKey, path);
  return path;
}

/// Starts Gift Factory on this request: the order linked to it, or it links the
/// next order made from Prepare. A running Gift Factory takes the id itself (one window).
Future<bool> openInGiftFactory(String requestId) async {
  final exe = await giftFactoryExe();
  if (exe == null) return false;
  await Process.start(exe, ['--crm-request', requestId],
      mode: ProcessStartMode.detached, workingDirectory: File(exe).parent.path);
  return true;
}
