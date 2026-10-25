import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/github_sync.dart';
import 'package:fl_clash/views/github_sync.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/backup_and_restore.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import '../helpers/glyph_finders.dart';
import '../helpers/test_app.dart';
import '../helpers/test_profiles.dart';

const _existing = DAVProps(
  uri: 'https://dav.example.com/remote',
  user: 'alice',
  password: 'secret',
  fileName: 'custom.zip',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [profilesProvider.overrideWith(TestProfiles.new)],
    );
    globalState.container = container;
    container.read(viewSizeProvider.notifier).value = const Size(1200, 1400);
    container.listen(davSettingProvider, (_, _) {}, fireImmediately: true);
  });

  tearDown(() => container.dispose());

  Future<void> pumpForm(WidgetTester tester, Widget form) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TestApp(
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showFormSheet<void>(context: context, builder: (_) => form),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder field(String title) => find.descendant(
    of: find.widgetWithText(FormRow, title),
    matching: find.byType(TextFormField),
  );

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
  }

  group('snippet sync', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));
    setUp(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (_) async => null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
    });

    Future<void> pumpSync(
      WidgetTester tester,
      SnippetService service,
      _SnippetClient client, {
      Future<bool> Function(Uri)? launchBrowser,
    }) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TestApp(
            child: Scaffold(
              body: ListView(
                children: [
                  GitHubSyncSection(
                    service: service,
                    client: client,
                    launchBrowser: launchBrowser ?? (_) async => true,
                    onBackup: (_, _) async {},
                    onRestore: (_, _) async {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> openTokenDialog(WidgetTester tester) async {
      await tester.tap(find.text('Sign in with browser'));
      await tester.pumpAndSettle();
      expect(find.textContaining('has not enabled browser'), findsOneWidget);
      await tester.tap(find.text('Connect with token'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    for (final service in SnippetService.values) {
      testWidgets(
        '${service.name} token connection persists only its session',
        (tester) async {
          final client = _SnippetClient(service);
          await pumpSync(tester, service, client);
          expect(
            find.text(
              service == SnippetService.github
                  ? 'GitHub Gist'
                  : 'Gitee snippets',
            ),
            findsWidgets,
          );
          await openTokenDialog(tester);
          await tester.enterText(find.byType(TextFormField), 'personal-token');
          await tester.tap(find.text('Confirm'));
          await tester.pumpAndSettle();
          expect(find.text('tester'), findsOneWidget);
          expect(find.text('No cloud backup yet'), findsOneWidget);
          expect(find.text('Upload encrypted backup'), findsOneWidget);
          const storage = FlutterSecureStorage();
          final stored = await storage.readAll();
          expect(stored.keys, ['flclashx.${service.name}.session.v1']);
          expect(
            (jsonDecode(stored.values.single) as Map)['token'],
            'personal-token',
          );
          await tester.pumpWidget(const SizedBox());
          expect(client.closed, true);
        },
      );
    }

    testWidgets(
      'failed token connection returns to an enabled sign-in control',
      (tester) async {
        final client = _SnippetClient(SnippetService.gitee)..fail = true;
        await pumpSync(tester, SnippetService.gitee, client);
        await openTokenDialog(tester);
        await tester.enterText(find.byType(TextFormField), 'bad-token');
        await tester.tap(find.text('Confirm'));
        await tester.pumpAndSettle();
        expect(find.text('Sign in with browser'), findsOneWidget);
        expect(find.textContaining('Session expired'), findsOneWidget);
        expect(await const FlutterSecureStorage().readAll(), isEmpty);
        client.fail = false;
        await openTokenDialog(tester);
        expect(find.byType(TextFormField), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byType(TextFormField), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    for (final service in SnippetService.values) {
      testWidgets(
        '${service.name} browser authorization persists its session',
        (tester) async {
          final opened = <Uri>[];
          final client = _SnippetClient(service, browser: true);
          await pumpSync(
            tester,
            service,
            client,
            launchBrowser: (uri) async {
              opened.add(uri);
              return true;
            },
          );
          await tester.tap(find.text('Sign in with browser'));
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(
            opened.single.host,
            service == SnippetService.github
                ? 'github.com'
                : 'oauth.example.com',
          );
          expect(
            find.text('ABCD-1234'),
            service == SnippetService.github ? findsOneWidget : findsNothing,
          );
          client.authorization.complete(
            const GitHubSession(
              token: 'oauth-token',
              login: 'browser-user',
              userId: 7,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('browser-user'), findsOneWidget);
          final stored = await const FlutterSecureStorage().readAll();
          expect(stored.keys, ['flclashx.${service.name}.session.v1']);
          expect(
            (jsonDecode(stored.values.single) as Map)['token'],
            'oauth-token',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'browser denial allows retry, then cancel stops authorization',
      (tester) async {
        final client = _SnippetClient(SnippetService.github, browser: true);
        await pumpSync(tester, SnippetService.github, client);
        await tester.tap(find.text('Sign in with browser'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        client.authorization.completeError(
          const GitHubSyncException(GitHubSyncFailure.denied),
        );
        await tester.pumpAndSettle();
        expect(find.text('Authorization was declined.'), findsOneWidget);
        client.authorization = Completer<GitHubSession>();
        await tester.tap(find.text('Retry'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(client.authorizationCancel!.isCancelled, true);
        expect(await const FlutterSecureStorage().readAll(), isEmpty);
        expect(find.text('Sign in with browser'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('browser launch failure offers token fallback', (tester) async {
      final client = _SnippetClient(SnippetService.github, browser: true);
      await pumpSync(
        tester,
        SnippetService.github,
        client,
        launchBrowser: (_) async => false,
      );
      await tester.tap(find.text('Sign in with browser'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not open the browser'), findsOneWidget);
      await tester.tap(find.text('Connect with token'));
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
    });

    testWidgets(
      'disposing browser authorization cancels without saving a late result',
      (tester) async {
        final client = _SnippetClient(SnippetService.gitee, browser: true);
        await pumpSync(tester, SnippetService.gitee, client);
        await tester.tap(find.text('Sign in with browser'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpWidget(const SizedBox());
        client.authorization.complete(
          const GitHubSession(token: 'late-token', login: 'late', userId: 7),
        );
        await tester.pumpAndSettle();
        expect(client.authorizationCancel!.isCancelled, true);
        expect(client.closed, true);
        expect(await const FlutterSecureStorage().readAll(), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('RestoreOptionsDialog', () {
    Future<RestoreOption?> openAndChoose(
      WidgetTester tester,
      String label,
    ) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      RestoreOption? chosen;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: TestApp(
            child: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    chosen = await showDialog<RestoreOption>(
                      context: context,
                      builder: (_) => const RestoreOptionsDialog(),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      return chosen;
    }

    testWidgets('returns onlyProfiles for the config-only option', (
      tester,
    ) async {
      expect(
        await openAndChoose(tester, 'Restore profiles only'),
        RestoreOption.onlyProfiles,
      );
    });

    testWidgets('returns all for the full-data option', (tester) async {
      expect(
        await openAndChoose(tester, 'Restore all data'),
        RestoreOption.all,
      );
    });
  });

  group('WebDAVForm', () {
    Future<void> chooseProvider(WidgetTester tester, String provider) async {
      await tester.tap(find.widgetWithText(FormRow, 'Service provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(provider).last);
      await tester.pumpAndSettle();
    }

    testWidgets('provider choices end with Custom', (tester) async {
      await pumpForm(tester, const WebDAVForm());
      expect(
        tester.widget<TextFormField>(field('Address')).controller!.text,
        'https://dav.jianguoyun.com/dav/',
      );
      await tester.tap(find.widgetWithText(FormRow, 'Service provider'));
      await tester.pumpAndSettle();
      const labels = [
        'Nutstore',
        'Koofr',
        'Yandex Disk',
        'pCloud (US)',
        'pCloud (EU)',
        'Custom',
      ];
      final positions = labels
          .map((label) => tester.getTopLeft(find.text(label).last).dy)
          .toList();
      expect(positions, orderedEquals([...positions]..sort()));
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(field('Address')).controller!.text,
        isEmpty,
      );
      expect(find.text('WebDAV server address'), findsOneWidget);
    });

    for (final entry in {
      'Nutstore': 'https://dav.jianguoyun.com/dav/',
      'Koofr': 'https://app.koofr.net/dav/Koofr/',
      'Yandex Disk': 'https://webdav.yandex.ru/',
      'pCloud (US)': 'https://webdav.pcloud.com/',
      'pCloud (EU)': 'https://ewebdav.pcloud.com/',
    }.entries) {
      testWidgets('${entry.key} saves without entering an address', (
        tester,
      ) async {
        await pumpForm(tester, const WebDAVForm());
        await chooseProvider(tester, entry.key);
        await tester.enterText(field('Account'), 'alice');
        await tester.enterText(field('Password'), 'app-password');
        await save(tester);
        final dav = container.read(davSettingProvider)!;
        expect(dav.uri, entry.value);
        expect(dav.user, 'alice');
        expect(dav.password, 'app-password');
        expect(dav.fileName, defaultDavFileName);
      });
    }

    testWidgets('changing providers preserves custom drafts and credentials', (
      tester,
    ) async {
      await pumpForm(tester, const WebDAVForm(dav: _existing));
      await chooseProvider(tester, 'Nutstore');
      await tester.enterText(
        field('Address'),
        'https://dav.jianguoyun.com/dav/backups/',
      );
      await chooseProvider(tester, 'Custom');
      expect(
        tester.widget<TextFormField>(field('Address')).controller!.text,
        _existing.uri,
      );
      await chooseProvider(tester, 'Koofr');
      await chooseProvider(tester, 'Nutstore');
      expect(
        tester.widget<TextFormField>(field('Address')).controller!.text,
        'https://dav.jianguoyun.com/dav/backups/',
      );
      await save(tester);
      final dav = container.read(davSettingProvider)!;
      expect(dav.user, _existing.user);
      expect(dav.password, _existing.password);
      expect(dav.fileName, _existing.fileName);
    });

    testWidgets(
      'editing recognizes a preset subfolder without rewriting its address',
      (tester) async {
        const uri = 'https://app.koofr.net/dav/Koofr/My%20Backups';
        await pumpForm(tester, WebDAVForm(dav: _existing.copyWith(uri: uri)));
        expect(find.widgetWithText(FormRow, 'Koofr'), findsOneWidget);
        await save(tester);
        expect(container.read(davSettingProvider)!.uri, uri);
        expect(
          container.read(davSettingProvider)!.fileName,
          _existing.fileName,
        );
      },
    );

    testWidgets(
      'dismissing provider selection does not alter the existing binding',
      (tester) async {
        await pumpForm(tester, const WebDAVForm(dav: _existing));
        await tester.tap(find.widgetWithText(FormRow, 'Service provider'));
        await tester.pumpAndSettle();
        Navigator.of(tester.element(find.text('Koofr'))).pop();
        await tester.pumpAndSettle();
        await save(tester);
        expect(container.read(davSettingProvider), _existing);
      },
    );

    testWidgets('rejects an empty form and stores nothing', (tester) async {
      await pumpForm(tester, const WebDAVForm());
      await tester.enterText(field('Address'), '');

      await save(tester);

      expect(container.read(davSettingProvider), isNull);
      expect(find.byType(WebDAVForm), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ErrorBanner),
          matching: find.text('Please enter a valid WebDAV address'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('names the password toggle by what pressing it does', (
      tester,
    ) async {
      await pumpForm(tester, const WebDAVForm());

      final toggle = find.descendant(
        of: find.widgetWithText(FormRow, 'Password'),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(toggle).tooltip, 'Show password');

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(tester.widget<IconButton>(toggle).tooltip, 'Hide password');
    });

    testWidgets('rejects a malformed address', (tester) async {
      await pumpForm(tester, const WebDAVForm());

      await tester.enterText(field('Address'), 'not-a-url');
      await tester.enterText(field('Account'), 'alice');
      await tester.enterText(field('Password'), 'secret');
      await save(tester);

      expect(container.read(davSettingProvider), isNull);
      expect(find.byType(WebDAVForm), findsOneWidget);
    });

    testWidgets('stores a valid binding with the default file name', (
      tester,
    ) async {
      await pumpForm(tester, const WebDAVForm());

      await tester.enterText(
        field('Address'),
        'https://dav.example.com/remote',
      );
      await tester.enterText(field('Account'), 'alice');
      await tester.enterText(field('Password'), 'secret');
      await save(tester);

      final dav = container.read(davSettingProvider);
      expect(dav?.uri, 'https://dav.example.com/remote');
      expect(dav?.user, 'alice');
      expect(dav?.password, 'secret');
      expect(dav?.fileName, defaultDavFileName);
      expect(find.byType(WebDAVForm), findsNothing);
    });

    testWidgets('editing preserves the previously chosen file name', (
      tester,
    ) async {
      container.read(davSettingProvider.notifier).update((_) => _existing);
      await pumpForm(tester, const WebDAVForm(dav: _existing));

      await tester.enterText(field('Account'), 'bob');
      await save(tester);

      final dav = container.read(davSettingProvider);
      expect(dav?.user, 'bob');
      expect(dav?.fileName, 'custom.zip');
    });

    testWidgets('offers delete only when editing an existing binding', (
      tester,
    ) async {
      await pumpForm(tester, const WebDAVForm());
      expect(find.widgetWithText(FormRow, 'Delete'), findsNothing);
      Navigator.of(tester.element(find.byType(WebDAVForm))).pop();
      await tester.pumpAndSettle();

      await pumpForm(tester, const WebDAVForm(dav: _existing));
      expect(find.widgetWithText(FormRow, 'Delete'), findsOneWidget);
    });

    testWidgets('delete clears the stored binding', (tester) async {
      container.read(davSettingProvider.notifier).update((_) => _existing);
      await pumpForm(tester, const WebDAVForm(dav: _existing));

      await tester.tap(find.widgetWithText(FormRow, 'Delete'));
      await tester.pumpAndSettle();

      expect(container.read(davSettingProvider), isNull);
    });

    testWidgets('toggles password visibility', (tester) async {
      await pumpForm(tester, const WebDAVForm(dav: _existing));

      expect(find.byGlyph(AppGlyphs.eye), findsOneWidget);
      await tester.tap(find.byGlyph(AppGlyphs.eye));
      await tester.pumpAndSettle();
      expect(find.byGlyph(AppGlyphs.eyeOff), findsOneWidget);
    });
  });
}

class _SnippetClient extends GitHubSyncClient {
  _SnippetClient(SnippetService service, {bool browser = false})
    : super(
        service: service,
        githubClientId: browser ? 'client' : '',
        giteeAuthorizationUrl: browser ? 'https://oauth.example.com' : '',
      );
  bool fail = false;
  bool closed = false;
  Completer<GitHubSession> authorization = Completer<GitHubSession>();
  CancelToken? authorizationCancel;

  @override
  Future<GitHubSession> authorize(
    String clientId, {
    required CancelToken cancel,
    required Future<void> Function(GitHubDeviceCode) onCode,
  }) async {
    authorizationCancel = cancel;
    await onCode(
      GitHubDeviceCode(
        service == SnippetService.github ? 'ABCD-1234' : '',
        Uri.parse(
          service == SnippetService.github
              ? 'https://github.com/login/device'
              : 'https://oauth.example.com/authorize?state=test',
        ),
      ),
    );
    return Future.any([
      authorization.future,
      cancel.whenCancel.then<GitHubSession>((error) => throw error),
    ]);
  }

  @override
  Future<GitHubSession> signInWithToken(String token) async {
    if (fail) throw const GitHubSyncException(GitHubSyncFailure.unauthorized);
    return GitHubSession(token: token, login: 'tester', userId: 7);
  }

  @override
  Future<List<GitHubBackup>> list(GitHubSession session) async => [];

  @override
  void close() {
    closed = true;
    super.close();
  }
}
