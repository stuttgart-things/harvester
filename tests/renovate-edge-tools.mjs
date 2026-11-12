import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import test from 'node:test';

const config = JSON.parse(readFileSync('renovate.json', 'utf8'));
function extract(file) {
  const content = readFileSync(file, 'utf8');
  return config.customManagers.flatMap(manager => {
    if (!manager.managerFilePatterns.some(pattern => new RegExp(pattern.slice(1, -1)).test(file))) return [];
    return manager.matchStrings.flatMap(pattern => [...content.matchAll(new RegExp(pattern, 'g'))].map(match => ({
      dep: manager.depNameTemplate ?? match.groups.depName,
      value: match.groups.currentValue,
      versioning: manager.versioningTemplate,
    })));
  });
}

test('explicit platform overrides are tracked once in source and generated output', () => {
  for (const file of ['clusters/edge/cluster-apps.yaml', 'clusters/edge/apps/apps-platform.yaml']) {
    const deps = extract(file);
    for (const dep of ['homerun2-notification-catcher', 'homerun2-notification-catcher-kustomize', 'redis-stack-server', 'charts/minio/minio']) {
      const matches = deps.filter(item => item.dep === `ghcr.io/stuttgart-things/${dep}`);
      assert.equal(matches.length, 1, `${file}: ${dep}`);
      if (dep === 'redis-stack-server') {
        assert.equal(matches[0].value, '7.4.0-v8');
        assert.equal(new RegExp(matches[0].versioning.slice(6)).exec('7.4.0-v9').groups.build, '9');
      }
    }
  }
});

test('Zaehlwerk helpers and ACME use release tracking, with both log-sink workloads grouped', () => {
  const piezo = extract('clusters/edge/lab/esp-mock/piezo-a.yaml');
  assert.equal(piezo.filter(item => item.dep === 'goacme/lego').length, 1);
  assert.equal(piezo.filter(item => item.dep === 'ghcr.io/stuttgart-things/zaehlwerk-piezo').length, 1);
  const sink = extract('clusters/edge/lab/log-sink/log-sink.yaml');
  assert.equal(sink.length, 2);
  assert.ok(sink.every(item => item.dep === 'ghcr.io/stuttgart-things/zaehlwerk-log-sink' && /^v\d+\.\d+\.\d+$/.test(item.value)));
  assert.ok(config.packageRules.some(rule => rule.groupSlug === 'edge-zaehlwerk-log-sink'));
});

test('platform mirror groups and MinIO compatibility hold are retained', () => {
  const rules = config.packageRules;
  const catcher = rules.find(rule => rule.groupSlug === 'edge-notification-catcher');
  assert.equal(catcher.matchPackageNames.length, 2);
  for (const slug of ['edge-redis-stack', 'edge-minio']) assert.ok(rules.some(rule => rule.groupSlug === slug));
  assert.ok(rules.some(rule => rule.matchPackageNames.includes('ghcr.io/stuttgart-things/charts/minio/minio') && rule.allowedVersions === '<17.0.0'));
});
