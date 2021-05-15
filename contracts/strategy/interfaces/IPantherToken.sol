// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

/*
  ___ _  _   _   ___ _  __  _ _ 
 / __| || | /_\ | _ \ |/ / | | |
 \__ \ __ |/ _ \|   / ' <  |_|_|
 |___/_||_/_/ \_\_|_\_|\_\ (_|_)
*/

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";

interface IPantherToken is IBEP20 {
    
    function transferTaxRate() external view returns (uint16);
}
