import 'package:flutter_test/flutter_test.dart';

import '../tool/setup_device.dart';

Map<String, String> _config(String env) => watchConfig(parseDotEnv(env));

void main() {
  const hub = 'HUB_URL=http://192.168.8.10:3000\n';
  const cloud =
      'SUPABASE_URL=https://example.supabase.co\n'
      'SUPABASE_ANON_KEY=sb_publishable_synthetic\n';

  test('builds env.json values from .env, ignoring other settings', () {
    expect(_config('# comment\nPORT=3000\n$hub$cloud'), {
      'HUB_URL': 'http://192.168.8.10:3000',
      'SUPABASE_URL': 'https://example.supabase.co',
      'SUPABASE_ANON_KEY': 'sb_publishable_synthetic',
    });
    expect(
      _config(
        'HUB_URL="http://10.0.0.2:3000"\n'
        "SUPABASE_URL='https://example.supabase.co'\n"
        'SUPABASE_ANON_KEY=sb_publishable_synthetic # inline note\n',
      )['SUPABASE_ANON_KEY'],
      'sb_publishable_synthetic',
    );
  });

  test('allows a LAN-only build with empty Supabase values', () {
    expect(_config(hub), {
      'HUB_URL': 'http://192.168.8.10:3000',
      'SUPABASE_URL': '',
      'SUPABASE_ANON_KEY': '',
    });
  });

  test('rejects secret keys, partial, placeholder and conflicting values', () {
    for (final env in [
      '${hub}SUPABASE_URL=https://example.supabase.co\nSUPABASE_ANON_KEY=sb_secret_synthetic\n',
      '${hub}SUPABASE_URL=https://example.supabase.co\n',
      '${hub}SUPABASE_URL=http://example.supabase.co\nSUPABASE_ANON_KEY=sb_publishable_synthetic\n',
      '${hub}SUPABASE_URL=https://<project-ref>.supabase.co\nSUPABASE_ANON_KEY=x\n',
      '$hub${cloud}SUPABASE_ANON_KEY=sb_publishable_other\n',
      'HUB_URL=http://<hub-lan-ip>:3000\n',
      'HUB_URL=192.168.8.10:3000\n',
      cloud,
    ]) {
      expect(() => _config(env), throwsFormatException, reason: env);
    }
    expect(_config('$hub$cloud${cloud.split('\n')[1]}\n'), isNotEmpty);
  });

  test('lists only authorized adb devices', () {
    expect(
      adbDevices(
        'List of devices attached\n'
        'emulator-5554\tdevice\n'
        'R5CT1234\tunauthorized\n'
        '192.168.8.20:5555\tdevice\n\n',
      ),
      ['emulator-5554', '192.168.8.20:5555'],
    );
  });

  test('masks values without revealing the full key', () {
    expect(mask(''), '(empty)');
    final masked = mask('sb_publishable_abcdefghijklmnop');
    expect(masked, isNot(contains('abcdefghijklmnop')));
    expect(masked, contains('31 chars'));
  });
}
