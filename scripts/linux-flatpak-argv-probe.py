#!/usr/bin/env python3
"""Write a minimal dynamic/static Swift argv probe, separate from app inputs."""
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
(root / 'main.swift').write_text('''import Foundation
print("CommandLine:", CommandLine.arguments)
print("ProcessInfo:", ProcessInfo.processInfo.arguments)
let raw = try Data(contentsOf: URL(fileURLWithPath: "/proc/self/cmdline"))
print("proc:", raw.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
''')
(root / 'Package.swift').write_text("""// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ArgvProbe", targets: [.executableTarget(name: "ArgvProbe")])
""")
manifest = {
    'app-id': 'com.justspeaktoit.ArgvProbe', 'runtime': 'org.gnome.Platform',
    'runtime-version': '50', 'sdk': 'org.gnome.Sdk',
    'sdk-extensions': ['org.freedesktop.Sdk.Extension.swift6'],
    'command': 'probe-static', 'appstream-compose': False,
    'build-options': {'append-path': '/usr/lib/sdk/swift6/bin',
                      'prepend-ld-library-path': '/usr/lib/sdk/swift6/lib'},
    'modules': [{'name': 'argv-probe', 'buildsystem': 'simple', 'build-commands': [
        'swift --version', 'mkdir -p /app/bin',
        'swiftc main.swift -o /app/bin/probe-dynamic',
        'swiftc -static-stdlib main.swift -o /app/bin/probe-static',
        'swiftc -O -whole-module-optimization -static-stdlib main.swift -o /app/bin/probe-optimized-static',
        'mkdir -p Sources/ArgvProbe && cp main.swift Sources/ArgvProbe/main.swift',
        'swift build --configuration release --static-swift-stdlib --disable-sandbox',
        'cp .build/release/ArgvProbe /app/bin/probe-swiftpm-static',
        "sh -c '/app/bin/probe-optimized-static --version; result=$?; echo optimized-static-exit:$result; exit 0'",
        "sh -c '/app/bin/probe-swiftpm-static --version; result=$?; echo swiftpm-static-exit:$result; exit 0'",
        "sh -c '/app/bin/probe-dynamic --version; result=$?; echo dynamic-exit:$result; exit 0'",
        "sh -c '/app/bin/probe-static --version; result=$?; echo static-exit:$result; exit 0'"],
        'sources': [{'type': 'file', 'path': 'main.swift'}, {'type': 'file', 'path': 'Package.swift'}]}],
}
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
