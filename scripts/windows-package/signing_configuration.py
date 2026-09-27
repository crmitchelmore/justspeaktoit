#!/usr/bin/env python3
"""Decides whether and how CI signs the Windows MSIX packages.

Signing is configured entirely through GitHub secrets and variables; nothing
in the repository names an account, a person, a tenant or a certificate. Three
methods exist, chosen by ``WINDOWS_SIGNING_METHOD`` or, when it is unset, by
which method's settings are present:

* ``certum`` (primary): a Certum Open Source Code Signing certificate held in
  Certum's SimplySign cloud. CI logs in to SimplySign Desktop with the
  account's one-time-password seed, SignTool signs with the certificate's
  thumbprint and timestamps at ``http://time.certum.pl``. The key never
  leaves Certum.
* ``certum-local``: the same certificate, signed on the owner's own PC (a
  SimplySign session or a card). CI only builds unsigned packages whose
  Publisher is the certificate subject, ready for
  ``sign-windows-package-locally.ps1``.
* ``azure``: Azure Artifact Signing through GitHub OIDC, the documented
  alternative for organisations and for individuals in the US and Canada.

The plan is:

* no setting present: keep the unsigned developer package and say so;
* a method with every setting present and valid: sign (or, for
  ``certum-local``, build for local signing) with the manifest publisher set to
  the certificate subject from ``WINDOWS_MSIX_PUBLISHER``;
* anything in between, settings of two methods at once, or an invalid value:
  fail, naming only the settings (never their values), so a half-finished
  setup is not silently skipped.

``plan`` prints the decision and writes ``enabled``, ``method``, ``publisher``
and ``timestamp-url`` to ``$GITHUB_OUTPUT``; for Azure it also writes the
SignTool dlib ``metadata.json``.
"""
import argparse
import json
import os
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import certum_signing  # noqa: E402
import windows_msix  # noqa: E402

METHOD_VARIABLE = "WINDOWS_SIGNING_METHOD"
PUBLISHER = "WINDOWS_MSIX_PUBLISHER"
METHODS = ("certum", "certum-local", "azure")

# GitHub secrets: identify the Entra app whose federated credential trusts
# this repository's `windows-signing` environment. No client secret exists.
AZURE_SECRETS = ("AZURE_ARTIFACT_SIGNING_CLIENT_ID", "AZURE_ARTIFACT_SIGNING_TENANT_ID",
                 "AZURE_ARTIFACT_SIGNING_SUBSCRIPTION_ID")
# GitHub variables: where to sign.
AZURE_VARIABLES = ("AZURE_ARTIFACT_SIGNING_ENDPOINT", "AZURE_ARTIFACT_SIGNING_ACCOUNT",
                   "AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE")
# Kept for callers and tests that name the Azure settings as a whole.
SECRETS = AZURE_SECRETS
VARIABLES = AZURE_VARIABLES + (PUBLISHER,)

# GitHub secrets: the SimplySign account and the seed of its one-time
# passwords (the otpauth:// URI in the QR code SimplySign shows when the
# mobile app is paired). Together they sign as the certificate holder, so they
# live only in the protected `windows-signing` environment.
CERTUM_SECRETS = ("CERTUM_SIMPLYSIGN_USERNAME", "CERTUM_SIMPLYSIGN_OTP_URI")
# Optional GitHub variable: pins the certificate by SHA-1 thumbprint, so a
# renewed or second certificate on the account is never picked by accident.
CERTUM_THUMBPRINT = "CERTUM_CERTIFICATE_THUMBPRINT"

REQUIRED = {
    "certum": CERTUM_SECRETS + (PUBLISHER,),
    "certum-local": (PUBLISHER,),
    "azure": AZURE_SECRETS + AZURE_VARIABLES + (PUBLISHER,),
}
OPTIONAL = {"certum": (CERTUM_THUMBPRINT,), "certum-local": (CERTUM_THUMBPRINT,), "azure": ()}
ALL_SETTINGS = tuple(dict.fromkeys(
    (METHOD_VARIABLE,) + CERTUM_SECRETS + (CERTUM_THUMBPRINT,) + AZURE_SECRETS + AZURE_VARIABLES + (PUBLISHER,)))
