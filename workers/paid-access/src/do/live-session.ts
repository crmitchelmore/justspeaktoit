/**
 * Live transcription WebSocket proxy.
 *
 * A Durable Object owns each live session so that the quota reservation taken
 * at connect time is guaranteed to be finalised or released exactly once, even
 * if the client vanishes mid-sentence. Cloudflare's WebSocket support lets us
 * hold both the client socket and the upstream provider socket in one place and
 * relay between them; the vendor credential is attached to the upstream socket
 * inside the Worker and never reaches the device.
 *
 * Sessions are bounded: an alarm closes the session at `maxSessionSeconds`
 * regardless of client behaviour, so a forgotten tab cannot burn a month of
 * quota.
 *
 * Metering is settled here too, not by the client. Whatever ends the session —
 * the duration alarm, an abrupt disconnect, an upstream failure — `settle()`
 * finalises the quota reservation from the server's own measurement. The
 * client-facing finalise route only reconciles the ledger afterwards, and can
 * therefore be skipped entirely without any usage going unmetered.
 */

import { QuotaSettlement } from '../quota.js';

export interface LiveSessionInit {
  readonly userId: string;
  readonly reservationId: string;
  /**
   * The period the reservation was taken against. Carried through the session so
   * the ledger row lands in the same month the quota was committed to — a
   * session that starts on the last day of a month and finalises on the first of
   * the next would otherwise split its accounting across two periods.
   */
  readonly billingPeriod: string;
  readonly upstreamUrl: string;
  readonly upstreamProtocolHeader: string;
  readonly maxSessionSeconds: number;
  readonly connectTimeoutMs: number;
  readonly correlationId: string;
}

interface SessionMetadata extends LiveSessionInit {
  readonly startedAtMs: number;
}

/**
 * What is safe to write to durable storage.
 *
 * `upstreamProtocolHeader` carries the raw vendor API key. The upstream socket
 * is opened once, inside the same request that receives it, so persisting the
 * credential would buy nothing and leave a long-lived secret at rest in every
 * live session's storage.
 */
type StoredSessionMetadata = Omit<SessionMetadata, 'upstreamProtocolHeader'>;

/** The subset of bindings this Durable Object is allowed to reach. */
export interface LiveSessionEnv {
  readonly QUOTA: DurableObjectNamespace;
}

const METADATA_KEY = 'metadata';
const SETTLED_KEY = 'settled';
const OUTCOME_KEY = 'outcome';
const RECONCILED_KEY = 'reconciled';
const OUTCOME_PATH = '/outcome';
/** POSTed by the finalise route to claim the outcome exactly once. */
const RECONCILE_PATH = '/outcome/reconcile';

export interface LiveSessionOutcome {
  readonly userId: string;
  readonly reservationId: string;
  /** The reservation's period, not the period the session happened to end in. */
  readonly billingPeriod: string;
  readonly elapsedSeconds: number;
  readonly closed: boolean;
}

/**
 * Answer to a reconciliation claim.
 *
 * `alreadyReconciled` is what stops a replayed finalise call appending a second
 * `usage_ledger` row: the first claim wins, every later one is told so.
 */
export interface LiveSessionReconciliation {
  readonly outcome: LiveSessionOutcome | null;
  readonly alreadyReconciled: boolean;
}

export class LiveSessionDurableObject implements DurableObject {
  private readonly state: DurableObjectState;
  private readonly quota: QuotaSettlement;
  private client: WebSocket | null = null;
  private upstream: WebSocket | null = null;
  private metadata: SessionMetadata | null = null;
  private settled = false;

  constructor(state: DurableObjectState, env: LiveSessionEnv) {
    this.state = state;
    this.quota = new QuotaSettlement(env.QUOTA);
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === OUTCOME_PATH) {
      const stored = await this.state.storage.get<LiveSessionOutcome>(OUTCOME_KEY);
      return Response.json(stored ?? null);
    }
    if (url.pathname === RECONCILE_PATH) {
      return Response.json(await this.claimReconciliation());
    }

