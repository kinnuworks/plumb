// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Minimal interfaces for Mezo's concentrated-liquidity stack (Velodrome Slipstream fork).
/// Signatures checked against the verified mainnet sources of CLPool
/// (0x819CfAdd7F5bc0854FA3B7F5749ea0410a943E5F), NonfungiblePositionManager
/// (0x509Bc221df2B83927c695FA0bb0f5B21053C874c) and CLGauge
/// (0x8f11a90265f7a784B46fe326638Ec37a5CC29c33).

interface ICLPool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        );

    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function gauge() external view returns (address);

    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function burn(uint256 tokenId) external payable;

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function approve(address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface ICLGauge {
    function pool() external view returns (address);
    function rewardToken() external view returns (address);
    function rewardRate() external view returns (uint256);
    function periodFinish() external view returns (uint256);
    function earned(address account, uint256 tokenId) external view returns (uint256);
    function getReward(uint256 tokenId) external;
    function deposit(uint256 tokenId) external;
    function withdraw(uint256 tokenId) external;
    function stakedContains(address depositor, uint256 tokenId) external view returns (bool);
}

/// Velodrome-style BribeVotingReward. Anyone may add a whitelisted reward token.
interface IVotingReward {
    function notifyRewardAmount(address token, uint256 amount) external;
}

interface ICLFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
    function createPool(address tokenA, address tokenB, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        returns (address pool);
}

interface IPoolsVoter {
    function gauges(address pool) external view returns (address);
    function gaugeToBribe(address gauge) external view returns (address);
    function isAlive(address gauge) external view returns (bool);
}
