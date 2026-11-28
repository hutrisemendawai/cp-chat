import type { Logger } from '../lib/logger.js';
import type { CallSignalingService } from './call-signaling.js';

const RING_SWEEP_INTERVAL_MS = 5_000;
const GHOST_SWEEP_INTERVAL_MS = 60_000;

/**
 * Periodic sweeper running inside the REST API process:
 *  - Every 5 s: marks expired ringing 1:1 calls as `missed` and dismisses callee rings.
 *  - Every 60 s: reconciles active calls whose LiveKit room has vanished (missed webhook).
 */
export class CallSweeper {
  private ringTimer: NodeJS.Timeout | null = null;
  private ghostTimer: NodeJS.Timeout | null = null;
  private runningRing = false;
  private runningGhost = false;

  constructor(
    private readonly signaling: CallSignalingService,
    private readonly logger: Logger,
  ) {}

  start(): void {
    if (this.ringTimer) return;

    this.ringTimer = setInterval(() => {
      if (this.runningRing) return;
      this.runningRing = true;
      void this.signaling
        .sweepExpiredRinging()
        .catch((error) => this.logger.warn({ err: error }, 'call ringing sweep failed'))
        .finally(() => {
          this.runningRing = false;
        });
    }, RING_SWEEP_INTERVAL_MS);
    this.ringTimer.unref?.();

    this.ghostTimer = setInterval(() => {
      if (this.runningGhost) return;
      this.runningGhost = true;
      void this.signaling
        .reconcileGhostRooms()
        .catch((error) => this.logger.warn({ err: error }, 'call ghost-room sweep failed'))
        .finally(() => {
          this.runningGhost = false;
        });
    }, GHOST_SWEEP_INTERVAL_MS);
    this.ghostTimer.unref?.();
  }

  stop(): void {
    if (this.ringTimer) {
      clearInterval(this.ringTimer);
      this.ringTimer = null;
    }
    if (this.ghostTimer) {
      clearInterval(this.ghostTimer);
      this.ghostTimer = null;
    }
  }
}
