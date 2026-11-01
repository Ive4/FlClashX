import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import DiagnosticLog from './DiagnosticLog';

export default class BackgroundTransfer {
  private context: common.UIAbilityContext;
  private diagnostics: DiagnosticLog;
  private desired: boolean = false;
  private notificationId: number = -1;
  private taskId: number = -1;
  private operation: Promise<void> = Promise.resolve();
  private timer: number = -1;
  private lastUpdate: number = 0;
  private lastUp: number = -1;
  private lastDown: number = -1;
  private onCancel = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (info.id !== this.taskId) return;
    this.diagnostics.record('background_task_cancelled',
      `id=${info.id} reason=${info.reason} detail=${info.detailedReason}`);
    this.notificationId = -1;
    this.taskId = -1;
  };

  constructor(context: common.UIAbilityContext, diagnostics: DiagnosticLog) {
    this.context = context;
    this.diagnostics = diagnostics;
    try { backgroundTaskManager.on('continuousTaskCancel', this.onCancel); }
    catch (_) { this.diagnostics.record('background_task_watch_failed'); }
  }

  setRunning(running: boolean): Promise<void> {
    this.desired = running;
    this.operation = this.operation.then(() => this.reconcile()).catch((error: Error) => {
      this.diagnostics.record('background_task_failed', error.message);
    });
    return this.operation;
  }

  private async reconcile(): Promise<void> {
    if (this.desired && this.notificationId === -1) {
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: 'com.follow.fl_clash', abilityName: 'EntryAbility' }],
        actionType: wantAgent.OperationType.START_ABILITY, requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      if (!this.desired) return;
      const notification = await backgroundTaskManager.startBackgroundRunning(this.context, ['dataTransfer'], agent);
      this.notificationId = notification.notificationId;
      this.taskId = notification.continuousTaskId ?? -1;
      this.lastUp = -1;
      this.lastDown = -1;
      this.lastUpdate = 0;
      this.diagnostics.record('background_task_started', `id=${this.taskId} notification=${this.notificationId}`);
      this.diagnostics.sample('background_task_started');
      if (this.timer === -1) {
        this.timer = setInterval(() => {
          if (!this.diagnostics.canRecover()) this.setRunning(false);
        }, 30000);
      }
    }
    if (!this.desired) {
      if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
      if (this.notificationId !== -1) {
        await backgroundTaskManager.stopBackgroundRunning(this.context);
        this.notificationId = -1;
        this.taskId = -1;
        this.diagnostics.record('background_task_stopped');
      }
    }
  }

  update(up: number, down: number): Promise<void> {
    this.operation = this.operation.then(() => this.publish(up, down));
    return this.operation;
  }

  private async publish(up: number, down: number): Promise<void> {
    if (this.notificationId === -1 || !this.desired ||
      Date.now() - this.lastUpdate < 30000 || (up === this.lastUp && down === this.lastDown)) return;
    const id = this.notificationId;
    try {
      const text = `↑ ${Math.floor(up / 1024)} KiB  ↓ ${Math.floor(down / 1024)} KiB`;
      await notificationManager.publish({
        id, notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: { typeCode: 8, title: 'FlClashX VPN', text }
        },
        template: { name: 'downloadTemplate', data: { title: 'FlClashX VPN', fileName: text } }
      });
      if (this.notificationId === id) {
        this.lastUpdate = Date.now();
        this.lastUp = up;
        this.lastDown = down;
        this.diagnostics.record('background_transfer_updated', `up=${up} down=${down}`);
      }
    } catch (error) {
      this.diagnostics.record('background_transfer_update_failed', (error as Error).message);
    }
  }

  close(): void {
    this.setRunning(false);
    try { backgroundTaskManager.off('continuousTaskCancel', this.onCancel); } catch (_) {}
  }
}
