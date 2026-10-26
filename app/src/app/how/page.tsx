export const metadata = { title: "How Plumb works" };

const evidence = [
  ["A $25,000 deposit on a fork of today's mainnet", "Selling 100,000 MUSD pays $63,556 instead of $38,556"],
  ["One day with the bid in range", "About 40,600 MEZO streamed to depositors from the pool's gauge"],
  ["sMUSD switched to PlumbAskStrategy by its real owner, on a fork", "All 7,382,555 MUSD moved; deposits and withdrawals stay instant"],
  ["A full market cycle through that strategy", "27,158 MUSD sold at $1.001 or more, bought back cheaper, 164 MUSD paid to savers"],
  ["Six invariants over 360 random calls per run", "Including one that caught a share-pricing bug when the pool runs dry"],
];

export default function How() {
  return (
    <main className="mx-auto max-w-3xl px-4 py-10 space-y-10 leading-relaxed">
      <h1 className="text-3xl font-semibold">How Plumb works</h1>

      <section className="space-y-3">
        <h2 className="text-xl font-semibold">The problem</h2>
        <p>
          MUSD trades about 1% under $1. On Mezo&apos;s main MUSD/mUSDC pool, roughly 5.3 million MUSD is offered for
          sale between $0.99 and $1.00, and the buy side holds under $40,000. Until mid October a 100,000 MUSD sale
          cleared at about $0.99. After the bids were pulled, the same sale runs the book dry.
        </p>
      </section>

      <section className="space-y-3">
        <h2 className="text-xl font-semibold">The vault</h2>
        <p>
          You deposit mUSDC. The vault places it as a bid that starts one tick below the market and runs 2% deeper, so
          a seller meets real buyers instead of an empty book. The position is staked in the pool&apos;s gauge and earns
          MEZO, which streams to depositors.
        </p>
        <p>
          MUSD the bid buys goes into sMUSD, Mezo&apos;s savings vault, and earns there while MUSD is under $1. Once MUSD
          trades within 0.2% of $1, the vault takes it back out and offers it for sale at $1 or more. That round trip is
          where depositors earn the discount.
        </p>
      </section>

      <section className="space-y-3">
        <h2 className="text-xl font-semibold">What keeps it safe</h2>
        <ul className="list-disc pl-5 space-y-1">
          <li>There is no owner. Every parameter is fixed at deployment.</li>
          <li>The vault only moves liquidity when the live price agrees with the 30-minute average, so one block of
            manipulation can&apos;t steer it.</li>
          <li>Withdrawals pay your share of each token directly. No price is involved, so nobody can game an exit.</li>
          <li>Bids and deposits stop if MUSD falls below $0.96, and bidding stops once 60% of the vault is MUSD.</li>
          <li>Nothing relies on signatures or meta-transactions.</li>
        </ul>
      </section>

      <section className="space-y-3">
        <h2 className="text-xl font-semibold">The sMUSD strategy</h2>
        <p>
          sMUSD keeps 7.38 million MUSD in a strategy that earns nothing. PlumbAskStrategy plugs into the same hook. It
          keeps at least 95% idle so withdrawals stay instant, and offers the rest only at $1.001 and up. Savers never
          sell below par. When the order fills and MUSD later dips, the strategy buys back more MUSD than it sold, and
          the surplus becomes sMUSD yield. Switching to it takes one call from the sMUSD owner, and switching back
          returns every token.
        </p>
      </section>

      <section className="space-y-3">
        <h2 className="text-xl font-semibold">Evidence</h2>
        <p className="opacity-80">From the test suite, run against the real Mezo mainnet contracts on a fork:</p>
        <table className="w-full text-sm">
          <tbody>
            {evidence.map(([what, result]) => (
              <tr key={what} className="border-t border-current/10 align-top">
                <td className="py-2 pr-4">{what}</td>
                <td className="py-2">{result}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
    </main>
  );
}
