#!/usr/bin/env python3
"""Certum signing plan and one-time-password tests; synthetic values only, no network."""
import base64
import io
import pathlib
import sys
import tempfile
import unittest
import unittest.mock

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import certum_signing  # noqa: E402
import signing_configuration  # noqa: E402
import windows_msix  # noqa: E402

# RFC 6238 appendix B seeds.
SEED_SHA1 = b"12345678901234567890"
SEED_SHA256 = b"12345678901234567890123456789012"
SEED_SHA512 = b"1234567890123456789012345678901234567890123456789012345678901234"


def otp_uri(seed=SEED_SHA1, **parameters):
    query = "&".join("%s=%s" % item for item in parameters.items())
    secret = base64.b32encode(seed).decode().rstrip("=")
    return "otpauth://totp/Certum:someone%40example.com?secret=" + secret + ("&" + query if query else "")


# A Certum Open Source subject: the CN carries a comma, so Windows quotes it.
PUBLISHER = 'CN="Open Source Developer, Example Person", O=Open Source Developer, L=Leeds, S=West Yorkshire, C=GB'
CERTUM = {
    "CERTUM_SIMPLYSIGN_USERNAME": "someone@example.com",
    "CERTUM_SIMPLYSIGN_OTP_URI": otp_uri(algorithm="SHA256"),
    "WINDOWS_MSIX_PUBLISHER": PUBLISHER,
}
AZURE = {
    "AZURE_ARTIFACT_SIGNING_CLIENT_ID": "00000000-0000-4000-8000-000000000001",
    "AZURE_ARTIFACT_SIGNING_TENANT_ID": "00000000-0000-4000-8000-000000000002",
    "AZURE_ARTIFACT_SIGNING_SUBSCRIPTION_ID": "00000000-0000-4000-8000-000000000003",
    "AZURE_ARTIFACT_SIGNING_ENDPOINT": "https://weu.codesigning.azure.net",
    "AZURE_ARTIFACT_SIGNING_ACCOUNT": "examplesigning",
    "AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE": "example-public",
    "WINDOWS_MSIX_PUBLISHER": "CN=Example Ltd, O=Example Ltd, L=Leeds, C=GB",
}


class OneTimePasswordTests(unittest.TestCase):
    def test_rfc_6238_vectors(self):
        vectors = [(59, "94287082", "46119246", "90693936"),
                   (1111111109, "07081804", "68084774", "25091201"),
                   (1234567890, "89005924", "91819424", "93441116"),
                   (20000000000, "65353130", "77737706", "47863826")]
        for at, sha1, sha256, sha512 in vectors:
            with self.subTest(at=at):
                self.assertEqual(certum_signing.totp(SEED_SHA1, at, 8, 30, "SHA1"), sha1)
                self.assertEqual(certum_signing.totp(SEED_SHA256, at, 8, 30, "SHA256"), sha256)
                self.assertEqual(certum_signing.totp(SEED_SHA512, at, 8, 30, "SHA512"), sha512)

    def test_the_uri_from_the_pairing_qr_code_is_read_with_its_defaults(self):
        settings = certum_signing.parse_otp_uri(otp_uri())
        self.assertEqual((settings["secret"], settings["algorithm"], settings["digits"], settings["period"]),
                         (SEED_SHA1, "SHA1", 6, 30))
        spaced = otp_uri(algorithm="sha-256", digits=8, period=60).replace("secret=", "secret=").lower()
        settings = certum_signing.parse_otp_uri(spaced.replace("otpauth://totp", "otpauth://TOTP"))
        self.assertEqual((settings["algorithm"], settings["digits"], settings["period"]), ("SHA256", 8, 60))

    def test_unusable_seeds_are_refused_without_echoing_them(self):
        secret = base64.b32encode(SEED_SHA1).decode().rstrip("=")
        for uri in ["", "https://example.com", "otpauth://hotp/x?secret=" + secret, "otpauth://totp/x",
                    "otpauth://totp/x?secret=not-base32!", "otpauth://totp/x?secret=AAAA",
                    otp_uri(algorithm="MD5"), otp_uri(digits=4), otp_uri(period=5), otp_uri(digits="six"),
                    otp_uri() + "&secret=" + secret]:
            with self.subTest(uri=uri):
                with self.assertRaises(certum_signing.CertumConfigurationError) as caught:
                    certum_signing.parse_otp_uri(uri)
                self.assertNotIn(secret, str(caught.exception))

    def test_a_code_about_to_expire_waits_for_the_next_period(self):
        waits = []
        clock = iter([1_000_000_048.0, 1_000_000_050.6])
        code = certum_signing.current_code(otp_uri(), 8, clock=lambda: next(clock), sleep=waits.append)
        self.assertEqual(waits, [2.5])
        self.assertEqual(code, certum_signing.totp(SEED_SHA1, 1_000_000_050.6))
        waits.clear()
        fresh = certum_signing.current_code(otp_uri(), 8, clock=lambda: 1_000_000_005.0, sleep=waits.append)
        self.assertEqual(waits, [])
        self.assertEqual(fresh, certum_signing.totp(SEED_SHA1, 1_000_000_005.0))

    def test_the_command_prints_only_the_code(self):
        output, errors = io.StringIO(), io.StringIO()
        with unittest.mock.patch.dict("os.environ", {"CERTUM_SIMPLYSIGN_OTP_URI": otp_uri()}, clear=True), \
                unittest.mock.patch("sys.stdout", output), unittest.mock.patch("sys.stderr", errors):
            self.assertEqual(certum_signing.main(["code", "--minimum-remaining", "0"]), 0)
            self.assertEqual(certum_signing.main(["check"]), 0)
        code, check = output.getvalue().splitlines()
        self.assertRegex(code, r"^\d{6}$")
        self.assertNotIn(base64.b32encode(SEED_SHA1).decode().rstrip("="), output.getvalue())
        with unittest.mock.patch.dict("os.environ", {}, clear=True), unittest.mock.patch("sys.stderr", errors):
            self.assertEqual(certum_signing.main(["code"]), 1)


class CertumPlanTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = pathlib.Path(self.scratch.name)

    def run_main(self, environment):
        output = self.root / "output"
        output.unlink(missing_ok=True)
        with unittest.mock.patch.dict("os.environ", environment, clear=True), \
                unittest.mock.patch("sys.stdout", io.StringIO()) as printed:
            status = signing_configuration.main(["--github-output", str(output),
                                                 "--metadata", str(self.root / "metadata.json")])
        return status, output.read_text(encoding="utf-8") if output.exists() else "", printed.getvalue()

    def test_no_settings_keep_the_unsigned_developer_package(self):
        decision = signing_configuration.plan({"UNRELATED": "1", "CERTUM_SIMPLYSIGN_USERNAME": " "})
        self.assertFalse(decision["enabled"])
        status, output, _ = self.run_main({})
        self.assertEqual((status, output), (0, "enabled=false\n"))

    def test_certum_is_the_primary_signer_with_its_timestamp(self):
        decision = signing_configuration.plan(CERTUM)
        self.assertEqual((decision["method"], decision["publisher"], decision["timestampUrl"]),
                         ("certum", PUBLISHER, "http://time.certum.pl"))
        self.assertIsNone(decision["thumbprint"])
        self.assertNotIn("metadata", decision)
        status, output, printed = self.run_main(CERTUM)
        self.assertEqual(status, 0)
        self.assertEqual(output, "enabled=true\nmethod=certum\npublisher=" + PUBLISHER
                         + "\ntimestamp-url=http://time.certum.pl\n")
        self.assertFalse((self.root / "metadata.json").exists())
        for secret in ("CERTUM_SIMPLYSIGN_USERNAME", "CERTUM_SIMPLYSIGN_OTP_URI"):
            self.assertNotIn(CERTUM[secret], output + printed)
        pinned = dict(CERTUM, CERTUM_CERTIFICATE_THUMBPRINT="ab" * 20)
        self.assertEqual(signing_configuration.plan(pinned)["thumbprint"], "AB" * 20)
        self.assertIn("thumbprint=" + "AB" * 20, self.run_main(pinned)[1])

    def test_the_certum_subject_is_a_valid_manifest_publisher_and_its_own_family(self):
        windows_msix.validate_publisher(PUBLISHER)
        identity = windows_msix.load_identity()
        record = windows_msix.package_identity(identity, "1.0.0.0", PUBLISHER)
        self.assertNotEqual(record["packageFamilyName"], windows_msix.package_identity(
            identity, "1.0.0.0", identity["identity"]["developerPublisher"])["packageFamilyName"])
        manifest = windows_msix.render_manifest(identity, "1.0.0.0", PUBLISHER)
        self.assertIn(b'Publisher="CN=&quot;Open Source Developer, Example Person&quot;, O=Open Source Developer',
                      manifest)

    def test_local_signing_builds_for_the_certificate_without_ci_secrets(self):
        local = {"WINDOWS_SIGNING_METHOD": "certum-local", "WINDOWS_MSIX_PUBLISHER": PUBLISHER}
        decision = signing_configuration.plan(local)
        self.assertEqual((decision["method"], decision["publisher"]), ("certum-local", PUBLISHER))
        self.assertIn("sign-windows-package-locally.ps1", decision["message"])
        with self.assertRaisesRegex(signing_configuration.SigningConfigurationError, "CERTUM_SIMPLYSIGN_USERNAME"):
            signing_configuration.plan(dict(local, CERTUM_SIMPLYSIGN_USERNAME="someone@example.com"))

    def test_partial_or_ambiguous_setups_fail_naming_only_settings(self):
        cases = [
            ({"CERTUM_SIMPLYSIGN_USERNAME": "someone@example.com"},
             "also set CERTUM_SIMPLYSIGN_OTP_URI, WINDOWS_MSIX_PUBLISHER"),
            ({"WINDOWS_MSIX_PUBLISHER": PUBLISHER}, "WINDOWS_SIGNING_METHOD=certum-local"),
            ({"CERTUM_CERTIFICATE_THUMBPRINT": "ab" * 20}, "partly configured"),
            (dict(CERTUM, AZURE_ARTIFACT_SIGNING_ACCOUNT="examplesigning"), "Both Certum"),
            (dict(CERTUM, WINDOWS_SIGNING_METHOD="azure"), "also set AZURE_ARTIFACT_SIGNING_CLIENT_ID"),
            (dict(AZURE, WINDOWS_SIGNING_METHOD="certum"), "also set CERTUM_SIMPLYSIGN_USERNAME"),
            (dict(CERTUM, WINDOWS_SIGNING_METHOD="gpg"), "must be one of certum, certum-local, azure"),
        ]
        for environment, expected in cases:
            with self.subTest(expected=expected):
                with self.assertRaises(signing_configuration.SigningConfigurationError) as caught:
                    signing_configuration.plan(environment)
                self.assertIn(expected, str(caught.exception))
                for secret in ("CERTUM_SIMPLYSIGN_USERNAME", "CERTUM_SIMPLYSIGN_OTP_URI"):
                    if environment.get(secret):
                        self.assertNotIn(environment[secret], str(caught.exception))
                status, output, _ = self.run_main(environment)
                self.assertEqual((status, output), (1, ""))

    def test_malformed_certum_settings_are_refused(self):
        for name, value in [("CERTUM_SIMPLYSIGN_USERNAME", "not an e-mail"),
                            ("CERTUM_SIMPLYSIGN_OTP_URI", "123456"),
                            ("CERTUM_SIMPLYSIGN_OTP_URI", otp_uri(algorithm="MD5")),
                            ("CERTUM_CERTIFICATE_THUMBPRINT", "abc"),
                            ("WINDOWS_MSIX_PUBLISHER", "Open Source Developer, Example Person"),
                            ("WINDOWS_MSIX_PUBLISHER", "CN=Just Speak to It Developer")]:
            with self.subTest(name=name, value=value):
                with self.assertRaisesRegex(signing_configuration.SigningConfigurationError, name) as caught:
                    signing_configuration.plan(dict(CERTUM, **{name: value}))
                self.assertNotIn(value if "OTP" in name else "\0", str(caught.exception))

    def test_azure_remains_a_documented_alternative(self):
        decision = signing_configuration.plan(AZURE)
        self.assertEqual((decision["method"], decision["timestampUrl"]), ("azure", "http://timestamp.acs.microsoft.com"))
        self.assertEqual(decision["metadata"]["CodeSigningAccountName"], "examplesigning")
        self.assertEqual(signing_configuration.plan(dict(AZURE, WINDOWS_SIGNING_METHOD="azure"))["method"], "azure")


if __name__ == "__main__":
    unittest.main()
