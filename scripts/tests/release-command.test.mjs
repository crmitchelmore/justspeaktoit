import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runReleaseCommand } from '../release-command.mjs';

test('release command preserves a GitHub response larger than both the default and a raised 16 MiB limit', () => {
    const output = runReleaseCommand(process.execPath, ['-e',
        'process.stdout.write(JSON.stringify({body: "x".repeat(17 * 1024 * 1024)}))']);
    assert.equal(JSON.parse(output).body.length, 17 * 1024 * 1024);
});

test('release command propagates command failure', () => {
    assert.throws(() => runReleaseCommand(process.execPath, ['-e', 'process.exit(17)']),
        error => error.status === 17);
});
