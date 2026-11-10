import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "build_kernel_index", ROOT / "scripts" / "build_kernel_index.py"
)
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)
COMMIT = "a" * 40


class KernelIndexTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in builder.SCENARIOS.values():
            (self.root / "MobilityAgent" / directory / "SupportedKernels").mkdir(
                parents=True
            )

    def manifest(self, scenario, version, name, content):
        path = (
            self.root
            / "MobilityAgent"
            / builder.SCENARIOS[scenario]
            / "SupportedKernels"
            / version
            / name
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def test_exact_entries_scenarios_and_original_provenance(self):
        source = self.manifest(
            "A2A",
            "9.68.7978.1",
            "Ubuntu-26.04-64_supported_kernels.txt",
            "\ufeff 7.0.0-1-azure \n7.0.0-1-azure\n\n7.0.0-1-generic\n",
        )
        self.manifest(
            "V2A",
            "9.66.7643.1",
            "UBUNTU-26.04-64_supported_kernels.txt",
            "7.0.0-1-azure\n",
        )
        index = builder.build_index(self.root, COMMIT)
        self.assertEqual(list(index["kernels"]), ["7.0.0-1-azure", "7.0.0-1-generic"])
        self.assertEqual(index["kernels"]["7.0.0-1-azure"], [0, 1])
        self.assertEqual(index["kernels"]["7.0.0-1-generic"], [0])
        self.assertEqual(
            [manifest["scenario"] for manifest in index["manifests"]], ["A2A", "V2A"]
        )
        self.assertEqual(
            [manifest["distribution"] for manifest in index["manifests"]],
            ["Ubuntu", "Ubuntu"],
        )
        manifest = index["manifests"][0]
        self.assertEqual(manifest["release"], "26.04")
        self.assertEqual(manifest["architecture"], "64")
        self.assertEqual(manifest["path"], source.relative_to(self.root).as_posix())
        self.assertEqual(
            manifest["url"],
            f"https://github.com/Azure/Azure-SiteRecovery/blob/{COMMIT}/{manifest['path']}",
        )

    def test_sparse_updates_and_empty_manifests_are_not_inherited(self):
        self.manifest("A2A", "9.66.9.1", "DEBIAN12-64_supported_kernels.txt", "6.1.0")
        self.manifest("A2A", "9.66.10.1", "SLES15-64_supported_kernels.txt", "")
        index = builder.build_index(self.root, COMMIT)
        self.assertEqual(len(index["manifests"]), 2)
        references = index["kernels"]["6.1.0"]
        self.assertEqual(len(references), 1)
        self.assertEqual(index["manifests"][references[0]]["version"], "9.66.9.1")

    def test_deterministic_generation_and_written_artifact(self):
        self.manifest("A2A", "9.68.1.1", "RHEL9-64_supported_kernels.txt", "z\nb\n")
        first = builder.build_index(self.root, COMMIT)
        self.assertEqual(first, builder.build_index(self.root, COMMIT))
        assets = self.root / "site" / "kernel-search"
        assets.mkdir(parents=True)
        for name in builder.ASSETS:
            (assets / name).write_text(name, encoding="utf-8")
        output = self.root / "output"
        builder.write_site(self.root, output, first)
        self.assertEqual(json.loads((output / "kernels.json").read_text()), first)
        self.assertEqual((output / "app.js").read_text(), "app.js")

    def test_rejects_unexpected_filename_or_layout(self):
        for version, filename in [
            ("9.68.1.1", "unknown.txt"),
            ("latest", "SLES15-64_supported_kernels.txt"),
            ("9.68.1.1/nested", "SLES15-64_supported_kernels.txt"),
        ]:
            with self.subTest(version=version, filename=filename):
                path = self.manifest("A2A", version, filename, "6.1.0\n")
                with self.assertRaisesRegex(ValueError, "Unexpected manifest path"):
                    builder.build_index(self.root, COMMIT)
                path.unlink()

    def test_rejects_invalid_provenance_and_missing_or_empty_dataset(self):
        with self.assertRaisesRegex(ValueError, "full 40-character"):
            builder.build_index(self.root, "main")
        with self.assertRaisesRegex(ValueError, "owner/name"):
            builder.build_index(self.root, COMMIT, "https://example.com")
        with self.assertRaisesRegex(ValueError, "No kernel entries"):
            builder.build_index(self.root, COMMIT)
        (self.root / "MobilityAgent" / "AzureToAzure" / "SupportedKernels").rmdir()
        with self.assertRaisesRegex(ValueError, "Missing manifest directory"):
            builder.build_index(self.root, COMMIT)

    def test_complete_repository_matches_every_source_entry(self):
        index = builder.build_index(ROOT, COMMIT)
        expected_paths = set()
        for directory in builder.SCENARIOS.values():
            base = ROOT / "MobilityAgent" / directory / "SupportedKernels"
            expected_paths.update(path.relative_to(ROOT).as_posix() for path in base.rglob("*.txt"))
        self.assertEqual(
            {manifest["path"] for manifest in index["manifests"]}, expected_paths
        )
        actual_entries = [set() for _ in index["manifests"]]
        for kernel, references in index["kernels"].items():
            for reference in references:
                actual_entries[reference].add(kernel)
        for reference, manifest in enumerate(index["manifests"]):
            with self.subTest(path=manifest["path"]):
                path = ROOT / manifest["path"]
                expected = {
                    line.strip()
                    for line in path.read_text(encoding="utf-8-sig").splitlines()
                    if line.strip()
                }
                self.assertEqual(actual_entries[reference], expected)
                self.assertEqual(
                    manifest["url"],
                    f"https://github.com/Azure/Azure-SiteRecovery/blob/{COMMIT}/{manifest['path']}",
                )


if __name__ == "__main__":
    unittest.main()
