import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";
import { Providers } from "@/components/Providers";

export const metadata: Metadata = {
  title: "Plumb",
  description: "The buy side MUSD is missing on Mezo, plus a live view of MUSD's peg.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className="antialiased">
        <Providers>
          <nav className="border-b border-current/10">
            <div className="mx-auto max-w-5xl px-4 h-14 flex items-center gap-6 text-sm">
              <Link href="/" className="font-semibold">Plumb</Link>
              <Link href="/" className="opacity-80 hover:opacity-100">Observatory</Link>
              <Link href="/vault" className="opacity-80 hover:opacity-100">Vault</Link>
              <Link href="/how" className="opacity-80 hover:opacity-100">How it works</Link>
            </div>
          </nav>
          {children}
        </Providers>
      </body>
    </html>
  );
}
