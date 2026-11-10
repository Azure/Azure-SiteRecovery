# Supported-kernel search

This static page searches the existing A2A and V2A manifests. It needs no backend,
database, frontend framework, npm packages, or separate repository. Python 3.13+
builds the index; Node.js 24+ runs the JavaScript tests.

## What results mean

Paste a kernel release from `uname -r`. Matching is exact and case-sensitive by
default, after trimming surrounding whitespace. Enable partial search to use a
literal substring; it does not interpret regular expressions or version ranges.
Optional filters select a scenario, distro/release, and kernel module update
version. Reset clears the query and all filters.

Results group the same kernel, scenario, distro/release, and architecture across
explicitly matching manifests. Expand a result to see its update versions and
commit-pinned source links. Versions sort numerically, newest first. Broad
searches display 50 groups at a time; **Show more matches** reveals the next batch.

A match means **listed in that published manifest**, not a guarantee of
compatibility with the installed agent. Folder versions identify kernel module
updates, not necessarily agent or extension releases. Updates can be sparse; the
search does not infer cumulative support or treat missing entries as proof of
unsupported status. Empty manifests provide no kernel matches.

## Local build and checks

Run these commands from the repository root in PowerShell:

```powershell
python -B -m unittest discover -s tests -p 'test_*.py'
node --test tests\kernel_search.test.mjs
$output = Join-Path ([System.IO.Path]::GetTempPath()) 'asr-kernel-search'
python -B scripts\build_kernel_index.py --output-dir $output
python -m http.server 8000 --bind 127.0.0.1 --directory $output
```

Open `http://127.0.0.1:8000`. Stop the local server with Ctrl+C when finished.
The source HTML cannot be opened directly with `file://` because it loads
`kernels.json` using HTTP. Generated files stay in the output directory, not in
the repository. Rebuild after editing manifests or static source files.

The generator reads the working tree and defaults its source commit to Git
`HEAD`. For reliable provenance, publish only from a clean, committed checkout.
The workflow supplies the build commit and repository explicitly. The index
stores shared manifest metadata and kernel-to-manifest references; the original
text files remain authoritative. Unexpected filenames or directory layouts fail
the build instead of silently omitting data.

## Maintainer: enable GitHub Pages

The public page is **not available until Pages is enabled and deployment succeeds**.
No custom domain or separate repository is required.

1. Merge the feature into `main`.
2. In repository **Settings > Pages > Build and deployment**, select
   **GitHub Actions** as the source. This may require repository administrator
   access and must be allowed by organization policy.
3. In **Actions > Kernel search**, run the workflow on `main` if it has not
   already deployed successfully. Approve the `github-pages` environment
   deployment if repository protections require it.
4. Open the URL reported by the successful deployment and exercise a known
   exact kernel query, scenario filters, and source links before announcing it.

For `Azure/Azure-SiteRecovery` with default project Pages settings, the expected
URL is `https://azure.github.io/Azure-SiteRecovery/`. Use the deployment output
as the authoritative URL, especially for forks or repositories with custom
Pages settings.

The workflow validates pull requests without deployment permissions. Relevant
pushes to `main` rebuild and deploy automatically, including changes under
either scenario's `SupportedKernels` directory. Manual runs on other branches
validate/build only; they cannot deploy. Deployment is serialized and uses the
standard GitHub Pages artifact and environment.

If GitHub Actions or Pages is disabled by organization policy, a maintainer
must resolve that setting; the same generated artifact can still be previewed
locally without changing manifests.
