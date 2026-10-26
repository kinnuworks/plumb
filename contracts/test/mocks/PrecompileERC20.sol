// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Stand-in for Mezo's MEZO token precompile (0x7B7c...0001) in fork tests.
/// Foundry's EVM cannot execute Mezo's native precompiles, so tests etch this standard ERC-20
/// at the same address. Everything else in the fork (pool, gauge, sMUSD, router) is the real
/// mainnet bytecode and state.
contract PrecompileERC20 is ERC20 {
    constructor() ERC20("Mezo", "MEZO") {}
}
