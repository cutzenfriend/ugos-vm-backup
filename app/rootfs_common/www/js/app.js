"use strict";

// All data from the server goes into the DOM through text nodes only. VM names
// and manifests can contain anything, so innerHTML is never used in this file.

const STALE_AFTER_SECONDS = 30 * 60;
const POLL_MS = 15000;
const STRIP_DAYS = 30;
const DAY = 86400;

const TYPE_NAMES = { snapshot: "Snapshot", file: "File backup", ova: "OVA export" };
const RUNNING_NAMES = {
  live: "while running",
  shutdown: "with a brief shutdown",
  skip: "only when powered off",
};
const INTERVALS = [
  [1, "Every hour"], [2, "Every 2 hours"], [3, "Every 3 hours"], [4, "Every 4 hours"],
  [6, "Every 6 hours"], [8, "Every 8 hours"], [12, "Every 12 hours"], [24, "Daily"],
  [48, "Every 2 days"], [72, "Every 3 days"], [168, "Weekly (Mondays)"],
  [336, "Every 2 weeks (Mondays)"], [720, "Every 30 days"],
];

let state = null;
let token = null;
let currentView = "overview";
let chosenView = false;

// --- DOM helper ---------------------------------------------------------------

function h(tag, props, ...children) {
  const element = document.createElement(tag);
  for (const [key, value] of Object.entries(props || {})) {
    if (value === undefined || value === null || value === false) continue;
    if (key === "class") element.className = value;
    else if (key.startsWith("on")) element.addEventListener(key.slice(2), value);
    else if (key in element && key !== "list") element[key] = value;
    else element.setAttribute(key, value);
  }
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    element.append(child);
  }
  return element;
}

// --- Server -------------------------------------------------------------------

async function api(method, path, body) {
  const headers = {};
  if (token) headers["Ugreen-Ttk"] = token;
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const response = await fetch(path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `The server responded with error ${response.status}`);
  return data;
}

// Outside the UGOS desktop the SDK never answers, so waiting has a limit.
async function loadToken() {
  if (!window.UgvmSdk) return;
  try {
    const info = await Promise.race([
      window.UgvmSdk.getThirdToken(),
      new Promise((resolve) => setTimeout(resolve, 2000)),
    ]);
    if (info && info.third_token) token = info.third_token;
  } catch (error) {
    console.warn("UGOS token not available", error);
  }
}

async function refresh() {
  try {
    state = await api("GET", "/api/state");
    render();
  } catch (error) {
    renderFatal(error.message);
  }
}

// --- Formatting ---------------------------------------------------------------

const formatDateTime = (epoch) => new Date(epoch * 1000).toLocaleString(undefined, {
  day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit",
});

function formatAge(seconds) {
  if (seconds < 90) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 90) return `${minutes} minutes ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 36) return `${hours} hours ago`;
  const days = Math.round(hours / 24);
  return days === 1 ? "1 day ago" : `${days} days ago`;
}

function formatSize(bytes) {
  if (!bytes) return "";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(unit < 3 ? 0 : 1)} ${units[unit]}`;
}

function intervalName(hours) {
  const found = INTERVALS.find(([value]) => value === hours);
  return found ? found[1] : `Every ${hours} hours`;
}

function retentionText(job) {
  const count = job.keep_count === 1 ? "at most 1 backup" : `at most ${job.keep_count} backups`;
  const days = job.keep_days === 1 ? "for up to 1 day" : `for up to ${job.keep_days} days`;
  if (job.keep_count && job.keep_days) return `keeps ${count} ${days}`;
  if (job.keep_count) return `keeps ${count}`;
  if (job.keep_days) return `keeps backups ${days}`;
  return "keeps all backups";
}

const vmTitle = (id) => {
  const vm = state.status && (state.status.vms || []).find((item) => item.id === id);
  return (vm && vm.title) || id;
};

// --- Health -------------------------------------------------------------------

function scriptAge() {
  return state.status ? state.now - state.status.heartbeat : Infinity;
}

const setupIncomplete = () => !state.config_host_path || !state.status;
const scriptStale = () => Boolean(state.status) && scriptAge() > STALE_AFTER_SECONDS;
const scriptOutdated = () => Boolean(state.status) && state.status.script_version !== state.script_version;

