"""tools/asc.py given-identity: sign with an identity and an App Store profile made elsewhere
(ASC_SIGNING_KEY, ASC_SIGNING_CERT, ASC_PROFILE), with no App Store Connect call. The functions
under test are taken from asc.py with ast and run offline; the profile install is a stub.

Rows (expected results written before the code):
  1  all three set, profile for the app and listing the certificate -> installed for the app
     with the given key and certificate; no API call, no certificate created
  2  a variable missing -> refused, naming it, before any file is read
  3  a key that is not the certificate's -> refused
  4  an app with an extension -> refused, naming the extension's bundle id
  5  a profile for another app id, or without the certificate -> refused
  6  export options teamID that differs from the profile's team -> refused
  7  key_matches_certificate with real keys (skipped without `cryptography`)
Mutants (each must fail its row; checked by hand when the test was written):
  M1  drop the key check -> row 3
  M2  sign extensions with the app's profile -> row 4
  M3  drop check_named_profile -> row 5
"""
import ast
import base64
import datetime
import hashlib
import io
import os
import plistlib
import re
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

NAMES = {"export_options", "check_signing_certificate", "check_named_profile", "check_profile_team",
         "key_matches_certificate", "given_identity"}
CERT = b"GIVEN-CERTIFICATE-DER"


def namespace(**extra):
    source = (Path(__file__).resolve().parents[1] / "tools/asc.py").read_text()
    tree = ast.parse(source)
    keep = [node for node in tree.body
            if (isinstance(node, ast.FunctionDef) and node.name in NAMES)
            or (isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id in {"APP_STORE_METHODS", "DISTRIBUTION_CERTIFICATES", "EXPORT_KEYS"}
                for t in node.targets))]
    tree.body = keep
    if {n.name for n in keep if isinstance(n, ast.FunctionDef)} != NAMES:
        raise AssertionError("asc.py must contain the functions under test")

    def die(message):
        raise SystemExit(message)
    ns = dict(os=os, re=re, Path=Path, plistlib=plistlib, hashlib=hashlib, base64=base64, die=die, **extra)
    exec(compile(tree, "asc-given-identity.py", "exec"), ns)
    return ns


def payload(app_id="TEAM123456.com.example.app", certs=(CERT,), team="TEAM123456"):
    return {"Entitlements": {"application-identifier": app_id}, "DeveloperCertificates": list(certs),
            "TeamIdentifier": [team]}


class GivenIdentityTests(unittest.TestCase):
    def setUp(self):
        self.ns = namespace()
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        self.key, self.cert, self.prov = root / "key.pem", root / "cert.der", root / "app.mobileprovision"
        self.key.write_bytes(b"KEY")
        self.cert.write_bytes(CERT)
        self.prov.write_bytes(b"PROFILE")
        self.plist = root / "ExportOptions.plist"
        self.payload = payload()
        self.idents = ["com.example.app"]
        self.installed = {}
        self.matches = True

        def install(app_dir, out_dir, prov_for, key_path, cert_path):
            for ident in self.idents:
                self.installed[ident] = prov_for(ident)
            self.installed["key"], self.installed["cert"] = key_path, cert_path

        def no_api(*args, **kwargs):
            raise AssertionError("given-identity must not call App Store Connect")

        self.ns.update(
            install_all_bundles=install, call=no_api, certificate=no_api, profile=no_api,
            bundles=lambda app: [(Path(app) / i, i) for i in self.idents],
            profile_payload=lambda prov: self.payload,
            key_matches_certificate=lambda key, cert: self.matches)

    def env(self, **overrides):
        values = {"ASC_SIGNING_KEY": str(self.key), "ASC_SIGNING_CERT": str(self.cert),
                  "ASC_PROFILE": str(self.prov)}
        values.update(overrides)
        env = {k: v for k, v in os.environ.items() if k not in values and k != "ASC_EXPORT_OPTIONS"}
        env.update({k: v for k, v in values.items() if v is not None})
        return patch.dict(os.environ, env, clear=True)

    def run_given(self, **overrides):
        with self.env(**overrides), redirect_stdout(io.StringIO()):
            self.ns["given_identity"]("Runner.app", "out")

    def refused(self, fragment, **overrides):
        with self.assertRaises(SystemExit) as e:
            self.run_given(**overrides)
        self.assertIn(fragment, str(e.exception.code))

    def test_row1_installs_given_profile(self):
        self.run_given()
        self.assertEqual(self.installed["com.example.app"], b"PROFILE")
        self.assertEqual((self.installed["key"], self.installed["cert"]), (self.key, self.cert))

    def test_row2_missing_variable(self):
        self.key.unlink()
        self.refused("ASC_SIGNING_CERT", ASC_SIGNING_CERT=None)
        self.refused("ASC_PROFILE", ASC_PROFILE=None)

    def test_row3_key_not_the_certificates(self):
        self.matches = False
        self.refused("not the private key")

    def test_row4_extension(self):
        self.idents = ["com.example.app", "com.example.app.widget"]
        self.refused("com.example.app.widget")
        self.assertEqual(self.installed, {})

    def test_row5_profile_for_another_app_or_certificate(self):
        self.payload = payload("TEAM123456.com.other.app")
        self.refused("com.other.app")
        self.payload = payload(certs=[b"OTHER"])
        self.refused("certificate")

    def test_row6_team(self):
        self.plist.write_bytes(plistlib.dumps({"method": "app-store-connect", "teamID": "OTHER12345"}))
        self.refused("OTHER12345", ASC_EXPORT_OPTIONS=str(self.plist))


class KeyMatchesCertificateTests(unittest.TestCase):
    def test_row7_real_keys(self):
        try:
            from cryptography import x509
            from cryptography.hazmat.primitives import hashes, serialization
            from cryptography.hazmat.primitives.asymmetric import rsa
            from cryptography.x509.oid import NameOID
        except ImportError:
            self.skipTest("needs cryptography (the pymobile3 venv has it)")
        ns = namespace(x509=x509, serialization=serialization)

        def identity():
            key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "test")])
            now = datetime.datetime.now(datetime.timezone.utc)
            cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                    .public_key(key.public_key()).serial_number(1)
                    .not_valid_before(now).not_valid_after(now + datetime.timedelta(days=1))
                    .sign(key, hashes.SHA256()))
            pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                    serialization.NoEncryption())
            return pem, cert.public_bytes(serialization.Encoding.DER)
        key_a, cert_a = identity()
        key_b, _ = identity()
        self.assertTrue(ns["key_matches_certificate"](key_a, cert_a))
        self.assertFalse(ns["key_matches_certificate"](key_b, cert_a))


if __name__ == "__main__":
    unittest.main()
