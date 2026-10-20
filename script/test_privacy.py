import unittest
import struct
import zlib
import check_privacy as privacy


class PrivacyTests(unittest.TestCase):
    def test_personal_paths_are_reported_without_including_the_value(self):
        path = privacy.HOME_PREFIX + "private-tester/project"
        self.assertEqual(privacy.text_findings(path.encode()), ["personal-home-path"])

    def test_documentation_placeholder_is_allowed(self):
        self.assertEqual(privacy.text_findings((privacy.HOME_PREFIX + "example/project").encode()), [])

    def test_real_credential_assignment_is_blocked(self):
        value = "CPE_" + "PASS='private-fixture-value'"
        self.assertEqual(privacy.text_findings(value.encode()), ["literal-test-credential"])

    def test_environment_and_placeholder_examples_are_allowed(self):
        for value in ["…", "...", "example-password", "$CPE_TEST_PASSWORD"]:
            text = "CPE_" + "PASS='" + value + "'"
            self.assertEqual(privacy.text_findings(text.encode()), [])

    def test_private_capture_and_local_ignore_files_are_blocked(self):
        for name in [".gitignore", ".env.local", "session.har", "packets.pcapng", "report.docx", "reference-device.png"]:
            self.assertTrue(privacy.path_findings(name))
        self.assertEqual(privacy.path_findings("Sources/firmware-protocol.der"), [])

    def test_external_denylist_checks_exact_values(self):
        plan = {"confirmed_exact_replacements": [
            {"match_regex": r"\bprivate-fixture-token\b", "category": "test"}
        ]}
        self.assertEqual(privacy.text_findings(b"private-fixture-token", plan), ["private-value:test"])
        self.assertEqual(privacy.text_findings(b"public-fixture-token", plan), [])

    def test_binary_protocol_material_is_not_treated_as_text_credentials(self):
        self.assertEqual(privacy.text_findings(b"\x00\xffprivate-fixture-token"), [])

    def test_field_scoped_private_rule_does_not_flag_unrelated_protocol_constants(self):
        plan = {"confirmed_exact_replacements": [
            {"match_regex": r'(?P<prefix>\bpci:\s*)(?P<value>777)(?![0-9])', "category": "radio-sample"}
        ]}
        self.assertEqual(privacy.text_findings(b"pci: 777, channel: 999", plan), ["private-value:radio-sample"])
        self.assertEqual(privacy.text_findings(b"pci: 101, channel: 777", plan), [])

    def test_binary_string_table_does_not_hide_private_paths(self):
        data = b"\xcf\xfa\xed\xfe\0" + (privacy.HOME_PREFIX + "private-tester/project/file.swift").encode() + b"\0\xff"
        self.assertEqual(privacy.payload_findings(data), ["personal-home-path"])

    def test_binary_string_table_checks_external_secret_rule(self):
        plan = {"confirmed_exact_replacements": [{"match_regex": "private-fixture-token", "category": "fixture"}]}
        self.assertEqual(privacy.payload_findings(b"\0\xffprivate-fixture-token\0", plan), ["private-value:fixture"])

    def test_compressed_png_metadata_and_icns_are_scanned(self):
        body = b"Comment\0\0" + zlib.compress((privacy.HOME_PREFIX + "private-tester/image").encode())
        chunk = struct.pack(">I", len(body)) + b"zTXt" + body + b"\0" * 4
        png = b"\x89PNG\r\n\x1a\n" + chunk
        icon = b"icns" + struct.pack(">I", len(png) + 16) + b"ic10" + struct.pack(">I", len(png) + 8) + png
        for data in [png, icon]:
            self.assertEqual(privacy.payload_findings(data), ["personal-home-path"])

    def test_invalid_compressed_metadata_cannot_pass_privacy_check(self):
        body = b"Comment\0\0invalid-zlib"
        png = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", len(body)) + b"zTXt" + body + b"\0" * 4
        self.assertEqual(privacy.payload_findings(png), ["invalid-image-text-metadata"])


if __name__ == "__main__":
    unittest.main()
