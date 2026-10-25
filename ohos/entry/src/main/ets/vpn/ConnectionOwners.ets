import { connection } from '@kit.NetworkKit';
import bundle from '@ohos.bundle';
import bridge from 'libflclash_vpn.so';
import { fileIo } from '@kit.CoreFileKit';
import { writeVpnState } from './VpnState';

interface OwnerRequest {
  id: number;
  protocol: string;
  local: string;
  remote: string;
}

function address(endpoint: string): connection.NetAddress {
  const separator = endpoint.lastIndexOf(':');
  const host = endpoint.substring(0, separator).replace('[', '').replace(']', '');
  return { address: host, port: Number(endpoint.substring(separator + 1)), family: host.includes(':') ? 2 : 1 };
}

export default class ConnectionOwners {
  private pending: boolean = false;
  private names: Set<string> = new Set();
  private path: string;

  constructor(path: string) {
    this.path = path;
    if (fileIo.accessSync(path)) {
      try { this.names = new Set(JSON.parse(fileIo.readTextSync(path)) as string[]); }
      catch (error) { console.warn(`FlClash known apps: ${(error as Error).message}`); }
    }
  }

  async poll(): Promise<void> {
    if (this.pending) return;
    const requests = JSON.parse(bridge.takeOwners()) as OwnerRequest[];
    if (requests.length === 0) return;
    this.pending = true;
    let changed = false;
    try {
      for (let offset = 0; offset < requests.length; offset += 8) {
        await Promise.all(requests.slice(offset, offset + 8).map(async (request: OwnerRequest): Promise<void> => {
          let uid = -1;
          let name = '';
          try {
            uid = await connection.getConnectOwnerUid(
              request.protocol === 'tcp' ? connection.ProtocolType.PROTO_TYPE_TCP : connection.ProtocolType.PROTO_TYPE_UDP,
              address(request.local), address(request.remote)
            );
            if (uid >= 0) name = await bundle.getNameForUid(uid);
            if (name && name !== 'com.follow.fl_clash' && !this.names.has(name) && this.names.size < 512) {
              this.names.add(name);
              changed = true;
            }
          } catch (error) {
            console.warn(`FlClash connection owner: ${(error as Error).message}`);
          }
          bridge.resolveOwner(request.id, uid, name);
        }));
      }
    } finally {
      this.pending = false;
      if (changed) writeVpnState(this.path, JSON.stringify(Array.from(this.names)));
    }
  }
}
