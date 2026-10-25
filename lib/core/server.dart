import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'errors.dart';

bool get hasServer => AppConfig.serverUrl.isNotEmpty;

/// Calls the home server with the signed-in user's Firebase ID token, which
/// the server checks on every route. Every call has a timeout.
Future<Map<String, dynamic>> server(
  String method,
  String path, [
  Map<String, dynamic>? body,
]) async {
  final token = await FirebaseAuth.instance.currentUser?.getIdToken();
  final req = http.Request(method, Uri.parse('${AppConfig.serverUrl}$path'))
    ..headers['Content-Type'] = 'application/json';
  if (token != null) req.headers['Authorization'] = 'Bearer $token';
  if (body != null) req.body = jsonEncode(body);
  final res = await http.Response.fromStream(
      await req.send().timeout(const Duration(seconds: 30)));
  if (res.statusCode >= 400) {
    throw ServerException(res.statusCode, res.body);
  }
  return res.body.isEmpty ? {} : jsonDecode(res.body) as Map<String, dynamic>;
}