function jobIssues() {
  const status = state.status;
  if (!status) return [];
  const issues = [];
  if (status.config_error) issues.push(status.config_error);
  for (const entry of status.job_errors || []) issues.push(entry.error);
  for (const job of status.jobs || []) {
    for (const vm of job.vms || []) {
      if (vm.result === "error") issues.push(`${vmTitle(vm.vm)}: ${vm.error}`);
    }
  }
  return issues;
}

function health() {
  if (state.config_error) {
    return { level: "bad", title: "The settings can't be read", text: state.config_error, view: "setup" };
  }
  if (setupIncomplete()) {
    return {
      level: "warn",
      title: "No backups are active yet",
      text: "Setup isn't finished yet.",
      view: "setup",
      action: "Continue setup",
    };
  }
  if (scriptStale()) {
    return {
      level: "bad",
      title: "Backups aren't running",
      text: `The backup script last reported ${formatAge(scriptAge())}. A UGOS update or restart may have removed the cron job.`,
      view: "setup",
      action: "Check cron job",
    };
  }
  const issues = jobIssues();
  if (issues.length) {
    return {
      level: "bad",
      title: issues.length === 1 ? "1 backup problem" : `${issues.length} backup problems`,
      text: issues[0],
    };
  }
  if (scriptOutdated()) {
    return {
      level: "warn",
      title: "Script update available",
      text: `Version ${state.status.script_version} is installed. This app includes ${state.script_version}.`,
      view: "setup",
      action: "Update script",
    };
  }
  if (!state.jobs.length) {
    return {
      level: "warn",
      title: "No jobs yet",
      text: "The script is running, but it backs up nothing until you create a job.",
      view: "jobs",
      action: "Create job",
    };
  }
  const uncovered = unprotectedVMs();
  if (uncovered.length) {
    return {
      level: "warn",
      title: uncovered.length === 1 ? "1 VM has no backup" : `${uncovered.length} VMs have no backup`,
      text: uncovered.map((vm) => vm.title || vm.id).join(", "),
    };
  }
  return {
    level: "ok",
    title: "All VMs are backed up",
    text: `The backup script last reported ${formatAge(scriptAge())}.`,
  };
}

function restorePoints(vmId) {
  const status = state.status || {};
  return [...(status.backups || []), ...(status.snapshots || [])]
    .filter((point) => point.vm === vmId)
    .sort((a, b) => b.created - a.created);
}

function jobsCovering(vmId) {
  return state.jobs.filter((job) => job.vms.includes("*") || job.vms.includes(vmId));
}

function unprotectedVMs() {
  return ((state.status && state.status.vms) || []).filter((vm) => !restorePoints(vm.id).length);
}

function vmErrors(vmId) {
  const errors = [];
  for (const job of (state.status && state.status.jobs) || []) {
    for (const vm of job.vms || []) {
      if (vm.vm === vmId && vm.result === "error") errors.push(vm.error);
    }
  }
  return errors;
}

// --- Overview -----------------------------------------------------------------

function renderHealth() {
  const summary = health();
  return h("section", { class: `health ${summary.level}` },
    h("h2", {}, summary.title),
    h("p", {}, summary.text),
    summary.action && h("button", {
      type: "button",
      class: "button primary",
      onclick: () => show(summary.view),
    }, summary.action));
}

function renderStrip(points) {
  const start = state.now - STRIP_DAYS * DAY;
  const strip = h("div", {
    class: "strip",
    role: "img",
    "aria-label": `${points.length} restore points, last ${STRIP_DAYS} days`,
  });
  points.forEach((point, index) => {
    if (point.created < start) return;
    const position = ((point.created - start) / (STRIP_DAYS * DAY)) * 100;
    const marker = h("span", {
      class: `point ${point.type}${index === 0 ? " latest" : ""}`,
      title: `${TYPE_NAMES[point.type]}, ${formatDateTime(point.created)}${point.size ? `, ${formatSize(point.size)}` : ""}`,
    });
    marker.setAttribute("data-left", String(Math.min(100, position)));
    strip.append(marker);
  });
  return strip;
}

