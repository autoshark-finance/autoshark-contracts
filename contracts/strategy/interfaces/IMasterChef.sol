// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IMasterChef {
    function pantherPerBlock() view external returns(uint);
    function totalAllocPoint() view external returns(uint);

    function poolInfo(uint _pid) view external returns(address lpToken, uint allocPoint, uint lastRewardBlock, uint accPantherPerShare);
    function userInfo(uint _pid, address _account) view external returns(uint amount, uint rewardDebt);

    function deposit(uint256 _pid, uint256 _amount, address _referrer) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
    function emergencyWithdraw(uint256 _pid) external;

    function canHarvest(uint256 _pid, address _user) view external returns(bool);
    // function enterStaking(uint256 _amount) external;
    // function leaveStaking(uint256 _amount) external;
}