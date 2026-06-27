const state = {
  viewToken: sessionStorage.getItem("ejectors_view_token") || "",
  timer: null,
  loading: false,
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
};

const STATUS_LABELS = {
  online: "正常",
  degraded: "异常",
  offline: "离线",
  shutdown: "已关机",
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
    button.textContent = "验证中…";
    try {
      const response = await apiFetch("/api/v1/session", { method: "POST" }, token);
      if (!response.ok) throw new Error("查看密码不正确");
      state.viewToken = token;
      sessionStorage.setItem("ejectors_view_token", token);
      elements.dialog.close();
      await refreshNodes();
    } catch (error) {
      elements.error.textContent = error.message || "验证失败";
    } finally {
      button.disabled = false;
      button.textContent = "进入状态面板";
    }
  });

  elements.lock.addEventListener("click", () => {
    sessionStorage.removeItem("ejectors_view_token");
    state.viewToken = "";
    clearInterval(state.timer);
    openLogin();
  });
  elements.refresh.addEventListener("click", refreshNodes);
}

function openLogin() {
  if (!elements.dialog.open) elements.dialog.showModal();
  setTimeout(() => elements.token.focus(), 50);
}

async function refreshNodes() {
  if (state.loading || !state.viewToken) return;
  state.loading = true;
  elements.refresh.classList.add("spinning");
  setSync("正在刷新", "");

  try {
    const response = await apiFetch("/api/v1/nodes");
    if (response.status === 401) {
      sessionStorage.removeItem("ejectors_view_token");
      state.viewToken = "";
      openLogin();
      throw new Error("查看密码已失效");
    }
    if (!response.ok) throw new Error("状态接口暂时不可用");
    const data = await response.json();
    render(data);
    setSync("实时连接", "ok");
    scheduleRefresh((data.refresh_seconds || 15) * 1000);
  } catch (error) {
    setSync(error.message || "刷新失败", "error");
  } finally {
    state.loading = false;
    elements.refresh.classList.remove("spinning");
  }
}

function render(data) {
  document.querySelector("#countTotal").textContent = data.summary.total;
  document.querySelector("#countOnline").textContent = data.summary.online;
  document.querySelector("#countDegraded").textContent = data.summary.degraded;
  document.querySelector("#countOffline").textContent = data.summary.offline + data.summary.shutdown;
  elements.updatedAt.textContent = `更新于 ${formatClock(data.server_time)}`;
  elements.drive.href = data.cloud_drive_url || "https://disk.ejectors.net";

  elements.grid.replaceChildren();
  if (!data.nodes.length) {
    elements.grid.innerHTML = `
      <div class="empty-state">
        <strong>还没有 VPS 上报</strong>
        <p>在服务器运行安装脚本后，节点会自动出现在这里。</p>
      </div>`;
    return;
  }

  for (const node of data.nodes) {
    elements.grid.appendChild(renderNode(node, data.server_time));
  }
}

function renderNode(node, serverTime) {
  const fragment = elements.template.content.cloneNode(true);
  const card = fragment.querySelector(".node-card");
  card.dataset.status = node.status;
  text(fragment, ".node-name", node.name || node.node_id);
  text(fragment, ".node-location", [node.provider, node.location].filter(Boolean).join(" · ") || node.hostname || "未设置位置");
  text(fragment, ".status-pill", STATUS_LABELS[node.status] || node.status);
  text(fragment, ".public-ip", node.public_ip || "未获取");
  text(fragment, ".uptime", node.status === "shutdown" ? "已关机" : formatDuration(node.uptime_seconds));

  setMetric(fragment, "cpu", node.cpu?.usage_pct, `${fixed(node.cpu?.usage_pct)}%`, `负载 ${fixed(node.cpu?.load_1, 2)} · ${node.cpu?.cores || "—"} 核`);
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
    services.innerHTML = '<span class="service-empty">未检测到已安装的监控服务</span>';
  } else {
    for (const service of installedServices) {
      const chip = document.createElement("span");
      chip.className = `service-chip ${service.running ? "" : "stopped"}`;
      const dot = document.createElement("i");
      chip.append(dot, document.createTextNode(`${service.name} · ${service.running ? "正常" : "停止"}`));
      services.appendChild(chip);
    }
  }

  const ports = Array.isArray(node.ports) ? node.ports : [];
  text(fragment, ".port-count", `${ports.length} 个`);
  const portList = fragment.querySelector(".port-list");
  for (const port of ports) {
    const chip = document.createElement("span");
    chip.className = "port-chip";
    chip.textContent = `${port.port}${port.process ? ` · ${port.process}` : ""}`;
    portList.appendChild(chip);
  }
  if (!ports.length) portList.innerHTML = '<span class="service-empty">未获取到监听端口</span>';

  return fragment;
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
  if (token) headers.set("x-view-token", token);
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
  if (days > 0) return `${days} 天 ${hours} 小时`;
  const minutes = Math.floor((value % 3600) / 60);
  return `${hours} 小时 ${minutes} 分`;
}

function relativeTime(timestamp, serverTime) {
  const seconds = Math.max(0, (serverTime || Date.now() / 1000) - timestamp);
  if (seconds < 70) return "刚刚在线";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟前`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} 小时前`;
  return `${Math.floor(seconds / 86400)} 天前`;
}

function formatClock(timestamp) {
  return new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).format(new Date(timestamp * 1000));
}
