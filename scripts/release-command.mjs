import { execFileSync } from 'node:child_process';
import { closeSync, mkdtempSync, openSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// GitHub release and CI histories grow over time. Spool stdout to a private
// temporary file instead of imposing execFileSync's fixed pipe-buffer limit.
export function runReleaseCommand(command, args) {
    const directory = mkdtempSync(join(tmpdir(), 'release-command-'));
    const output = join(directory, 'stdout');
    try {
        const descriptor = openSync(output, 'w', 0o600);
        try {
            execFileSync(command, args, { stdio: ['pipe', descriptor, 'inherit'] });
        } finally {
            closeSync(descriptor);
        }
        return readFileSync(output, 'utf8').trim();
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
}
