#!/usr/bin/env python3
"""Check the resolved Flatpak build contract before an expensive native build."""
import argparse
import json
from itertools import islice
import re
import stat
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def verify(manifest):
    # Preserve existing desktop/microphone access. Environment defaults select
    # the app-owned runtime and preseed its existing debugger policy; no new access.
    assert set(manifest['finish-args']) == {
        '--share=network', '--share=ipc', '--socket=wayland', '--socket=fallback-x11',
        '--socket=pulseaudio', '--device=dri', '--talk-name=org.kde.StatusNotifierWatcher',
        '--env=JSTI_WHISPER_RUNTIME_DIRECTORY=/app/lib/justspeaktoit',
        '--env=GGML_NO_BACKTRACE=1',
    }, 'sandbox permissions changed: owner review required'
    assert not manifest.get('build-options', {}).get('build-args'), 'build must be offline'
    modules = {module['name']: module for module in manifest['modules']}
    assert len(modules) == len(manifest['modules']), 'module names must be unique'
    for module in modules.values():
        assert not module.get('build-options', {}).get('build-args'), 'build must be offline'
    pin = json.loads((ROOT / 'scripts/windows-local-runtime/dependencies.json').read_text())['whisperCpp']
    runtime = modules['whisper-cpp']
    source = runtime['sources'][0]
    assert source['commit'] == pin['commit'] and source['tag'] == pin['tag'], 'whisper.cpp pin drift'
    assert '-DCMAKE_INSTALL_LIBDIR=lib/justspeaktoit' in runtime['config-opts']
    assert '-DGGML_NATIVE=OFF' in runtime['config-opts'], 'must run on baseline CPUs'
    assert '-DGGML_CPU_ALL_VARIANTS=ON' in runtime['config-opts']
    assert '-DGGML_VULKAN=ON' in runtime['config-opts']
    local_sources = runtime['sources'][1:]
    expected_sources = [
        (ROOT / 'packaging/linux/verify-flatpak-manifest.py', 'jsti-flatpak-runtime.py'),
        (ROOT / 'scripts/linux-local-runtime/dependencies.json', 'jsti-linux-runtime-policy.json'),
    ]
    assert len(local_sources) == len(expected_sources), 'pre-strip verifier and policy sources missing'
    for source, (expected, destination) in zip(local_sources, expected_sources):
        path = Path(source.get('path', ''))
        if not path.is_absolute():
            path = ROOT / 'packaging/linux' / path
        assert source.get('type') == 'file' and source.get('dest-filename') == destination and \
            path.resolve() == expected.resolve(), 'pre-strip verifier and policy must come from this checkout'
    commands = runtime['post-install']
    assert 'cp -L /app/lib/justspeaktoit/$name' in commands[0]
    assert commands[1] == (
        'python3 "$FLATPAK_BUILDER_BUILDDIR/jsti-flatpak-runtime.py" '
        '--runtime-directory /app/lib/justspeaktoit '
        '--runtime-policy "$FLATPAK_BUILDER_BUILDDIR/jsti-linux-runtime-policy.json" --cleanup-runtime'
    ), 'verify closure and remove duplicates after SONAME copies, before builder stripping'
    assert '/lib/justspeaktoit/libparakeet.so' not in runtime['cleanup'], 'guard must see all Parakeet names'
    for module in modules.values():
        for source in module.get('sources', []):
            if source.get('type') == 'git':
                assert len(source.get('commit', '')) == 40, 'all git sources must be pinned'
    print('Flatpak pins, offline build and existing sandbox permissions verified.')


def inspect_runtime_elf(path, deadline):
    """Use the same build-host readelf fields as the native runtime builder."""
    import resource

    def limit_output():
        resource.setrlimit(resource.RLIMIT_FSIZE, (1 << 20, 1 << 20))

    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ValueError('runtime inspection deadline expired')
    with tempfile.TemporaryFile() as output:
        subprocess.run(['readelf', '--wide', '--file-header', '--dynamic', str(path)],
                       stdout=output, stderr=subprocess.DEVNULL, check=True,
                       timeout=min(10, remaining), preexec_fn=limit_output)
        output.seek(0)
        text = output.read((1 << 20) + 1).decode('utf-8', errors='strict')
    if len(text.encode('utf-8')) > 1 << 20:
        raise ValueError('runtime inspection output exceeds bound')
    kind = re.search(r'^\s*Type:\s+(\S+)', text, re.M)
    machine = re.search(r'^\s*Machine:\s+(.+?)\s*$', text, re.M)
    soname = re.search(r'\(SONAME\)\s+Library soname: \[([^\]]*)\]', text)
    return {
        'type': kind[1] if kind else None,
        'machine': machine[1] if machine else None,
        'soname': soname[1] if soname else None,
        'needed': re.findall(r'\(NEEDED\)\s+Shared library: \[([^\]]*)\]', text),
        'searchPaths': re.findall(r'\((?:RPATH|RUNPATH)\)\s+Library r(?:un)?path: \[([^\]]*)\]', text),
    }


