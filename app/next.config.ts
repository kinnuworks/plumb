import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // wagmi pulls in WalletConnect, whose logger optionally requires pino-pretty. Plumb only
  // uses injected wallets, so tell webpack to skip those optional modules.
  webpack: (config) => {
    config.externals.push("pino-pretty", "lokijs", "encoding");
    return config;
  },
  /* config options here */
};

export default nextConfig;
