/**
 * Webhook routes.
 *
 * Webhooks authenticate with their own provider secret, entirely separately
 * from user sessions — there is no path by which a signed-in user can reach
 * these handlers, and no path by which a webhook can act as a user.
 *
 * Both handlers are idempotent: the delivery is claimed in D1 by a unique
 * (provider, event_id) key before any state changes, so a replayed delivery is
 * acknowledged with 200 and does nothing.
 */

import { ApiError, jsonResponse, readBoundedText } from '../http.js';
import { requireSecret } from '../env.js';
import { payloadDigest, subscriptionView, verifyStripeSignature } from '../billing/stripe.js';
import {
  appleRootCertificate,
  storeKitEntitlementView,
  verifyAppStoreNotification,
  type StoreKitRenewalPayload,
  type StoreKitTransactionPayload,
} from '../auth/storekit.js';
import { verifyAppleSignedJws } from '../auth/apple-jws.js';
import { transitionEntitlement } from './billing.js';
import type { RequestContext } from '../context.js';

const MAX_WEBHOOK_BYTES = 512 * 1024;

export async function handleStripeWebhook(
  request: Request,
  context: RequestContext,
): Promise<Response> {
  const payload = await readBoundedText(request, MAX_WEBHOOK_BYTES);

  let event;
  try {
    event = await verifyStripeSignature(
      payload,
      request.headers.get('stripe-signature'),
      requireSecret(context.env, 'STRIPE_WEBHOOK_SECRET'),
      context.nowSeconds,
    );
  } catch {
    context.logger.warn('webhook.stripe.signature_rejected');
    throw new ApiError('unauthorized', 'Stripe signature verification failed');
  }

  const claimed = await context.repository.claimWebhookEvent({
    provider: 'stripe',
    eventId: event.id,
    eventType: event.type,
    payloadDigest: await payloadDigest(payload),
    correlationId: context.correlationId,
    nowSeconds: context.nowSeconds,
  });
  if (!claimed) {
    context.logger.info('webhook.stripe.duplicate', { event_type: event.type });
    return jsonResponse({ received: true, duplicate: true }, { correlationId: context.correlationId });
  }

  try {
    const view = subscriptionView(event);
    if (view === null) {
      await context.repository.completeWebhookEvent({
        provider: 'stripe',
        eventId: event.id,
        status: 'ignored',
        failureReason: null,
        nowSeconds: context.nowSeconds,
      });
      return jsonResponse({ received: true, ignored: true }, { correlationId: context.correlationId });
    }

    const userId =
      view.userIdHint ?? (await context.repository.findUserByBillingCustomer('stripe', view.customerId));
    if (userId === null) {
      // The subscription exists but we cannot attribute it. Recording this as
      // failed keeps it visible for reconciliation instead of silently dropping.
      await context.repository.completeWebhookEvent({
        provider: 'stripe',
        eventId: event.id,
        status: 'failed',
        failureReason: 'unattributable_customer',
        nowSeconds: context.nowSeconds,
      });
      context.logger.error('webhook.stripe.unattributable', { event_type: event.type });
      return jsonResponse({ received: true }, { correlationId: context.correlationId });
    }

    await transitionEntitlement(context, {
      userId,
      status: view.status,
      planId: context.config.stripePriceId,
      source: 'stripe',
      sourceReference: view.subscriptionId,
      currentPeriodStart: view.currentPeriodStart,
      currentPeriodEnd: view.currentPeriodEnd,
      cancelAtPeriodEnd: view.cancelAtPeriodEnd,
      revocationReason: null,
      sourceEventAt: event.created,
      reason: event.type,
      eventSource: 'stripe',
      sourceEventId: event.id,
    });

    await context.repository.completeWebhookEvent({
      provider: 'stripe',
      eventId: event.id,
      status: 'processed',
      failureReason: null,
      nowSeconds: context.nowSeconds,
    });
    await context.repository.recordAudit({
      userId,
      actor: 'webhook',
      action: `webhook.stripe.${event.type}`,
      outcome: 'allowed',
      detail: null,
      correlationId: context.correlationId,
      nowSeconds: context.nowSeconds,
    });
    context.logger.info('webhook.stripe.processed', { event_type: event.type });
  } catch (error) {
    // A processing failure is transient by assumption, so the claim is released
    // and the provider's retry is processed instead of being answered as a
    // duplicate and dropped for ever.
    await context.repository.releaseWebhookClaim({ provider: 'stripe', eventId: event.id });
    context.logger.error('webhook.stripe.failed', {
      event_type: event.type,
      reason: error instanceof Error ? error.name : 'unknown',
    });
    throw error;
  }

  return jsonResponse({ received: true }, { correlationId: context.correlationId });
}

