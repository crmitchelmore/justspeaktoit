import { describe, expect, it } from 'vitest';
import { verifyAppleSignedJws, CertificateError } from '../src/auth/apple-jws.js';
import {
  appleRootCertificate,
  storeKitEntitlementView,
  verifyStoreKitTransaction,
  StoreKitError,
  APPLE_ROOT_CA_G3_BASE64,
} from '../src/auth/storekit.js';
import {
  buildTestChain,
  signJws,
  generateKeyPair,
  buildCertificate,
  OID_APPLE_WWDR,
} from './helpers/x509.js';
import { base64ToBytes, sha256Hex } from '../src/crypto.js';

const NOW_MS = Date.now();
const NOW_SECONDS = Math.floor(NOW_MS / 1_000);

describe('Apple signed JWS verification', () => {
  it('accepts a payload signed by a leaf that chains to the pinned root', async () => {
    const chain = await buildTestChain();
    const jws = await signJws({ hello: 'world' }, chain);
    const payload = await verifyAppleSignedJws<{ hello: string }>(jws, chain.rootDer, NOW_MS);
    expect(payload.hello).toBe('world');
  });

  it('rejects a payload whose body was altered after signing', async () => {
    const chain = await buildTestChain();
    const jws = await signJws({ productId: 'com.justspeaktoit.paid.monthly' }, chain);
    const [header, , signature] = jws.split('.');
    const forgedBody = btoa(JSON.stringify({ productId: 'com.justspeaktoit.paid.yearly' }))
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/, '');

    await expect(
      verifyAppleSignedJws(`${header}.${forgedBody}.${signature}`, chain.rootDer, NOW_MS),
    ).rejects.toBeInstanceOf(CertificateError);
  });

  it('rejects a chain that terminates at a different root', async () => {
    const genuine = await buildTestChain();
    const attacker = await buildTestChain();
    const jws = await signJws({ hello: 'world' }, attacker);

    // The attacker's chain is internally valid but is not anchored to our root.
    await expect(verifyAppleSignedJws(jws, genuine.rootDer, NOW_MS)).rejects.toBeInstanceOf(
      CertificateError,
    );
  });

  it('rejects a chain whose intermediate was not signed by the root', async () => {
    const chain = await buildTestChain();
    const rogueIssuer = await generateKeyPair('P-384');
    const rogueIntermediateKey = await generateKeyPair('P-256');
    const rogueIntermediate = await buildCertificate({
      subject: 'Test Intermediate CA',
      issuer: 'Test Root CA',
      subjectKey: rogueIntermediateKey,
      issuerKey: rogueIssuer,
      notBefore: new Date(NOW_MS - 86_400_000),
      notAfter: new Date(NOW_MS + 86_400_000),
    });
    let binary = '';
    for (const byte of rogueIntermediate) binary += String.fromCharCode(byte);

    const tampered = {
      ...chain,
      chainBase64: [chain.chainBase64[0]!, btoa(binary), chain.chainBase64[2]!],
    };
    const jws = await signJws({ hello: 'world' }, tampered);

    await expect(verifyAppleSignedJws(jws, chain.rootDer, NOW_MS)).rejects.toBeInstanceOf(
      CertificateError,
    );
  });

  it('rejects a chain containing an expired certificate', async () => {
    const chain = await buildTestChain({
      leafNotBefore: new Date(NOW_MS - 172_800_000),
      leafNotAfter: new Date(NOW_MS - 86_400_000),
    });
    const jws = await signJws({ hello: 'world' }, chain);
    await expect(verifyAppleSignedJws(jws, chain.rootDer, NOW_MS)).rejects.toBeInstanceOf(
      CertificateError,
    );
  });

  it('rejects a chain that is not yet valid', async () => {
    const chain = await buildTestChain({
      leafNotBefore: new Date(NOW_MS + 86_400_000),
      leafNotAfter: new Date(NOW_MS + 172_800_000),
    });
    const jws = await signJws({ hello: 'world' }, chain);
    await expect(verifyAppleSignedJws(jws, chain.rootDer, NOW_MS)).rejects.toBeInstanceOf(
      CertificateError,
    );
  });

  it('rejects an unsigned "alg: none" payload', async () => {
    const chain = await buildTestChain();
    const jws = await signJws({ hello: 'world' }, chain, { alg: 'none' });
    await expect(verifyAppleSignedJws(jws, chain.rootDer, NOW_MS)).rejects.toBeInstanceOf(
      CertificateError,
    );
  });

  it('rejects a payload with no certificate chain at all', async () => {
    const chain = await buildTestChain();
    const jws = await signJws({ hello: 'world' }, chain, { x5c: undefined });
    await expect(verifyAppleSignedJws(jws, chain.rootDer, NOW_MS)).rejects.toBeInstanceOf(
      CertificateError,
    );
  });

  it('rejects a self-signed single-certificate chain', async () => {
    const chain = await buildTestChain();
    const jws = await signJws({ hello: 'world' }, chain, { x5c: [chain.chainBase64[0]] });
    await expect(verifyAppleSignedJws(jws, chain.rootDer, NOW_MS)).rejects.toBeInstanceOf(
      CertificateError,
    );
  });

  it('rejects a leaf without Apple\'s receipt-signing marker OID', async () => {
    // A certificate can chain to the Apple root without being issued for App
    // Store receipt signing; Apple requires this marker specifically.
    const chain = await buildTestChain({ omitLeafMarkerOid: true });
    const jws = await signJws({ hello: 'world' }, chain);
    await expect(verifyAppleSignedJws(jws, chain.rootDer, NOW_MS)).rejects.toBeInstanceOf(
      CertificateError,
    );
  });

  it('rejects an intermediate without the Apple WWDR marker OID', async () => {
    const chain = await buildTestChain({ omitIntermediateMarkerOid: true });
    const jws = await signJws({ hello: 'world' }, chain);
    await expect(verifyAppleSignedJws(jws, chain.rootDer, NOW_MS)).rejects.toBeInstanceOf(
      CertificateError,
    );
  });

  it('rejects a chain whose intermediate is not marked as a CA', async () => {
    const chain = await buildTestChain({ intermediateIsNotCA: true });
    const jws = await signJws({ hello: 'world' }, chain);
    await expect(verifyAppleSignedJws(jws, chain.rootDer, NOW_MS)).rejects.toBeInstanceOf(
      CertificateError,
    );
  });

  it('rejects a chain whose issuer and subject names do not line up', async () => {
    const chain = await buildTestChain();
    const rootKey = await generateKeyPair('P-384');
    const intermediateKey = await generateKeyPair('P-256');
    // Correctly signed by a CA, but naming a different issuer than it has.
    const mismatched = await buildCertificate({
      subject: 'Someone Else CA',
      issuer: 'Test Root CA',
      subjectKey: intermediateKey,
      issuerKey: rootKey,
      notBefore: new Date(NOW_MS - 86_400_000),
      notAfter: new Date(NOW_MS + 86_400_000),
      isCertificateAuthority: true,
      markerOids: [OID_APPLE_WWDR],
    });
    let binary = '';
    for (const byte of mismatched) binary += String.fromCharCode(byte);

    const tampered = {
      ...chain,
      chainBase64: [chain.chainBase64[0]!, btoa(binary), chain.chainBase64[2]!],
    };
    const jws = await signJws({ hello: 'world' }, tampered);
    await expect(verifyAppleSignedJws(jws, chain.rootDer, NOW_MS)).rejects.toBeInstanceOf(
      CertificateError,
    );
  });

  it('rejects a value that is not a compact JWS', async () => {
    const chain = await buildTestChain();
    await expect(
      verifyAppleSignedJws('definitely-not-a-jws', chain.rootDer, NOW_MS),
    ).rejects.toBeInstanceOf(CertificateError);
  });
});

