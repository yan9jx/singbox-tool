const state = {
  viewToken: sessionStorage.getItem("ejectors_view_token") || "",
  timer: null,
  loading: false,
  nodes: new Map(),
  reminders: new Map(),
  serverTime: 0,
  telegramConfigured: false,
};

const elements = {
  dialog: document.querySelector("#loginDialog"),
  form: document.querySelector("#loginForm"),
  token: document.querySelector("#viewToken"),
  error: document.querySelector("#loginError"),
  lock: document.querySelector("#lockButton"),
  refresh: document.querySelector("#refreshButton"),
  sync: document.querySelector("#syncState"),
  grid: document.querySelector("#nodeGrid"),
  template: document.querySelector("#nodeTemplate"),
  updatedAt: document.querySelector("#updatedAt"),
  drive: document.querySelector("#driveLink"),
  settingsDialog: document.querySelector("#settingsDialog"),
  settingsForm: document.querySelector("#settingsForm"),
  settingsClose: document.querySelector("#settingsClose"),
  settingsNodeId: document.querySelector("#settingsNodeId"),
  settingsNodeName: document.querySelector("#settingsNodeName"),
  expiryDate: document.querySelector("#expiryDate"),
  reminderAt: document.querySelector("#reminderAt"),
  nodeMemo: document.querySelector("#nodeMemo"),
  memoCount: document.querySelector("#memoCount"),
  telegramEnabled: document.querySelector("#telegramEnabled"),
  telegramStatus: document.querySelector("#telegramStatus"),
  telegramTest: document.querySelector("#telegramTest"),
  clearReminder: document.querySelector("#clearReminder"),
  settingsError: document.querySelector("#settingsError"),
  reminderGrid: document.querySelector("#reminderGrid"),
  addReminder: document.querySelector("#addReminderButton"),
  reminderDialog: document.querySelector("#reminderDialog"),
  reminderForm: document.querySelector("#reminderForm"),
  reminderClose: document.querySelector("#reminderClose"),
  reminderCancel: document.querySelector("#reminderCancel"),
  reminderId: document.querySelector("#reminderId"),
  reminderDialogTitle: document.querySelector("#reminderDialogTitle"),
  reminderTitle: document.querySelector("#reminderTitle"),
  reminderContent: document.querySelector("#reminderContent"),
  reminderType: document.querySelector("#reminderType"),
  reminderOnceAt: document.querySelector("#reminderOnceAt"),
  reminderRepeatTime: document.querySelector("#reminderRepeatTime"),
  reminderWeekday: document.querySelector("#reminderWeekday"),
  reminderMonth: document.querySelector("#reminderMonth"),
  reminderMonthday: document.querySelector("#reminderMonthday"),
  reminderEnabled: document.querySelector("#reminderEnabled"),
  reminderError: document.querySelector("#reminderError"),
  onceTimeField: document.querySelector("#onceTimeField"),
  repeatTimeField: document.querySelector("#repeatTimeField"),
  weekdayField: document.querySelector("#weekdayField"),
  monthField: document.querySelector("#monthField"),
  monthdayField: document.querySelector("#monthdayField"),
  intervalMonthsField: document.querySelector("#intervalMonthsField"),
  reminderIntervalMonths: document.querySelector("#reminderIntervalMonths"),
  globalTelegramStatus: document.querySelector("#globalTelegramStatus"),
  telegramCoverage: document.querySelector("#telegramCoverage"),
  globalTelegramTest: document.querySelector("#globalTelegramTest"),
  autoDeleteDays: document.querySelector("#autoDeleteDays"),
  exportConfig: document.querySelector("#exportConfig"),
  importConfig: document.querySelector("#importConfig"),
  importConfigFile: document.querySelector("#importConfigFile"),
  displayName: document.querySelector("#displayName"),
  displayProvider: document.querySelector("#displayProvider"),
  displayLocation: document.querySelector("#displayLocation"),
  nodePurpose: document.querySelector("#nodePurpose"),
  nodeGroup: document.querySelector("#nodeGroup"),
  maintenanceUntil: document.querySelector("#maintenanceUntil"),
  profileDialog: document.querySelector("#profileDialog"),
  profileForm: document.querySelector("#profileForm"),
  profileClose: document.querySelector("#profileClose"),
  profileNodeId: document.querySelector("#profileNodeId"),
  profileNodeName: document.querySelector("#profileNodeName"),
  profileError: document.querySelector("#profileError"),
  telegramRepeatButton: document.querySelector("#telegramRepeatButton"),
  telegramRepeatDialog: document.querySelector("#telegramRepeatDialog"),
  telegramRepeatForm: document.querySelector("#telegramRepeatForm"),
  telegramRepeatClose: document.querySelector("#telegramRepeatClose"),
  telegramRepeatInterval: document.querySelector("#telegramRepeatInterval"),
  telegramHourlyStart: document.querySelector("#telegramHourlyStart"),
  telegramHourlyEnd: document.querySelector("#telegramHourlyEnd"),
  telegramRepeatError: document.querySelector("#telegramRepeatError"),
};

