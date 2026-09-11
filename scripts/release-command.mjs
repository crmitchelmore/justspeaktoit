import { execFileSync } from 'node:child_process';

// Release histories include every asset and routinely exceed Node's 1 MiB default.
// Match the bounded allowance already used by release-notes-lib.mjs.
export function runReleaseCommand(command, args) {
    return execFileSync(command, args, {
        encoding: 'utf8',
        stdio: ['pipe', 'pipe', 'inherit'],
        maxBuffer: 16 * 1024 * 1024,
    }).trim();
}
