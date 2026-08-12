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
 */

export interface LiveSessionInit {
  readonly userId: string;
  readonly reservationId: string;
  readonly upstreamUrl: string;
  readonly upstreamProtocolHeader: string;
  readonly maxSessionSeconds: number;
  readonly connectTimeoutMs: number;
  readonly correlationId: string;
}

interface SessionMetadata extends LiveSessionInit {
  readonly startedAtMs: number;
}

const METADATA_KEY = 'metadata';
const SETTLED_KEY = 'settled';
const OUTCOME_PATH = '/outcome';

export interface LiveSessionOutcome {
  readonly userId: string;
  readonly reservationId: string;
  readonly elapsedSeconds: number;
  readonly closed: boolean;
}

export class LiveSessionDurableObject implements DurableObject {
  private readonly state: DurableObjectState;
  private client: WebSocket | null = null;
  private upstream: WebSocket | null = null;
  private metadata: SessionMetadata | null = null;
  private settled = false;

  constructor(state: DurableObjectState) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === OUTCOME_PATH) {
      const stored = await this.state.storage.get<LiveSessionOutcome>('outcome');
      return Response.json(stored ?? null);
    }

    if (request.headers.get('upgrade') !== 'websocket') {
      return new Response('Expected WebSocket upgrade', { status: 426 });
    }

    // One reservation, one socket. A second upgrade for the same Durable Object
    // would replace `this.client`/`this.upstream` and orphan the first relay,
    // which then never settles its share of the reservation.
    if (this.client !== null || (await this.state.storage.get<SessionMetadata>(METADATA_KEY))) {
      return new Response('Live session is already in use', { status: 409 });
    }

    const init = JSON.parse(request.headers.get('x-session-init') ?? '{}') as Partial<LiveSessionInit>;
    if (
      typeof init.userId !== 'string' ||
      typeof init.reservationId !== 'string' ||
      typeof init.upstreamUrl !== 'string'
    ) {
      return new Response('Invalid session initialisation', { status: 400 });
    }

    this.metadata = {
      userId: init.userId,
      reservationId: init.reservationId,
      upstreamUrl: init.upstreamUrl,
      upstreamProtocolHeader: init.upstreamProtocolHeader ?? '',
      maxSessionSeconds: init.maxSessionSeconds ?? 1_800,
      connectTimeoutMs: init.connectTimeoutMs ?? 15_000,
      correlationId: init.correlationId ?? 'unknown',
      startedAtMs: Date.now(),
    };
    await this.state.storage.put(METADATA_KEY, this.metadata);

    let upstreamResponse: Response;
    try {
      upstreamResponse = await this.connectUpstream(this.metadata);
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
    await this.state.storage.setAlarm(Date.now() + this.metadata.maxSessionSeconds * 1_000);

    return new Response(null, { status: 101, webSocket: clientSide });
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
   * Records the measured session duration exactly once. The Worker reads this
   * to finalise the quota reservation; `settled` makes a double close idempotent.
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
      this.metadata ?? (await this.state.storage.get<SessionMetadata>(METADATA_KEY)) ?? null;
    if (metadata === null) return;

    const elapsedSeconds = Math.max(0, Math.ceil((Date.now() - metadata.startedAtMs) / 1_000));
    const outcome: LiveSessionOutcome = {
      userId: metadata.userId,
      reservationId: metadata.reservationId,
      elapsedSeconds: Math.min(elapsedSeconds, metadata.maxSessionSeconds),
      closed,
    };
    await this.state.storage.put('outcome', outcome);
    await this.state.storage.deleteAlarm();
  }
}