describe('pinned Apple root', () => {
  it('matches the fingerprint Apple publishes for Apple Root CA G3', async () => {
    const der = appleRootCertificate();
    const digest = await sha256Hex(der);
    expect(digest.toUpperCase()).toBe(
      '63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179',
    );
  });

  it('decodes the embedded root when no override is configured', () => {
    // Comparing the default against the same constant decoded a second time
    // would pass however broken the function was; compare against the bytes.
    expect(Array.from(appleRootCertificate())).toEqual(
      Array.from(base64ToBytes(APPLE_ROOT_CA_G3_BASE64)),
    );
  });

  it('honours a configured root override', () => {
    // Staging and the test chains pin their own anchor, so an override that was
    // silently ignored would mean those deployments trusted Apple's root instead.
    const override = appleRootCertificate(btoa('not-the-apple-root'));
    expect(new TextDecoder().decode(override)).toBe('not-the-apple-root');
  });
});

describe('StoreKit transaction claim validation', () => {
  const bundleIds = ['com.justspeaktoit.ios'];
  const productIds = ['com.justspeaktoit.paid.monthly'];

  it('accepts a transaction for a known bundle and product', async () => {
    const chain = await buildTestChain();
    const jws = await signJws(
      {
        bundleId: 'com.justspeaktoit.ios',
        productId: 'com.justspeaktoit.paid.monthly',
        originalTransactionId: 'orig-1',
        transactionId: 'txn-1',
        expiresDate: (NOW_SECONDS + 86_400) * 1_000,
        purchaseDate: (NOW_SECONDS - 100) * 1_000,
        signedDate: NOW_MS,
      },
      chain,
    );

    const payload = await verifyStoreKitTransaction(
      jws,
      { rootDer: chain.rootDer, bundleIds, productIds },
      NOW_MS,
    );
    expect(payload.originalTransactionId).toBe('orig-1');
  });

  it('rejects a transaction for another app', async () => {
    const chain = await buildTestChain();
    const jws = await signJws(
      {
        bundleId: 'com.someone.else',
        productId: 'com.justspeaktoit.paid.monthly',
        originalTransactionId: 'orig-2',
      },
      chain,
    );
    await expect(
      verifyStoreKitTransaction(jws, { rootDer: chain.rootDer, bundleIds, productIds }, NOW_MS),
    ).rejects.toBeInstanceOf(StoreKitError);
  });

  it('rejects a transaction for a product that is not the subscription', async () => {
    const chain = await buildTestChain();
    const jws = await signJws(
      {
        bundleId: 'com.justspeaktoit.ios',
        productId: 'com.justspeaktoit.tip.small',
        originalTransactionId: 'orig-3',
      },
      chain,
    );
    await expect(
      verifyStoreKitTransaction(jws, { rootDer: chain.rootDer, bundleIds, productIds }, NOW_MS),
    ).rejects.toBeInstanceOf(StoreKitError);
  });
});