const CURRENT_AGENT_VERSION = "1.1.0";

const STATUS_LABELS = {
  online: "??",
  degraded: "??",
  offline: "??",
  shutdown: "???",
  maintenance: "???",
};

document.addEventListener("DOMContentLoaded", () => {
  bindEvents();
  if (state.viewToken) {
    refreshNodes();
  } else {
    openLogin();
  }
});

function bindEvents() {
  elements.form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const token = elements.token.value.trim();
    if (!token) return;
    elements.error.textContent = "";
    const button = elements.form.querySelector("button");
    button.disabled = true;
    button.textContent = "????";
    try {
      const response = await apiFetch("/api/v1/session", { method: "POST" }, token);
      const result = await response.json();
      if (!response.ok) {
        const suffix = result.remaining_attempts > 0 ? `????? ${result.remaining_attempts} ??` : "";
        throw new Error(`${result.error || "???????"}${suffix}`);
      }
      state.viewToken = token;
      sessionStorage.setItem("ejectors_view_token", token);
      elements.dialog.close();
      await refreshNodes();
    } catch (error) {
      elements.error.textContent = error.message || "????";
    } finally {
      button.disabled = false;
      button.textContent = "??????";
    }
  });

  elements.lock.addEventListener("click", () => {
    sessionStorage.removeItem("ejectors_view_token");
    state.viewToken = "";
    clearInterval(state.timer);
    openLogin();
  });
  elements.refresh.addEventListener("click", refreshNodes);
  elements.grid.addEventListener("click", (event) => {
    const deleteButton = event.target.closest(".delete-node-button");
    if (deleteButton) {
      deleteOfflineNode(deleteButton.dataset.nodeId);
      return;
    }
    const editButton = event.target.closest(".node-edit-button");
    if (editButton) {
      openNodeProfile(editButton.dataset.nodeId);
      return;
    }
    const button = event.target.closest(".node-settings-button");
    if (button) openNodeSettings(button.dataset.nodeId);
  });
  elements.settingsClose.addEventListener("click", () => elements.settingsDialog.close());
  elements.settingsDialog.addEventListener("click", (event) => {
    if (event.target === elements.settingsDialog) elements.settingsDialog.close();
  });
  elements.nodeMemo.addEventListener("input", () => {
    elements.memoCount.textContent = elements.nodeMemo.value.length;
  });
  elements.clearReminder.addEventListener("click", () => {
    elements.reminderAt.value = "";
  });
  elements.telegramTest.addEventListener("click", testTelegram);
  elements.settingsForm.addEventListener("submit", saveNodeSettings);
  elements.profileClose.addEventListener("click", () => elements.profileDialog.close());
  elements.profileDialog.addEventListener("click", (event) => {
    if (event.target === elements.profileDialog) elements.profileDialog.close();
  });
  elements.profileForm.addEventListener("submit", saveNodeProfile);
  elements.addReminder.addEventListener("click", () => openReminderDialog());
  elements.reminderClose.addEventListener("click", () => elements.reminderDialog.close());
  elements.reminderCancel.addEventListener("click", () => elements.reminderDialog.close());
  elements.reminderType.addEventListener("change", updateReminderFields);
  elements.reminderForm.addEventListener("submit", saveReminder);
  elements.reminderGrid.addEventListener("click", handleReminderAction);
  elements.globalTelegramTest.addEventListener("click", testGlobalTelegram);
  elements.autoDeleteDays.addEventListener("change", saveAutoDeleteSetting);
  elements.exportConfig.addEventListener("click", exportDashboardConfig);
  elements.importConfig.addEventListener("click", () => elements.importConfigFile.click());
  elements.importConfigFile.addEventListener("change", importDashboardConfig);
  elements.telegramRepeatButton.addEventListener("click", () => elements.telegramRepeatDialog.showModal());
  elements.telegramRepeatClose.addEventListener("click", () => elements.telegramRepeatDialog.close());
  elements.telegramRepeatDialog.addEventListener("click", (event) => {
    if (event.target === elements.telegramRepeatDialog) elements.telegramRepeatDialog.close();
  });
  elements.telegramRepeatForm.addEventListener("submit", saveTelegramRepeatSettings);
  elements.grid.addEventListener("dragstart", handleNodeDragStart);
  elements.grid.addEventListener("dragover", handleNodeDragOver);
  elements.grid.addEventListener("drop", handleNodeDrop);
  elements.grid.addEventListener("dragend", handleNodeDragEnd);
}

