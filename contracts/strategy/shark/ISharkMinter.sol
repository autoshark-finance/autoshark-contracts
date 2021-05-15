// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface ISharkMinter {
    function isMinter(address) view external returns(bool);
    function amountSharkToMint(uint bnbProfit) view external returns(uint);
    function amountSharkToMintForSharkBNB(uint amount, uint duration) view external returns(uint);
    function withdrawalFee(uint amount, uint depositedAt) view external returns(uint);
    function performanceFee(uint profit) view external returns(uint);
    function mintFor(address flip, uint _withdrawalFee, uint _performanceFee, address to, uint depositedAt, uint boostRate) external returns(uint mintAmount);
    function mintForSharkBNB(uint amount, uint duration, address to) external returns(uint mintAmount);
    function mint(uint amount, address to) external;
}