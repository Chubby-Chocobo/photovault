#!/usr/bin/env node

/**
 * Test suite for payment integration scripts
 */

const SePayWebhookVerifier = require('./sepay-webhook-verify');
const PolarWebhookVerifier = require('./polar-webhook-verify');
const CheckoutHelper = require('./checkout-helper');

class TestRunner {
  constructor() {
    this.passed = 0;
    this.failed = 0;
  }

  test(name, fn) {
    try {
      fn();
      console.log(`✓ ${name}`);
      this.passed++;
    } catch (error) {
      console.error(`✗ ${name}`);
      console.error(`  Error: ${error.message}`);
      this.failed++;
    }
  }

  assert(condition, message) {
    if (!condition) {
      throw new Error(message || 'Assertion failed');
    }
  }

  assertEqual(actual, expected, message) {
    if (actual !== expected) {
      throw new Error(message || `Expected ${expected}, got ${actual}`);
    }
  }

  summary() {
    console.log(`\nTest Summary: ${this.passed} passed, ${this.failed} failed`);
    return this.failed === 0;
  }
}

// Run tests
console.log('Running Payment Integration Script Tests\n');
const runner = new TestRunner();

// SePay Webhook Verifier Tests
console.log('SePay Webhook Verifier Tests:');

runner.test('should verify valid SePay webhook', () => {
  const verifier = new SePayWebhookVerifier('none');
  const payload = {
    id: 12345,
    gateway: 'Vietcombank',
    transactionDate: '2025-01-13 10:00:00',
    accountNumber: '0123456789',
    transferType: 'in',
    transferAmount: 100000,
    referenceCode: 'REF123',
    content: 'Order payment'
  };

  const result = verifier.process(payload);
  runner.assert(result.success === true, 'Should verify successfully');
  runner.assert(result.transaction.id === 12345, 'Should parse transaction ID');
  runner.assert(result.isIncoming === true, 'Should detect incoming transfer');
});

runner.test('should reject invalid SePay transfer type', () => {
  const verifier = new SePayWebhookVerifier('none');
  const payload = {
    id: 12345,
    gateway: 'Vietcombank',
    transactionDate: '2025-01-13 10:00:00',
    accountNumber: '0123456789',
    transferType: 'invalid',
    transferAmount: 100000,
    referenceCode: 'REF123'
  };

  const result = verifier.process(payload);
  runner.assert(result.success === false, 'Should fail validation');
  runner.assert(result.error.includes('Invalid transferType'), 'Should report invalid transfer type');
});

runner.test('should verify SePay webhook with API key', () => {
  const verifier = new SePayWebhookVerifier('api_key', 'test_key_123');
  const payload = {
    id: 12345,
    gateway: 'Vietcombank',
    transactionDate: '2025-01-13 10:00:00',
    accountNumber: '0123456789',
    transferType: 'in',
    transferAmount: 100000,
    referenceCode: 'REF123'
  };

  const headers = { Authorization: 'Apikey test_key_123' };
  const result = verifier.process(payload, headers);
  runner.assert(result.success === true, 'Should verify with valid API key');
});

runner.test('should reject SePay webhook with invalid API key', () => {
  const verifier = new SePayWebhookVerifier('api_key', 'test_key_123');
  const payload = {
    id: 12345,
    gateway: 'Vietcombank',
    transactionDate: '2025-01-13 10:00:00',
    accountNumber: '0123456789',
    transferType: 'in',
    transferAmount: 100000,
    referenceCode: 'REF123'
  };

  const headers = { Authorization: 'Apikey wrong_key' };
  const result = verifier.process(payload, headers);
  runner.assert(result.success === false, 'Should reject invalid API key');
});

// Polar Webhook Verifier Tests
console.log('\nPolar Webhook Verifier Tests:');

