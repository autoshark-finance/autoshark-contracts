/*
  ___ _  _   _   ___ _  __  _ _ 
 / __| || | /_\ | _ \ |/ / | | |
 \__ \ __ |/ _ \|   / ' <  |_|_|
 |___/_||_/_/ \_\_|_\_|\_\ (_|_)
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;


interface IRocketShark {

    // Swap for simple auction and Callback for delegate contract
    enum AuctionOpts {
        Swap, Callback
    }

    struct AuctionInfo {
        string name;                    // auction name
        uint deadline;                  // auction deadline
        uint swapRatio;                 // swap ratio [1-100000000]
        uint allocation;                // allocation per wallet
        uint tokenSupply;               // amount of the pre-sale token
        uint tokenRemain;               // remain of the pre-sale token
        uint capacity;                  // total value of pre-sale token in ETH or BNB (calculated by RocketShark)
        uint engaged;                   // total raised fund value ()
        address token;                  // address of the pre-sale token
        address payable beneficiary;    // auction host (use contract address for AuctionOpts.Callback)
        bool archived;                  // flag to determine archived
        AuctionOpts option;             // options [Swap, Callback]
    }

    struct UserInfo {
        uint engaged;
        bool claim;
    }

    function getAuction(uint id) external view returns (AuctionInfo memory);

    /**
     * @dev User's amount and boolean flag for claim
     * @param id Auction ID
     * @param user User's address
     * @return True for already claimed
     */
    function getUserInfo(uint id, address user) external view returns (UserInfo memory);

    /**
     * @dev Calculate the amount of tokens for the funds raised.
     * @param id Auction ID
     * @param amount Raised amount (ETH/BNB)
     * @return The amount of tokens swapped
     */
    function swapTokenAmount(uint id, uint amount) external view returns (uint);

    function archive(uint id) external;
}