function openLogin() {
  if (!elements.dialog.open) elements.dialog.showModal();
  setTimeout(() => elements.token.focus(), 50);
}

async function refreshNodes() {
  if (state.loading || !state.viewToken) return;
  state.loading = true;
  elements.refresh.classList.add("spinning");
  setSync("????", "");

  try {
    const response = await apiFetch("/api/v1/nodes");
    if (response.status === 401) {
      sessionStorage.removeItem("ejectors_view_token");
      state.viewToken = "";
      openLogin();
      throw new Error("???????");
    }
    if (!response.ok) throw new Error("?????????");
    const data = await response.json();
    render(data);
    await Promise.all([refreshReminders(), refreshDashboardSettings()]);
    setSync("????", "ok");
    scheduleRefresh((data.refresh_seconds || 15) * 1000);
  } catch (error) {
    setSync(error.message || "????", "error");
  } finally {
    state.loading = false;
    elements.refresh.classList.remove("spinning");
  }
}

async function refreshReminders() {
  const response = await apiFetch("/api/v1/reminders");
  if (!response.ok) throw new Error("?????????");
  const data = await response.json();
  state.reminders = new Map(data.reminders.map((item) => [item.id, item]));
  renderReminders(data.reminders);
  updateTelegramCoverage();
}

function updateTelegramCoverage() {
  const nodeItems = [...state.nodes.values()];
  const reminderItems = [...state.reminders.values()];
  const total = nodeItems.length + reminderItems.length;
  const enabled = state.telegramConfigured
    ? nodeItems.filter((node) => node.settings?.telegram_enabled !== false).length
      + reminderItems.filter((reminder) => reminder.enabled).length
    : 0;
  elements.telegramCoverage.textContent = state.telegramConfigured
    ? `Telegram ????????${enabled}/${total}`
    : `Telegram ????????0/${total}`;
  elements.telegramCoverage.classList.toggle("configured", state.telegramConfigured);
}

async function refreshDashboardSettings() {
  const response = await apiFetch("/api/v1/dashboard-settings");
  if (!response.ok) throw new Error("?????????");
  const data = await response.json();
  elements.autoDeleteDays.value = String(data.settings?.auto_delete_offline_days || 0);
  const interval = Number(data.settings?.telegram_repeat_interval_minutes || 10);
  elements.telegramRepeatInterval.value = String(interval);
  elements.telegramHourlyStart.value = data.settings?.telegram_repeat_start || "09:00";
  elements.telegramHourlyEnd.value = data.settings?.telegram_repeat_end || "18:00";
  elements.telegramRepeatButton.textContent = `?????? ${interval} ??`;
}

async function saveAutoDeleteSetting() {
  elements.autoDeleteDays.disabled = true;
  try {
    const response = await apiFetch("/api/v1/dashboard-settings", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ auto_delete_offline_days: Number(elements.autoDeleteDays.value) }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "??????????");
  } catch (error) {
    alert(error.message || "??????????");
    await refreshDashboardSettings();
  } finally {
    elements.autoDeleteDays.disabled = false;
  }
}

async function saveTelegramRepeatSettings(event) {
  event.preventDefault();
  const submit = elements.telegramRepeatForm.querySelector('button[type="submit"]');
  submit.disabled = true;
  submit.textContent = "????";
  elements.telegramRepeatError.textContent = "";
  try {
    const response = await apiFetch("/api/v1/dashboard-settings", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        telegram_repeat_interval_minutes: Number(elements.telegramRepeatInterval.value),
        telegram_repeat_start: elements.telegramHourlyStart.value,
        telegram_repeat_end: elements.telegramHourlyEnd.value,
      }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "????");
    elements.telegramRepeatDialog.close();
    await refreshDashboardSettings();
  } catch (error) {
    elements.telegramRepeatError.textContent = error.message || "????";
  } finally {
    submit.disabled = false;
    submit.textContent = "??????";
  }
}

