"""Build the static kernel lookup from the repository's published manifests."""

import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path
from urllib.parse import quote


ROOT = Path(__file__).resolve().parents[1]
SCENARIOS = {"A2A": "AzureToAzure", "V2A": "OnPremiseToAzure"}
DISTRIBUTIONS = {
    "DEBIAN": "Debian",
    "OL": "Oracle Linux",
    "RHEL": "RHEL",
    "SLES": "SUSE Linux Enterprise Server",
    "UBUNTU": "Ubuntu",
}
FILENAME = re.compile(
    r"(?P<distro>DEBIAN|OL|RHEL|SLES|UBUNTU)-?"
    r"(?P<release>\d+(?:\.\d+)?)-(?P<architecture>\d+)_supported_kernels\.txt",
    re.IGNORECASE,
)
ASSETS = ("index.html", "styles.css", "search.js", "app.js")


def build_index(root, source_commit, repository="Azure/Azure-SiteRecovery"):
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise ValueError("Source commit must be a full 40-character Git commit SHA.")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository, flags=re.ASCII):
        raise ValueError("Repository must have the form owner/name.")

    manifests = []
    kernels = {}
    for scenario, directory in SCENARIOS.items():
        base = root / "MobilityAgent" / directory / "SupportedKernels"
        if not base.is_dir():
            raise ValueError(f"Missing manifest directory: {base}")
        files = sorted(
            (path for path in base.rglob("*") if path.is_file()),
            key=lambda path: path.relative_to(base).as_posix(),
        )
        for path in files:
            relative = path.relative_to(base)
            match = FILENAME.fullmatch(path.name)
            if (
                len(relative.parts) != 2
                or not re.fullmatch(r"\d+(?:\.\d+){3}", relative.parts[0])
                or match is None
            ):
                raise ValueError(f"Unexpected manifest path: {path.relative_to(root)}")
            source_path = path.relative_to(root).as_posix()
            manifest_id = len(manifests)
            manifests.append(
                {
                    "scenario": scenario,
                    "distribution": DISTRIBUTIONS[match["distro"].upper()],
                    "release": match["release"],
                    "architecture": match["architecture"],
                    "version": relative.parts[0],
                    "path": source_path,
                    "url": (
                        f"https://github.com/{repository}/blob/{source_commit}/"
                        f"{quote(source_path, safe='/')}"
                    ),
                }
            )
            entries = {
                line.strip()
                for line in path.read_text(encoding="utf-8-sig").splitlines()
                if line.strip()
            }
            for kernel in sorted(entries):
                kernels.setdefault(kernel, []).append(manifest_id)
    if not manifests or not kernels:
        raise ValueError("No kernel entries found in the published manifests.")
    return {
        "schemaVersion": 1,
        "repository": repository,
        "sourceCommit": source_commit,
        "manifests": manifests,
        "kernels": dict(sorted(kernels.items())),
    }


def write_site(root, output_dir, index):
    output_dir.mkdir(parents=True, exist_ok=True)
    for name in ASSETS:
        shutil.copyfile(root / "site" / "kernel-search" / name, output_dir / name)
    (output_dir / "kernels.json").write_text(
        json.dumps(index, ensure_ascii=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--source-commit", help="Defaults to the current Git HEAD.")
    parser.add_argument("--repository", default="Azure/Azure-SiteRecovery")
    args = parser.parse_args()
    try:
        commit = args.source_commit or subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip()
        index = build_index(ROOT, commit, args.repository)
        write_site(ROOT, args.output_dir, index)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Kernel search build failed: {error}\n")
    print(
        f"Built {len(index['kernels'])} distinct kernels from "
        f"{len(index['manifests'])} manifests in {args.output_dir}"
    )


if __name__ == "__main__":
    main()