function latestText(vm, points) {
  if (points.length) {
    const latest = points[0];
    const size = latest.size ? `, ${formatSize(latest.size)}` : "";
    return h("div", { class: "vm-latest" }, `${TYPE_NAMES[latest.type]} ${formatAge(state.now - latest.created)}${size}`);
  }
  if (!jobsCovering(vm.id).length) {
    return h("div", { class: "vm-latest bad" }, "No job covers this VM");
  }
  return h("div", { class: "vm-latest bad" }, "No backup yet");
}

function renderOverview() {
  const nodes = [renderHealth()];
  const status = state.status;
  if (status && status.state === "running") {
    nodes.push(h("div", { class: "current" },
      `${vmTitle(status.current.vm)}: ${status.current.step}`));
  }
  if (!status) return nodes;

  const vms = status.vms || [];
  if (!vms.length) {
    nodes.push(h("p", { class: "empty" },
      "The script found no VMs. Create one in the Virtual Machine app and it will appear here."));
    return nodes;
  }

  nodes.push(h("ul", { class: "vms" }, vms.map((vm) => {
    const points = restorePoints(vm.id);
    const running = vm.state === "running";
    return h("li", { class: "vm" },
      h("div", {},
        h("div", { class: "vm-name" }, vm.title || vm.id),
        h("div", { class: `vm-state${running ? " running" : ""}` }, running ? "Running" : "Powered off"),
        latestText(vm, points)),
      h("div", {},
        renderStrip(points),
        h("div", { class: "axis" }, h("span", {}, `${STRIP_DAYS} days ago`), h("span", {}, "today"))),
      vmErrors(vm.id).map((error) => h("div", { class: "vm-error" }, error)));
  })));

  nodes.push(h("div", { class: "legend" },
    h("span", { class: "l-file" }, "File backup"),
    h("span", { class: "l-ova" }, "OVA export"),
    h("span", { class: "l-snapshot" }, "Snapshot")));

  const log = (status.log || []).slice().reverse();
  if (log.length) {
    nodes.push(h("details", { class: "log" },
      h("summary", {}, "Recent events"),
      h("ul", { class: "log-list" }, log.map((entry) => h("li", {},
        h("time", {}, formatDateTime(entry.time)),
        h("span", { class: entry.level === "error" ? "error" : "" }, entry.message))))));
  }
  return nodes;
}

function applyStripPositions(container) {
  for (const marker of container.querySelectorAll(".point")) {
    marker.style.left = `${marker.getAttribute("data-left")}%`;
  }
}

// --- Jobs ---------------------------------------------------------------------

function jobSchedule(job) {
  const interval = intervalName(job.interval_hours);
  return job.interval_hours >= 24 ? `${interval} at ${job.at}` : interval;
}

function jobVmNames(job) {
  return job.vms.includes("*") ? "all VMs" : job.vms.map(vmTitle).join(", ");
}

function statusForJob(id) {
  return ((state.status && state.status.jobs) || []).find((job) => job.id === id);
}

function renderJobs() {
  const head = h("div", { class: "section-head" },
    h("h2", {}, "Jobs"),
    h("button", {
      type: "button",
      class: "button primary",
      disabled: !state.config_host_path,
      onclick: () => openJobDialog(null),
    }, "Create job"));

  if (!state.config_host_path) {
    return [head, h("div", { class: "empty" },
      "First choose a config folder in Setup.",
      h("button", { type: "button", class: "button", onclick: () => show("setup") }, "Go to Setup"))];
  }
  if (!state.jobs.length) {
    return [head, h("p", { class: "empty" },
      "A job sets which VMs are backed up, how often, and how long the backups are kept.")];
  }

  return [head, h("ul", { class: "job-list" }, state.jobs.map((job) => {
    const status = statusForJob(job.id);
    const errors = ((status && status.vms) || []).filter((vm) => vm.result === "error");
    const target = job.type === "snapshot" ? "" : ` ${RUNNING_NAMES[job.running_vm]}, to ${job.target}`;
    return h("li", { class: "job" },
      h("div", { class: "job-main" },
        h("div", { class: "job-title" }, job.name || TYPE_NAMES[job.type],
          !job.enabled && h("span", { class: "off" }, " (paused)")),
        h("div", { class: "job-detail" },
          `${TYPE_NAMES[job.type]} for ${jobVmNames(job)}: ${jobSchedule(job)},${target ? `${target},` : ""} ${retentionText(job)}.`),
        job.enabled && status && status.next_run && h("div", { class: "job-detail" },
          `Next run: ${formatDateTime(status.next_run)}`),
        errors.map((vm) => h("div", { class: "job-error" }, `${vmTitle(vm.vm)}: ${vm.error}`))),
      h("div", { class: "job-actions" },
        h("button", { type: "button", class: "button", onclick: () => runNow(job) }, "Back up now"),
        h("button", { type: "button", class: "button", onclick: () => openJobDialog(job) }, "Edit")));
  }))];
}

