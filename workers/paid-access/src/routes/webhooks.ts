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
import { EntitlementTransitionError } from '../entitlement.js';
import { payloadDigest, subscriptionView, verifyStripeSignature } from '../billing/stripe.js';
import {
  acceptedAppleEnvironments,
  appleRootCertificate,
  storeKitEntitlementView,
  verifyAppStoreNotification,
  verifyStoreKitTransaction,
  type StoreKitRenewalPayload,
} from '../auth/storekit.js';
import { verifyAppleSignedJws } from '../auth/apple-jws.js';
import { transitionEntitlement } from './billing.js';
import type { RequestContext } from '../context.js';

const MAX_WEBHOOK_BYTES = 512 * 1024;

/**
 * Acknowledges a delivery whose transition the entitlement machine refuses.
 *
 * Both providers retry anything they are not told succeeded, and this class of
 * failure never becomes succeedable: the entitlement is already in a state this
 * event cannot move it out of — `revoked`, typically. Answering 200 stops an
 * endless redelivery loop, and the recorded event keeps the anomaly visible.
 */
async function acknowledgeIllegalTransition(
  context: RequestContext,
  provider: 'stripe' | 'appstore',
  eventId: string,
  eventType: string,
  error: EntitlementTransitionError,
): Promise<Response> {
  await context.repository.completeWebhookEvent({
    provider,
    eventId,
    status: 'ignored',
    failureReason: `illegal_transition_${error.from}_to_${error.to}`,
    nowSeconds: context.nowSeconds,
  });
  context.logger.warn(`webhook.${provider}.illegal_transition`, {
    event_type: eventType,
    from: error.from,
    to: error.to,
  });
  return jsonResponse(
    { received: true, ignored: true },
    { correlationId: context.correlationId },
  );
}

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

    // The subscription must bill on a price we sell. Stripe accounts routinely
    // carry other products, and a webhook for one of them must not silently
    // grant this product's entitlement.
    //
    // Only events that would grant or extend access are gated this way. A
    // cancellation must always be applied: `customer.subscription.deleted`
    // frequently arrives without expanded line items, and refusing it for
    // "wrong price" would leave a cancelled user entitled indefinitely — the
    // failure that costs us money rather than protecting it.
    const grantsAccess = view.status !== 'expired';
    if (grantsAccess && !view.priceIds.some((id) => context.config.stripePriceIds.includes(id))) {
      await context.repository.completeWebhookEvent({
        provider: 'stripe',
        eventId: event.id,
        status: 'ignored',
        failureReason: 'price_not_in_plan',
        nowSeconds: context.nowSeconds,
      });
      context.logger.info('webhook.stripe.other_price', { event_type: event.type });
      return jsonResponse({ received: true, ignored: true }, { correlationId: context.correlationId });
    }

    // Attribution comes from the customer mapping we wrote ourselves when the
    // checkout was created. `metadata.user_id` is writable from the Stripe
    // dashboard and by anything holding an API key, so it is only ever a
    // cross-check: if it disagrees with the mapping, something is wrong and the
    // safe move is to change nothing.
    const userId = await context.repository.findUserByBillingCustomer('stripe', view.customerId);
    if (userId !== null && view.userIdHint !== null && view.userIdHint !== userId) {
      await context.repository.completeWebhookEvent({
        provider: 'stripe',
        eventId: event.id,
        status: 'failed',
        failureReason: 'metadata_user_mismatch',
        nowSeconds: context.nowSeconds,
      });
      context.logger.error('webhook.stripe.metadata_mismatch', { event_type: event.type });
      return jsonResponse({ received: true }, { correlationId: context.correlationId });
    }

    // A cancellation skips the price gate, which leaves it able to expire an
    // entitlement belonging to a different subscription entirely — another
    // product on the same Stripe customer, or a previous subscription of ours.
    // It may only apply to the subscription the entitlement actually names.
    if (!grantsAccess && userId !== null) {
      const current = await context.repository.findEntitlement(userId);
      if (current !== null && current.sourceReference !== view.subscriptionId) {
        await context.repository.completeWebhookEvent({
          provider: 'stripe',
          eventId: event.id,
          status: 'ignored',
          failureReason: 'subscription_not_current',
          nowSeconds: context.nowSeconds,
        });
        context.logger.info('webhook.stripe.other_subscription', { event_type: event.type });
        return jsonResponse(
          { received: true, ignored: true },
          { correlationId: context.correlationId },
        );
      }
    }

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

    try {
      await transitionEntitlement(context, {
        userId,
        status: view.status,
        // The price actually billed, not the plan's headline price, so a yearly
        // subscriber's record does not claim to be on the monthly plan.
        planId:
          view.priceIds.find((id) => context.config.stripePriceIds.includes(id)) ??
          context.config.stripePriceIds[0] ??
          'unknown',
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
    } catch (error) {
      if (!(error instanceof EntitlementTransitionError)) throw error;
      return acknowledgeIllegalTransition(context, 'stripe', event.id, event.type, error);
    }

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

    // The notification envelope is bound to our bundle, but the transaction it
    // carries is a separate JWS. It goes through exactly the same allow-lists as
    // a client-supplied receipt — bundle, product and Apple environment — so a
    // notification cannot grant an entitlement for another app or product, and a
    // Sandbox notification cannot grant production access. No account binding is
    // checked here: a notification has no caller, and is attributed below through
    // the stored customer mapping instead.
    const transaction = await verifyStoreKitTransaction(
      signedTransaction,
      {
        rootDer,
        bundleIds: context.config.appleBundleIds,
        productIds: context.config.storeKitProductIds,
        environments: acceptedAppleEnvironments(context.config.environment),
      },
      context.nowMs,
    );
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
    try {
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
    } catch (error) {
      if (!(error instanceof EntitlementTransitionError)) throw error;
      return acknowledgeIllegalTransition(
        context,
        'appstore',
        notificationId,
        notification.notificationType ?? 'unknown',
        error,
      );
    }

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
