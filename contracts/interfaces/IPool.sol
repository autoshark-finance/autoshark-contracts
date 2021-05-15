// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IPool {
    function deposit(uint _amount) external;
    function depositAll() external;
    function withdraw(uint256 _amount) external;    
    function withdrawAll() external;
    function getReward() external;                  
    function harvest() external;

    function balance() external view returns (uint);
    function balanceOf(address account) external view returns(uint);
    function principalOf(address account) external view returns (uint);
    function withdrawableBalanceOf(address account) external view returns (uint);   
    function profitOf(address account) external view returns (uint _usd, uint _shark, uint _bnb);
    function tvl() external view returns (uint);    // in USD
    function apy() external view returns(uint _usd, uint _shark, uint _bnb);
    function priceShare() external view returns(uint);
}