import { vpnExtension } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { MethodCall, MethodCallHandler, MethodResult } from '@ohos/flutter_ohos';
import { CoreRequest, VpnCommand, VpnRequest, writeVpnState } from '../vpn/VpnState';
import DiagnosticLog from '../vpn/DiagnosticLog';
import BackgroundTransfer from '../vpn/BackgroundTransfer';

export default class VpnPlugin implements MethodCallHandler {
  private want: Want = { bundleName: 'com.follow.fl_clash', abilityName: 'FlClashVpnAbility' };
  private active: boolean = false;
  private status: string = '';
  private control: string = '';
  private sequence: number = 0;
  private diagnostics: DiagnosticLog;
  private backgroundTransfer: BackgroundTransfer;

  constructor(diagnostics: DiagnosticLog, backgroundTransfer: BackgroundTransfer) {
    this.diagnostics = diagnostics;
    this.backgroundTransfer = backgroundTransfer;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.handle(call, result).catch((error: Error) => {
      this.diagnostics.record(`method_${call.method}_failed`, error.message);
      result.error('harmony_vpn_failed', error.message, null);
    });
  }

  private async wait(path: string, expected: string): Promise<void> {
    for (let attempt = 0; attempt < 600; attempt++) {
      if (fileIo.accessSync(path)) {
        const state = fileIo.readTextSync(path);
        if (state === expected) return;
        if (state.startsWith('error:') || state === 'stopped') throw new Error(state);
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 100));
    }
    throw new Error('VPN extension did not respond');
  }

  private async handle(call: MethodCall, result: MethodResult): Promise<void> {
    switch (call.method) {
      case 'enterLightweight':
        if (!this.active || !this.control) throw new Error('VPN Core is not running');
        const lightStatus = `${this.control}.light-${++this.sequence}`;
        const lightCommand: VpnCommand = {
          action: 'lightweight', status: lightStatus,
          runningSince: call.argument('runningSince') as number,
          tunnelStatus: this.status
        };
        writeVpnState(this.control, JSON.stringify(lightCommand));
        await this.wait(lightStatus, 'ready');
        result.success(true);
        break;
      case 'resumeCore':
        this.control = call.argument('control') as string;
        this.status = call.argument('status') as string ?? '';
        this.active = true;
        if (this.status) await this.backgroundTransfer.setRunning(true);
        result.success(true);
        break;
      case 'startCore':
        this.diagnostics.record('core_start_requested');
        const core = JSON.parse(call.argument('request') as string) as CoreRequest;
        this.control = core.control;
        await vpnExtension.startVpnExtensionAbility({
          bundleName: this.want.bundleName, abilityName: this.want.abilityName,
          parameters: { core: JSON.stringify(core) }
        });
        this.active = true;
        await this.wait(`${this.control}.core`, 'ready');
        this.diagnostics.record('core_ready');
        result.success(true);
        break;
      case 'stopCore':
        this.diagnostics.record('core_stop_requested');
        if (call.argument('control') !== this.control) {
          result.success(true);
          break;
        }
        if (call.argument('disconnected') !== true) await this.backgroundTransfer.setRunning(false);
        if (this.active) {
          const disconnected = call.argument('disconnected') === true;
          if (!fileIo.accessSync(`${this.control}.core`) || fileIo.readTextSync(`${this.control}.core`) !== 'stopped') {
            try {
              await vpnExtension.stopVpnExtensionAbility(this.want);
            } catch (error) {
              if (!disconnected) throw error as Error;
            }
          }
          if (!disconnected) await this.wait(`${this.control}.core`, 'stopped');
          this.active = false;
          this.status = '';
        }
        result.success(true);
        break;
      case 'start':
        this.diagnostics.record('tunnel_start_requested');
        if (!this.active) throw new Error('VPN Core is not running');
        const request = JSON.parse(call.argument('request') as string) as VpnRequest;
        this.status = request.status;
        const command: VpnCommand = { action: 'start', status: this.status, request };
        writeVpnState(this.control, JSON.stringify(command));
        await this.wait(this.status, 'ready');
        this.diagnostics.record('tunnel_ready');
        await this.backgroundTransfer.setRunning(true);
        result.success(true);
        break;
      case 'stop':
        this.diagnostics.record('tunnel_stop_requested');
        await this.backgroundTransfer.setRunning(false);
        if (this.active && this.status && fileIo.accessSync(`${this.control}.core`) &&
          fileIo.readTextSync(`${this.control}.core`) === 'ready') {
          this.sequence++;
          const status = `${this.control}.stop-${this.sequence}`;
          const stop: VpnCommand = { action: 'stop', status };
          writeVpnState(this.control, JSON.stringify(stop));
          await this.wait(status, 'stopped');
          this.status = '';
        }
        result.success(true);
        break;
      case 'updateTransfer':
        await this.backgroundTransfer.update(call.argument('up') as number, call.argument('down') as number);
        result.success(null);
        break;
      case 'status':
        result.success(this.active && this.status !== '' && fileIo.accessSync(this.status) &&
          fileIo.readTextSync(this.status) === 'ready' && fileIo.readTextSync(`${this.control}.core`) === 'ready');
        break;
      case 'diagnostic':
        this.diagnostics.record(call.argument('event') as string, call.argument('detail') as string);
        result.success(null);
        break;
      case 'diagnostics':
        result.success(await this.diagnostics.read());
        break;
      case 'canRecover':
        const eligible = this.diagnostics.canRecover();
        this.diagnostics.record('recovery_eligibility', `unfinishedSession=${eligible}`);
        result.success(eligible);
        break;
      default:
        result.notImplemented();
    }
  }
}
