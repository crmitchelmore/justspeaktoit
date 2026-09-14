/**
 * StoreKit 2 / App Store Server Notification verification.
 *
 * The client hands us a signed transaction from `Transaction.currentEntitlements`
 * (or Apple posts a signed notification). Both are JWS blobs verified against
 * the pinned Apple root before any claim is read — the client never tells us
 * whether it is entitled, it only supplies evidence we check.
 */

import { verifyAppleSignedJws } from './apple-jws.js';
import { base64ToBytes } from '../crypto.js';
import type { EntitlementStatus } from '../entitlement.js';

/**
 * Apple Root CA G3, the trust anchor for all StoreKit signed data.
 * Published at https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
 * SHA-256: 63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179
 */
export const APPLE_ROOT_CA_G3_BASE64 =
  'MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEcz' +
  'MSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkG' +
  'A1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENB' +
  'IC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMu' +
  'MQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWm' +
  'BSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEK' +
  'MaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQD' +
  'AgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4' +
  'at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==';

/** Why a signed payload was rejected, so callers can answer 401 or 403 correctly. */
export type StoreKitRejection = 'unverifiable' | 'not_this_account';

export class StoreKitError extends Error {
  readonly reason: StoreKitRejection;

  constructor(message: string, reason: StoreKitRejection = 'unverifiable') {
    super(message);
    this.name = 'StoreKitError';
    this.reason = reason;
  }
}

/** The subset of Apple's JWSTransactionDecodedPayload we depend on. */
export interface StoreKitTransactionPayload {
  readonly transactionId?: string;
  readonly originalTransactionId?: string;
  readonly bundleId?: string;
  readonly productId?: string;
  readonly type?: string;
  readonly purchaseDate?: number;
  readonly originalPurchaseDate?: number;
  readonly expiresDate?: number;
  readonly revocationDate?: number;
  readonly revocationReason?: number;
  readonly environment?: string;
  readonly signedDate?: number;
  readonly appAccountToken?: string;
}

/** The subset of Apple's JWSRenewalInfoDecodedPayload we depend on. */
export interface StoreKitRenewalPayload {
  readonly originalTransactionId?: string;
  readonly productId?: string;
  readonly autoRenewStatus?: number;
  readonly expirationIntent?: number;
  readonly gracePeriodExpiresDate?: number;
  readonly isInBillingRetryPeriod?: boolean;
  readonly signedDate?: number;
}

export interface AppStoreNotificationPayload {
  readonly notificationType?: string;
  readonly subtype?: string;
  readonly notificationUUID?: string;
  readonly signedDate?: number;
  readonly data?: {
    readonly bundleId?: string;
    readonly environment?: string;
    readonly signedTransactionInfo?: string;
    readonly signedRenewalInfo?: string;
  };
}

export function appleRootCertificate(overrideBase64?: string): Uint8Array {
  return base64ToBytes(overrideBase64 ?? APPLE_ROOT_CA_G3_BASE64);
}

export async function verifyStoreKitTransaction(
  signedTransaction: string,
  options: {
    rootDer: Uint8Array;
    bundleIds: readonly string[];
    productIds: readonly string[];
    /** Apple environments this deployment accepts, e.g. `['Production']`. */
    environments?: readonly string[];
    /**
     * The account this transaction must belong to.
     *
     * Supply it whenever a user is presenting the receipt themselves. Omit it
     * only where the account is established by other means — App Store server
     * notifications arrive with no caller and are attributed through the stored
     * customer mapping instead.
     */
    appAccountToken?: string;
  },
  nowMs: number,
): Promise<StoreKitTransactionPayload> {
  const payload = await verifyAppleSignedJws<StoreKitTransactionPayload>(
    signedTransaction,
    options.rootDer,
    nowMs,
  );

  if (typeof payload.bundleId !== 'string' || !options.bundleIds.includes(payload.bundleId)) {
    throw new StoreKitError('Signed transaction is for an unexpected bundle identifier');
  }
  if (typeof payload.productId !== 'string' || !options.productIds.includes(payload.productId)) {
    throw new StoreKitError('Signed transaction is for an unexpected product identifier');
  }
  // A Sandbox receipt is trivially obtainable and must never grant production
  // entitlements, so the environment is checked like any other claim.
  if (options.environments !== undefined) {
    if (
      typeof payload.environment !== 'string' ||
      !options.environments.includes(payload.environment)
    ) {
      throw new StoreKitError('Signed transaction is for an unexpected Apple environment');
    }
  }
  if (typeof payload.originalTransactionId !== 'string') {
    throw new StoreKitError('Signed transaction has no original transaction identifier');
  }
  // The client sets `appAccountToken` to its own user id when it buys, and Apple
  // stamps it onto that transaction and every renewal of it. Requiring it to
  // match the caller is what makes a receipt non-transferable: without it, a
  // signed transaction lifted from another device — or shared through a family
  // Apple ID — grants paid access to whoever presents it first.
  if (options.appAccountToken !== undefined) {
    if (
      typeof payload.appAccountToken !== 'string' ||
      payload.appAccountToken.toLowerCase() !== options.appAccountToken.toLowerCase()
    ) {
      throw new StoreKitError(
        'Signed transaction is not bound to the signed-in account',
        'not_this_account',
      );
    }
  }
  return payload;
}

