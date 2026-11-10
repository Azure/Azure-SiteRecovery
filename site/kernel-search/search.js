export function compareVersions(left, right) {
  const a = left.split(".").map(Number);
  const b = right.split(".").map(Number);
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const difference = (b[i] ?? 0) - (a[i] ?? 0);
    if (difference) return difference;
  }
  return 0;
}

export function distroLabel(manifest) {
  return `${manifest.distribution} ${manifest.release}`;
}

export function filterOptions(index) {
  return {
    scenarios: [...new Set(index.manifests.map((item) => item.scenario))].sort(),
    distributions: [...new Set(index.manifests.map(distroLabel))].sort((a, b) =>
      a.localeCompare(b, "en", { numeric: true }),
    ),
    versions: [...new Set(index.manifests.map((item) => item.version))].sort(compareVersions),
  };
}

export function search(index, { query = "", partial = false, scenario = "", distribution = "", version = "" } = {}) {
  const needle = query.trim();
  if (!needle) return [];
  const kernels = partial
    ? Object.keys(index.kernels).filter((kernel) => kernel.includes(needle))
    : Object.hasOwn(index.kernels, needle) ? [needle] : [];
  const groups = new Map();
  for (const kernel of kernels.sort()) {
    for (const reference of index.kernels[kernel]) {
      const manifest = index.manifests[reference];
      if (scenario && manifest.scenario !== scenario) continue;
      if (distribution && distroLabel(manifest) !== distribution) continue;
      if (version && manifest.version !== version) continue;
      const key = JSON.stringify([
        kernel, manifest.scenario, manifest.distribution, manifest.release, manifest.architecture,
      ]);
      if (!groups.has(key)) {
        groups.set(key, {
          kernel,
          scenario: manifest.scenario,
          distribution: distroLabel(manifest),
          architecture: manifest.architecture,
          manifests: [],
        });
      }
      groups.get(key).manifests.push(manifest);
    }
  }
  return [...groups.values()].map((group) => ({
    ...group,
    manifests: group.manifests.sort((a, b) =>
      compareVersions(a.version, b.version) || a.path.localeCompare(b.path),
    ),
  }));
}