def verify_runtime(directory, policy, cleanup=False, inspect=None):
    """Validate all kept ELF edges before removing only proved redundant names.

    Cleanup runs before Flatpak strips each filename independently. Installed
    checks require absence of leftovers, not equality of post-strip debug links.
    The dependency policy is the native builder's existing canonical JSON.
    """
    directory = Path(directory)
    target = policy['architectures']['x86_64']
    required = set(target['requiredModules'])
    gpu = policy['vulkan']['module']
    system = set(target['systemLibraries']) | set(policy['vulkan']['systemLibraries'])
    entries = list(islice(directory.iterdir(), 65))
    if len(entries) > 64:
        raise ValueError('runtime inventory exceeds bound')
    names = {path.name for path in entries if path.name.startswith('lib') and '.so' in path.name}
    variants = {name for name in names if re.fullmatch(target['cpuVariantPattern'], name)}
    kept = required | variants | {gpu}
    if not kept <= names or len(variants) < target['minimumCpuVariants']:
        raise ValueError('required SONAME, CPU variant or Vulkan module missing')
    development = {name.split('.so.')[0] + '.so' for name in required}
    parakeet = {name for name in names if re.fullmatch(r'libparakeet\.so(?:\.[0-9]+)*', name)}
    originals = {}
    for name in names:
        for canonical in required:
            if re.fullmatch(re.escape(canonical) + r'(?:\.[0-9]+)+', name):
                originals[name] = canonical
    removed = parakeet | set(originals)
    if names - kept - removed - development:
        raise ValueError('unexpected runtime library name')
    if not cleanup and (removed or names & development):
        raise ValueError('unused or development runtime names remain installed')
    deadline = time.monotonic() + 60
    inspect = inspect or (lambda path: inspect_runtime_elf(path, deadline))
    for name in sorted(kept):
        path = directory / name
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 128 << 20:
            raise ValueError('runtime module must be a bounded regular file')
        elf = inspect(path)
        if elf['type'] != 'DYN' or elf['machine'] != target['elfMachine']:
            raise ValueError('runtime module ELF type or machine mismatch')
        if elf['soname'] not in (None, name) or any(value != '$ORIGIN' for value in elf['searchPaths']):
            raise ValueError('runtime SONAME or search path mismatch')
        if any(needed not in kept and needed not in system for needed in elf['needed']):
            raise ValueError('runtime NEEDED edge escapes retained closure')
    for name, canonical in originals.items():
        path = directory / name
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 128 << 20 or \
                not same_runtime_bytes(path, directory / canonical, deadline):
            raise ValueError('full-version original differs from regular SONAME copy')
    for name in parakeet:
        if not (directory / name).is_symlink() and not stat.S_ISREG((directory / name).lstat().st_mode):
            raise ValueError('unexpected unused library file kind')
    # No deletions precede complete validation. Never unlink a canonical name,
    # CPU/Vulkan module, license, or the target of a Parakeet symlink.
    if cleanup:
        for name in sorted(removed):
            (directory / name).unlink()
    print('Flatpak runtime SONAMEs, CPU/Vulkan modules and ELF NEEDED closure verified.')


def same_runtime_bytes(left, right, deadline):
    # No metadata-based comparison cache: prove the pre-strip copies' bytes.
    with left.open('rb') as first, right.open('rb') as second:
        for _ in range(129):
            if time.monotonic() >= deadline:
                raise ValueError('runtime copy comparison deadline expired')
            one, two = first.read(1 << 20), second.read(1 << 20)
            if one != two:
                return False
            if not one:
                return True
    raise ValueError('runtime copy comparison exceeds bound')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', nargs='?', type=Path)
    parser.add_argument('--runtime-directory', type=Path)
    parser.add_argument('--runtime-policy', type=Path, default=ROOT / 'scripts/linux-local-runtime/dependencies.json')
    parser.add_argument('--cleanup-runtime', action='store_true')
    args = parser.parse_args()
    if args.runtime_directory is not None and args.manifest is None:
        verify_runtime(args.runtime_directory, json.loads(args.runtime_policy.read_text()), args.cleanup_runtime)
    elif args.manifest is not None and args.runtime_directory is None and not args.cleanup_runtime:
        verify(json.loads(args.manifest.read_text()))
    else:
        parser.error('choose a manifest or an explicit runtime directory')
