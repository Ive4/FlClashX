import { fileIo } from '@kit.CoreFileKit';
import { hiAppEvent, hidebug } from '@kit.PerformanceAnalysisKit';
import process from '@ohos.process';
import { writeVpnState } from './VpnState';

interface SystemEventDetails {
  time?: number;
  reason?: string;
  foreground?: boolean;
  pid?: number;
  process_name?: string;
  app_running_unique_id?: string;
}

interface SessionState {
  pid: number;
  session: string;
  stage: string;
  active: boolean;
  time: string;
}

export default class DiagnosticLog {
  private directory: string;
  private path: string;
  private role: string;
  private watcher?: hiAppEvent.Watcher;
  private timer: number = -1;
  private startupTimer: number = -1;
  private sampling: boolean = false;
  private session: string = '';
  private static readonly limit: number = 128 * 1024;

  constructor(filesDir: string, role: string) {
    this.role = role;
    this.directory = `${filesDir}/diagnostics`;
    this.path = `${this.directory}/${role}.jsonl`;
    try { fileIo.mkdirSync(this.directory, true); } catch (_) {}
  }

  private clean(value: string): string {
    return value.replace(/https?:\/\/\S+/gi, '[URL]')
      .replace(/(token|password|secret|authorization)[=: ]+\S+/gi, '$1=[redacted]')
      .slice(0, 768);
  }

  record(event: string, detail: string = ''): void {
    try {
      const line = JSON.stringify({
        time: new Date().toISOString(), pid: process.pid, role: this.role,
        session: this.session, event: event.slice(0, 64), detail: this.clean(detail)
      }) + '\n';
      console.info(`FlClash diagnostic ${line.trim()}`);
      if (fileIo.accessSync(this.path) && fileIo.statSync(this.path).size + line.length * 4 > DiagnosticLog.limit) {
        const previous = `${this.path}.1`;
        if (fileIo.accessSync(previous)) fileIo.unlinkSync(previous);
        fileIo.renameSync(this.path, previous);
      }
      const file = fileIo.openSync(this.path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.APPEND);
      try { fileIo.writeSync(file.fd, line); } finally { fileIo.closeSync(file); }
    } catch (_) {
      console.warn('FlClash diagnostic write failed');
    }
  }

  beginSession(control: string): void {
    this.session = control.substring(control.lastIndexOf('/') + 1).slice(0, 100);
    try {
      const path = `${this.directory}/vpn-session.json`;
      if (fileIo.accessSync(path)) {
        const previous = JSON.parse(fileIo.readTextSync(path)) as SessionState;
        if (previous.active) {
          this.record('previous_session_unfinished',
            `pid=${previous.pid} session=${previous.session} stage=${previous.stage} time=${previous.time}`);
        }
      }
    } catch (_) { this.record('previous_session_unreadable'); }
    this.state('extension_created', true);
  }

  state(stage: string, active: boolean): void {
    this.record(stage);
    try {
      const state: SessionState = {
        pid: process.pid, session: this.session, stage, active, time: new Date().toISOString()
      };
      writeVpnState(`${this.directory}/vpn-session.json`, JSON.stringify(state));
    } catch (_) { this.record('session_state_write_failed'); }
  }

  sample(stage: string): void {
    if (this.sampling) return;
    this.sampling = true;
    hidebug.getAppNativeMemInfoAsync().then((memory: hidebug.NativeMemInfo) => {
      this.record('memory_sample',
        `stage=${stage} rssKiB=${memory.rss} pssKiB=${memory.pss} privateDirtyKiB=${memory.privateDirty}${this.memoryContext()}`);
    }).catch(() => this.record('memory_sample_failed')).finally(() => { this.sampling = false; });
  }

  private memoryContext(): string {
    let priority: string = 'unavailable';
    try {
      const buffer = new ArrayBuffer(32);
      const file = fileIo.openSync('/proc/self/oom_score_adj', fileIo.OpenMode.READ_ONLY);
      let length: number = 0;
      try { length = fileIo.readSync(file.fd, buffer); } finally { fileIo.closeSync(file); }
      let value: string = '';
      for (const byte of new Uint8Array(buffer, 0, length)) value += String.fromCharCode(byte);
      if (/^-?\d+$/.test(value.trim())) priority = value.trim().slice(0, 8);
    } catch (_) {}
    let detail: string = ` oomScoreAdj=${priority}`;
    try {
      const memory = hidebug.getSystemMemInfo();
      detail += ` systemAvailableKiB=${memory.availableMem} systemTotalKiB=${memory.totalMem}`;
    } catch (_) {}
    return detail;
  }

  startSampling(): void {
    this.sample('start');
    if (this.startupTimer === -1) {
      this.startupTimer = setTimeout(() => {
        this.startupTimer = -1;
        this.sample('startup_settled');
      }, 15000);
    }
    if (this.timer === -1) this.timer = setInterval(() => this.sample('heartbeat'), 60000);
  }

  watchSystemEvents(): void {
    if (this.watcher) return;
    this.watcher = {
      name: `FlClash${this.role}Diagnostics`,
      appEventFilters: [{ domain: hiAppEvent.domain.OS, names: [
        hiAppEvent.event.APP_KILLED, hiAppEvent.event.APP_CRASH,
        hiAppEvent.event.APP_FREEZE, hiAppEvent.event.RESOURCE_OVERLIMIT
      ] }],
      onReceive: (_domain: string, groups: hiAppEvent.AppEventGroup[]): void => {
        for (const group of groups) {
          for (const event of group.appEventInfos) {
            const params = event.params as SystemEventDetails;
            this.record(`system_${event.name}`, JSON.stringify({
              time: params.time, reason: params.reason, foreground: params.foreground,
              pid: params.pid, process: params.process_name, run: params.app_running_unique_id
            }));
          }
        }
      }
    };
    try { hiAppEvent.addWatcher(this.watcher); }
    catch (_) { this.record('system_event_watch_failed'); }
  }

  async read(): Promise<string> {
    const entries: string[] = [];
    for (const role of ['ui', 'vpn']) {
      for (const suffix of ['.1', '']) {
        const path = `${this.directory}/${role}.jsonl${suffix}`;
        if (!fileIo.accessSync(path)) continue;
        try { entries.push(await fileIo.readText(path, { length: DiagnosticLog.limit })); }
        catch (_) { entries.push(`[${role}${suffix}: diagnostic read failed]`); }
      }
    }
    return entries.join('\n');
  }

  canRecover(): boolean {
    try {
      const state = JSON.parse(fileIo.readTextSync(`${this.directory}/vpn-session.json`)) as SessionState;
      return state.active;
    } catch (_) {
      return false;
    }
  }

  close(): void {
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
    if (this.startupTimer !== -1) { clearTimeout(this.startupTimer); this.startupTimer = -1; }
    if (this.watcher) {
      try { hiAppEvent.removeWatcher(this.watcher); } catch (_) {}
      this.watcher = undefined;
    }
  }
}
