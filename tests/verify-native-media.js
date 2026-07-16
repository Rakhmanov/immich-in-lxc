const assert = require('node:assert/strict');
const appDir = process.env.IMMICH_APP_DIR;
if (!appDir) {
  throw new Error('IMMICH_APP_DIR must point to the deployed Immich application');
}

// This script lives in the installer snapshot, not the deployed application.
// Resolve Sharp from the application explicitly so Node does not search only
// the snapshot's tests/node_modules hierarchy.
const sharp = require(require.resolve('sharp', { paths: [appDir] }));

async function encode(format) {
  const output = await sharp({
    create: { width: 8, height: 8, channels: 3, background: '#336699' },
  })[format]().toBuffer();
  assert.ok(output.length > 0, `${format} encode produced no data`);
  console.log(`${format}_bytes=${output.length}`);
}

async function main() {
  assert.ok(sharp.versions.vips, 'Sharp did not report a libvips runtime version');
  assert.equal(sharp.format.avif.output, true, 'Sharp lacks AVIF output support');
  assert.equal(sharp.format.jxl.output, true, 'Sharp lacks JPEG-XL output support');

  console.log(JSON.stringify({ versions: sharp.versions, simd: sharp.simd() }));
  await Promise.all(['jpeg', 'avif', 'jxl'].map(encode));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