runner.test('should verify valid Polar webhook', () => {
  const crypto = require('crypto');
  const secret = 'test_secret_key';
  const verifier = new PolarWebhookVerifier(secret);

  const payload = JSON.stringify({
    type: 'order.paid',
    data: { id: 'order_123', amount: 2000 }
  });

  const timestamp = Math.floor(Date.now() / 1000);
  const signedContent = `msg_123.${timestamp}.${payload}`;
  const signature = crypto
    .createHmac('sha256', Buffer.from(secret, 'utf8'))
    .update(signedContent)
    .digest('base64');

  const headers = {
    'webhook-id': 'msg_123',
    'webhook-timestamp': timestamp.toString(),
    'webhook-signature': `v1,${signature}`
  };

  const result = verifier.process(payload, headers);
  if (!result.success) {
    throw new Error(`Verification failed: ${result.error}`);
  }
  runner.assert(result.success === true, 'Should verify successfully');
  runner.assertEqual(result.event.type, 'order.paid', 'Should parse event type');
});

runner.test('should reject Polar webhook with invalid signature', () => {
  const secret = 'test_secret_key';
  const verifier = new PolarWebhookVerifier(secret);

  const payload = JSON.stringify({
    type: 'order.paid',
    data: { id: 'order_123' }
  });

  const headers = {
    'webhook-id': 'msg_123',
    'webhook-timestamp': Math.floor(Date.now() / 1000).toString(),
    'webhook-signature': 'v1,invalid_signature'
  };

  const result = verifier.process(payload, headers);
  runner.assert(result.success === false, 'Should reject invalid signature');
});

// Vectors computed with `openssl dgst -sha256 -hmac` over `id.timestamp.body`,
// independent of the verifier code.
const VECTOR_BODY = '{"test": 2432232314}';
const VECTOR_TIMESTAMP = '1614265330';
const vectorNow = () => 1614265330;

function verifyVector(secret, id, signature, overrides = {}) {
  const verifier = new PolarWebhookVerifier(secret, { now: vectorNow });
  return verifier.verifySignature(overrides.body || VECTOR_BODY, {
    'webhook-id': id,
    'webhook-timestamp': overrides.timestamp || VECTOR_TIMESTAMP,
    'webhook-signature': signature
  });
}

runner.test('should verify a Polar-style secret against an openssl vector', () => {
  const sig = 'PIkiJ8uTnbcJVAnmrF2/hhDd6336m/AfeASjsB5uHII=';
  runner.assert(verifyVector('polar_whs_testsecret', 'msg_2KWPBgLlAfxdpx2AI54pPJ85f4W', `v1,${sig}`) === true);
});

runner.test('should verify a whsec_ secret against an openssl vector', () => {
  const sig = 'g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=';
  const secret = 'whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw';
  runner.assert(verifyVector(secret, 'msg_p5jXN8AQM9LWM0D4loKWxJek', `v1,${sig}`) === true);
});

runner.test('should accept any matching entry in a space-separated signature list', () => {
  const sig = 'PIkiJ8uTnbcJVAnmrF2/hhDd6336m/AfeASjsB5uHII=';
  runner.assert(verifyVector('polar_whs_testsecret', 'msg_2KWPBgLlAfxdpx2AI54pPJ85f4W', `v1,bogus v2,${sig} v1,${sig}`) === true);
});

runner.test('should reject the old timestamp.body signing scheme and wrong message id', () => {
  const sig = 'PIkiJ8uTnbcJVAnmrF2/hhDd6336m/AfeASjsB5uHII=';
  let threw = false;
  try { verifyVector('polar_whs_testsecret', 'msg_other', `v1,${sig}`); } catch { threw = true; }
  runner.assert(threw, 'Signature bound to a different webhook-id must fail');
});

runner.test('should reject a tampered body and an unknown version', () => {
  const sig = 'PIkiJ8uTnbcJVAnmrF2/hhDd6336m/AfeASjsB5uHII=';
  const id = 'msg_2KWPBgLlAfxdpx2AI54pPJ85f4W';
  let tampered = false;
  try { verifyVector('polar_whs_testsecret', id, `v1,${sig}`, { body: '{"test": 1}' }); } catch { tampered = true; }
  runner.assert(tampered, 'Tampered body must fail');
  let wrongVersion = false;
  try { verifyVector('polar_whs_testsecret', id, `v2,${sig}`); } catch { wrongVersion = true; }
  runner.assert(wrongVersion, 'Only v1 signatures count');
});