async function runNow(job) {
  try {
    await api("POST", `/api/jobs/${encodeURIComponent(job.id)}/run`);
    toast("Starts on the script's next run, within 10 minutes.");
    await refresh();
  } catch (error) {
    toast(error.message);
  }
}

async function saveJobs(jobs) {
  await api("PUT", "/api/jobs", { jobs });
  await refresh();
}

function openJobDialog(existing) {
  const job = existing ? { ...existing } : {
    id: "", name: "", type: "file", enabled: true, interval_hours: 24, at: "03:00",
    vms: ["*"], target: "", keep_count: 7, keep_days: 30, running_vm: "live",
  };

  const vmList = (state.status && state.status.vms) || [];
  const allBox = h("input", { type: "checkbox", checked: job.vms.includes("*") });
  const vmBoxes = vmList.map((vm) => ({
    id: vm.id,
    box: h("input", { type: "checkbox", checked: job.vms.includes(vm.id) }),
    title: vm.title || vm.id,
  }));
  const vmChecks = h("div", { class: "vm-checks" },
    h("label", { class: "choice" }, allBox, h("span", {}, "All VMs, including future ones")),
    vmBoxes.map(({ box, title }) => h("label", { class: "vm-choice choice" }, box, h("span", {}, title))));

  const typeRadios = Object.keys(TYPE_NAMES).map((type) => h("input", {
    type: "radio", name: "job-type", value: type, checked: job.type === type,
  }));
  const typeHelp = {
    snapshot: "Fast and stored on the VM disk. Protects against mistakes, not against drive failure.",
    file: "A full copy of the disks in a folder, ready to attach again.",
    ova: "A full copy as a single OVA file, for importing into other systems.",
  };
  const typeChoices = Object.keys(TYPE_NAMES).map((type, index) => h("label", { class: "choice" },
    typeRadios[index],
    h("span", {}, TYPE_NAMES[type], h("small", {}, typeHelp[type]))));

  const nameInput = h("input", { type: "text", value: job.name, maxLength: 64, placeholder: "For example: Nightly" });
  const intervalSelect = h("select", {}, INTERVALS.map(([value, label]) => h("option", {
    value: String(value), selected: value === job.interval_hours,
  }, label)));
  const atInput = h("input", { type: "time", value: job.at });
  const atField = h("label", { class: "field" }, h("span", { class: "label" }, "Time"), atInput);

  const runningSelect = h("select", {},
    h("option", { value: "live", selected: job.running_vm === "live" }, "Back up while running"),
    h("option", { value: "shutdown", selected: job.running_vm === "shutdown" }, "Shut down, back up, start again"),
    h("option", { value: "skip", selected: job.running_vm === "skip" }, "Skip while it is running"));

  let target = job.target;
  const targetPath = h("span", { class: "path" }, target || "No folder chosen yet");
  const pickButton = h("button", {
    type: "button",
    class: "button",
    onclick: () => openFolderPicker({
      title: "Choose target folder",
      onPick: (listing) => {
        target = listing.host_path;
        targetPath.textContent = target;
      },
    }),
  }, "Choose folder");
  const folderFields = h("div", {},
    h("div", { class: "field" }, h("span", { class: "label" }, "Target folder"),
      h("div", { class: "path-row" }, targetPath, pickButton)),
    h("label", { class: "field" }, h("span", { class: "label" }, "If the VM is running"), runningSelect));

  const countInput = h("input", { type: "number", min: "0", max: "1000", value: String(job.keep_count) });
  const daysInput = h("input", { type: "number", min: "0", max: "3650", value: String(job.keep_days) });
  const snapshotHint = h("div", { class: "hint warn", hidden: true },
    "Many snapshots slow the VM down, and each one uses about as much space as its RAM. Keep 3 at most.");

  const enabledBox = h("input", { type: "checkbox", checked: job.enabled });
  const errorBox = h("p", { class: "form-error", role: "alert", hidden: true });

  const selectedType = () => typeRadios.find((radio) => radio.checked).value;

  function sync() {
    const type = selectedType();
    folderFields.hidden = type === "snapshot";
    atField.hidden = Number(intervalSelect.value) < 24;
    snapshotHint.hidden = !(type === "snapshot" && (Number(countInput.value) === 0 || Number(countInput.value) > 3));
    for (const { box } of vmBoxes) box.disabled = allBox.checked;
  }
  for (const element of [...typeRadios, intervalSelect, countInput, allBox]) {
    element.addEventListener("input", sync);
  }

  async function save(event) {
    event.preventDefault();
    errorBox.hidden = true;
    const type = selectedType();
    const result = {
      id: job.id,
      name: nameInput.value.trim(),
      type,
      enabled: enabledBox.checked,
      interval_hours: Number(intervalSelect.value),
      at: atInput.value || "00:00",
      vms: allBox.checked ? ["*"] : vmBoxes.filter(({ box }) => box.checked).map(({ id }) => id),
      target: type === "snapshot" ? "" : target,
      keep_count: Number(countInput.value),
      keep_days: Number(daysInput.value),
      running_vm: type === "snapshot" ? "" : runningSelect.value,
    };
    const others = state.jobs.filter((item) => item.id !== job.id);
    try {
      await saveJobs(existing ? state.jobs.map((item) => (item.id === job.id ? result : item)) : [...others, result]);
      closeDialog();
      toast(existing ? "Job saved." : "Job created. It runs at its next scheduled time.");
    } catch (error) {
      errorBox.textContent = error.message;
      errorBox.hidden = false;
    }
  }

  async function remove() {
    if (!window.confirm("Delete this job? Existing backups are kept.")) return;
    try {
      await saveJobs(state.jobs.filter((item) => item.id !== job.id));
      closeDialog();
      toast("Job deleted. Its backups were kept.");
    } catch (error) {
      errorBox.textContent = error.message;
      errorBox.hidden = false;
    }
  }

  openDialog(h("form", { onsubmit: save },
    h("h2", {}, existing ? "Edit job" : "Create job"),
    h("label", { class: "field" }, h("span", { class: "label" }, "Name"), nameInput),
    h("fieldset", { class: "field" }, h("legend", {}, "Backup type"), typeChoices),
    h("div", { class: "field" }, h("span", { class: "label" }, "VMs"), vmChecks),
    h("div", { class: "row" },
      h("label", { class: "field" }, h("span", { class: "label" }, "How often"), intervalSelect),
      atField),
    folderFields,
    h("div", { class: "row" },
      h("label", { class: "field" }, h("span", { class: "label" }, "Keep at most (backups)"), countInput),
      h("label", { class: "field" }, h("span", { class: "label" }, "Keep at most (days)"), daysInput)),
    h("p", { class: "hint" }, "0 means no limit. The newest backup is never deleted."),
    snapshotHint,
    h("label", { class: "choice" }, enabledBox, h("span", {}, "Job is active")),
    errorBox,
    h("div", { class: "dialog-actions" },
      existing && h("button", { type: "button", class: "button danger spacer", onclick: remove }, "Delete job"),
      h("button", { type: "button", class: "button", onclick: closeDialog }, "Cancel"),
      h("button", { type: "submit", class: "button primary" }, existing ? "Save job" : "Create job"))));
  sync();
}

