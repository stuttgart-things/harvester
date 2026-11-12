import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const config = JSON.parse(readFileSync('renovate.json', 'utf8'));
const dependency = 'ghcr.io/stuttgart-things/flux/repo';
const manager = config.customManagers.find(m => m.depNameTemplate === dependency);
const files = ['clusters/edge/cluster-apps.yaml', 'clusters/edge/apps.yaml'];
const selected = file => manager.managerFilePatterns.some(pattern => new RegExp(pattern.slice(1, -1)).test(file));
function matches(text) {
  return manager.matchStrings.flatMap(pattern => [...text.matchAll(new RegExp(pattern, 'g'))]);
}

test('both actual edge pins are extracted exactly once and agree', () => {
  assert.ok(manager, 'missing edge Flux manager');
  const versions = files.map(file => {
    assert.ok(selected(file));
    const found = matches(readFileSync(file, 'utf8'));
    assert.equal(found.length, 1, `${file}: expected one Flux repo pin`);
    return found[0].groups.currentValue;
  });
  assert.equal(versions[0], versions[1], 'ClusterApps and generated source pins drifted');
  assert.match(versions[0], /^v\d+\.\d+\.\d+$/);
  assert.equal(manager.datasourceTemplate, 'docker');
  assert.equal(manager.versioningTemplate, 'semver');
  assert.equal(manager.extractVersionTemplate, undefined, 'preserve registry tags including v');
});

test('the rule stays scoped to edge and ignores other OCI dependencies', () => {
  for (const file of ['clusters/sthings-edge/apps.yaml', 'clusters/edge/secrets.yaml', 'clusters/edge/lab/apps.yaml']) {
    assert.equal(selected(file), false, file);
  }
  for (const file of files) {
    const original = readFileSync(file, 'utf8');
    assert.equal(matches(original.replaceAll(dependency, 'example.com/other/repo')).length, 0);
    assert.equal(matches(original.replaceAll(dependency, `${dependency}-other`)).length, 0);
  }
});

test('a future update replaces only the captured version in both file formats', () => {
  for (const file of files) {
    const original = readFileSync(file, 'utf8');
    const found = matches(original)[0];
    const current = found.groups.currentValue;
    const replacement = found[0].replace(current, 'v9.8.7');
    const updated = original.slice(0, found.index) + replacement + original.slice(found.index + found[0].length);
    assert.equal(matches(updated)[0].groups.currentValue, 'v9.8.7');
    assert.equal(updated.replace('v9.8.7', current), original, 'unrelated generated content changed');
  }
});

test('source and generated pins belong to one update group', () => {
  const rules = config.packageRules.filter(r => r.matchPackageNames?.includes(dependency));
  assert.equal(rules.length, 1);
  assert.equal(rules[0].groupSlug, 'edge-flux-bundle');
  assert.ok(rules[0].groupName);
  for (const file of files) assert.ok(rules[0].matchFileNames.includes(file));
});