runner.test('should reject timestamps outside the tolerance window', () => {
  const sig = 'PIkiJ8uTnbcJVAnmrF2/hhDd6336m/AfeASjsB5uHII=';
  const verifier = new PolarWebhookVerifier('polar_whs_testsecret', { now: () => 1614265330 + 301 });
  let threw = false;
  try {
    verifier.verifySignature(VECTOR_BODY, {
      'webhook-id': 'msg_2KWPBgLlAfxdpx2AI54pPJ85f4W',
      'webhook-timestamp': VECTOR_TIMESTAMP,
      'webhook-signature': `v1,${sig}`
    });
  } catch { threw = true; }
  runner.assert(threw, 'Stale timestamp must fail');
});

runner.test('should categorize Polar event types', () => {
  runner.assertEqual(PolarWebhookVerifier.getEventCategory('order.paid'), 'order');
  runner.assertEqual(PolarWebhookVerifier.getEventCategory('subscription.active'), 'subscription');
  runner.assertEqual(PolarWebhookVerifier.getEventCategory('customer.created'), 'customer');
  runner.assert(PolarWebhookVerifier.isPaymentEvent('order.paid') === true);
  runner.assert(PolarWebhookVerifier.isSubscriptionEvent('subscription.active') === true);
});

// Checkout Helper Tests
console.log('\nCheckout Helper Tests:');

runner.test('should generate SePay checkout fields', () => {
  const config = {
    merchantId: 'SP-TEST-123',
    secretKey: 'test_secret',
    orderInvoiceNumber: 'ORD001',
    orderAmount: 100000,
    successUrl: 'https://example.com/success',
    errorUrl: 'https://example.com/error',
    cancelUrl: 'https://example.com/cancel',
    env: 'sandbox'
  };

  const result = CheckoutHelper.generateSePayCheckout(config);
  runner.assert(result.fields !== undefined, 'Should generate fields');
  runner.assert(result.fields.signature !== undefined, 'Should generate signature');
  runner.assertEqual(result.fields.merchant_id, 'SP-TEST-123', 'Should include merchant ID');
  runner.assert(result.formUrl.includes('sandbox'), 'Should use sandbox URL');
});

runner.test('should generate Polar checkout config', () => {
  const config = {
    productPriceId: 'price_123',
    successUrl: 'https://example.com/success',
    externalCustomerId: 'user_123',
    accessToken: 'test_token',
    server: 'sandbox'
  };

  const result = CheckoutHelper.generatePolarCheckout(config);
  runner.assert(result.config !== undefined, 'Should generate config');
  runner.assertEqual(result.config.product_price_id, 'price_123', 'Should include price ID');
  runner.assertEqual(result.config.external_customer_id, 'user_123', 'Should include customer ID');
  runner.assert(result.apiEndpoint.includes('sandbox'), 'Should use sandbox endpoint');
});

runner.test('should reject Polar config with relative URL', () => {
  try {
    CheckoutHelper.generatePolarCheckout({
      productPriceId: 'price_123',
      successUrl: '/success' // Relative URL
    });
    runner.assert(false, 'Should throw error for relative URL');
  } catch (error) {
    runner.assert(error.message.includes('absolute URL'), 'Should require absolute URL');
  }
});

runner.test('should reject a wrong or differently sized SePay API key', () => {
  const verifier = new SePayWebhookVerifier('api_key', 'test_key_123');
  for (const header of ['Apikey test_key_124', 'Apikey test_key_1234', 'Apikey ', 'Bearer test_key_123']) {
    let threw = false;
    try { verifier.verifyAuthentication({ authorization: header }); } catch (error) { threw = error.message === 'Invalid API key'; }
    runner.assert(threw, `Should reject ${header}`);
  }
  runner.assert(verifier.verifyAuthentication({ authorization: 'Apikey test_key_123' }) === true, 'Should accept the right key');
});

runner.test('should not accept an unverified SePay OAuth2 Bearer token', () => {
  const verifier = new SePayWebhookVerifier('oauth2');
  let threw = false;
  try { verifier.verifyAuthentication({ authorization: 'Bearer anything' }); } catch (error) { threw = /not verified/.test(error.message); }
  runner.assert(threw, 'Should refuse a Bearer token it cannot verify');
});

// Run summary
const success = runner.summary();
process.exit(success ? 0 : 1);
