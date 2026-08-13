import { exports as workerExports } from "cloudflare:workers";
import { createExecutionContext, createScheduledController, env, waitOnExecutionContext } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import worker, { PANEL_KEYBOARD, nodeIssues, type Env } from "../src/index";

const AGENT_SECRET = "local-agent-secret-at-least-32-characters";

async function signature(secret: string, timestamp: string, body: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const result = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${body}`));
  return [...new Uint8Array(result)].map((value) => value.toString(16).padStart(2, "0")).join("");
}

describe("standalone Telegram VPS Worker", () => {
  it("keeps the three control rows paired and detects structured VPS issues without AI", () => {
    expect(PANEL_KEYBOARD).toEqual({
      inline_keyboard: [
        [{ text: "📊 状态刷新", callback_data: "status" }, { text: "🔍 状态更新", callback_data: "refresh_local" }],
        [{ text: "🔄 重启节点", callback_data: "restart_node" }, { text: "🌐 重启反代", callback_data: "restart_proxy" }],
        [{ text: "🖥 切换 VPS", callback_data: "nodes" }, { text: "♻️ 重启 VPS", callback_data: "reboot_ask" }],
      ],
    });
    expect(nodeIssues({
      diagnostics: {
        cpu: { used_pct: 91 },
        memory: { used_pct: 85, swap_used_pct: 2 },
        disk: { used_pct: 40 },
        services: { xray: "failed", caddy: "active" },
        expected_ports: [443, 8443],
        listening_tcp_ports: [443],
      },
    })).toEqual({ resource: "RAM 85%；CPU 91%", service: "xray: failed；端口未监听: 8443" });
  });

  it("reports configuration readiness without exposing values", async () => {
    const response = await workerExports.default.fetch(new Request("https://worker.test/health"));
    expect(response.status).toBe(200);
    const body = await response.json<Record<string, unknown>>();
    expect(body.ok).toBe(true);
    expect(body.configured).toEqual({
      telegram_bot_token: true,
      telegram_chat_id: true,
      telegram_webhook_secret: true,
      deepseek_api_key: true,
      vps_agent_secret: true,
    });
    expect(body.nodes).toEqual({ connected_nodes: 0, online_nodes: 0, newest_last_seen: 0 });
    expect(JSON.stringify(body)).not.toContain(AGENT_SECRET);
  });

  it("rejects unsigned VPS reports", async () => {
    const response = await workerExports.default.fetch(new Request("https://worker.test/api/agent/sync", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    }));
    expect(response.status).toBe(401);
  });

  it("accepts an HMAC-signed report and returns an empty command queue", async () => {
    const payload = {
      version: "1.0.0",
      node_id: "test-vps",
      name: "Test VPS",
      reported_at: Date.now(),
      snapshot: { status_text: "all good", diagnostics: { load: { "1m": 0.1 } } },
      command_results: [],
    };
    const body = JSON.stringify(payload);
    const timestamp = String(Date.now());
    const response = await workerExports.default.fetch(new Request("https://worker.test/api/agent/sync", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Agent-Id": payload.node_id,
        "X-Agent-Timestamp": timestamp,
        "X-Agent-Signature": await signature(AGENT_SECRET, timestamp, body),
      },
      body,
    }));
    expect(response.status).toBe(200);
    const value = await response.json<{ commands: unknown[]; server_time: number }>();
    expect(value.commands).toEqual([]);
    expect(value.server_time).toBeGreaterThan(0);
  });

  it("rejects Telegram webhook calls without the secret header", async () => {
    const response = await workerExports.default.fetch(new Request("https://worker.test/telegram/webhook", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ update_id: 1 }),
    }));
    expect(response.status).toBe(401);
  });

  it("queues weekly cleanup for online VPS nodes", async () => {
    const payload = {
      version: "1.0.0",
      node_id: "weekly-cleanup-vps",
      name: "Weekly Cleanup VPS",
      reported_at: Date.now(),
      snapshot: { status_text: "all good" },
      command_results: [],
    };
    const firstBody = JSON.stringify(payload);
    const firstTimestamp = String(Date.now());
    await workerExports.default.fetch(new Request("https://worker.test/api/agent/sync", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Agent-Id": payload.node_id,
        "X-Agent-Timestamp": firstTimestamp,
        "X-Agent-Signature": await signature(AGENT_SECRET, firstTimestamp, firstBody),
      },
      body: firstBody,
    }));

    const ctx = createExecutionContext();
    const scheduledTime = Date.UTC(2026, 7, 15, 20, 0, 0);
    await worker.scheduled(
      createScheduledController({ cron: "0 20 * * SAT", scheduledTime }),
      env as unknown as Env,
      ctx,
    );
    await waitOnExecutionContext(ctx);

    const secondBody = JSON.stringify({ ...payload, reported_at: Date.now() });
    const secondTimestamp = String(Date.now());
    const response = await workerExports.default.fetch(new Request("https://worker.test/api/agent/sync", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Agent-Id": payload.node_id,
        "X-Agent-Timestamp": secondTimestamp,
        "X-Agent-Signature": await signature(AGENT_SECRET, secondTimestamp, secondBody),
      },
      body: secondBody,
    }));
    const value = await response.json<{ commands: Array<{ action: string; target: string }> }>();
    expect(value.commands).toContainEqual(expect.objectContaining({ action: "clean", target: "auto" }));
  });
});
