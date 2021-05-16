// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IPriceCalculator {
    function pricesInUSD(address[] memory assets)
        external
        view
        returns (uint256[] memory);

    function valueOfAsset(address asset, uint256 amount)
        external
        view
        returns (uint256 valueInBNB, uint256 valueInUSD);
}
