# Windows developer MSIX package

These scripts turn the verified self-contained runtime bundle into an unsigned
Windows x64 developer MSIX, pack it with Microsoft's pinned MakeAppx, sign
copies with an externally supplied certificate and run the install, upgrade,
failure and uninstall lifecycle on a disposable Windows machine.

| File | Role |
|---|---|
| `package-identity.json` | The developer package identity, capabilities and data policy |
| `AppxManifest.xml.in` | The reviewed manifest template |
| `build-windows-package-layout.py` | Authenticates the bundle and writes the package layout |
| `pack-windows-package.ps1` | MakeAppx pack and independent block-map verification |
| `sign-windows-package.ps1` | Signs a copy with a certificate from a Windows store |
| `sign-windows-package-artifact-signing.ps1` | Signs a copy through Azure Artifact Signing (pinned dlib, timestamped) |
| `signing_configuration.py` | Decides from CI secrets and variables whether to sign, and writes the dlib metadata |
| `test-windows-package-lifecycle.ps1` | Disposable-machine lifecycle test (Windows PowerShell 5.1, elevated) |
| `LifecycleOwnership.ps1`, `test-lifecycle-ownership.ps1` | Admission and owned-state cleanup rules, verified against a fake machine |
| `test-windows-package-admission.ps1` | Negative control: the lifecycle test must refuse, and leave untouched, an existing installation |
| `verify-windows-package.py`, `windows_msix.py`, `lifecycle_support.py` | Shared checks, fixture and negative controls |

Design, data behaviour, signing, evidence and remaining gates are in
[Docs/windows-installer.md](../../Docs/windows-installer.md).

```sh
python3 -B -m unittest discover -s scripts/windows-package -p 'test_*.py'
pwsh -NoProfile -File scripts/windows-package/test-lifecycle-ownership.ps1
```