function renderReminders(reminders) {
  elements.reminderGrid.replaceChildren();
  if (!reminders.length) {
    const empty = document.createElement("div");
    empty.className = "reminder-empty";
    empty.textContent = "?????????????????";
    elements.reminderGrid.appendChild(empty);
    return;
  }
  for (const reminder of reminders) {
    const card = document.createElement("article");
    card.className = `reminder-card ${reminder.enabled ? "" : "disabled"}`;
    card.dataset.id = reminder.id;
    const head = document.createElement("div");
    head.className = "reminder-card-head";
    const titleWrap = document.createElement("div");
    const title = document.createElement("h3");
    title.textContent = reminder.title;
    const schedule = document.createElement("span");
    schedule.className = "reminder-schedule";
    schedule.textContent = reminderScheduleLabel(reminder);
    titleWrap.append(title, schedule);
    const stateText = document.createElement("span");
    stateText.className = "reminder-toggle";
    stateText.textContent = reminder.enabled ? "???" : reminder.completed ? "???" : "???";
    head.append(titleWrap, stateText);
    const content = document.createElement("p");
    content.className = "reminder-content";
    content.textContent = reminder.content || "?????";
    const actions = document.createElement("div");
    actions.className = "reminder-card-actions";
    const toggle = document.createElement("button");
    toggle.className = "mini-button";
    toggle.dataset.action = "toggle";
    toggle.textContent = reminder.enabled ? "??" : "??";
    const buttons = document.createElement("div");
    const edit = document.createElement("button");
    edit.className = "mini-button";
    edit.dataset.action = "edit";
    edit.textContent = "??";
    const remove = document.createElement("button");
    remove.className = "mini-button delete";
    remove.dataset.action = "delete";
    remove.textContent = "??";
    buttons.append(edit, remove);
    actions.append(toggle, buttons);
    card.append(head, content, actions);
    elements.reminderGrid.appendChild(card);
  }
}

function openReminderDialog(id = "") {
  const reminder = id ? state.reminders.get(id) : null;
  elements.reminderId.value = reminder?.id || "";
  elements.reminderDialogTitle.textContent = reminder ? "????" : "????";
  elements.reminderTitle.value = reminder?.title || "";
  elements.reminderContent.value = reminder?.content || "";
  elements.reminderType.value = reminder?.schedule_type || "once";
  elements.reminderOnceAt.value = reminder?.schedule_at ? toDateTimeLocal(reminder.schedule_at) : "";
  elements.reminderRepeatTime.value = reminder?.schedule_time || "09:00";
  elements.reminderWeekday.value = String(reminder?.weekday ?? 1);
  elements.reminderMonth.value = String(reminder?.schedule_month ?? 1);
  elements.reminderMonthday.value = String(reminder?.monthday ?? 1);
  elements.reminderIntervalMonths.value = String(reminder?.interval_months ?? 3);
  elements.reminderEnabled.checked = reminder?.enabled !== false;
  elements.reminderError.textContent = "";
  updateReminderFields();
  elements.reminderDialog.showModal();
  setTimeout(() => elements.reminderTitle.focus(), 50);
}

function updateReminderFields() {
  const type = elements.reminderType.value;
  const usesAnchor = ["once", "interval_months"].includes(type);
  elements.onceTimeField.hidden = !usesAnchor;
  elements.onceTimeField.querySelector("span").textContent = type === "interval_months" ? "??????" : "????";
  elements.repeatTimeField.hidden = usesAnchor;
  elements.intervalMonthsField.hidden = type !== "interval_months";
  elements.weekdayField.hidden = type !== "weekly";
  elements.monthField.hidden = type !== "yearly";
  elements.monthdayField.hidden = !["monthly", "yearly"].includes(type);
}

async function saveReminder(event) {
  event.preventDefault();
  const type = elements.reminderType.value;
  const submit = elements.reminderForm.querySelector('button[type="submit"]');
  const onceAt = elements.reminderOnceAt.value ? Math.floor(new Date(elements.reminderOnceAt.value).getTime() / 1000) : 0;
  if (["once", "interval_months"].includes(type) && !onceAt) {
    elements.reminderError.textContent = type === "interval_months" ? "?????????" : "?????????";
    return;
  }
  submit.disabled = true;
  submit.textContent = "????";
  try {
    const response = await apiFetch("/api/v1/reminders", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        id: elements.reminderId.value,
        title: elements.reminderTitle.value.trim(),
        content: elements.reminderContent.value.trim(),
        schedule_type: type,
        schedule_at: onceAt,
        schedule_time: elements.reminderRepeatTime.value,
        weekday: Number(elements.reminderWeekday.value),
        schedule_month: Number(elements.reminderMonth.value),
        monthday: Number(elements.reminderMonthday.value),
        interval_months: Number(elements.reminderIntervalMonths.value),
        enabled: elements.reminderEnabled.checked,
      }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "????");
    elements.reminderDialog.close();
    await refreshReminders();
  } catch (error) {
    elements.reminderError.textContent = error.message || "????";
  } finally {
    submit.disabled = false;
    submit.textContent = "????";
  }
}