    if (request.headers.get('upgrade') !== 'websocket') {
      return new Response('Expected WebSocket upgrade', { status: 426 });
    }

    // One reservation, one socket. A second upgrade for the same Durable Object
    // would replace `this.client`/`this.upstream` and orphan the first relay,
    // which then never settles its share of the reservation.
    if (this.client !== null || (await this.state.storage.get<StoredSessionMetadata>(METADATA_KEY))) {
      return new Response('Live session is already in use', { status: 409 });
    }

    const init = JSON.parse(request.headers.get('x-session-init') ?? '{}') as Partial<LiveSessionInit>;
    if (
      typeof init.userId !== 'string' ||
      typeof init.reservationId !== 'string' ||
      typeof init.billingPeriod !== 'string' ||
      typeof init.upstreamUrl !== 'string'
    ) {
      return new Response('Invalid session initialisation', { status: 400 });
    }

    const metadata: SessionMetadata = {
      userId: init.userId,
      reservationId: init.reservationId,
      billingPeriod: init.billingPeriod,
      upstreamUrl: init.upstreamUrl,
      upstreamProtocolHeader: init.upstreamProtocolHeader ?? '',
      maxSessionSeconds: init.maxSessionSeconds ?? 1_800,
      connectTimeoutMs: init.connectTimeoutMs ?? 15_000,
      correlationId: init.correlationId ?? 'unknown',
      startedAtMs: Date.now(),
    };
    this.metadata = metadata;
    await this.persistMetadata(metadata);

    let upstreamResponse: Response;
    try {
      upstreamResponse = await this.connectUpstream(metadata);
    } catch {
      await this.settle(false);
      return new Response('Upstream provider is unavailable', { status: 502 });
    }

    const upstream = upstreamResponse.webSocket;
    if (!upstream) {
      await this.settle(false);
      return new Response('Upstream provider did not accept the WebSocket', { status: 502 });
    }

    const pair = new WebSocketPair();
    const clientSide = pair[0];
    const serverSide = pair[1];

    upstream.accept();
    serverSide.accept();
    this.upstream = upstream;
    this.client = serverSide;

    this.wireRelay(serverSide, upstream);

    // Hard ceiling on session duration, enforced server-side.
    await this.state.storage.setAlarm(Date.now() + metadata.maxSessionSeconds * 1_000);

