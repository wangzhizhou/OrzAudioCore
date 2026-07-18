#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const readJSON = async path => JSON.parse(await readFile(resolve(root, path), 'utf8'));
const manifest = await readJSON('decoder-manifest.json');
const webManifest = await readJSON('SDK/Web/decoder-manifest.json');
const webPackage = await readJSON('SDK/Web/package.json');
const webLock = await readJSON('SDK/Web/package-lock.json');
const cmake = await readFile(resolve(root, 'CMakeLists.txt'), 'utf8');

const version = manifest.sdkVersion;
const semver = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?$/;
const match = semver.exec(version);
if (!match) throw new Error(`Invalid SDK semver: ${version}`);

const expected = new Map([
  ['SDK/Web/package.json', webPackage.version],
  ['SDK/Web/package-lock.json', webLock.version],
  ['SDK/Web/package-lock.json root package', webLock.packages?.['']?.version],
  ['SDK/Web/decoder-manifest.json', webManifest.sdkVersion],
]);
for (const [source, actual] of expected) {
  if (actual !== version) throw new Error(`${source} has ${actual ?? 'no version'}; expected ${version}`);
}
if (JSON.stringify(webManifest) !== JSON.stringify(manifest)) {
  throw new Error('SDK/Web/decoder-manifest.json differs from decoder-manifest.json');
}

const baseVersion = `${match[1]}.${match[2]}.${match[3]}`;
if (!cmake.includes(`project(OrzAudioCore VERSION ${baseVersion} `)) {
  throw new Error(`CMake project version does not match ${baseVersion}`);
}

const requestedTag = process.argv[2];
if (requestedTag && requestedTag !== version) {
  throw new Error(`Release tag version ${requestedTag} does not match ${version}`);
}

console.log(`release metadata ready: ${version} (${match[4] ? 'prerelease' : 'stable'})`);