export async function handleAppStoreWebhook(
  request: Request,
  context: RequestContext,
): Promise<Response> {
  const payload = await readBoundedText(request, MAX_WEBHOOK_BYTES);

  let body: { signedPayload?: unknown };
  try {
    body = JSON.parse(payload) as { signedPayload?: unknown };
  } catch {
    throw new ApiError('bad_request', 'App Store notification body is not valid JSON');
  }
  if (typeof body.signedPayload !== 'string') {
    throw new ApiError('bad_request', 'App Store notification has no signedPayload');
  }

  const rootDer = appleRootCertificate(context.env.APPSTORE_ROOT_CA_G3_BASE64);

  let notification;
  try {
    notification = await verifyAppStoreNotification(
      body.signedPayload,
      { rootDer, bundleIds: context.config.appleBundleIds },
      context.nowMs,
    );
  } catch {
    context.logger.warn('webhook.appstore.signature_rejected');
    throw new ApiError('unauthorized', 'App Store notification verification failed');
  }

  const notificationId = notification.notificationUUID as string;
  const claimed = await context.repository.claimWebhookEvent({
    provider: 'appstore',
    eventId: notificationId,
    eventType: notification.notificationType ?? 'unknown',
    payloadDigest: await payloadDigest(payload),
    correlationId: context.correlationId,
    nowSeconds: context.nowSeconds,
  });
  if (!claimed) {
    context.logger.info('webhook.appstore.duplicate');
    return jsonResponse({ received: true, duplicate: true }, { correlationId: context.correlationId });
  }

  try {
    const signedTransaction = notification.data?.signedTransactionInfo;
    if (typeof signedTransaction !== 'string') {
      await context.repository.completeWebhookEvent({
        provider: 'appstore',
        eventId: notificationId,
        status: 'ignored',
        failureReason: null,
        nowSeconds: context.nowSeconds,
      });
      return jsonResponse({ received: true, ignored: true }, { correlationId: context.correlationId });
    }

    const transaction = await verifyAppleSignedJws<StoreKitTransactionPayload>(
      signedTransaction,
      rootDer,
      context.nowMs,
    );
    // The notification envelope is bound to our bundle, but the transaction it
    // carries is a separate JWS. Validate it against the same allow-lists so a
    // notification cannot grant an entitlement for another app or product.
    if (
      typeof transaction.bundleId !== 'string' ||
      !context.config.appleBundleIds.includes(transaction.bundleId)
    ) {
      throw new ApiError('bad_request', 'Notification transaction is for an unexpected bundle');
    }
    if (
      typeof transaction.productId !== 'string' ||
      !context.config.storeKitProductIds.includes(transaction.productId)
    ) {
      throw new ApiError('bad_request', 'Notification transaction is for an unexpected product');
    }
    const renewal =
      typeof notification.data?.signedRenewalInfo === 'string'
        ? await verifyAppleSignedJws<StoreKitRenewalPayload>(
            notification.data.signedRenewalInfo,
            rootDer,
            context.nowMs,
          )
        : null;
    // Renewal info is only meaningful for the transaction it belongs to.
    if (
      renewal !== null &&
      typeof renewal.originalTransactionId === 'string' &&
      renewal.originalTransactionId !== transaction.originalTransactionId
    ) {
      throw new ApiError('bad_request', 'Renewal info does not match the signed transaction');
    }

    const originalTransactionId = transaction.originalTransactionId;
    if (typeof originalTransactionId !== 'string') {
      throw new ApiError('bad_request', 'Notification transaction has no original transaction id');
    }

    const userId = await context.repository.findUserByBillingCustomer(
      'storekit',
      originalTransactionId,
    );
    if (userId === null) {
      // Apple can notify before the client has synced its first transaction.
      // Recording as ignored is correct: the next client sync establishes the
      // link and reads current state directly from the signed transaction.
      await context.repository.completeWebhookEvent({
        provider: 'appstore',
        eventId: notificationId,
        status: 'ignored',
        failureReason: 'unlinked_original_transaction',
        nowSeconds: context.nowSeconds,
      });
      return jsonResponse({ received: true, ignored: true }, { correlationId: context.correlationId });
    }

    const view = storeKitEntitlementView(transaction, renewal, context.nowSeconds);
    await transitionEntitlement(context, {
      userId,
      status: view.status,
      planId: view.productId,
      source: 'storekit',
      sourceReference: view.originalTransactionId,
      currentPeriodStart: view.currentPeriodStart,
      currentPeriodEnd: view.currentPeriodEnd,
      cancelAtPeriodEnd: view.cancelAtPeriodEnd,
      revocationReason: view.revocationReason,
      sourceEventAt: view.sourceEventAt,
      reason: notification.notificationType ?? 'appstore_notification',
      eventSource: 'storekit',
      sourceEventId: notificationId,
    });

    await context.repository.completeWebhookEvent({
      provider: 'appstore',
      eventId: notificationId,
      status: 'processed',
      failureReason: null,
      nowSeconds: context.nowSeconds,
    });
    context.logger.info('webhook.appstore.processed', {
      notification_type: notification.notificationType ?? 'unknown',
    });
  } catch (error) {
    await context.repository.releaseWebhookClaim({
      provider: 'appstore',
      eventId: notificationId,
    });
    context.logger.error('webhook.appstore.failed', {
      reason: error instanceof Error ? error.name : 'unknown',
    });
    throw error;
  }

  return jsonResponse({ received: true }, { correlationId: context.correlationId });
}