/**
 * The Apple environments a deployment accepts. Production installs only trust
 * Production receipts; every other deployment also accepts Sandbox so TestFlight
 * and local builds can exercise the flow.
 */
export function acceptedAppleEnvironments(deployment: string): readonly string[] {
  return deployment.toLowerCase() === 'production' ? ['Production'] : ['Production', 'Sandbox'];
}

export async function verifyAppStoreNotification(
  signedPayload: string,
  options: { rootDer: Uint8Array; bundleIds: readonly string[] },
  nowMs: number,
): Promise<AppStoreNotificationPayload> {
  const payload = await verifyAppleSignedJws<AppStoreNotificationPayload>(
    signedPayload,
    options.rootDer,
    nowMs,
  );
  const bundleId = payload.data?.bundleId;
  if (typeof bundleId !== 'string' || !options.bundleIds.includes(bundleId)) {
    throw new StoreKitError('Notification is for an unexpected bundle identifier');
  }
  if (typeof payload.notificationUUID !== 'string' || payload.notificationUUID.length === 0) {
    throw new StoreKitError('Notification has no UUID to deduplicate on');
  }
  return payload;
}

export interface StoreKitEntitlementView {
  readonly status: EntitlementStatus;
  readonly productId: string;
  readonly originalTransactionId: string;
  readonly currentPeriodStart: number | null;
  readonly currentPeriodEnd: number | null;
  readonly cancelAtPeriodEnd: boolean;
  readonly revocationReason: string | null;
  readonly sourceEventAt: number;
}

/**
 * Maps a verified transaction (plus optional renewal info) onto our entitlement
 * vocabulary. Kept pure so the mapping is unit-testable without any crypto.
 */
export function storeKitEntitlementView(
  transaction: StoreKitTransactionPayload,
  renewal: StoreKitRenewalPayload | null,
  nowSeconds: number,
): StoreKitEntitlementView {
  const productId = transaction.productId as string;
  const originalTransactionId = transaction.originalTransactionId as string;
  const expiresSeconds =
    typeof transaction.expiresDate === 'number' ? Math.floor(transaction.expiresDate / 1000) : null;
  const startSeconds =
    typeof transaction.purchaseDate === 'number' ? Math.floor(transaction.purchaseDate / 1000) : null;
  const signedSeconds =
    typeof transaction.signedDate === 'number'
      ? Math.floor(transaction.signedDate / 1000)
      : nowSeconds;

  if (typeof transaction.revocationDate === 'number') {
    return {
      status: 'revoked',
      productId,
      originalTransactionId,
      currentPeriodStart: startSeconds,
      currentPeriodEnd: expiresSeconds,
      cancelAtPeriodEnd: true,
      revocationReason: `apple_revocation_reason_${transaction.revocationReason ?? 'unspecified'}`,
      sourceEventAt: signedSeconds,
    };
  }

  const gracePeriodEnd =
    typeof renewal?.gracePeriodExpiresDate === 'number'
      ? Math.floor(renewal.gracePeriodExpiresDate / 1000)
      : null;

  let status: EntitlementStatus;
  if (expiresSeconds !== null && expiresSeconds > nowSeconds) {
    status = 'active';
  } else if (gracePeriodEnd !== null && gracePeriodEnd > nowSeconds) {
    status = 'grace';
  } else if (renewal?.isInBillingRetryPeriod === true) {
    status = 'past_due';
  } else {
    status = 'expired';
  }

  return {
    status,
    productId,
    originalTransactionId,
    currentPeriodStart: startSeconds,
    // In grace, access is granted until the grace window ends rather than the
    // lapsed subscription period.
    currentPeriodEnd: status === 'grace' ? gracePeriodEnd : expiresSeconds,
    cancelAtPeriodEnd: renewal?.autoRenewStatus === 0,
    revocationReason: null,
    sourceEventAt: signedSeconds,
  };
}
