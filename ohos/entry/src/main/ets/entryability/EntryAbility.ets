
import { FlutterAbility, FlutterEngine, MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { AbilityConstant, Want, bundleManager } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import InstalledApps from '../plugins/InstalledApps';
import VpnPlugin from '../plugins/VpnPlugin';
import SecureStoragePlugin from '../plugins/SecureStoragePlugin';
import FilePickerPlugin from '../plugins/FilePickerPlugin';
import DiagnosticLog from '../vpn/DiagnosticLog';
import BackgroundTransfer from '../vpn/BackgroundTransfer';

export default class EntryAbility extends FlutterAbility implements MethodCallHandler {
  private diagnostics?: DiagnosticLog;
  private backgroundTransfer?: BackgroundTransfer;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.diagnostics = new DiagnosticLog(this.context.filesDir, 'ui');
    this.diagnostics.record('ui_created',
      `lastExitReason=${launchParam.lastExitReason} lastExitMessage=${launchParam.lastExitMessage}`);
    this.diagnostics.watchSystemEvents();
    super.onCreate(want, launchParam);
  }

  onForeground(): void {
    super.onForeground();
    this.diagnostics?.record('ui_foreground');
    this.diagnostics?.sample('foreground');
  }

  onBackground(): void {
    this.diagnostics?.record('ui_background');
    super.onBackground();
  }

  onDestroy(): void {
    this.backgroundTransfer?.close();
    this.diagnostics?.record('ui_destroyed');
    this.diagnostics?.close();
    super.onDestroy();
  }

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    const messenger = flutterEngine.getDartExecutor().getBinaryMessenger();
    const diagnostics = this.diagnostics ?? new DiagnosticLog(this.context.filesDir, 'ui');
    this.backgroundTransfer = new BackgroundTransfer(this.context, diagnostics);
    new MethodChannel(messenger, 'com.follow.clash/vpn')
      .setMethodCallHandler(new VpnPlugin(diagnostics, this.backgroundTransfer));
    new MethodChannel(messenger, 'com.follow.clash/app').setMethodCallHandler(new InstalledApps(this.context));
    new MethodChannel(messenger, 'plugins.it_nomads.com/flutter_secure_storage').setMethodCallHandler(new SecureStoragePlugin());
    new MethodChannel(messenger, 'com.follow.clash/file_picker').setMethodCallHandler(new FilePickerPlugin(this.context));
    for (const name of ['plugins.flutter.io/path_provider', 'dev.fluttercommunity.plus/package_info',
      'dev.fluttercommunity.plus/device_info']) {
      new MethodChannel(messenger, name).setMethodCallHandler(this);
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'getApplicationSupportDirectory':
      case 'getApplicationDocumentsDirectory':
        result.success(this.context.filesDir);
        break;
      case 'getTemporaryDirectory':
        result.success(this.context.tempDir);
        break;
      case 'getApplicationCacheDirectory':
        result.success(this.context.cacheDir);
        break;
      case 'getDownloadsDirectory':
        result.success(null);
        break;
      case 'getAll':
        const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
        result.success(new Map<string, string>([
          ['appName', 'FlClashX'], ['packageName', info.name],
          ['version', info.versionName], ['buildNumber', info.versionCode.toString()]
        ]));
        break;
      case 'getDeviceInfo':
        result.success(new Map<string, Object>([
          ['sdkInt', deviceInfo.sdkApiVersion], ['model', deviceInfo.productModel],
          ['deviceType', deviceInfo.deviceType]
        ]));
        break;
      default:
        result.notImplemented();
    }
  }
}
