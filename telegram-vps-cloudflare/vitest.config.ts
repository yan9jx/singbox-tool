import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          TELEGRAM_BOT_TOKEN: "123456:test-token-for-local-runtime",
          TELEGRAM_CHAT_ID: "10001",
          TELEGRAM_WEBHOOK_SECRET: "local-webhook-secret",
          DEEPSEEK_API_KEY: "sk-local-test-only",
          VPS_AGENT_SECRET: "local-agent-secret-at-least-32-characters",
        },
      },
    }),
  ],
});
