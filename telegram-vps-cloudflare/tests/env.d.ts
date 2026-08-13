export {};

declare module "cloudflare:workers" {
  interface ProvidedEnv extends Env {
    TELEGRAM_BOT_TOKEN: string;
    TELEGRAM_CHAT_ID: string;
    TELEGRAM_WEBHOOK_SECRET: string;
    DEEPSEEK_API_KEY: string;
    VPS_AGENT_SECRET: string;
  }
}
