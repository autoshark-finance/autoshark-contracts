// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IVaultController {
    function minter() external view returns (address);
    function sharkChef() external view returns (address);
    function stakingToken() external view returns (address);
}