async function handleReminderAction(event) {
  const button = event.target.closest("[data-action]");
  const card = event.target.closest(".reminder-card");
  if (!button || !card) return;
  const reminder = state.reminders.get(card.dataset.id);
  if (!reminder) return;
  if (button.dataset.action === "edit") return openReminderDialog(reminder.id);
  if (button.dataset.action === "delete" && !confirm(`?????${reminder.title}??`)) return;
  const endpoint = button.dataset.action === "delete" ? "delete" : "toggle";
  const response = await apiFetch(`/api/v1/reminders/${endpoint}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ id: reminder.id, enabled: !reminder.enabled }),
  });
  if (response.ok) await refreshReminders();
}

function reminderScheduleLabel(reminder) {
  if (reminder.schedule_type === "once") return `?? ? ${formatDateTime(reminder.schedule_at)}`;
  if (reminder.schedule_type === "daily") return `?? ? ${reminder.schedule_time}`;
  if (reminder.schedule_type === "weekly") return `??${"???????"[reminder.weekday]} ? ${reminder.schedule_time}`;
  if (reminder.schedule_type === "monthly") return `?? ${reminder.monthday} ? ? ${reminder.schedule_time}`;
  if (reminder.schedule_type === "interval_months") return `? ${reminder.interval_months} ?? ? ?? ${formatDateTime(reminder.schedule_at)}`;
  return `?? ${reminder.schedule_month} ? ${reminder.monthday} ? ? ${reminder.schedule_time}`;
}

function render(data) {
  state.serverTime = data.server_time;
  state.telegramConfigured = Boolean(data.telegram_configured);
  elements.globalTelegramStatus.textContent = state.telegramConfigured ? "Telegram ???" : "Telegram ???";
  elements.globalTelegramStatus.classList.toggle("configured", state.telegramConfigured);
  elements.globalTelegramTest.disabled = !state.telegramConfigured;
  state.nodes = new Map(data.nodes.map((node) => [node.node_id, node]));
  updateTelegramCoverage();
  document.querySelector("#countTotal").textContent = data.summary.total;
  document.querySelector("#countOnline").textContent = data.summary.online;
  document.querySelector("#countDegraded").textContent = data.summary.degraded;
  document.querySelector("#countOffline").textContent = data.summary.offline + data.summary.shutdown;
  elements.updatedAt.textContent = `??? ${formatClock(data.server_time)}`;
  elements.drive.href = data.cloud_drive_url || "https://disk.example.com";

  elements.grid.replaceChildren();
  if (!data.nodes.length) {
    elements.grid.innerHTML = `
      <div class="empty-state">
        <strong>??? VPS ??</strong>
        <p>???????????????????????</p>
      </div>`;
    return;
  }

  const offlineNodes = data.nodes.filter((node) => ["offline", "shutdown"].includes(node.status));
  const activeNodes = data.nodes.filter((node) => !["offline", "shutdown"].includes(node.status));
  if (offlineNodes.length) {
    const heading = document.createElement("h3");
    heading.className = "node-group-title offline-group-title";
    heading.textContent = "?? / ??";
    elements.grid.appendChild(heading);
    for (const node of offlineNodes) elements.grid.appendChild(renderNode(node, data.server_time));
  }

  const grouped = activeNodes.some((node) => node.settings?.group);
  let lastGroup = null;
  for (const node of activeNodes) {
    const group = node.settings?.group || "???";
    if (grouped && group !== lastGroup) {
      const heading = document.createElement("h3");
      heading.className = "node-group-title";
      heading.textContent = group;
      elements.grid.appendChild(heading);
      lastGroup = group;
    }
    elements.grid.appendChild(renderNode(node, data.server_time));
  }
}

function renderNode(node, serverTime) {
  const fragment = elements.template.content.cloneNode(true);
  const card = fragment.querySelector(".node-card");
  card.dataset.status = node.status;
  card.dataset.nodeId = node.node_id;
  card.draggable = true;
  const deleteButton = fragment.querySelector(".delete-node-button");
  deleteButton.dataset.nodeId = node.node_id;
  deleteButton.hidden = !["offline", "shutdown"].includes(node.status);
  text(fragment, ".node-name", node.name || node.node_id);
  fragment.querySelector(".node-edit-button").dataset.nodeId = node.node_id;
  text(fragment, ".node-location", [node.provider, node.location, node.purpose].filter(Boolean).join(" ? ") || node.hostname || "?????");
  text(fragment, ".status-pill", STATUS_LABELS[node.status] || node.status);
  text(fragment, ".public-ip", node.public_ip || "???");
  text(fragment, ".uptime", node.status === "shutdown" ? "???" : formatDuration(node.uptime_seconds));
  const versionState = compareVersions(node.agent_version || "0", CURRENT_AGENT_VERSION);
  text(fragment, ".agent-version", !node.agent_version
    ? "Agent ?????"
    : versionState < 0 ? `Agent v${node.agent_version} ? ???? v${CURRENT_AGENT_VERSION}` : `Agent v${node.agent_version} ? ??`);
  fragment.querySelector(".agent-version").classList.toggle("outdated", versionState < 0);

  setMetric(fragment, "cpu", node.cpu?.usage_pct, `${fixed(node.cpu?.usage_pct)}%`, `?? ${fixed(node.cpu?.load_1, 2)} ? ${node.cpu?.cores || "?"} ?`);
  setMetric(fragment, "memory", node.memory?.usage_pct, `${fixed(node.memory?.usage_pct)}%`, `${formatBytesFromMB(node.memory?.used_mb)} / ${formatBytesFromMB(node.memory?.total_mb)}`);
  setMetric(fragment, "disk", node.disk?.usage_pct, `${fixed(node.disk?.usage_pct)}%`, `${formatBytes(node.disk?.used_bytes)} / ${formatBytes(node.disk?.total_bytes)}`);
  setMetric(fragment, "swap", node.swap?.usage_pct, `${fixed(node.swap?.usage_pct)}%`, `${formatBytesFromMB(node.swap?.used_mb)} / ${formatBytesFromMB(node.swap?.total_mb)}`);

  text(fragment, ".network-rx", `${formatBytes(node.network?.rx_bps)}/s`);
  text(fragment, ".network-tx", `${formatBytes(node.network?.tx_bps)}/s`);
  text(fragment, ".network-total", formatBytes((node.network?.rx_bytes || 0) + (node.network?.tx_bytes || 0)));
  text(fragment, ".last-seen", relativeTime(node.last_seen, serverTime));

  const services = fragment.querySelector(".service-list");
  const installedServices = Array.isArray(node.services) ? node.services.filter((service) => service.installed !== false) : [];
  if (!installedServices.length) {
    services.innerHTML = '<span class="service-empty">????????????</span>';
  } else {
    for (const service of installedServices) {
      const chip = document.createElement("span");
      chip.className = `service-chip ${service.running ? "" : "stopped"}`;
      const dot = document.createElement("i");
      chip.append(dot, document.createTextNode(`${service.name} ? ${service.running ? "??" : "??"}`));
      services.appendChild(chip);
    }
  }

  const ports = Array.isArray(node.ports) ? node.ports : [];
  text(fragment, ".port-count", `${ports.length} ?`);
  const portList = fragment.querySelector(".port-list");
  for (const port of ports) {
    const chip = document.createElement("span");
    chip.className = "port-chip";
    chip.textContent = `${port.port}${port.process ? ` ? ${port.process}` : ""}`;
    portList.appendChild(chip);
  }
  if (!ports.length) portList.innerHTML = '<span class="service-empty">????????</span>';

  const lifecycle = fragment.querySelector(".node-settings-button");
  lifecycle.dataset.nodeId = node.node_id;
  const expiry = expiryState(node.settings?.expiry_date, state.serverTime);
  lifecycle.dataset.expiry = expiry.level;
  text(fragment, ".expiry-countdown", expiry.label);
  text(fragment, ".memo-preview", node.settings?.memo || (node.settings?.reminder_at ? `???${formatDateTime(node.settings.reminder_at)}` : "??????????"));

  return fragment;
}

async function deleteOfflineNode(nodeId) {
  const node = state.nodes.get(nodeId);
  if (!node || !confirm(`????????????${node.name || nodeId}???`)) return;
  try {
    const response = await apiFetch("/api/v1/nodes/delete", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ node_id: nodeId }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "????");
    await refreshNodes();
  } catch (error) {
    alert(error.message || "????");
  }
}

function openNodeSettings(nodeId) {
  const node = state.nodes.get(nodeId);
  if (!node) return;
  const settings = node.settings || {};
  elements.settingsNodeId.value = node.node_id;
  elements.settingsNodeName.textContent = node.name || node.node_id;
  elements.expiryDate.value = settings.expiry_date || "";
  elements.reminderAt.value = settings.reminder_at ? toDateTimeLocal(settings.reminder_at) : "";
  elements.nodeMemo.value = settings.memo || "";
  elements.memoCount.textContent = elements.nodeMemo.value.length;
  elements.telegramEnabled.checked = settings.telegram_enabled !== false;
  elements.telegramStatus.textContent = state.telegramConfigured ? "???" : "???";
  elements.telegramStatus.classList.toggle("configured", state.telegramConfigured);
  elements.telegramTest.disabled = !state.telegramConfigured;
  elements.settingsError.textContent = "";
  elements.settingsDialog.showModal();
}

async function saveNodeSettings(event) {
  event.preventDefault();
  const submit = elements.settingsForm.querySelector('button[type="submit"]');
  const reminderAt = elements.reminderAt.value
    ? Math.floor(new Date(elements.reminderAt.value).getTime() / 1000)
    : 0;
  submit.disabled = true;
  submit.textContent = "????";
  elements.settingsError.textContent = "";

  try {
    const response = await apiFetch("/api/v1/node-settings", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        node_id: elements.settingsNodeId.value,
        expiry_date: elements.expiryDate.value,
        memo: elements.nodeMemo.value.trim(),
        reminder_at: reminderAt,
        telegram_enabled: elements.telegramEnabled.checked,
      }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "????");
    elements.settingsDialog.close();
    await refreshNodes();
  } catch (error) {
    elements.settingsError.textContent = error.message || "????";
  } finally {
    submit.disabled = false;
    submit.textContent = "????";
  }
}

function openNodeProfile(nodeId) {
  const node = state.nodes.get(nodeId);
  if (!node) return;
  const settings = node.settings || {};
  elements.profileNodeId.value = node.node_id;
  elements.profileNodeName.textContent = node.name || node.node_id;
  elements.displayName.value = settings.display_name || "";
  elements.displayProvider.value = settings.display_provider || "";
  elements.displayLocation.value = settings.display_location || "";
  elements.nodePurpose.value = settings.purpose || "";
  elements.nodeGroup.value = settings.group || "";
  elements.maintenanceUntil.value = settings.maintenance_until ? toDateTimeLocal(settings.maintenance_until) : "";
  elements.profileError.textContent = "";
  elements.profileDialog.showModal();
  setTimeout(() => elements.displayName.focus(), 50);
}

async function saveNodeProfile(event) {
  event.preventDefault();
  const submit = elements.profileForm.querySelector('button[type="submit"]');
  const maintenanceUntil = elements.maintenanceUntil.value
    ? Math.floor(new Date(elements.maintenanceUntil.value).getTime() / 1000)
    : 0;
  submit.disabled = true;
  submit.textContent = "????";
  elements.profileError.textContent = "";
  try {
    const response = await apiFetch("/api/v1/node-profile", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        node_id: elements.profileNodeId.value,
        display_name: elements.displayName.value.trim(),
        display_provider: elements.displayProvider.value.trim(),
        display_location: elements.displayLocation.value.trim(),
        purpose: elements.nodePurpose.value.trim(),
        group: elements.nodeGroup.value.trim(),
        maintenance_until: maintenanceUntil,
      }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "????");
    elements.profileDialog.close();
    await refreshNodes();
  } catch (error) {
    elements.profileError.textContent = error.message || "????";
  } finally {
    submit.disabled = false;
    submit.textContent = "??????";
  }
}

let draggedNodeId = "";

function handleNodeDragStart(event) {
  const card = event.target.closest(".node-card");
  if (!card) return;
  draggedNodeId = card.dataset.nodeId;
  card.classList.add("dragging");
  event.dataTransfer.effectAllowed = "move";
}

function handleNodeDragOver(event) {
  const target = event.target.closest(".node-card");
  if (!target || target.dataset.nodeId === draggedNodeId) return;
  event.preventDefault();
  const rect = target.getBoundingClientRect();
  const before = event.clientY < rect.top + rect.height / 2;
  target.parentNode.insertBefore(document.querySelector(`.node-card[data-node-id="${CSS.escape(draggedNodeId)}"]`), before ? target : target.nextSibling);
}

async function handleNodeDrop(event) {
  if (!draggedNodeId) return;
  event.preventDefault();
  const nodeIds = [...elements.grid.querySelectorAll(".node-card")].map((card) => card.dataset.nodeId);
  await apiFetch("/api/v1/nodes/order", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ node_ids: nodeIds }),
  });
  draggedNodeId = "";
  await refreshNodes();
}

function handleNodeDragEnd() {
  elements.grid.querySelectorAll(".dragging").forEach((card) => card.classList.remove("dragging"));
  draggedNodeId = "";
}

async function exportDashboardConfig() {
  const response = await apiFetch("/api/v1/config/export");
  if (!response.ok) return alert("??????");
  const blob = await response.blob();
  const link = document.createElement("a");
  link.href = URL.createObjectURL(blob);
  link.download = `ejectors-dashboard-backup-${new Date().toISOString().slice(0, 10)}.json`;
  link.click();
  URL.revokeObjectURL(link.href);
}

async function importDashboardConfig() {
  const file = elements.importConfigFile.files?.[0];
  elements.importConfigFile.value = "";
  if (!file || !confirm("???????????????????? ID ????????????")) return;
  try {
    const data = JSON.parse(await file.text());
    const response = await apiFetch("/api/v1/config/import", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(data),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "????");
    alert(`?????${result.imported.nodes} ? VPS?${result.imported.reminders} ?????? ${result.skipped_nodes} ???? VPS?`);
    await refreshNodes();
  } catch (error) {
    alert(error.message || "????????");
  }
}

function compareVersions(left, right) {
  const a = String(left).split(".").map(Number);
  const b = String(right).split(".").map(Number);
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    if ((a[i] || 0) !== (b[i] || 0)) return (a[i] || 0) > (b[i] || 0) ? 1 : -1;
  }
  return 0;
}

async function testTelegram() {
  elements.telegramTest.disabled = true;
  elements.telegramTest.textContent = "????";
  elements.settingsError.textContent = "";
  try {
    const response = await apiFetch("/api/v1/telegram/test", { method: "POST" });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "????");
    elements.telegramStatus.textContent = "????";
    elements.telegramStatus.classList.add("configured");
  } catch (error) {
    elements.settingsError.textContent = error.message || "Telegram ????";
  } finally {
    elements.telegramTest.disabled = !state.telegramConfigured;
    elements.telegramTest.textContent = "????";
  }
}

async function testGlobalTelegram() {
  elements.globalTelegramTest.disabled = true;
  elements.globalTelegramTest.textContent = "????";
  try {
    const response = await apiFetch("/api/v1/telegram/test", { method: "POST" });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "????");
    elements.globalTelegramStatus.textContent = "Telegram ????";
    elements.globalTelegramStatus.classList.add("configured");
    alert("???????? Telegram");
  } catch (error) {
    alert(error.message || "Telegram ????");
  } finally {
    elements.globalTelegramTest.disabled = !state.telegramConfigured;
    elements.globalTelegramTest.textContent = "????";
  }
}

function setMetric(root, name, percentage, value, detail) {
  const metric = root.querySelector(`[data-metric="${name}"]`);
  const pct = Math.max(0, Math.min(100, Number(percentage) || 0));
  metric.querySelector(".metric-value").textContent = value;
  metric.querySelector(".metric-detail").textContent = detail;
  metric.querySelector(".bar i").style.width = `${pct}%`;
  metric.dataset.level = pct >= 90 ? "critical" : pct >= 75 ? "warn" : "normal";
}

function text(root, selector, value) {
  root.querySelector(selector).textContent = value ?? "";
}

function scheduleRefresh(delay) {
  clearInterval(state.timer);
  state.timer = setInterval(refreshNodes, delay);
}

function setSync(message, className) {
  elements.sync.className = `sync-state ${className}`;
  elements.sync.querySelector("span").textContent = message;
}

function apiFetch(path, options = {}, token = state.viewToken) {
  const headers = new Headers(options.headers || {});
  if (token) headers.set("x-view-token", encodeURIComponent(token));
  return fetch(path, { ...options, headers, cache: "no-store" });
}

function fixed(value, digits = 1) {
  const number = Number(value);
  return Number.isFinite(number) ? number.toFixed(digits) : "0.0";
}

function formatBytes(value) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const index = Math.min(Math.floor(Math.log(number) / Math.log(1024)), units.length - 1);
  return `${(number / 1024 ** index).toFixed(index > 1 ? 1 : 0)} ${units[index]}`;
}

function formatBytesFromMB(value) {
  return formatBytes((Number(value) || 0) * 1024 * 1024);
}

function formatDuration(seconds) {
  const value = Number(seconds) || 0;
  const days = Math.floor(value / 86400);
  const hours = Math.floor((value % 86400) / 3600);
  if (days > 0) return `${days} ? ${hours} ??`;
  const minutes = Math.floor((value % 3600) / 60);
  return `${hours} ?? ${minutes} ?`;
}

function relativeTime(timestamp, serverTime) {
  const seconds = Math.max(0, (serverTime || Date.now() / 1000) - timestamp);
  if (seconds < 70) return "????";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} ???`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} ???`;
  return `${Math.floor(seconds / 86400)} ??`;
}

function formatClock(timestamp) {
  return new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).format(new Date(timestamp * 1000));
}

function expiryState(expiryDate, serverTime) {
  if (!expiryDate) return { level: "none", label: "????????" };
  const [year, month, day] = expiryDate.split("-").map(Number);
  const now = new Date(((serverTime || Date.now() / 1000) + 8 * 3600) * 1000);
  const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const expiry = Date.UTC(year, month - 1, day);
  const days = Math.round((expiry - today) / 86400000);
  if (days < 0) return { level: "expired", label: `??? ${Math.abs(days)} ? ? ${expiryDate}` };
  if (days === 0) return { level: "expired", label: `???? ? ${expiryDate}` };
  if (days <= 30) return { level: "soon", label: `?? ${days} ? ? ${expiryDate}` };
  return { level: "normal", label: `?? ${days} ? ? ${expiryDate}` };
}

function toDateTimeLocal(timestamp) {
  const date = new Date(timestamp * 1000);
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return local.toISOString().slice(0, 16);
}

function formatDateTime(timestamp) {
  return new Intl.DateTimeFormat("zh-CN", {
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date(timestamp * 1000));
}