// --- Folder picker ------------------------------------------------------------

// The picker opens on top of a job form, so it uses its own dialog element.
function openFolderPicker({ title, onPick }) {
  const box = h("dialog", {});
  document.body.append(box);
  box.addEventListener("close", () => box.remove());
  const content = h("div", {});
  box.append(content);
  box.showModal();

  function renderRoots() {
    const usable = state.folders;
    content.replaceChildren(
      h("h2", {}, title),
      usable.length
        ? h("ul", { class: "tree" }, usable.map((folder) => h("li", {},
          h("button", {
            type: "button",
            disabled: !folder.usable,
            onclick: () => open(folder.name),
          }, folder.name, h("small", {}, folder.reason || folder.host_path)))))
        : h("p", { class: "none" }, "No folders authorized yet. Give this app access to a folder in its App Center settings."),
      h("div", { class: "dialog-actions" },
        h("button", { type: "button", class: "button", onclick: () => box.close() }, "Cancel")));
  }

  async function open(path) {
    let listing;
    try {
      listing = await api("GET", `/api/folders?path=${encodeURIComponent(path)}`);
    } catch (error) {
      toast(error.message);
      return;
    }
    const parts = path.split("/");
    content.replaceChildren(
      h("h2", {}, title),
      h("div", { class: "crumbs" },
        h("button", { type: "button", class: "link", onclick: renderRoots }, "Shared folders"),
        parts.map((part, index) => [
          h("span", {}, "/"),
          h("button", {
            type: "button",
            class: "link",
            onclick: () => open(parts.slice(0, index + 1).join("/")),
          }, part),
        ])),
      h("ul", { class: "tree" }, listing.dirs.length
        ? listing.dirs.map((dir) => h("li", {},
          h("button", { type: "button", onclick: () => open(`${path}/${dir}`) }, dir)))
        : h("li", { class: "none" }, "No subfolders")),
      h("div", { class: "dialog-actions" },
        h("button", { type: "button", class: "button", onclick: () => box.close() }, "Cancel"),
        h("button", {
          type: "button",
          class: "button primary",
          onclick: () => {
            onPick(listing);
            box.close();
          },
        }, "Choose this folder")));
  }

  renderRoots();
}

