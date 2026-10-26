import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { MethodCall, MethodCallHandler, MethodResult } from '@ohos/flutter_ohos';

export default class SecureStoragePlugin implements MethodCallHandler {
  private readonly label: Uint8Array = new util.TextEncoder().encodeInto('flclashx.secure-storage.v1');

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.handle(call, result).catch((error: BusinessError) => {
      result.error('secure_storage_failed', `HarmonyOS secure storage error ${error.code}`, null);
    });
  }

  private encode(value: string): Uint8Array {
    return new util.TextEncoder().encodeInto(value);
  }

  private decode(value: asset.Value): string {
    return util.TextDecoder.create('utf-8').decodeToString(value as Uint8Array);
  }

  private query(key?: string): asset.AssetMap {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.DATA_LABEL_NORMAL_1, this.label);
    if (key !== undefined) query.set(asset.Tag.ALIAS, this.encode(key));
    return query;
  }

  private async find(key?: string, secret: boolean = true): Promise<Array<asset.AssetMap>> {
    const query = this.query(key);
    query.set(asset.Tag.RETURN_TYPE, secret ? asset.ReturnType.ALL : asset.ReturnType.ATTRIBUTES);
    try {
      return await asset.query(query);
    } catch (error) {
      if ((error as BusinessError).code === asset.ErrorCode.NOT_FOUND) return [];
      throw error as Error;
    }
  }

  private async handle(call: MethodCall, result: MethodResult): Promise<void> {
    const key = call.argument('key') as string;
    switch (call.method) {
      case 'read':
        const rows = await this.find(key);
        result.success(rows.length === 0 ? null : this.decode(rows[0].get(asset.Tag.SECRET)!));
        break;
      case 'write':
        const attributes = this.query(key);
        attributes.set(asset.Tag.SECRET, this.encode(call.argument('value') as string));
        attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
        attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
        await asset.add(attributes);
        result.success(null);
        break;
      case 'containsKey':
        result.success((await this.find(key, false)).length !== 0);
        break;
      case 'readAll':
        const values = new Map<string, string>();
        for (const item of await this.find(undefined, false)) {
          const alias = this.decode(item.get(asset.Tag.ALIAS)!);
          const found = await this.find(alias);
          if (found.length !== 0) values.set(alias, this.decode(found[0].get(asset.Tag.SECRET)!));
        }
        result.success(values);
        break;
      case 'delete':
      case 'deleteAll':
        try {
          await asset.remove(this.query(call.method === 'delete' ? key : undefined));
        } catch (error) {
          if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) throw error as Error;
        }
        result.success(null);
        break;
      default:
        result.notImplemented();
    }
  }
}
