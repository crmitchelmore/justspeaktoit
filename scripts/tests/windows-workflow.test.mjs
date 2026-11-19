import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { test } from 'node:test';

const root = new URL('../../', import.meta.url);
const workflow = readFileSync(new URL('.github/workflows/windows.yml', root), 'utf8');
const step = id => workflow.split(`        id: ${id}\n`)[1]?.split('\n      - ')[0] ?? '';

test('the opt-in Windows diagnostics dot-source their scripts behind the manual opt-in', () => {
    for (const [id, script, timeout] of [
        ['owned-capture-diagnostics', 'scripts/ci/windows/owned-capture-diagnostics.ps1', 8],
        ['condition-lock-probe', 'scripts/ci/windows/condition-lock-probe.ps1', 2],
    ]) {
        const body = step(id);
        assert.match(body, /if: \$\{\{ !cancelled\(\) && steps\.owned-capture-build\.outcome == 'success' \}\}/, id);
        assert.match(body, new RegExp(`timeout-minutes: ${timeout}\\n`), id);
        // Dot-sourcing keeps the inline script's scope, `exit` and error semantics.
        assert.match(body, new RegExp(`run: \\. \\./${script.replaceAll('.', '\\.')}$`, 'm'), id);
        assert.ok(existsSync(new URL(script, root)), script);
    }
    assert.match(step('owned-capture-build'), /inputs\.owned_capture_diagnostics == true/);
});

test('the NSConditionLock probe compiles the diagnostic that sits beside it', () => {
    const probe = readFileSync(new URL('scripts/ci/windows/condition-lock-probe.ps1', root), 'utf8');
    const path = probe.match(/^\$scriptPath = '([^']+)'$/m)?.[1];
    assert.ok(path && existsSync(new URL(path, root)), path);
});
