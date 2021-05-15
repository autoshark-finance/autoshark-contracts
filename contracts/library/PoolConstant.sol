// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

library PoolConstant {

    enum PoolTypes {
        SharkStake, // no perf fee
        SharkFlip_deprecated, // deprecated
        PantherStake, FlipToFlip, FlipToPanther,
        Shark, // no perf fee
        SharkBNB,
        Venus
    }

    struct PoolInfoBSC {
        address pool;
        uint balance;
        uint principal;
        uint available;
        uint tvl;
        uint utilized;
        uint liquidity;
        uint pBASE;
        uint pSHARK;
        uint depositedAt;
        uint feeDuration;
        uint feePercentage;
    }

    struct PoolInfoETH {
        address pool;
        uint collateralETH;
        uint collateralBSC;
        uint bnbDebt;
        uint leverage;
        uint tvl;
        uint updatedAt;
        uint depositedAt;
        uint feeDuration;
        uint feePercentage;
    }
}
