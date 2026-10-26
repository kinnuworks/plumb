// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// The sMUSD vault (MUSDSavingsRate, proxy 0xb4D498029af77680cD1eF828b967f010d06C51CC).
/// It is not ERC-4626: deposits mint sMUSD 1:1, and yield accrues through a separate
/// index that holders pull with claimYield().
interface IMUSDSavingsRate {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function claimYield() external returns (uint256);
    function claimableYield(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function strategy() external view returns (address);
    function setStrategy(address newStrategy) external;
    function owner() external view returns (address);
    function receiveYieldFromStrategy() external;
}

/// Strategy hook that sMUSD's owner can switch with setStrategy().
/// Mirrors IVaultStrategy in MUSDSavingsRate.sol.
interface IVaultStrategy {
    function allocate(uint256 amount) external;
    function deallocate(uint256 amount) external;
    function claimYield() external returns (uint256 amount);
    function migrate(address newStrategy) external returns (uint256 amount);
    function onMigrated(uint256 amount) external;
}