describe('StoreKit entitlement mapping', () => {
  const base = {
    productId: 'com.justspeaktoit.paid.monthly',
    originalTransactionId: 'orig-1',
    purchaseDate: (NOW_SECONDS - 1_000) * 1_000,
    signedDate: NOW_MS,
  };

  it('maps an unexpired subscription to active', () => {
    const view = storeKitEntitlementView(
      { ...base, expiresDate: (NOW_SECONDS + 86_400) * 1_000 },
      null,
      NOW_SECONDS,
    );
    expect(view.status).toBe('active');
    expect(view.currentPeriodEnd).toBe(NOW_SECONDS + 86_400);
  });

  it('maps a lapsed subscription to expired', () => {
    const view = storeKitEntitlementView(
      { ...base, expiresDate: (NOW_SECONDS - 10) * 1_000 },
      null,
      NOW_SECONDS,
    );
    expect(view.status).toBe('expired');
  });

  it('maps a lapsed subscription inside a grace period to grace', () => {
    const view = storeKitEntitlementView(
      { ...base, expiresDate: (NOW_SECONDS - 10) * 1_000 },
      { gracePeriodExpiresDate: (NOW_SECONDS + 3_600) * 1_000 },
      NOW_SECONDS,
    );
    expect(view.status).toBe('grace');
    expect(view.currentPeriodEnd).toBe(NOW_SECONDS + 3_600);
  });

  it('maps billing retry to past_due', () => {
    const view = storeKitEntitlementView(
      { ...base, expiresDate: (NOW_SECONDS - 10) * 1_000 },
      { isInBillingRetryPeriod: true },
      NOW_SECONDS,
    );
    expect(view.status).toBe('past_due');
  });

  it('maps a refunded transaction to revoked with a reason', () => {
    const view = storeKitEntitlementView(
      {
        ...base,
        expiresDate: (NOW_SECONDS + 86_400) * 1_000,
        revocationDate: (NOW_SECONDS - 5) * 1_000,
        revocationReason: 1,
      },
      null,
      NOW_SECONDS,
    );
    expect(view.status).toBe('revoked');
    expect(view.revocationReason).toBe('apple_revocation_reason_1');
  });

  it('reports a cancelled auto-renew as cancel-at-period-end while still active', () => {
    const view = storeKitEntitlementView(
      { ...base, expiresDate: (NOW_SECONDS + 86_400) * 1_000 },
      { autoRenewStatus: 0 },
      NOW_SECONDS,
    );
    expect(view.status).toBe('active');
    expect(view.cancelAtPeriodEnd).toBe(true);
  });
});