// --- Setup --------------------------------------------------------------------

function commandBlock(command) {
  const copy = h("button", {
    type: "button",
    class: "button",
    onclick: async () => {
      try {
        await navigator.clipboard.writeText(command);
        toast("Copied.");
      } catch {
        // Clipboard access can be blocked inside the UGOS window.
        const range = document.createRange();
        range.selectNodeContents(code);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        toast("Command selected. Press Ctrl+C or Cmd+C to copy it.");
      }
    },
  }, "Copy");
  const code = h("code", {}, command);
  return h("div", { class: "command" }, code, copy);
}

function stepClass(done, isCurrent) {
  if (done) return "step done";
  return isCurrent ? "step current-step" : "step";
}

function renderSetup() {
  const hasFolders = state.folders.some((folder) => folder.usable);
  const hasConfig = Boolean(state.config_host_path);
  const reports = Boolean(state.status);
  const fresh = reports && !scriptStale();

  const steps = [
    h("li", { class: stepClass(hasFolders, !hasFolders) },
      h("h3", {}, "Authorize folders for the app"),
      h("p", {}, "Open App Center, open this app's settings, and give it access to the folders for its settings and your backups."),
      state.folders.filter((folder) => !folder.usable).map((folder) => h("div", { class: "note warn" },
        `${folder.name}: ${folder.reason}`)),
      h("button", { type: "button", class: "button", onclick: refresh }, "Check again")),

    h("li", { class: stepClass(hasConfig, hasFolders && !hasConfig) },
      h("h3", {}, "Choose a config folder"),
      h("p", {}, "This holds the settings and status, in a subfolder named ugvm-backup. Choose a folder only administrators can write to."),
      hasConfig && h("div", { class: "note ok" }, state.config_host_path),
      state.config_error && h("div", { class: "note bad" }, state.config_error),
      hasFolders && h("button", {
        type: "button",
        class: "button",
        onclick: () => openFolderPicker({ title: "Choose a config folder", onPick: chooseConfigFolder }),
      }, hasConfig ? "Choose another folder" : "Choose folder")),
  ];

  if (state.setup) {
    const outdated = scriptOutdated();
    steps.push(
      h("li", { class: stepClass(reports && !outdated, hasConfig && !reports) },
        h("h3", {}, outdated ? "Update the backup script" : "Install the backup script"),
        h("p", {}, "Connect to the NAS over SSH and run this command. It puts the script where only root can change it."),
        commandBlock(state.setup.install_command),
        outdated && h("div", { class: "note warn" },
          `Version ${state.status.script_version} is installed. This app includes ${state.script_version}.`)),

      h("li", { class: stepClass(fresh, hasConfig && !fresh) },
        h("h3", {}, "Create the root cron job"),
        h("p", {}, "Run sudo crontab -e and add this line. The script then runs every 10 minutes and only acts when a backup is due."),
        commandBlock(state.setup.cron_line),
        reports && !fresh && h("div", { class: "note bad" },
          `The script last reported ${formatAge(scriptAge())}. Check that the line is still in root's crontab.`),
        fresh && h("div", { class: "note ok" }, `The script last reported ${formatAge(scriptAge())}.`),
        !reports && h("p", { class: "hint" },
          "This step completes by itself after the script's first run. To test the script now, run:"),
        !reports && commandBlock(state.setup.check_command)),
    );
  }

  const nodes = [h("h2", {}, "Setup"), h("ol", { class: "steps" }, steps)];
  if (state.setup && reports) {
    nodes.push(h("details", { class: "log" },
      h("summary", {}, "Remove the app"),
      h("p", { class: "hint" }, "First remove the line from root's crontab (sudo crontab -e), then run this command. Your backups are kept."),
      commandBlock(state.setup.uninstall_command)));
  }
  return nodes;
}

