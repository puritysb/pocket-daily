import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("artifact", Path(__file__).with_name("host_renderer_artifact.py"))
artifact = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(artifact)


class HostRendererArtifactTests(unittest.TestCase):
    def make_package(self, root):
        package = root / "PocketUIHost.xcframework"
        (package / "fixture").mkdir(parents=True)
        (package / "Info.plist").write_bytes(b"fixture")
        (package / "fixture/libpdui_host.a").write_bytes(b"archive")
        files = {str(p.relative_to(package)): artifact.digest(p) for p in package.rglob("*") if p.is_file()}
        record = {"schema": 1, "abi": 1, "source": {"files": {}, "sha256": artifact.fingerprint({})},
                  "artifactFiles": files, "artifactSHA256": artifact.fingerprint(files)}
        (root / "PROVENANCE.json").write_text(json.dumps(record))
        (root / "PIN.json").write_text(json.dumps(artifact.pin_for(record)))
        (root / "RendererInputs.xcfilelist").write_text(artifact.input_list(record))
        return package

    def test_accepts_matching_record_and_rejects_changed_library(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = self.make_package(root)
            artifact.verify(root)
            (package / "fixture/libpdui_host.a").write_bytes(b"changed")
            with self.assertRaises(ValueError):
                artifact.verify(root)

    def test_rejects_changed_pin_added_files_and_symlinks(self):
        for variant in ["pin", "extra", "symlink"]:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                package = self.make_package(root)
                if variant == "pin":
                    (root / "PIN.json").write_text("{}")
                elif variant == "extra":
                    (package / "extra").write_bytes(b"x")
                else:
                    (package / "link").symlink_to("missing")
                with self.assertRaises(ValueError):
                    artifact.verify(root)


if __name__ == "__main__":
    unittest.main()
