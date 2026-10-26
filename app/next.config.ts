import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Static export for GitHub Pages at https://kinnuworks.github.io/plumb/
  output: "export",
  basePath: "/plumb",
  trailingSlash: true,
  images: { unoptimized: true },
  // wagmi pulls in WalletConnect, whose logger optionally requires pino-pretty. Plumb only
  // uses injected wallets, so tell webpack to skip those optional modules.
  webpack: (config) => {
    config.externals.push("pino-pretty", "lokijs", "encoding");
    return config;
  },
};

export default nextConfig;
