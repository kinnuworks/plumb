"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider, createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { useState } from "react";
import { mezo, mezoTestnet } from "@/lib/chains";

export const wagmiConfig = createConfig({
  chains: [mezoTestnet, mezo],
  connectors: [injected()],
  transports: {
    [mezoTestnet.id]: http(),
    [mezo.id]: http(),
  },
  ssr: true,
});

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