    return new Response(null, { status: 101, webSocket: clientSide });
  }

  /** Writes everything about the session except the vendor credential. */
  private async persistMetadata(metadata: SessionMetadata): Promise<void> {
    const stored: StoredSessionMetadata = {
      userId: metadata.userId,
      reservationId: metadata.reservationId,
      billingPeriod: metadata.billingPeriod,
      upstreamUrl: metadata.upstreamUrl,
      maxSessionSeconds: metadata.maxSessionSeconds,
      connectTimeoutMs: metadata.connectTimeoutMs,
      correlationId: metadata.correlationId,
      startedAtMs: metadata.startedAtMs,
    };
    await this.state.storage.put(METADATA_KEY, stored);
  }

  /**
   * Hands the settled outcome to the first caller that asks for it.
   *
   * Reconciliation appends a ledger row, so it must happen at most once. The
   * marker is written before the outcome is returned, which is why a replayed
   * finalise sees `alreadyReconciled` instead of a fresh outcome to bill again.
   */
  private async claimReconciliation(): Promise<LiveSessionReconciliation> {
    return this.state.blockConcurrencyWhile(async () => {
      const outcome = (await this.state.storage.get<LiveSessionOutcome>(OUTCOME_KEY)) ?? null;
      if (outcome === null) {
        return { outcome: null, alreadyReconciled: false };
      }
      if ((await this.state.storage.get<boolean>(RECONCILED_KEY)) === true) {
        return { outcome, alreadyReconciled: true };
      }
      await this.state.storage.put(RECONCILED_KEY, true);
      return { outcome, alreadyReconciled: false };
    });
  }

  private async connectUpstream(metadata: SessionMetadata): Promise<Response> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), metadata.connectTimeoutMs);
    try {
      return await fetch(metadata.upstreamUrl.replace(/^wss:/, 'https:'), {
        headers: {
          upgrade: 'websocket',
          authorization: metadata.upstreamProtocolHeader,
        },
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timer);
    }
  }

  private wireRelay(clientSocket: WebSocket, upstreamSocket: WebSocket): void {
    clientSocket.addEventListener('message', (event) => {
      try {
        upstreamSocket.send(event.data as string | ArrayBuffer);
      } catch {
        void this.shutdown(1011, 'relay failure');
      }
    });
    upstreamSocket.addEventListener('message', (event) => {
      try {
        clientSocket.send(event.data as string | ArrayBuffer);
      } catch {
        void this.shutdown(1011, 'relay failure');
      }
    });

    clientSocket.addEventListener('close', () => void this.shutdown(1000, 'client closed'));
    upstreamSocket.addEventListener('close', () => void this.shutdown(1000, 'upstream closed'));
    clientSocket.addEventListener('error', () => void this.shutdown(1011, 'client error'));
    upstreamSocket.addEventListener('error', () => void this.shutdown(1011, 'upstream error'));
  }

  async alarm(): Promise<void> {
    await this.shutdown(1000, 'session duration limit reached');
  }

  private async shutdown(code: number, reason: string): Promise<void> {
    for (const socket of [this.client, this.upstream]) {
      try {
        socket?.close(code, reason);
      } catch {
        // Already closed; nothing to do.
      }
    }
    this.client = null;
    this.upstream = null;
    await this.settle(true);
  }

  /**
   * Records the measured session duration and meters it, exactly once.
   *
   * Every way a session can end funnels through here — the duration alarm, a
   * client that disappears, an upstream that drops — and each of them finalises
   * the reservation. Metering therefore never depends on the client calling the
   * finalise route; that route only reconciles the ledger afterwards.
   *
   * `settled` (in memory, plus a durable copy for a restarted object) makes a
   * double close a no-op.
   */
  private async settle(closed: boolean): Promise<void> {
    if (this.settled) return;
    // The in-memory flag is lost when the Durable Object is evicted, so the
    // durable copy is what makes a double settle idempotent across restarts.
    if ((await this.state.storage.get<boolean>(SETTLED_KEY)) === true) {
      this.settled = true;
      return;
    }
    this.settled = true;
    await this.state.storage.put(SETTLED_KEY, true);

    const metadata =
      this.metadata ?? (await this.state.storage.get<StoredSessionMetadata>(METADATA_KEY)) ?? null;
    // The credential only ever lived in memory; drop it as soon as the relay is over.
    this.metadata = null;
    if (metadata === null) return;

    const elapsedSeconds = Math.max(0, Math.ceil((Date.now() - metadata.startedAtMs) / 1_000));
    const outcome: LiveSessionOutcome = {
      userId: metadata.userId,
      reservationId: metadata.reservationId,
      billingPeriod: metadata.billingPeriod,
      elapsedSeconds: Math.min(elapsedSeconds, metadata.maxSessionSeconds),
      closed,
    };
    await this.state.storage.put(OUTCOME_KEY, outcome);
    await this.state.storage.deleteAlarm();

    // Settle the reservation from the server's own measurement. A failure here
    // must not stop the outcome being recorded — the quota lease expires into a
    // commit anyway, so the usage is metered either way.
    try {
      await this.quota.finalise({
        userId: outcome.userId,
        reservationId: outcome.reservationId,
        actualUnits: outcome.elapsedSeconds,
        nowSeconds: Math.floor(Date.now() / 1_000),
      });
    } catch {
      // Deliberately swallowed: see above.
    }
  }
}
