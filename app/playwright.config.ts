import { defineConfig } from "@playwright/test";

// Walks the demo path against the static export, reading Mezo mainnet and testnet for real.
// Every run records a video (the rough cut lives in test-results/).
export default defineConfig({
  testDir: "e2e",
  timeout: 90_000,
  retries: 0,
  use: {
    baseURL: "http://localhost:4174",
    video: "on",
    viewport: { width: 1280, height: 800 },
  },
  webServer: {
    command: "python3 -m http.server 4174 --directory .preview",
    url: "http://localhost:4174/plumb/",
    reuseExistingServer: true,
  },
});