SETTINGS = AZURE_SECRETS + AZURE_VARIABLES + (PUBLISHER,)

TIMESTAMP_URLS = {"certum": certum_signing.TIMESTAMP_URL, "certum-local": certum_signing.TIMESTAMP_URL,
                  "azure": "http://timestamp.acs.microsoft.com"}
TIMESTAMP_URL = TIMESTAMP_URLS["azure"]
UNSIGNED_MESSAGE = ("Windows signing is not configured (no signing secrets or variables are set); "
                    "keeping the unsigned developer MSIX. See Docs/windows-installer.md to enable signing.")

GUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
# Regional endpoints are https://<region code>.codesigning.azure.net.
ENDPOINT = re.compile(r"https://[a-z0-9]{2,8}\.codesigning\.azure\.net/?")
# Artifact Signing naming rules: accounts 3-24, profiles 5-100 alphanumerics
# or hyphens, starting with a letter, ending alphanumeric, no "--".
ACCOUNT = re.compile(r"[A-Za-z](?!.*--)[A-Za-z0-9-]{1,22}[A-Za-z0-9]")
PROFILE = re.compile(r"[A-Za-z](?!.*--)[A-Za-z0-9-]{3,98}[A-Za-z0-9]")
THUMBPRINT = re.compile(r"[0-9A-Fa-f]{40}")
# A SimplySign login is the e-mail address the account was opened with.
USERNAME = re.compile(r"[^\s@]+@[^\s@]+\.[^\s@]+")
# DefaultAzureCredential then uses only the Azure CLI session from azure/login.
EXCLUDED_CREDENTIALS = [
    "EnvironmentCredential", "WorkloadIdentityCredential", "ManagedIdentityCredential",
    "SharedTokenCacheCredential", "VisualStudioCredential", "VisualStudioCodeCredential",
    "AzurePowerShellCredential", "AzureDeveloperCliCredential", "InteractiveBrowserCredential",
]


class SigningConfigurationError(Exception):
    pass


def _valid_publisher(value):
    try:
        windows_msix.validate_publisher(value)
    except windows_msix.PackageError:
        return False
    return value != windows_msix.load_identity()["identity"]["developerPublisher"]


def _valid_otp_uri(value):
    try:
        certum_signing.parse_otp_uri(value)
    except certum_signing.CertumConfigurationError:
        return False
    return True


VALIDATORS = {
    "AZURE_ARTIFACT_SIGNING_CLIENT_ID": GUID.fullmatch,
    "AZURE_ARTIFACT_SIGNING_TENANT_ID": GUID.fullmatch,
    "AZURE_ARTIFACT_SIGNING_SUBSCRIPTION_ID": GUID.fullmatch,
    "AZURE_ARTIFACT_SIGNING_ENDPOINT": ENDPOINT.fullmatch,
    "AZURE_ARTIFACT_SIGNING_ACCOUNT": ACCOUNT.fullmatch,
    "AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE": PROFILE.fullmatch,
    "CERTUM_SIMPLYSIGN_USERNAME": USERNAME.fullmatch,
    "CERTUM_SIMPLYSIGN_OTP_URI": _valid_otp_uri,
    CERTUM_THUMBPRINT: THUMBPRINT.fullmatch,
    PUBLISHER: _valid_publisher,
}


