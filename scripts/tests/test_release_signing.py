"""Offline release-signing contract tests; never use production secrets."""
import base64
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "autarx_release_signing", ROOT / "scripts/check-update-signing-key.py"
)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class ReleaseSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.private_der = subprocess.check_output(
            ["openssl", "genpkey", "-algorithm", "ED25519", "-outform", "DER"]
        )
        cls.public_der = subprocess.check_output(
            ["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
            input=cls.private_der,
        )

    def make_fixture(self, root, spki=None):
        spki = spki if spki is not None else self.public_der
        for name in checker.RACKET_CLIENTS:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(
                '(define update-public-key-b64\n  "'
                + base64.b64encode(spki).decode() + '")', encoding="utf-8"
            )

    def test_matching_private_key_and_both_clients(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_fixture(root)
            self.assertEqual(checker.trusted_public_key(root), self.public_der)
            checker.verify_secret(base64.b64encode(self.private_der).decode(), root)

    def test_mismatched_private_key_is_rejected(self):
        other = subprocess.check_output(
            ["openssl", "genpkey", "-algorithm", "ED25519", "-outform", "DER"]
        )
        with self.assertRaisesRegex(ValueError, "does not match"):
            checker.verify(other, self.public_der)

    def test_missing_corrupt_and_wrong_key(self):
        for encoded in ("", "not base64!"):
            with self.subTest(encoded=encoded), self.assertRaises(ValueError):
                checker.verify_secret(encoded)
        for raw in (b"", b"not an Ed25519 key"):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                checker.verify(raw, self.public_der)

    def test_racket_key_disagreement_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_fixture(root)
            (root / checker.RACKET_CLIENTS[1]).write_text(
                '(define update-public-key-b64 "Zm9v")', encoding="utf-8"
            )
            with self.assertRaisesRegex(ValueError, "invalid Ed25519"):
                checker.trusted_public_key(root)

    def test_real_embedded_keys_and_canonical_feed_urls(self):
        checker.trusted_public_key(ROOT)
        for name in checker.RACKET_CLIENTS:
            source = (ROOT / name).read_text(encoding="utf-8")
            self.assertNotIn("turinglambdaai/autarx/releases/", source)
            self.assertIn("turlamai/autarx/releases/", source)


if __name__ == "__main__":
    unittest.main()
