# Plumb app

The peg observatory (`/`), the vault (`/vault`) and the explainer (`/how`).

```bash
pnpm install
pnpm dev   # http://localhost:3000
```

The observatory reads Mezo mainnet through public RPCs and needs no keys. The vault page talks to the testnet vault in `src/lib/addresses.ts`; override it with `NEXT_PUBLIC_TESTNET_VAULT`.
