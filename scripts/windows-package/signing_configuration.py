#!/usr/bin/env python3
"""Decides whether CI signs the developer MSIX with Azure Artifact Signing.

Signing is configured entirely through GitHub secrets and variables; nothing
in the repository names an account, tenant or certificate. The plan is:

* every setting present and valid: sign, with the manifest publisher set to
  the certificate subject from ``WINDOWS_MSIX_PUBLISHER``;
* no setting present: keep the unsigned developer package and say so;
* anything in between, or an invalid value: fail, naming only the settings
  (never their values), so a half-finished setup is not silently skipped.

``plan`` prints the decision, writes ``enabled`` and ``publisher`` to
``$GITHUB_OUTPUT`` and, when enabled, the SignTool dlib ``metadata.json``.
"""
import argparse
import json
import os
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import windows_msix  # noqa: E402

# GitHub secrets: identify the Entra app whose federated credential trusts
# this repository's `windows-signing` environment. No client secret exists.
SECRETS = ("AZURE_ARTIFACT_SIGNING_CLIENT_ID", "AZURE_ARTIFACT_SIGNING_TENANT_ID",
           "AZURE_ARTIFACT_SIGNING_SUBSCRIPTION_ID")
# GitHub variables: where to sign and which certificate subject to expect.
VARIABLES = ("AZURE_ARTIFACT_SIGNING_ENDPOINT", "AZURE_ARTIFACT_SIGNING_ACCOUNT",
             "AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE", "WINDOWS_MSIX_PUBLISHER")
SETTINGS = SECRETS + VARIABLES
TIMESTAMP_URL = "http://timestamp.acs.microsoft.com"
UNSIGNED_MESSAGE = ("Azure Artifact Signing is not configured (no signing secrets or variables are set); "
                    "keeping the unsigned developer MSIX. See Docs/windows-installer.md to enable signing.")

GUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
# Regional endpoints are https://<region code>.codesigning.azure.net.
ENDPOINT = re.compile(r"https://[a-z0-9]{2,8}\.codesigning\.azure\.net/?")
# Artifact Signing naming rules: accounts 3-24, profiles 5-100 alphanumerics
# or hyphens, starting with a letter, ending alphanumeric, no "--".
ACCOUNT = re.compile(r"[A-Za-z](?!.*--)[A-Za-z0-9-]{1,22}[A-Za-z0-9]")
PROFILE = re.compile(r"[A-Za-z](?!.*--)[A-Za-z0-9-]{3,98}[A-Za-z0-9]")
# DefaultAzureCredential then uses only the Azure CLI session from azure/login.
EXCLUDED_CREDENTIALS = [
    "EnvironmentCredential", "WorkloadIdentityCredential", "ManagedIdentityCredential",
    "SharedTokenCacheCredential", "VisualStudioCredential", "VisualStudioCodeCredential",
    "AzurePowerShellCredential", "AzureDeveloperCliCredential", "InteractiveBrowserCredential",
]


class SigningConfigurationError(Exception):
    pass


def _validators():
    return {
        "AZURE_ARTIFACT_SIGNING_CLIENT_ID": GUID.fullmatch,
        "AZURE_ARTIFACT_SIGNING_TENANT_ID": GUID.fullmatch,
        "AZURE_ARTIFACT_SIGNING_SUBSCRIPTION_ID": GUID.fullmatch,
        "AZURE_ARTIFACT_SIGNING_ENDPOINT": ENDPOINT.fullmatch,
        "AZURE_ARTIFACT_SIGNING_ACCOUNT": ACCOUNT.fullmatch,
        "AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE": PROFILE.fullmatch,
        "WINDOWS_MSIX_PUBLISHER": _valid_publisher,
    }


def _valid_publisher(value):
    try:
        windows_msix.validate_publisher(value)
    except windows_msix.PackageError:
        return False
    return value != windows_msix.load_identity()["identity"]["developerPublisher"]


def plan(environment):
    """Returns ``{"enabled": bool, ...}`` or raises for a partial or invalid setup."""
    values = {name: (environment.get(name) or "").strip() for name in SETTINGS}
    present = [name for name in SETTINGS if values[name]]
    if not present:
        return {"enabled": False, "message": UNSIGNED_MESSAGE}
    missing = [name for name in SETTINGS if not values[name]]
    if missing:
        raise SigningConfigurationError(
            "Azure Artifact Signing is partly configured; also set " + ", ".join(missing)
            + " (or remove " + ", ".join(present) + " to keep the unsigned package).")
    invalid = [name for name, check in _validators().items() if not check(values[name])]
    if invalid:
        raise SigningConfigurationError("Azure Artifact Signing settings are malformed: " + ", ".join(invalid)
                                        + ". See Docs/windows-installer.md for the expected formats.")
    return {
        "enabled": True,
        "publisher": values["WINDOWS_MSIX_PUBLISHER"],
        "timestampUrl": TIMESTAMP_URL,
        "metadata": {
            "Endpoint": values["AZURE_ARTIFACT_SIGNING_ENDPOINT"].rstrip("/"),
            "CodeSigningAccountName": values["AZURE_ARTIFACT_SIGNING_ACCOUNT"],
            "CertificateProfileName": values["AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE"],
            "ExcludeCredentials": EXCLUDED_CREDENTIALS,
        },
        "message": "Azure Artifact Signing is configured; signing the developer MSIX as "
                   + values["WINDOWS_MSIX_PUBLISHER"] + ".",
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--github-output", type=pathlib.Path, help="append enabled/publisher step outputs here")
    parser.add_argument("--metadata", type=pathlib.Path, help="write the SignTool dlib metadata.json here")
    args = parser.parse_args(argv)
    try:
        decision = plan(os.environ)
    except SigningConfigurationError as error:
        print("::error::" + str(error), flush=True)
        return 1
    print(decision["message"], flush=True)
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as output:
            output.write("enabled=%s\n" % ("true" if decision["enabled"] else "false"))
            if decision["enabled"]:
                output.write("publisher=%s\n" % decision["publisher"])
    if decision["enabled"] and args.metadata:
        args.metadata.write_text(json.dumps(decision["metadata"], indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
