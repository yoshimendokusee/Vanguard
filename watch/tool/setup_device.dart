// Generates watch/env.json from the repository-root .env, then optionally builds
// the APK and installs it on every connected Android/Wear OS device.
//
//   cd watch
//   dart run tool/setup_device.dart            # write env.json only
//   dart run tool/setup_device.dart --build    # + flutter build apk
//   dart run tool/setup_device.dart --install  # + build + adb install on all devices
//   dart run tool/setup_device.dart --env path/to/.env
//
// Values are never printed in full. Only the publishable/anon key is accepted.
import 'dart:convert';
import 'dart:io';

import 'package:vanguard_wrist/services/cloud_config.dart';

const watchKeys = ['HUB_URL', 'SUPABASE_URL', 'SUPABASE_ANON_KEY'];

/// Every `KEY=value` occurrence in a dotenv file, keyed by name, in file order.
Map<String, List<String>> parseDotEnv(String text) {
  final values = <String, List<String>>{};
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final match = RegExp(r'^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$')
        .firstMatch(line);
    if (match == null) continue;
    var value = match.group(2)!.trim();
    if (value.length >= 2 &&
        (value[0] == '"' || value[0] == "'") &&
        value.endsWith(value[0])) {
      value = value.substring(1, value.length - 1);
    } else {
      value = value.replaceFirst(RegExp(r'\s+#.*$'), '');
    }
    values.putIfAbsent(match.group(1)!, () => []).add(value);
  }
  return values;
}

/// The watch build values, or a [FormatException] explaining what to fix.
/// Supabase values may both be empty (LAN-only build); a partial, placeholder,
/// non-HTTPS or secret-key configuration is rejected.
Map<String, String> watchConfig(Map<String, List<String>> env) {
  String value(String key) {
    final found = (env[key] ?? const []).toSet();
    if (found.length > 1) {
      throw FormatException(
        '$key is defined ${env[key]!.length} times with different values; '
        'keep only the correct line in .env',
      );
    }
    final v = found.isEmpty ? '' : found.single;
    if (v.contains('<')) {
      throw FormatException('$key still contains a <placeholder> value');
    }
    return v;
  }

  final config = {for (final key in watchKeys) key: value(key)};
  final hub = Uri.tryParse(config['HUB_URL']!);
  if (hub == null ||
      !(hub.scheme == 'http' || hub.scheme == 'https') ||
      hub.host.isEmpty) {
    throw const FormatException(
      'HUB_URL must be http://<hub-lan-ip>:<port> (the hub laptop LAN address)',
    );
  }
  final url = config['SUPABASE_URL']!, key = config['SUPABASE_ANON_KEY']!;
  if (url.isNotEmpty || key.isNotEmpty) {
    final error = cloudConfigurationError(url, key);
    if (error != null) throw FormatException(error);
  }
  return config;
}

String mask(String value) => value.isEmpty
    ? '(empty)'
    : '${value.substring(0, (value.length ~/ 3).clamp(0, 15))}... '
          '(${value.length} chars)';

/// Serials of authorized devices in `adb devices` output.
List<String> adbDevices(String output) => [
  for (final line in const LineSplitter().convert(output))
    if (RegExp(r'^\S+\s+device$').hasMatch(line.trim()))
      line.trim().split(RegExp(r'\s+')).first,
];

String? findAdb() {
  final exe = Platform.isWindows ? 'adb.exe' : 'adb';
  final home = Platform.environment['HOME'] ?? '';
  final roots = [
    Platform.environment['ANDROID_HOME'],
    Platform.environment['ANDROID_SDK_ROOT'],
    if (Platform.environment['LOCALAPPDATA'] case final local?)
      '$local/Android/Sdk',
    '$home/Library/Android/sdk',
    '$home/Android/Sdk',
  ];
  for (final root in roots.whereType<String>()) {
    final candidate = File('$root/platform-tools/$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  final which = Process.runSync(Platform.isWindows ? 'where' : 'which', [
    'adb',
  ], runInShell: true);
  final path = '${which.stdout}'.trim().split(RegExp(r'\r?\n')).first;
  return which.exitCode == 0 && path.isNotEmpty ? path : null;
}

Future<void> run(String exe, List<String> args, String dir) async {
  final process = await Process.start(
    exe,
    args,
    workingDirectory: dir,
    runInShell: true,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0) throw ProcessException(exe, args, 'exit code $code', code);
}

Future<void> main(List<String> args) async {
  final watchDir = File.fromUri(Platform.script).parent.parent.path;
  final envIndex = args.indexOf('--env');
  final envPath = envIndex >= 0 && envIndex + 1 < args.length
      ? args[envIndex + 1]
      : '$watchDir/../.env';
  final install = args.contains('--install');
  final build = install || args.contains('--build');

  try {
    final envFile = File(envPath);
    if (!envFile.existsSync()) {
      throw FormatException(
        'No .env at ${envFile.path}. Copy .env.example to .env and fill in '
        'HUB_URL, SUPABASE_URL and SUPABASE_ANON_KEY',
      );
    }
    final config = watchConfig(parseDotEnv(envFile.readAsStringSync()));
    File('$watchDir/env.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(config)}\n',
    );
    stdout
      ..writeln('Wrote watch/env.json (git-ignored):')
      ..writeln('  HUB_URL           ${config['HUB_URL']}')
      ..writeln('  SUPABASE_URL      ${mask(config['SUPABASE_URL']!)}')
      ..writeln('  SUPABASE_ANON_KEY ${mask(config['SUPABASE_ANON_KEY']!)}');
    if (config['SUPABASE_URL']!.isEmpty) {
      stdout.writeln(
        'Supabase values are empty: LAN-only build, no cloud sync.',
      );
    }
    final models = Directory('$watchDir/assets/models');
    if (!models.existsSync() ||
        !models.listSync().any((f) => f.path.endsWith('.zip'))) {
      stdout.writeln(
        'Warning: no Vosk model zip in watch/assets/models; speech capture '
        'will not work in this build (see README).',
      );
    }
    if (!build) return;

    await run('flutter', [
      'build',
      'apk',
      '--dart-define-from-file=env.json',
    ], watchDir);
    if (!install) return;

    final adb = findAdb();
    if (adb == null) {
      throw const FormatException(
        'adb not found. Install Android SDK platform-tools or set ANDROID_HOME',
      );
    }
    final listing = Process.runSync(adb, ['devices'], runInShell: true);
    final devices = adbDevices('${listing.stdout}');
    if (devices.isEmpty) {
      throw FormatException(
        'No authorized device. Connect a device with ADB debugging on and '
        'accept the prompt.\n${listing.stdout}',
      );
    }
    final apk = '$watchDir/build/app/outputs/flutter-apk/app-release.apk';
    for (final serial in devices) {
      stdout.writeln('Installing on $serial...');
      await run(adb, ['-s', serial, 'install', '-r', apk], watchDir);
    }
    stdout.writeln(
      'Installed on ${devices.length} device(s). Open the app online once '
      'and sign in; reports then sync automatically when online.',
    );
  } on FormatException catch (e) {
    stderr.writeln('Setup failed: ${e.message}');
    exitCode = 1;
  } on ProcessException catch (e) {
    stderr.writeln(
      'Setup failed: ${e.executable} ${e.arguments.join(' ')}: '
      '${e.message}',
    );
    exitCode = 1;
  }
}
