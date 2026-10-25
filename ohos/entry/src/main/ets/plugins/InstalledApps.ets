import bundle from '@ohos.bundle';
import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { MethodCall, MethodCallHandler, MethodResult } from '@ohos/flutter_ohos';

interface PackageRecord {
  packageName: string;
  label: string;
  system: boolean;
  internet: boolean;
  lastUpdateTime: number;
}

interface AppMetadata {
  systemApp: boolean;
}

interface LaunchAbility {
  bundleName: string;
  name: string;
  applicationInfo: AppMetadata;
}

export default class InstalledApps implements MethodCallHandler {
  private abilities = new Map<string, LaunchAbility>();
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.handle(call, result).catch((error: Error) => {
      console.error(`FlClash apps ${call.method}: ${JSON.stringify(error)}`);
      result.error('harmony_app_query_failed', error.message, null);
    });
  }

  private async handle(call: MethodCall, result: MethodResult): Promise<void> {
    switch (call.method) {
      case 'getPackages':
        result.success(JSON.stringify(await this.getPackages(call.argument('knownPackages') as string[] ?? [])));
        break;
      case 'getPackageIcon':
        result.success(await this.getIcon(call.argument('packageName') as string));
        break;
      case 'isInstalledAppsPermissionGranted':
      case 'requestInstalledAppsPermission':
        await this.query();
        result.success(true);
        break;
      case 'moveTaskToBack':
        await this.context.moveAbilityToBackground();
        result.success(true);
        break;
      default:
        result.notImplemented();
    }
  }

  private async query(): Promise<LaunchAbility[]> {
    const abilities = await bundle.queryAbilityByWant({
      action: 'action.system.home', entities: ['entity.system.home']
    }, bundle.BundleFlag.GET_ABILITY_INFO_WITH_APPLICATION);
    console.info(`FlClash apps query: ${abilities.length}`);
    return abilities;
  }

  private async getPackages(knownPackages: string[]): Promise<PackageRecord[]> {
    const abilities = await this.query();
    this.abilities.clear();
    for (const ability of abilities) {
      if (!this.abilities.has(ability.bundleName)) this.abilities.set(ability.bundleName, ability);
    }
    const path = `${this.context.filesDir}/vpn-applications.json`;
    const known = new Set(knownPackages);
    if (fileIo.accessSync(path)) {
      for (const name of JSON.parse(fileIo.readTextSync(path)) as string[]) known.add(name);
    }
    for (const name of known) {
      if (this.abilities.has(name) || name === 'com.follow.fl_clash') continue;
      this.abilities.set(name, {
        bundleName: name, name: '', applicationInfo: { systemApp: false }
      });
      try {
        const matches = await bundle.queryAbilityByWant({ bundleName: name, action: 'action.system.home' },
          bundle.BundleFlag.GET_ABILITY_INFO_WITH_APPLICATION);
        if (matches.length > 0) this.abilities.set(name, {
          bundleName: matches[0].bundleName, name: matches[0].name,
          applicationInfo: { systemApp: matches[0].applicationInfo.systemApp }
        });
      } catch (error) {
        console.warn(`FlClash app ability: ${(error as Error).message}`);
      }
    }
    const records: PackageRecord[] = [];
    const entries = Array.from(this.abilities.values());
    for (let offset = 0; offset < entries.length; offset += 6) {
      const batch = await Promise.all(entries.slice(offset, offset + 6).map(async (ability: LaunchAbility): Promise<PackageRecord> => {
        let label = ability.bundleName;
        let internet = true;
        let updateTime = 0;
        try {
          const info = await bundle.getBundleInfo(ability.bundleName, bundle.BundleFlag.GET_BUNDLE_WITH_REQUESTED_PERMISSION);
          internet = known.has(ability.bundleName) || (info.reqPermissions ?? []).includes('ohos.permission.INTERNET');
          updateTime = info.updateTime;
        } catch (error) {
          console.warn(`FlClash app metadata: ${(error as Error).message}`);
        }
        try {
          label = await bundle.getAbilityLabel(ability.bundleName, ability.name) || label;
        } catch (error) {
          console.warn(`FlClash app label: ${(error as Error).message}`);
        }
        return {
          packageName: ability.bundleName,
          label: label || ability.bundleName,
          system: ability.applicationInfo.systemApp,
          internet,
          lastUpdateTime: updateTime
        };
      }));
      records.push(...batch);
    }
    return records;
  }

  private async getIcon(packageName: string): Promise<string | null> {
    const ability = this.abilities.get(packageName);
    if (!ability || !ability.name) return null;
    const path = `${this.context.cacheDir}/app-${encodeURIComponent(packageName)}.png`;
    const pixels = await bundle.getAbilityIcon(packageName, ability.name);
    const packer = image.createImagePacker();
    try {
      const data = await packer.packing(pixels, { format: 'image/png', quality: 100 });
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try { fileIo.writeSync(file.fd, data); } finally { fileIo.closeSync(file); }
      return path;
    } finally {
      await pixels.release();
      await packer.release();
    }
  }
}
