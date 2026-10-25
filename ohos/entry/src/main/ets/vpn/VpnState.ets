import { fileIo } from '@kit.CoreFileKit';

export interface VpnRequest {
  status: string;
  ipv6: boolean;
  dnsHijacking: boolean;
  stack: string;
  mtu: number;
  routes: string[];
  accepted: string[];
  blocked: string[];
}

export interface CoreRequest {
  endpoint: string;
  control: string;
}

export interface VpnCommand {
  action: string;
  status: string;
  request?: VpnRequest;
}

export function writeVpnState(path: string, state: string): void {
  const temporary = `${path}.tmp`;
  const file = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
  try { fileIo.writeSync(file.fd, state); } finally { fileIo.closeSync(file); }
  fileIo.renameSync(temporary, path);
}
