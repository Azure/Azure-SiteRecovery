import { filterOptions, search } from "./search.js";

const form = document.querySelector("#search-form");
const controls = document.querySelector("#search-controls");
const kernelInput = document.querySelector("#kernel");
const partialInput = document.querySelector("#partial");
const scenarioInput = document.querySelector("#scenario");
const distributionInput = document.querySelector("#distribution");
const versionInput = document.querySelector("#version");
const status = document.querySelector("#status");
const resultList = document.querySelector("#result-list");
const showMore = document.querySelector("#show-more");
const retry = document.querySelector("#retry");
const provenance = document.querySelector("#provenance");
const PAGE_SIZE = 50;
let index;
let matches = [];
let displayed = 0;
let scheduled;

function element(tag, text) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  return node;
}

function appendResults() {
  const next = matches.slice(displayed, displayed + PAGE_SIZE);
  const fragment = document.createDocumentFragment();
  for (const match of next) {
    const item = element("li");
    const heading = element("h3");
    heading.append(element("code", match.kernel));
    item.append(heading, element("p", `${match.scenario} | ${match.distribution} | ${match.architecture}-bit`));
    const details = element("details");
    const count = new Set(match.manifests.map((manifest) => manifest.version)).size;
    details.append(element("summary", `Listed in ${count} kernel module update version${count === 1 ? "" : "s"} (view sources)`));
    const sources = element("ul");
    for (const manifest of match.manifests) {
      const source = element("li");
      const link = element("a", `${manifest.version} - ${manifest.path.split("/").at(-1)}`);
      link.href = manifest.url;
      source.append(link);
      sources.append(source);
    }
    details.append(sources);
    item.append(details);
    fragment.append(item);
  }
  resultList.append(fragment);
  displayed += next.length;
  showMore.hidden = displayed >= matches.length;
  if (matches.length) {
    status.textContent = `Listed in published manifests: ${matches.length} matching kernel/scenario/distribution group${matches.length === 1 ? "" : "s"}. Showing ${displayed}.`;
  }
}

function runSearch() {
  clearTimeout(scheduled);
  if (!index) return;
  matches = search(index, {
    query: kernelInput.value,
    partial: partialInput.checked,
    scenario: scenarioInput.value,
    distribution: distributionInput.value,
    version: versionInput.value,
  });
  resultList.replaceChildren();
  displayed = 0;
  showMore.hidden = true;
  if (!kernelInput.value.trim()) {
    status.textContent = "Enter a kernel release to search the published manifests.";
  } else if (!matches.length) {
    status.textContent = "No matching entry found in the published manifests for this query and filters. This does not prove the kernel is unsupported.";
  } else {
    appendResults();
  }
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  runSearch();
});
kernelInput.addEventListener("input", () => {
  clearTimeout(scheduled);
  scheduled = setTimeout(runSearch, 150);
});
for (const input of [partialInput, scenarioInput, distributionInput, versionInput]) {
  input.addEventListener("change", runSearch);
}
form.addEventListener("reset", () => {
  // The reset event fires before the browser restores the control defaults.
  setTimeout(runSearch, 0);
});
showMore.addEventListener("click", () => {
  const previous = displayed;
  appendResults();
  const heading = resultList.children[previous]?.querySelector("h3");
  if (heading) {
    heading.tabIndex = -1;
    heading.focus();
  }
});
retry.addEventListener("click", loadIndex);

async function loadIndex() {
  retry.hidden = true;
  status.textContent = "Loading published manifests...";
  try {
    const response = await fetch("./kernels.json");
    if (!response.ok) throw new Error(`Index request failed: ${response.status}`);
    const data = await response.json();
    if (data.schemaVersion !== 1 || !Array.isArray(data.manifests) || !data.kernels) {
      throw new Error("Unrecognized kernel index.");
    }
    index = data;
    const options = filterOptions(index);
    for (const [select, values] of [
      [scenarioInput, options.scenarios],
      [distributionInput, options.distributions],
      [versionInput, options.versions],
    ]) {
      select.replaceChildren(select.options[0]);
      for (const value of values) select.add(new Option(value, value));
    }
    const commit = element("a", index.sourceCommit.slice(0, 12));
    commit.href = `https://github.com/${index.repository}/commit/${index.sourceCommit}`;
    provenance.replaceChildren(
      document.createTextNode(`Indexed ${index.manifests.length} manifests from source commit `),
      commit,
      document.createTextNode("."),
    );
    controls.disabled = false;
    runSearch();
  } catch {
    controls.disabled = true;
    status.textContent = "Could not load the kernel index. Retry or browse the source repository below.";
    retry.hidden = false;
  }
}

loadIndex();
