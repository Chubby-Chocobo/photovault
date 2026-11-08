#!/usr/bin/env node

/**
 * Polar Webhook Verification Script
 *
 * Verifies Polar webhook signatures following Standard Webhooks specification.
 *
 * Usage:
 *   node polar-webhook-verify.js <webhook-payload-json> <webhook-secret>
 *
 * Environment Variables:
 *   POLAR_WEBHOOK_SECRET - Webhook secret as shown in the Polar dashboard
 *
 * Secret handling: a secret starting with "whsec_" is a Standard Webhooks
 * secret and its remainder is base64-decoded. Any other secret is used as its
 * raw UTF-8 bytes, which is what the Polar SDK does before verifying.
 */

const crypto = require('crypto');

const DEFAULT_TOLERANCE_SECONDS = 300;

function decodeSecret(secret) {
  if (secret.startsWith('whsec_')) {
    return Buffer.from(secret.slice('whsec_'.length), 'base64');
  }
  return Buffer.from(secret, 'utf8');
}

function safeEqual(a, b) {
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  return bufA.length === bufB.length && crypto.timingSafeEqual(bufA, bufB);
}

class PolarWebhookVerifier {
  /**
   * @param {string} secret - Webhook secret
   * @param {{toleranceSeconds?: number, now?: () => number}} [options] - `now` returns unix seconds
   */
  constructor(secret, options = {}) {
    if (!secret) {
      throw new Error('Webhook secret is required');
    }
    this.secret = decodeSecret(secret);
    this.toleranceSeconds = options.toleranceSeconds ?? DEFAULT_TOLERANCE_SECONDS;
    this.now = options.now || (() => Math.floor(Date.now() / 1000));
  }

  /**
   * Verify webhook signature (Standard Webhooks: signs `id.timestamp.body`)
   */
  verifySignature(payload, headers) {
    const webhookId = headers['webhook-id'];
    const webhookTimestamp = headers['webhook-timestamp'];
    const webhookSignature = headers['webhook-signature'];

    if (!webhookId || !webhookTimestamp || !webhookSignature) {
      throw new Error('Missing required webhook headers');
    }

    if (!/^\d+$/.test(String(webhookTimestamp))) {
      throw new Error('Invalid webhook timestamp');
    }
    const timestamp = parseInt(webhookTimestamp, 10);
    if (Math.abs(this.now() - timestamp) > this.toleranceSeconds) {
      throw new Error('Webhook timestamp too old or in future');
    }

    // Header is a space-separated list of "version,signature" entries
    const signatures = String(webhookSignature).split(' ').filter(Boolean).map(entry => {
      const comma = entry.indexOf(',');
      return comma === -1
        ? { version: '', signature: '' }
        : { version: entry.slice(0, comma), signature: entry.slice(comma + 1) };
    });

    const signedContent = `${webhookId}.${webhookTimestamp}.${payload}`;
    const expectedSignature = crypto
      .createHmac('sha256', this.secret)
      .update(signedContent)
      .digest('base64');

    // Evaluate every entry so timing does not reveal which one matched
    let isValid = false;
    for (const sig of signatures) {
      if (sig.version === 'v1' && safeEqual(sig.signature, expectedSignature)) {
        isValid = true;
      }
    }

    if (!isValid) {
      throw new Error('Invalid webhook signature');
    }

    return true;
  }

  /**
   * Process webhook event
   */
  process(payload, headers) {
    try {
      // Verify signature
      this.verifySignature(payload, headers);

      // Parse payload
      const event = typeof payload === 'string' ? JSON.parse(payload) : payload;

      // Validate event structure
      if (!event.type || !event.data) {
        throw new Error('Invalid event structure');
      }

      return {
        success: true,
        event: {
          type: event.type,
          data: event.data
        }
      };
    } catch (error) {
      return {
        success: false,
        error: error.message
      };
    }
  }

  /**
   * Get event category
   */
  static getEventCategory(eventType) {
    const categories = {
      'checkout.': 'checkout',
      'order.': 'order',
      'subscription.': 'subscription',
      'customer.': 'customer',
      'benefit_grant.': 'benefit',
      'refund.': 'refund',
      'product.': 'product'
    };

    for (const [prefix, category] of Object.entries(categories)) {
      if (eventType.startsWith(prefix)) {
        return category;
      }
    }

    return 'unknown';
  }

  /**
   * Check if event is a payment
   */
  static isPaymentEvent(eventType) {
    return ['order.paid', 'order.created'].includes(eventType);
  }

  /**
   * Check if event is a subscription change
   */
  static isSubscriptionEvent(eventType) {
    return eventType.startsWith('subscription.');
  }
}

// CLI Usage
if (require.main === module) {
  const args = process.argv.slice(2);

  if (args.length < 1) {
    console.log('Usage: node polar-webhook-verify.js <webhook-payload-json> [webhook-secret]');
    console.log('\nWebhook secret can also be provided via POLAR_WEBHOOK_SECRET environment variable');
    console.log('\nExample:');
    console.log('  node polar-webhook-verify.js \'{"type":"order.paid","data":{...}}\' whsec_...');
    process.exit(1);
  }

  try {
    const payload = args[0];
    const secret = args[1] || process.env.POLAR_WEBHOOK_SECRET;

    if (!secret) {
      console.error('✗ Error: Webhook secret is required');
      console.error('Provide it as second argument or set POLAR_WEBHOOK_SECRET environment variable');
      process.exit(1);
    }

    // Mock headers for CLI testing
    const timestamp = Math.floor(Date.now() / 1000);
    const webhookId = 'msg_test_' + Date.now();
    const signature = crypto
      .createHmac('sha256', decodeSecret(secret))
      .update(`${webhookId}.${timestamp}.${payload}`)
      .digest('base64');

    const headers = {
      'webhook-id': webhookId,
      'webhook-timestamp': timestamp.toString(),
      'webhook-signature': `v1,${signature}`
    };

    const verifier = new PolarWebhookVerifier(secret);
    const result = verifier.process(payload, headers);

    if (result.success) {
      console.log('✓ Webhook verified successfully\n');
      console.log('Event Details:');
      console.log(`  Type: ${result.event.type}`);
      console.log(`  Category: ${PolarWebhookVerifier.getEventCategory(result.event.type)}`);
      console.log(`  Is Payment: ${PolarWebhookVerifier.isPaymentEvent(result.event.type) ? 'Yes' : 'No'}`);
      console.log(`  Is Subscription: ${PolarWebhookVerifier.isSubscriptionEvent(result.event.type) ? 'Yes' : 'No'}`);
      console.log('\nEvent Data:');
      console.log(JSON.stringify(result.event.data, null, 2));
    } else {
      console.error('✗ Verification failed:', result.error);
      process.exit(1);
    }
  } catch (error) {
    console.error('✗ Error:', error.message);
    process.exit(1);
  }
}

module.exports = PolarWebhookVerifier;
