import 'package:fl_clash/common/application_proxy.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('disabled lists and empty blacklist leave profile rules alone', () {
    expect(
      applicationAccessRules(const AccessControlProps(), windows: true),
      isEmpty,
    );
    expect(
      applicationAccessRules(
        const AccessControlProps(enable: true),
        windows: true,
      ),
      isEmpty,
    );
    expect(
      applicationAccessRules(
        const AccessControlProps(
          enable: true,
          mode: AccessControlMode.acceptSelected,
        ),
        windows: true,
      ),
      ['IN-TYPE,TUN,DIRECT'],
    );
  });

  test('blacklist scopes escaped exact Windows paths to TUN', () {
    final rules = applicationAccessRules(
      const AccessControlProps(
        enable: true,
        rejectList: [r'windows:PROCESS-PATH:C:\Apps (1),Test\browser.exe'],
      ),
      windows: true,
    );
    final rule = rules.single;
    expect(rule, startsWith('AND,((IN-TYPE,TUN),(PROCESS-PATH-REGEX,'));
    expect(rule, contains(r'\x281\x29\x2cTest'));
    expect(rule, endsWith(r'browser\.exe$)),DIRECT'));
    expect(rule, contains('(?i)^'));
  });

  test(
    'whitelist uses NOT around all selected apps and ignores foreign IDs',
    () {
      final rules = applicationAccessRules(
        const AccessControlProps(
          enable: true,
          mode: AccessControlMode.acceptSelected,
          acceptList: [
            'macos:PROCESS-PATH:/Applications/Browser.app',
            'macos:PROCESS-PATH:/usr/bin/curl',
            r'windows:PROCESS-PATH:C:\Apps\other.exe',
          ],
        ),
        windows: false,
      );
      expect(rules.single, contains('(NOT,((OR,('));
      expect(rules.single, contains(r'^/Applications/Browser\.app/Contents/'));
      expect(rules.single, contains(r'^/usr/bin/curl$'));
      expect(rules.single, isNot(contains('other.exe')));
    },
  );

  test('routing projection ignores display preferences and inactive lists', () {
    const original = AccessControlProps(enable: true, rejectList: ['chosen']);
    final changed = original.copyWith(
      sort: AccessSortType.name,
      isFilterSystemApp: false,
      acceptList: ['inactive'],
    );
    expect(changed.forRouting, original.forRouting);
    expect(
      changed.copyWith(enable: false).forRouting,
      const AccessControlProps(),
    );
  });

  test('invalid selections cannot inject another rule', () {
    for (final selection in [
      'macos:PROCESS-NAME:bad\nMATCH,REJECT',
      'android:PROCESS-NAME:other',
      'com.example.app',
      'macos:PROCESS-PATH:',
    ]) {
      expect(
        applicationAccessRules(
          AccessControlProps(enable: true, rejectList: [selection]),
          windows: false,
        ),
        isEmpty,
      );
    }
  });
}
