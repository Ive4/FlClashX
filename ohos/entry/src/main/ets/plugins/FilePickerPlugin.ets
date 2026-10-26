import { common } from '@kit.AbilityKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { MethodCall, MethodCallHandler, MethodResult } from '@ohos/flutter_ohos';

export default class FilePickerPlugin implements MethodCallHandler {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.handle(call, result).catch(() => result.error('file_picker_failed', 'HarmonyOS file operation failed', null));
  }

  private async handle(call: MethodCall, result: MethodResult): Promise<void> {
    const documentPicker = new picker.DocumentViewPicker(this.context);
    if (call.method === 'pickFile') {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const uris = await documentPicker.select(options);
      if (uris.length === 0) {
        result.success(null);
        return;
      }
      const name = new fileUri.FileUri(uris[0]).name.replace(/[\\/]/g, '_');
      const path = `${this.context.cacheDir}/picked-${Date.now()}-${name}`;
      const source = await fileIo.open(uris[0], fileIo.OpenMode.READ_ONLY);
      try {
        await fileIo.copyFile(source.fd, path);
      } finally {
        await fileIo.close(source);
      }
      result.success(path);
    } else if (call.method === 'saveFile') {
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [call.argument('fileName') as string];
      const uris = await documentPicker.save(options);
      if (uris.length === 0) {
        result.success(null);
        return;
      }
      const target = await fileIo.open(uris[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try {
        const path = call.argument('path') as string | null;
        if (path) {
          await fileIo.copyFile(path, target.fd);
        } else {
          const bytes = call.argument('bytes') as Uint8Array;
          let offset = 0;
          while (offset < bytes.byteLength) {
            const written = await fileIo.write(target.fd, bytes.slice(offset).buffer);
            if (written === 0) throw new Error('File write made no progress');
            offset += written;
          }
        }
        await fileIo.fsync(target.fd);
      } finally {
        await fileIo.close(target);
      }
      result.success(uris[0]);
    } else {
      result.notImplemented();
    }
  }
}
