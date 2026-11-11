/**
 * Storage layout of the per-user quota object.
 *
 * Owns every key the object writes, so `QuotaDurableObject` reads typed state
 * and persists typed changes. Every write is one `put` of an entries object,
 * which Durable Objects apply atomically.
 */

import { emptyPeriod, type PeriodState, type Reservation } from './quota-accounting.js';
import { PENDING_PREFIX, pendingKey, receiptKey, type SettlementReceipt } from './settlement.js';

/**
 * Committed usage is stored one record per billing period.
 *
 * A single shared record cannot express "finalise a reservation taken last
 * month": the write would have to name one period, and naming the reservation's
 * period would overwrite — and so zero — the period that is currently being
 * metered. Keying by period lets a late finalise land where it belongs.
 */
const PERIOD_KEY_PREFIX = 'period:';
/** Pre-per-period-key storage layout; read once so no usage is lost on upgrade. */
const LEGACY_PERIOD_KEY = 'period';
/** The most recent period this user was seen in, used only for reporting. */
const LATEST_PERIOD_KEY = 'latest_period';
const RESERVATIONS_KEY = 'reservations';
const EXPIRED_PREFIX = 'expired:';

/** One atomic set of changes. Absent fields are left untouched. */
export interface QuotaWrite {
  readonly periods?: readonly PeriodState[];
  readonly latestPeriod?: string;
  readonly reservations?: readonly Reservation[];
  readonly receipts?: readonly SettlementReceipt[];
  /** Expired leases kept so a late finalise can refund them. */
  readonly expired?: readonly Reservation[];
  /** Expired leases a finalise has settled; stored as `null`. */
  readonly retiredExpired?: readonly string[];
  /** Receipts whose ledger reconciliation is scheduled at `nextReconcileAt`. */
  readonly pending?: readonly SettlementReceipt[];
}

/** The storage calls the quota object makes; a test can wrap them. */
type QuotaStorage = Pick<DurableObjectStorage, 'get' | 'put' | 'delete' | 'list' | 'getAlarm' | 'setAlarm'>;

export class QuotaStore {
  constructor(private readonly storage: QuotaStorage) {}

  /** A period's committed usage; a new billing period starts at zero. */
  async period(period: string): Promise<PeriodState> {
    const stored = await this.storage.get<PeriodState>(PERIOD_KEY_PREFIX + period);
    if (stored !== undefined && stored.period === period) return stored;
    const legacy = await this.storage.get<PeriodState>(LEGACY_PERIOD_KEY);
    if (legacy !== undefined && legacy.period === period) return legacy;
    // The ledger in D1 remains the durable record of what came before.
    return emptyPeriod(period);
  }

  /** Several periods' committed usage, keyed by period. */
  async periods(periods: Iterable<string>): Promise<Map<string, PeriodState>> {
    const loaded = new Map<string, PeriodState>();
    for (const period of periods) {
      if (!loaded.has(period)) loaded.set(period, await this.period(period));
    }
    return loaded;
  }

  /** The period to report on when the caller did not name one. */
  async latestPeriod(): Promise<PeriodState> {
    const latest = await this.storage.get<string>(LATEST_PERIOD_KEY);
    if (latest !== undefined) return this.period(latest);
    const legacy = await this.storage.get<PeriodState>(LEGACY_PERIOD_KEY);
    return legacy ?? { period: '1970-01', audioSecondsCommitted: 0, tokensCommitted: 0 };
  }

  async reservations(): Promise<Reservation[]> {
    return (await this.storage.get<Reservation[]>(RESERVATIONS_KEY)) ?? [];
  }

  /** An expired lease kept for a late finalise; `null` once retired. */
  async expiredReservation(id: string): Promise<Reservation | null | undefined> {
    return this.storage.get<Reservation | null>(EXPIRED_PREFIX + id);
  }

  async receipt(idempotencyKey: string): Promise<SettlementReceipt | undefined> {
    return this.storage.get<SettlementReceipt>(receiptKey(idempotencyKey));
  }

  /** Receipts by idempotency key; missing receipts are omitted. */
  async receipts(idempotencyKeys: Iterable<string>): Promise<Map<string, SettlementReceipt>> {
    const found = new Map<string, SettlementReceipt>();
    for (const key of idempotencyKeys) {
      const receipt = await this.receipt(key);
      if (receipt !== undefined) found.set(key, receipt);
    }
    return found;
  }

  async write(changes: QuotaWrite): Promise<void> {
    const entries: Record<string, unknown> = {};
    for (const period of changes.periods ?? []) entries[PERIOD_KEY_PREFIX + period.period] = period;
    if (changes.latestPeriod !== undefined) entries[LATEST_PERIOD_KEY] = changes.latestPeriod;
    if (changes.reservations !== undefined) entries[RESERVATIONS_KEY] = changes.reservations;
    for (const receipt of changes.receipts ?? []) entries[receiptKey(receipt.idempotencyKey)] = receipt;
    for (const entry of changes.expired ?? []) entries[EXPIRED_PREFIX + entry.id] = entry;
    for (const id of changes.retiredExpired ?? []) entries[EXPIRED_PREFIX + id] = null;
    for (const receipt of changes.pending ?? []) entries[pendingKey(receipt)] = receipt.idempotencyKey;
    await this.storage.put(entries);
  }

  async deletePendingMarker(marker: string): Promise<void> {
    await this.storage.delete(marker);
  }

  /** Pending reconciliation markers, earliest first: marker → idempotency key. */
  async pendingMarkers(limit: number): Promise<Map<string, string>> {
    return this.storage.list<string>({ prefix: PENDING_PREFIX, limit });
  }

  /** Brings the alarm forward to `atSeconds`; never pushes an earlier one back. */
  async ensureAlarm(atSeconds: number): Promise<void> {
    const existing = await this.storage.getAlarm();
    const at = Math.max(Date.now() + 1, atSeconds * 1000);
    if (existing === null || existing > at) await this.storage.setAlarm(at);
  }
}

/** The pending-marker time a marker was scheduled for, in seconds. */
export function pendingMarkerSeconds(marker: string): number {
  return Number(marker.slice(PENDING_PREFIX.length).split(':')[0]);
}
