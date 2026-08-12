/**
 * Paid Access Worker — request router.
 *
 * Every route is listed here explicitly. There is no catch-all proxy and no
 * delete endpoint anywhere in the surface: entitlement and usage history are
 * append-only by design, and support corrections happen through auditable
 * transitions rather than row removal.
 */

import { ApiError, errorResponse, jsonResponse } from './http.js';
import { ConfigurationError, type Env } from './env.js';
import { authenticate, createContext } from './context.js';
import { describeError } from './logging.js';
import { handleAppleSignIn, handleRefresh, handleSignOut } from './routes/auth.js';
import {
  handleEntitlement,
  handleStoreKitSync,
  handleStripeCheckout,
  handleStripePortal,
} from './routes/billing.js';
import { handleAppStoreWebhook, handleStripeWebhook } from './routes/webhooks.js';
import {
  handleBatchTranscription,
  handleLiveTranscription,
  handleLiveTranscriptionFinalise,
  handlePolicy,
  handlePostProcessing,
} from './routes/paid.js';

export { QuotaDurableObject } from './do/quota.js';
export { LiveSessionDurableObject } from './do/live-session.js';

type Route = `${'GET' | 'POST'} ${string}`;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const context = (() => {
      try {
        return createContext(request, env);
      } catch (error) {
        if (error instanceof ConfigurationError) {
          // Configuration problems are operator errors; surface them as 500 and
          // never leak which value is wrong to the caller.
          console.error(JSON.stringify({ level: 'error', event: 'config.invalid' }));
          return null;
        }
        throw error;
      }
    })();

    if (context === null) {
      return new Response(
        JSON.stringify({ error: { code: 'internal_error', message: 'Service is misconfigured' } }),
        { status: 500, headers: { 'content-type': 'application/json' } },
      );
    }

    const url = new URL(request.url);
    const route = `${request.method} ${url.pathname}` as Route;

    try {
      switch (route) {
        case 'GET /v1/health':
          return jsonResponse(
            { status: 'ok', environment: context.config.environment },
            { correlationId: context.correlationId },
          );

        // Authentication -----------------------------------------------------
        case 'POST /v1/auth/apple':
          return await handleAppleSignIn(request, context);
        case 'POST /v1/auth/refresh':
          return await handleRefresh(request, context);
        case 'POST /v1/auth/sign-out':
          return await handleSignOut(await authenticate(request, context));

        // Entitlement --------------------------------------------------------
        case 'GET /v1/entitlement':
          return await handleEntitlement(await authenticate(request, context));
        case 'GET /v1/policy':
          return handlePolicy(await authenticate(request, context));

        // Billing ------------------------------------------------------------
        case 'POST /v1/billing/stripe/checkout':
          return await handleStripeCheckout(request, await authenticate(request, context));
        case 'POST /v1/billing/stripe/portal':
          return await handleStripePortal(request, await authenticate(request, context));
        case 'POST /v1/billing/storekit/sync':
          return await handleStoreKitSync(request, await authenticate(request, context));

        // Webhooks (authenticated by provider signature, not by session) ------
        case 'POST /v1/webhooks/stripe':
          return await handleStripeWebhook(request, context);
        case 'POST /v1/webhooks/appstore':
          return await handleAppStoreWebhook(request, context);

        // Paid routing -------------------------------------------------------
        case 'POST /v1/paid/transcribe/batch':
          return await handleBatchTranscription(request, await authenticate(request, context));
        case 'POST /v1/paid/post-process':
          return await handlePostProcessing(request, await authenticate(request, context));
        case 'GET /v1/paid/transcribe/live':
          return await handleLiveTranscription(request, await authenticate(request, context));
        case 'POST /v1/paid/transcribe/live/finalise':
          return await handleLiveTranscriptionFinalise(
            request,
            await authenticate(request, context),
          );

        default:
          throw new ApiError('not_found', 'No such endpoint');
      }
    } catch (error) {
      if (error instanceof ApiError) {
        if (error.status >= 500) {
          context.logger.error('request.failed', { code: error.code, status: error.status });
        } else {
          context.logger.warn('request.rejected', { code: error.code, status: error.status });
        }
        return errorResponse(error, context.correlationId);
      }

      context.logger.error('request.unhandled', { error: describeError(error) });
      return errorResponse(
        new ApiError('internal_error', 'An unexpected error occurred'),
        context.correlationId,
      );
    }
  },
} satisfies ExportedHandler<Env>;
