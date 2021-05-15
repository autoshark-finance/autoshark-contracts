// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

/*
  ___ _  _   _   ___ _  __  _ _ 
 / __| || | /_\ | _ \ |/ / | | |
 \__ \ __ |/ _ \|   / ' <  |_|_|
 |___/_||_/_/ \_\_|_\_|\_\ (_|_)
*/

import "../shark/ISharkMinter.sol";

interface IStrategyHelper {
    function tokenPriceInBNB(address _token) view external returns(uint);
    function pantherPriceInBNB() view external returns(uint);
    function bnbPriceInUSD() view external returns(uint);

    function flipPriceInBNB(address _flip) view external returns(uint);
    function flipPriceInUSD(address _flip) view external returns(uint);

    function profitOf(ISharkMinter minter, address _flip, uint amount) external view returns (uint _usd, uint _shark, uint _bnb);

    function tvl(address _flip, uint amount) external view returns (uint);    // in USD
    function tvlInBNB(address _flip, uint amount) external view returns (uint);    // in BNB
    function apy(ISharkMinter minter, uint pid) external view returns(uint _usd, uint _shark, uint _bnb);
    function compoundingAPY(uint pid, uint compoundUnit) view external returns(uint);
}