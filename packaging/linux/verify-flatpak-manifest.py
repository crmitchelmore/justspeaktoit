#!/usr/bin/env python3
"""Check the resolved Flatpak build contract before an expensive native build."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def verify(manifest):
    # Preserve the existing desktop/microphone permissions; the only new finish
    # argument configures the app-owned inference runtime, not sandbox access.
    assert set(manifest['finish-args']) == {
        '--share=network', '--share=ipc', '--socket=wayland', '--socket=fallback-x11',
        '--socket=pulseaudio', '--device=dri', '--talk-name=org.kde.StatusNotifierWatcher',
        '--env=JSTI_WHISPER_RUNTIME_DIRECTORY=/app/lib/justspeaktoit',
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
    for module in modules.values():
        for source in module.get('sources', []):
            if source.get('type') == 'git':
                assert len(source.get('commit', '')) == 40, 'all git sources must be pinned'
    print('Flatpak pins, offline build and existing sandbox permissions verified.')


if __name__ == '__main__':
    verify(json.loads(Path(sys.argv[1]).read_text()))
