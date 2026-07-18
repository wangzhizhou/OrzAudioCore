#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const stage = process.argv[2];
if (!stage) throw new Error('usage: generate-release-metadata.mjs <staging-directory>');
const root = path.resolve(import.meta.dirname, '..');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'decoder-manifest.json'), 'utf8'));
const packages = new Map();
for (const format of manifest.formats) {
  packages.set(`${format.decoder}@${format.version}`, {
    name: format.decoder,
    version: format.version,
    formats: []
  });
  packages.get(`${format.decoder}@${format.version}`).formats.push(format.id);
}
const sbom = {
  bomFormat: 'CycloneDX',
  specVersion: '1.5',
  version: 1,
  metadata: { component: { type: 'library', name: 'OrzAudioCore', version: manifest.sdkVersion } },
  components: [...packages.values()].map(({formats, ...component}) => ({
    type: 'library',
    ...component,
    properties: [{name: 'orz:formats', value: formats.join(',')}]
  }))
};
fs.writeFileSync(path.join(stage, 'metadata', 'sbom.cdx.json'), `${JSON.stringify(sbom, null, 2)}\n`);
fs.writeFileSync(path.join(stage, 'metadata', 'build-info.json'), `${JSON.stringify({
  sdkVersion: manifest.sdkVersion,
  abiVersion: manifest.abiVersion,
  generatedAt: process.env.SOURCE_DATE_EPOCH
    ? new Date(Number(process.env.SOURCE_DATE_EPOCH) * 1000).toISOString()
    : new Date().toISOString(),
  decoderCount: packages.size,
  formatCount: manifest.formats.length
}, null, 2)}\n`);