async function chooseConfigFolder(listing) {
  try {
    await api("PUT", "/api/settings", { config_folder: listing.path });
    await refresh();
    toast("Config folder saved.");
  } catch (error) {
    toast(error.message);
  }
}

// --- Page ---------------------------------------------------------------------

const VIEWS = { overview: renderOverview, jobs: renderJobs, setup: renderSetup };

function render() {
  if (!chosenView && setupIncomplete()) currentView = "setup";
  for (const tab of document.querySelectorAll(".tab")) {
    if (tab.dataset.view === currentView) tab.setAttribute("aria-current", "page");
    else tab.removeAttribute("aria-current");
  }
  const view = document.getElementById("view");
  // A refresh must not close what the reader opened or move their position.
  const openDetails = [...view.querySelectorAll("details")].map((item) => item.open);
  view.replaceChildren(...VIEWS[currentView]().filter(Boolean));
  view.querySelectorAll("details").forEach((item, index) => {
    if (openDetails[index]) item.open = true;
  });
  applyStripPositions(view);
}

function renderFatal(message) {
  document.getElementById("view").replaceChildren(
    h("section", { class: "health bad" },
      h("h2", {}, "The app isn't responding"),
      h("p", {}, message),
      h("button", { type: "button", class: "button", onclick: refresh }, "Try again")));
}

function show(view) {
  chosenView = true;
  currentView = view;
  render();
  document.getElementById("view").focus();
}

const dialog = document.getElementById("dialog");

function openDialog(content) {
  dialog.replaceChildren(content);
  dialog.showModal();
}

function closeDialog() {
  dialog.close();
  dialog.replaceChildren();
}

let toastTimer = null;

function toast(message) {
  const box = document.getElementById("toast");
  // A toast must be inside the open modal dialog to appear above it.
  const modal = [...document.querySelectorAll("dialog[open]")].pop();
  (modal || document.body).append(box);
  box.textContent = message;
  box.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    box.hidden = true;
  }, 5000);
}

for (const tab of document.querySelectorAll(".tab")) {
  tab.addEventListener("click", () => show(tab.dataset.view));
}

async function start() {
  if (window.UgvmSdk) {
    try {
      window.UgvmSdk.init();
    } catch (error) {
      console.warn("UGOS SDK init failed", error);
    }
  }
  await loadToken();
  await refresh();
  setInterval(() => {
    if (!document.hidden && !dialog.open) refresh();
  }, POLL_MS);
}

start();
