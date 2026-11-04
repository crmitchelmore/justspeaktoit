#!/usr/bin/env python3
"""Decides whether and how CI signs Windows packages.

Signing is configured entirely through GitHub secrets and variables in the
`windows-signing` environment; nothing in the repository names an account,
tenant or certificate. ``WINDOWS_SIGNING_PROVIDER`` selects the route:

* ``artifact-signing`` (the default when unset): Azure Artifact Signing over
  GitHub OIDC. Public Trust is open to organisations in listed countries and
  individuals in the US and Canada;
* ``sslcom-esigner``: an SSL.com code signing certificate in its eSigner cloud
  HSM, loaded into the runner's certificate store by eSigner CKA. Open to
  individuals worldwide.

The plan is:

* every setting for the selected provider present and valid: sign, with the
  manifest publisher set to the certificate subject from
  ``WINDOWS_MSIX_PUBLISHER``;
* no setting present: keep the unsigned package, publish nothing, and say so;
* a provider the calling job does not support (``--supported``): skip;
* anything in between, an unknown provider, settings for two providers, or an
  invalid value: fail, naming only the settings (never their values), so a
  half-finished setup is not silently skipped.

``plan`` prints the decision, writes ``enabled``, ``provider``, ``publisher``,
``timestamp-url`` and, for certificate-store providers, ``certificate-thumbprint``
to ``$GITHUB_OUTPUT`` and, for Artifact Signing, the SignTool dlib
``metadata.json``.
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

PROVIDER = "WINDOWS_SIGNING_PROVIDER"
PUBLISHER = "WINDOWS_MSIX_PUBLISHER"
ARTIFACT_SIGNING = "artifact-signing"
SSLCOM_ESIGNER = "sslcom-esigner"

# Artifact Signing secrets identify the Entra app whose federated credential
# trusts this repository's `windows-signing` environment. No client secret exists.
# Variables say where to sign and which certificate subject to expect.
PROVIDERS = {
    ARTIFACT_SIGNING: {
        "name": "Azure Artifact Signing",
        "secrets": ("AZURE_ARTIFACT_SIGNING_CLIENT_ID", "AZURE_ARTIFACT_SIGNING_TENANT_ID",
                    "AZURE_ARTIFACT_SIGNING_SUBSCRIPTION_ID"),
        "variables": ("AZURE_ARTIFACT_SIGNING_ENDPOINT", "AZURE_ARTIFACT_SIGNING_ACCOUNT",
                      "AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE"),
        "timestampUrl": "http://timestamp.acs.microsoft.com",
    },
    # eSigner automated signing: the account credentials and the TOTP secret
    # SSL.com issues for unattended signing; the thumbprint pins which
    # certificate in the store SignTool may use.
    SSLCOM_ESIGNER: {
        "name": "SSL.com eSigner",
        "secrets": ("SSLCOM_ESIGNER_USERNAME", "SSLCOM_ESIGNER_PASSWORD", "SSLCOM_ESIGNER_TOTP_SECRET"),
        "variables": ("SSLCOM_ESIGNER_CERTIFICATE_THUMBPRINT",),
        "timestampUrl": "http://ts.ssl.com",
    },
}
SECRETS = PROVIDERS[ARTIFACT_SIGNING]["secrets"]
VARIABLES = PROVIDERS[ARTIFACT_SIGNING]["variables"] + (PUBLISHER,)
SETTINGS = SECRETS + VARIABLES
TIMESTAMP_URL = PROVIDERS[ARTIFACT_SIGNING]["timestampUrl"]
UNSIGNED_MESSAGE = ("Windows signing is not configured (no signing secrets or variables are set); "
                    "keeping the unsigned package and publishing nothing. See Docs/windows-installer.md.")

GUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
# Regional endpoints are https://<region code>.codesigning.azure.net.
ENDPOINT = re.compile(r"https://[a-z0-9]{2,8}\.codesigning\.azure\.net/?")
# Artifact Signing naming rules: accounts 3-24, profiles 5-100 alphanumerics
# or hyphens, starting with a letter, ending alphanumeric, no "--".
ACCOUNT = re.compile(r"[A-Za-z](?!.*--)[A-Za-z0-9-]{1,22}[A-Za-z0-9]")
PROFILE = re.compile(r"[A-Za-z](?!.*--)[A-Za-z0-9-]{3,98}[A-Za-z0-9]")
THUMBPRINT = re.compile(r"[0-9A-Fa-f]{40}")
# RFC 4648 base32, as SSL.com issues TOTP secrets.
TOTP_SECRET = re.compile(r"[A-Z2-7]{16,}=*")
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
        "SSLCOM_ESIGNER_USERNAME": _not_blank,
        "SSLCOM_ESIGNER_PASSWORD": bool,
        "SSLCOM_ESIGNER_TOTP_SECRET": TOTP_SECRET.fullmatch,
        "SSLCOM_ESIGNER_CERTIFICATE_THUMBPRINT": THUMBPRINT.fullmatch,
        PUBLISHER: _valid_publisher,
    }


def _not_blank(value):
    return bool(value) and not any(character.isspace() for character in value)


def _settings(provider):
    return PROVIDERS[provider]["secrets"] + PROVIDERS[provider]["variables"] + (PUBLISHER,)


def _valid_publisher(value):
    try:
        windows_msix.validate_publisher(value)
    except windows_msix.PackageError:
        return False
    return value != windows_msix.load_identity()["identity"]["developerPublisher"]


def plan(environment, supported=tuple(PROVIDERS)):
    """Returns ``{"enabled": bool, ...}`` or raises for a partial, ambiguous or invalid setup."""
    def value(name):
        return (environment.get(name) or "").strip()

    chosen = value(PROVIDER)
    if chosen and chosen not in PROVIDERS:
        raise SigningConfigurationError(PROVIDER + " must be one of " + ", ".join(sorted(PROVIDERS)) + ".")
    specific = {provider: [name for name in _settings(provider)[:-1] if value(name)] for provider in PROVIDERS}
    configured = [provider for provider, names in specific.items() if names]
    if not chosen:
        if configured and configured != [ARTIFACT_SIGNING]:
            raise SigningConfigurationError(
                "Settings for " + ", ".join(PROVIDERS[p]["name"] for p in configured)
                + " are present; set " + PROVIDER + " to choose the signing provider.")
        if not configured and not value(PUBLISHER):
            return {"enabled": False, "message": UNSIGNED_MESSAGE}
        chosen = ARTIFACT_SIGNING
    others = [name for provider in configured if provider != chosen for name in specific[provider]]
    if others:
        raise SigningConfigurationError(
            PROVIDER + " is " + chosen + " but settings for another provider are present; remove "
            + ", ".join(others) + ".")
    label = PROVIDERS[chosen]["name"]
    if chosen not in supported:
        return {"enabled": False, "provider": chosen,
                "message": label + " is configured, but this job signs only with "
                           + ", ".join(supported) + "; keeping the unsigned package."}
    names = _settings(chosen)
    present = [name for name in names if value(name)]
    missing = [name for name in names if not value(name)]
    if missing:
        removable = present + ([PROVIDER] if value(PROVIDER) else [])
        raise SigningConfigurationError(
            label + " is partly configured; also set " + ", ".join(missing)
            + " (or remove " + ", ".join(removable) + " to keep the unsigned package).")
    checks = _validators()
    invalid = [name for name in names if not checks[name](value(name))]
    if invalid:
        raise SigningConfigurationError(label + " settings are malformed: " + ", ".join(invalid)
                                        + ". See Docs/windows-installer.md for the expected formats.")
    decision = {
        "enabled": True,
        "provider": chosen,
        "publisher": value(PUBLISHER),
        "timestampUrl": PROVIDERS[chosen]["timestampUrl"],
        "message": label + " is configured; signing as " + value(PUBLISHER) + ".",
    }
    if chosen == ARTIFACT_SIGNING:
        decision["metadata"] = {
            "Endpoint": value("AZURE_ARTIFACT_SIGNING_ENDPOINT").rstrip("/"),
            "CodeSigningAccountName": value("AZURE_ARTIFACT_SIGNING_ACCOUNT"),
            "CertificateProfileName": value("AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE"),
            "ExcludeCredentials": EXCLUDED_CREDENTIALS,
        }
    else:
        decision["certificateThumbprint"] = value("SSLCOM_ESIGNER_CERTIFICATE_THUMBPRINT").upper()
    return decision


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--github-output", type=pathlib.Path, help="append enabled/publisher step outputs here")
    parser.add_argument("--metadata", type=pathlib.Path, help="write the SignTool dlib metadata.json here")
    parser.add_argument("--supported", action="append", choices=sorted(PROVIDERS),
                        help="a provider this job can sign with (repeatable; default: all)")
    args = parser.parse_args(argv)
    try:
        decision = plan(os.environ, tuple(args.supported or PROVIDERS))
    except SigningConfigurationError as error:
        print("::error::" + str(error), flush=True)
        return 1
    print(decision["message"], flush=True)
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as output:
            output.write("enabled=%s\n" % ("true" if decision["enabled"] else "false"))
            if decision["enabled"]:
                output.write("provider=%s\n" % decision["provider"])
                output.write("publisher=%s\n" % decision["publisher"])
                output.write("timestamp-url=%s\n" % decision["timestampUrl"])
                if "certificateThumbprint" in decision:
                    output.write("certificate-thumbprint=%s\n" % decision["certificateThumbprint"])
    if decision["enabled"] and args.metadata and "metadata" in decision:
        args.metadata.write_text(json.dumps(decision["metadata"], indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
