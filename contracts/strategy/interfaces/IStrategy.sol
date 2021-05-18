// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

/*
  ___ _  _   _   ___ _  __  _ _ 
 / __| || | /_\ | _ \ |/ / | | |
 \__ \ __ |/ _ \|   / ' <  |_|_|
 |___/_||_/_/ \_\_|_\_|\_\ (_|_)
*/

import "../shark/ISharkMinter.sol";

struct Profit {
    uint usd;
    uint shark;
    uint bnb;
}

struct APY {
    uint usd;
    uint shark;
    uint bnb;
}

struct UserInfo {
    uint balance;
    uint principal;
    uint available;
    Profit profit;
    uint poolTVL;
    APY poolAPY;
}

interface IStrategy {
    function deposit(uint _amount, address _referrer) external;
    function depositAll(address referrer) external;
    function withdraw(uint256 _amount) external;    // SHARK STAKING POOL ONLY
    function withdrawAll() external;
    function getReward() external;                  // SHARK STAKING POOL ONLY
    function harvest() external;
    function totalSupply() external view returns (uint);
    function earned(address account) external view returns (uint);
    function minter() external view returns (ISharkMinter);
    function sharkChef() external view returns (address);

    function balance() external view returns (uint);
    function balanceOf(address account) external view returns(uint);
    function principalOf(address account) external view returns (uint);
    function withdrawableBalanceOf(address account) external view returns (uint);   // SHARK STAKING POOL ONLY
    function profitOf(address account) external view returns (uint _usd, uint _shark, uint _bnb);
    function tvl() external view returns (uint);    // in USD
    function apy() external view returns(uint _usd, uint _shark, uint _bnb);
    function priceShare() external view returns (uint);

    function info(address account) external view returns(UserInfo memory);
    /* ========== Strategy Information ========== */

    // function poolType() external view returns (PoolConstant.PoolTypes);
    function depositedAt(address account) external view returns (uint);
    function stakingToken() external view returns (address);
    function rewardsToken() external view returns (address);


    function setBoostRate(uint _boostRate) external;
}