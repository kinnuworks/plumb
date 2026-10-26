import type { Address } from "viem";

/** Mezo mainnet contracts Plumb reads or integrates with. */
export const MAINNET = {
  musd: "0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186",
  musdc: "0x04671C72Aab5AC02A03c1098314b1BB6B560c197",
  mezo: "0x7B7c000000000000000000000000000000000001",
  pool: "0xCC372B7E15535aB225fe17c1075831D38ef7aC1a",
  gauge: "0x6d446E27505c71EE39D632488cE849fEF6aFFc57",
  basicMusdUsdc: "0xEd812AEc0Fecc8fD882Ac3eccC43f3aA80A6c356",
  basicMusdUsdt: "0x10906a9E9215939561597b4C8e4b98F93c02031A",
  smusd: "0xb4D498029af77680cD1eF828b967f010d06C51CC",
  idleStrategy: "0x0C0944713c185ea3e64F5609ECee3fB3C054a295",
  stabilityPool: "0x73245Eff485aB3AAc1158B3c4d8f4b23797B0e32",
  activePool: "0x3012C2fE1240e3754E5C200A0946bb0E07474876",
  troveManager: "0x94AfB503dBca74aC3E4929BACEeDfCe19B93c193",
  nttManager: "0x7efb386675d75280D39Aae42964A6776DE0ee0bD",
} as const satisfies Record<string, Address>;

/** Plumb's testnet deployment (contracts/deployments/mezo-testnet.json). */
export const PLUMB_TESTNET = {
  vault: (process.env.NEXT_PUBLIC_TESTNET_VAULT ?? "0xA27AbD357f28c41732EA6670278140284fbAcF9E") as Address,
  pool: (process.env.NEXT_PUBLIC_TESTNET_POOL ?? "0xf6212414351f29AB816371f6b4ceE51960916c2a") as Address,
  musd: "0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503" as Address,
  usd: "0xe1a26db653708A2AD8F824E92Db9852410e33A59" as Address,
};

/** Address the quoter's bytecode is placed at for state-override calls. Nothing lives here. */
export const QUOTER_OVERRIDE_ADDRESS: Address = "0x000000000000000000000000000000000000bEEF";
