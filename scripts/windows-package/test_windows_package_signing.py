#!/usr/bin/env python3
"""Signing configuration for the Windows package: Azure Artifact Signing and SSL.com eSigner."""
import json
import pathlib
import sys
import tempfile
import unittest
import unittest.mock

HERE = pathlib.Path(__file__).resolve().parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE))
import signing_configuration  # noqa: E402
import windows_msix  # noqa: E402
from package_test_fixtures import make_bundle, make_package  # noqa: E402

SIGNING = {
    "AZURE_ARTIFACT_SIGNING_CLIENT_ID": "00000000-0000-4000-8000-000000000001",
    "AZURE_ARTIFACT_SIGNING_TENANT_ID": "00000000-0000-4000-8000-000000000002",
    "AZURE_ARTIFACT_SIGNING_SUBSCRIPTION_ID": "00000000-0000-4000-8000-000000000003",
    "AZURE_ARTIFACT_SIGNING_ENDPOINT": "https://weu.codesigning.azure.net/",
    "AZURE_ARTIFACT_SIGNING_ACCOUNT": "examplesigning",
    "AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE": "example-public",
    "WINDOWS_MSIX_PUBLISHER": "CN=Example Developer, O=Example Developer, L=Leeds, C=GB",
}
SSLCOM = {
    "WINDOWS_SIGNING_PROVIDER": "sslcom-esigner",
    "SSLCOM_ESIGNER_USERNAME": "signer@example.com",
    "SSLCOM_ESIGNER_PASSWORD": "example password",
    "SSLCOM_ESIGNER_TOTP_SECRET": "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP",
    "SSLCOM_ESIGNER_CERTIFICATE_THUMBPRINT": "0123456789abcdef0123456789abcdef01234567",
    "WINDOWS_MSIX_PUBLISHER": SIGNING["WINDOWS_MSIX_PUBLISHER"],
}


class SigningConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = pathlib.Path(self.scratch.name)

    def test_no_settings_keeps_the_unsigned_developer_package(self):
        decision = signing_configuration.plan({"UNRELATED": "1", "AZURE_ARTIFACT_SIGNING_ACCOUNT": "  "})
        self.assertFalse(decision["enabled"])
        self.assertIn("keeping the unsigned package and publishing nothing", decision["message"])
        output = self.root / "output"
        with unittest.mock.patch.dict("os.environ", {}, clear=True):
            self.assertEqual(signing_configuration.main(["--github-output", str(output),
                                                         "--metadata", str(self.root / "metadata.json")]), 0)
        self.assertEqual(output.read_text(encoding="utf-8"), "enabled=false\n")
        self.assertFalse((self.root / "metadata.json").exists())

    def test_complete_settings_sign_as_the_configured_publisher(self):
        decision = signing_configuration.plan(SIGNING)
        self.assertTrue(decision["enabled"])
        self.assertEqual(decision["publisher"], SIGNING["WINDOWS_MSIX_PUBLISHER"])
        self.assertEqual(decision["timestampUrl"], "http://timestamp.acs.microsoft.com")
        self.assertEqual(decision["metadata"]["Endpoint"], "https://weu.codesigning.azure.net")
        self.assertEqual(decision["metadata"]["CodeSigningAccountName"], "examplesigning")
        self.assertEqual(decision["metadata"]["CertificateProfileName"], "example-public")
        self.assertNotIn("AzureCliCredential", decision["metadata"]["ExcludeCredentials"])
        output, metadata = self.root / "output", self.root / "metadata.json"
        with unittest.mock.patch.dict("os.environ", SIGNING, clear=True):
            self.assertEqual(signing_configuration.main(["--github-output", str(output),
                                                         "--metadata", str(metadata)]), 0)
        self.assertEqual(output.read_text(encoding="utf-8"),
                         "enabled=true\nprovider=artifact-signing\npublisher=" + SIGNING["WINDOWS_MSIX_PUBLISHER"]
                         + "\ntimestamp-url=http://timestamp.acs.microsoft.com\n")
        self.assertEqual(json.loads(metadata.read_text(encoding="utf-8")), decision["metadata"])
        for secret in signing_configuration.SECRETS:
            self.assertNotIn(SIGNING[secret], metadata.read_text(encoding="utf-8") + output.read_text(encoding="utf-8"))

    def test_partial_settings_fail_naming_only_the_missing_settings(self):
        partial = dict(SIGNING)
        del partial["WINDOWS_MSIX_PUBLISHER"], partial["AZURE_ARTIFACT_SIGNING_TENANT_ID"]
        with self.assertRaises(signing_configuration.SigningConfigurationError) as caught:
            signing_configuration.plan(partial)
        message = str(caught.exception)
        self.assertIn("AZURE_ARTIFACT_SIGNING_TENANT_ID, WINDOWS_MSIX_PUBLISHER", message)
        self.assertNotIn(SIGNING["AZURE_ARTIFACT_SIGNING_CLIENT_ID"], message)
        with unittest.mock.patch.dict("os.environ", partial, clear=True):
            self.assertEqual(signing_configuration.main([]), 1)

    def test_malformed_settings_are_refused(self):
        for name, value in [("AZURE_ARTIFACT_SIGNING_CLIENT_ID", "not-a-guid"),
                            ("AZURE_ARTIFACT_SIGNING_ENDPOINT", "https://example.com"),
                            ("AZURE_ARTIFACT_SIGNING_ENDPOINT", "http://weu.codesigning.azure.net"),
                            ("AZURE_ARTIFACT_SIGNING_ACCOUNT", "ab"),
                            ("AZURE_ARTIFACT_SIGNING_ACCOUNT", "bad--name"),
                            ("AZURE_ARTIFACT_SIGNING_CERTIFICATE_PROFILE", "1profile"),
                            ("WINDOWS_MSIX_PUBLISHER", "Example Developer"),
                            ("WINDOWS_MSIX_PUBLISHER", "CN=Just Speak to It Developer")]:
            with self.subTest(name=name, value=value):
                with self.assertRaisesRegex(signing_configuration.SigningConfigurationError, name):
                    signing_configuration.plan(dict(SIGNING, **{name: value}))

    def test_sslcom_esigner_signs_from_the_certificate_store(self):
        decision = signing_configuration.plan(SSLCOM)
        self.assertEqual(decision["provider"], "sslcom-esigner")
        self.assertEqual(decision["timestampUrl"], "http://ts.ssl.com")
        self.assertEqual(decision["certificateThumbprint"], SSLCOM["SSLCOM_ESIGNER_CERTIFICATE_THUMBPRINT"].upper())
        self.assertNotIn("metadata", decision)
        output, metadata = self.root / "output", self.root / "metadata.json"
        with unittest.mock.patch.dict("os.environ", SSLCOM, clear=True):
            self.assertEqual(signing_configuration.main(["--github-output", str(output),
                                                         "--metadata", str(metadata)]), 0)
        text = output.read_text(encoding="utf-8")
        self.assertIn("provider=sslcom-esigner\n", text)
        self.assertIn("certificate-thumbprint=" + SSLCOM["SSLCOM_ESIGNER_CERTIFICATE_THUMBPRINT"].upper(), text)
        self.assertFalse(metadata.exists())
        for secret in ("SSLCOM_ESIGNER_USERNAME", "SSLCOM_ESIGNER_PASSWORD", "SSLCOM_ESIGNER_TOTP_SECRET"):
            self.assertNotIn(SSLCOM[secret], text)

    def test_provider_choice_is_explicit_when_not_artifact_signing(self):
        implicit = dict(SSLCOM)
        del implicit["WINDOWS_SIGNING_PROVIDER"]
        with self.assertRaisesRegex(signing_configuration.SigningConfigurationError, "WINDOWS_SIGNING_PROVIDER"):
            signing_configuration.plan(implicit)
        with self.assertRaisesRegex(signing_configuration.SigningConfigurationError, "AZURE_ARTIFACT_SIGNING_ACCOUNT"):
            signing_configuration.plan(dict(SSLCOM, AZURE_ARTIFACT_SIGNING_ACCOUNT="examplesigning"))
        with self.assertRaisesRegex(signing_configuration.SigningConfigurationError, "must be one of"):
            signing_configuration.plan(dict(SSLCOM, WINDOWS_SIGNING_PROVIDER="self-signed"))
        explicit = dict(SIGNING, WINDOWS_SIGNING_PROVIDER="artifact-signing")
        self.assertEqual(signing_configuration.plan(explicit)["provider"], "artifact-signing")

    def test_partial_sslcom_settings_fail_and_unsupported_jobs_skip(self):
        partial = dict(SSLCOM)
        del partial["SSLCOM_ESIGNER_TOTP_SECRET"]
        with self.assertRaises(signing_configuration.SigningConfigurationError) as caught:
            signing_configuration.plan(partial)
        self.assertIn("also set SSLCOM_ESIGNER_TOTP_SECRET", str(caught.exception))
        self.assertNotIn(SSLCOM["SSLCOM_ESIGNER_PASSWORD"], str(caught.exception))
        skipped = signing_configuration.plan(SSLCOM, supported=("artifact-signing",))
        self.assertFalse(skipped["enabled"])
        self.assertIn("this job signs only with artifact-signing", skipped["message"])
        for name, value in [("SSLCOM_ESIGNER_CERTIFICATE_THUMBPRINT", "abc"),
                            ("SSLCOM_ESIGNER_TOTP_SECRET", "not base32!"),
                            ("SSLCOM_ESIGNER_USERNAME", "two words")]:
            with self.subTest(name=name):
                with self.assertRaisesRegex(signing_configuration.SigningConfigurationError, name):
                    signing_configuration.plan(dict(SSLCOM, **{name: value}))

    def test_signed_and_unsigned_layouts_follow_the_plan(self):
        bundle = make_bundle(self.root / "bundle")
        unsigned = windows_msix.build_layout(bundle, self.root / "unsigned", "0.0.9.1")
        self.assertEqual(unsigned["package"]["publisher"], "CN=Just Speak to It Developer")
        decision = signing_configuration.plan(SIGNING)
        signed = windows_msix.build_layout(bundle, self.root / "signed", "0.0.9.1", publisher=decision["publisher"])
        self.assertEqual(signed["package"]["publisher"], SIGNING["WINDOWS_MSIX_PUBLISHER"])
        self.assertNotEqual(signed["package"]["packageFamilyName"], unsigned["package"]["packageFamilyName"])
        layout = self.root / "signed" / "layout"
        reference = make_package(layout, self.root / "reference.msix")
        windows_msix.verify_package(reference, layout, signed=False)
        package = make_package(layout, self.root / "signed.msix", signed=True)
        windows_msix.verify_package(package, layout, signed=True, unsigned_reference=reference)
        with self.assertRaises(windows_msix.PackageError):
            windows_msix.verify_package(package, self.root / "unsigned" / "layout", signed=True)


if __name__ == "__main__":
    unittest.main()
