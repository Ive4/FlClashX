import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import bridge from 'libflclash_vpn.so';
import { fileIo } from '@kit.CoreFileKit';
import { CoreRequest, VpnCommand, VpnRequest, writeVpnState } from './VpnState';
import ConnectionOwners from './ConnectionOwners';

export default class FlClashVpnAbility extends VpnExtensionAbility {
  private connection?: vpnExtension.VpnConnection;
  private timer: number = -1;
  private destroyed: boolean = false;
  private status: string = '';
  private stage: string = 'initializing';
  private control: string = '';
  private processing: boolean = false;
  private lastCommand: string = '';
  private hasInterface: boolean = false;
  private owners?: ConnectionOwners;

  onCreate(want: Want): void {
    const request = JSON.parse(want.parameters?.core as string) as CoreRequest;
    this.control = request.control;
    this.owners = new ConnectionOwners(`${this.context.filesDir}/vpn-applications.json`);
    this.run(request).catch((error: Error) => {
      console.error(`FlClash Core: ${error.message}`);
      writeVpnState(`${this.control}.core`, `error:${error.message}`);
      this.stopExtension();
    });
  }

  private async run(request: CoreRequest): Promise<void> {
    this.connection = vpnExtension.createVpnConnection(this.context);
    await this.connection.protectProcessNet();
    const operation = bridge.runCore(request.endpoint);
    writeVpnState(`${this.control}.core`, 'ready');
    this.timer = setInterval(() => {
      this.consume().catch((error: Error) => console.error(error.message));
      this.owners?.poll().catch((error: Error) => console.error(error.message));
    }, 100);
    await operation;
    writeVpnState(`${this.control}.core`, 'stopped');
    await this.stopExtension();
  }

  private async stopExtension(): Promise<void> {
    if (this.destroyed) return;
    await vpnExtension.stopVpnExtensionAbility({ bundleName: 'com.follow.fl_clash', abilityName: 'FlClashVpnAbility' });
  }

  private async consume(): Promise<void> {
    if (this.processing || this.destroyed || !fileIo.accessSync(this.control)) return;
    const text = fileIo.readTextSync(this.control);
    if (text === this.lastCommand) return;
    this.lastCommand = text;
    this.processing = true;
    const command = JSON.parse(text) as VpnCommand;
    this.status = command.status;
    try {
      await this.stopTunnel();
      if (command.action === 'start' && command.request) await this.start(command.request);
      else writeVpnState(this.status, 'stopped');
    } catch (error) {
      await this.stopTunnel();
      const message = (error as Error).message;
      console.error(`FlClash VPN ${this.stage}: ${message}`);
      writeVpnState(this.status, `error:${this.stage}: ${message}`);
    } finally {
      this.processing = false;
    }
  }

  private async start(request: VpnRequest): Promise<void> {
    const addresses: vpnExtension.LinkAddress[] = [
      { address: { address: '172.19.0.1', family: 1 }, prefixLength: 30 }
    ];
    if (request.ipv6) addresses.push({ address: { address: 'fdfe:dcba:9876::1', family: 2 }, prefixLength: 126 });
    const routeAddresses = Array.from(new Set([
      ...(request.routes.length > 0 ? request.routes : ['0.0.0.0/0', '::/0']),
      '172.19.0.2/32'
    ]));
    const routes: vpnExtension.RouteInfo[] = [];
    for (const cidr of routeAddresses) {
      const parts = cidr.split('/');
      const ipv6 = parts[0].includes(':');
      if (ipv6 && !request.ipv6) continue;
      routes.push({
        interface: 'vpn-tun', destination: { address: { address: parts[0], family: ipv6 ? 2 : 1 }, prefixLength: Number(parts[1]) },
        gateway: { address: ipv6 ? '::' : '0.0.0.0', family: ipv6 ? 2 : 1 }, hasGateway: false,
        isDefaultRoute: parts[1] === '0'
      });
    }
    const config: vpnExtension.VpnConfig = {
      addresses, routes, dnsAddresses: ['172.19.0.2'], mtu: request.mtu,
      isIPv4Accepted: true, isIPv6Accepted: request.ipv6, isBlocking: false
    };
    if (request.accepted.length > 0) config.trustedApplications = request.accepted;
    else config.blockedApplications = request.blocked;
    if (!this.connection) throw new Error('VPN extension has stopped');
    this.stage = 'create virtual interface';
    await this.connection.protectProcessNet();
    const fd = await this.connection.create(config);
    this.hasInterface = true;
    if (this.destroyed) { await this.connection.destroy(); return; }
    this.stage = 'attach Core';
    await bridge.startTun(fd, JSON.stringify({
      stack: request.stack,
      address: request.ipv6 ? '172.19.0.1/30,fdfe:dcba:9876::1/126' : '172.19.0.1/30',
      dns: request.dnsHijacking ? '0.0.0.0,::' : '172.19.0.2', mtu: request.mtu
    }));
    if (this.destroyed) { await bridge.stopTun(); return; }
    writeVpnState(this.status, 'ready');
  }

  private async stopTunnel(): Promise<void> {
    await bridge.stopTun();
    if (this.connection && this.hasInterface) {
      await this.connection.destroy();
      this.hasInterface = false;
    }
  }

  onDestroy(): void {
    this.destroyed = true;
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
    bridge.stopCore();
    writeVpnState(`${this.control}.core`, 'stopped');
    if (this.status) writeVpnState(this.status, 'stopped');
    this.stopTunnel().catch((error: Error) => console.error(`VPN teardown: ${error.message}`));
  }
}
