/*
 * compute-id.js — derive a Chromium extension ID (and the manifest "key"
 * value) from a PEM private key.
 *
 * The ID is the first 128 bits of SHA-256(SubjectPublicKeyInfo DER), hex-encoded
 * and remapped 0-f -> a-p. The manifest "key" field is that same SPKI DER, base64.
 *
 * Usage:  node compute-id.js path\to\key.pem
 */
'use strict';
const crypto = require('crypto');
const fs = require('fs');

const keyPath = process.argv[2];
if (!keyPath) {
  console.error('usage: node compute-id.js <key.pem>');
  process.exit(1);
}

const spkiDer = crypto
  .createPrivateKey(fs.readFileSync(keyPath, 'utf8'))
  .export({ type: 'spki', format: 'der' });

const digest = crypto.createHash('sha256').update(spkiDer).digest();
const id = [...digest.subarray(0, 16)]
  .map((b) => b.toString(16).padStart(2, '0'))
  .join('')
  .replace(/[0-9a-f]/g, (c) => String.fromCharCode(97 + parseInt(c, 16)));

// When run directly, print "id<TAB>base64key" so callers can grab either.
if (require.main === module) {
  if (process.argv[3] === '--id-only') {
    process.stdout.write(id);
  } else {
    process.stdout.write(id + '\t' + spkiDer.toString('base64') + '\n');
  }
}

module.exports = { id, key: spkiDer.toString('base64') };
