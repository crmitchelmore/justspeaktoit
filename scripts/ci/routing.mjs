// scripts/ci/routing.json for Node tooling: the same routes and glob rules as scripts/ci/routing.py.
import { readFileSync } from 'node:fs';

let cached;
export function routes() {
    cached ??= JSON.parse(readFileSync(new URL('./routing.json', import.meta.url), 'utf8')).routes;
    return cached;
}

const regexes = new Map();
// GitHub's path-filter globs: `**` spans directories, `*` and `?` stay inside one, dot files match.
export function glob(path, pattern) {
    if (!regexes.has(pattern)) {
        let source = '';
        for (let i = 0; i < pattern.length;) {
            if (pattern.startsWith('**/', i)) { source += '(?:.*/)?'; i += 3; }
            else if (pattern.startsWith('**', i)) { source += '.*'; i += 2; }
            else if (pattern[i] === '*') { source += '[^/]*'; i += 1; }
            else if (pattern[i] === '?') { source += '[^/]'; i += 1; }
            else { source += pattern[i].replace(/[.+^${}()|[\]\\]/g, '\\$&'); i += 1; }
        }
        regexes.set(pattern, new RegExp(`^${source}$`));
    }
    return regexes.get(pattern).test(path);
}

export function routeMatches(name, path) {
    const route = routes()[name];
    if (route.quantifier === 'every') {
        return route.paths.every(p => (p.startsWith('!') ? !glob(path, p.slice(1)) : glob(path, p)));
    }
    return route.paths.some(p => glob(path, p));
}