def _choose_method(values):
    """The method the settings ask for, or a refusal naming what is ambiguous."""
    requested = values[METHOD_VARIABLE]
    if requested:
        if requested not in METHODS:
            raise SigningConfigurationError(
                METHOD_VARIABLE + " must be one of " + ", ".join(METHODS) + ".")
        return requested
    certum = [name for name in CERTUM_SECRETS if values[name]]
    azure = [name for name in AZURE_SECRETS + AZURE_VARIABLES if values[name]]
    if certum and azure:
        raise SigningConfigurationError(
            "Both Certum (" + ", ".join(certum) + ") and Azure Artifact Signing (" + ", ".join(azure)
            + ") settings are present; set " + METHOD_VARIABLE + " to certum or azure, or remove one set.")
    if certum:
        return "certum"
    if azure:
        return "azure"
    present = [name for name in ALL_SETTINGS if values[name]]
    raise SigningConfigurationError(
        "Windows signing is partly configured (" + ", ".join(present) + "). Add the Certum secrets "
        + ", ".join(CERTUM_SECRETS) + " to sign in CI, or set " + METHOD_VARIABLE
        + "=certum-local to build packages for signing on your own PC.")


def plan(environment):
    """Returns ``{"enabled": bool, "method": ..., ...}`` or raises for a partial or invalid setup."""
    values = {name: (environment.get(name) or "").strip() for name in ALL_SETTINGS}
    present = [name for name in ALL_SETTINGS if values[name]]
    if not present:
        return {"enabled": False, "method": None, "message": UNSIGNED_MESSAGE}
    method = _choose_method(values)
    required, optional = REQUIRED[method], OPTIONAL[method]
    missing = [name for name in required if not values[name]]
    if missing:
        raise SigningConfigurationError(
            "Windows signing with " + method + " is partly configured; also set " + ", ".join(missing)
            + " (or remove " + ", ".join(present) + " to keep the unsigned package).")
    foreign = [name for name in present if name not in required + optional + (METHOD_VARIABLE,)]
    if foreign:
        raise SigningConfigurationError(
            "Settings for another signing method are present with " + method + ": " + ", ".join(foreign)
            + ". Remove them so the method is unambiguous.")
    invalid = [name for name in required + optional if values[name] and not VALIDATORS[name](values[name])]
    if invalid:
        raise SigningConfigurationError("Windows signing settings are malformed: " + ", ".join(invalid)
                                        + ". See Docs/windows-installer.md for the expected formats.")
    publisher = values[PUBLISHER]
    decision = {"enabled": True, "method": method, "publisher": publisher, "timestampUrl": TIMESTAMP_URLS[method]}
    if method == "azure":
        decision["metadata"] = {
            "Endpoint": values["AZURE_ARTIFACT_SIGNING_ENDPOINT"].rstrip("/"),
            "CodeSigningAccountName": values["AZURE_ARTIFACT_SIGNING_ACCOUNT"],
            "CertificateProfileName": values["AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE"],
            "ExcludeCredentials": EXCLUDED_CREDENTIALS,
        }
        decision["message"] = "Azure Artifact Signing is configured; signing the developer MSIX as " + publisher + "."
    elif method == "certum":
        decision["thumbprint"] = values[CERTUM_THUMBPRINT].upper() or None
        decision["message"] = ("Certum SimplySign is configured; signing the developer MSIX as " + publisher
                               + " and timestamping at " + TIMESTAMP_URLS[method] + ".")
    else:
        decision["thumbprint"] = values[CERTUM_THUMBPRINT].upper() or None
        decision["message"] = ("Certum local signing is configured; building unsigned packages whose publisher is "
                               + publisher + " for sign-windows-package-locally.ps1.")
    return decision


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--github-output", type=pathlib.Path,
                        help="append enabled/method/publisher/timestamp-url step outputs here")
    parser.add_argument("--metadata", type=pathlib.Path, help="write the Azure SignTool dlib metadata.json here")
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
                output.write("method=%s\n" % decision["method"])
                output.write("publisher=%s\n" % decision["publisher"])
                output.write("timestamp-url=%s\n" % decision["timestampUrl"])
                if decision.get("thumbprint"):
                    output.write("thumbprint=%s\n" % decision["thumbprint"])
    if decision.get("metadata") and args.metadata:
        args.metadata.write_text(json.dumps(decision["metadata"], indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
