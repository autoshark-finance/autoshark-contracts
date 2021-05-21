// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

/*
  ___ _  _   _   ___ _  __  _ _ 
 / __| || | /_\ | _ \ |/ / | | |
 \__ \ __ |/ _ \|   / ' <  |_|_|
 |___/_||_/_/ \_\_|_\_|\_\ (_|_)
*/

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";

import "../library/RewardsDistributionRecipient.sol";
import "../library/Pausable.sol";
import "./interfaces/IStrategyHelper.sol";
import "./interfaces/IMasterChef.sol";
import "./interfaces/IPantherVault.sol";
import "./shark/ISharkMinter.sol";
import "./interfaces/IStrategy.sol";
import "./shark/ISharkReferral.sol";
import "./interfaces/IPantherToken.sol";

contract PantherVault is IStrategy, Ownable {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint256;

    IPantherToken private constant PANTHER = IPantherToken(0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7); // PANTHER
    IMasterChef private constant PANTHER_MASTER_CHEF = IMasterChef(0x058451C62B96c594aD984370eDA8B6FD7197bbd4); // Panther Chef

    address public keeper = 0x2F18BB0CaB431aF5B7BD012FAA08B0ee0d0F3B0f;

    uint public constant poolId = 9;

    uint public totalShares;
    mapping (address => uint) private _shares;
    mapping (address => uint) public override depositedAt;

    ISharkMinter public override minter;
    address public override sharkChef = 0x115BebB4CE6B95340aa84ba967193F1aF03ebC73;

    IStrategyHelper public helper = IStrategyHelper(0xBd17385A935C8D77d15DB2E2C0e1BDE82fdFCe44);
    mapping (address => bool) private _whitelist;
    uint public boostRate = 100000;

    constructor() public {
        IBEP20(PANTHER).safeApprove(address(PANTHER_MASTER_CHEF), uint(~0));
    }

    function setKeeper(address _keeper) external {
        require(msg.sender == _keeper || msg.sender == owner(), 'auth');
        require(_keeper != address(0), 'zero address');
        keeper = _keeper;
    }

    function setHelper(IStrategyHelper _helper) external {
        require(msg.sender == address(_helper) || msg.sender == owner(), 'auth');
        require(address(_helper) != address(0), "zero address");

        helper = _helper;
    }

    function setBoostRate(uint _boostRate) override public onlyOwner {
        require(_boostRate >= 10000, 'boost rate must be minimally 100%');
        boostRate = _boostRate;
    }

    function setWhitelist(address _address, bool _on) external onlyOwner {
        _whitelist[_address] = _on;
    }

    function totalSupply() external view override returns (uint) {
        return totalShares;
    }

    function stakingToken() external view override returns (address) {
        return 0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7;
    }

    function rewardsToken() external view override returns (address) {
        return 0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7;
    }

    function balance() override public view returns (uint) {
        (uint amount,) = PANTHER_MASTER_CHEF.userInfo(poolId, address(this));
        return PANTHER.balanceOf(address(this)).add(amount);
    }

    // @returns panther amount
    function balanceOf(address account) override public view returns(uint) {
        if (totalShares == 0) return 0;
        return balance().mul(sharesOf(account)).div(totalShares);
    }

    function withdrawableBalanceOf(address account) override public view returns (uint) {
        return balanceOf(account);
    }

    function sharesOf(address account) public view returns (uint) {
        return _shares[account];
    }

    function principalOf(address account) override public view returns (uint) {
        return balanceOf(account);
    }

    function profitOf(address) override public view returns (uint _usd, uint _bunny, uint _bnb) {
        // Not available
        return (0, 0, 0);
    }

    function tvl() override public view returns (uint) {
        return helper.tvl(address(PANTHER), balance());
    }

    function apy() override public view returns(uint _usd, uint _bunny, uint _bnb) {
        return helper.apy(ISharkMinter(address (0)), poolId);
    }

    function info(address account) override external view returns(UserInfo memory) {
        UserInfo memory userInfo;

        userInfo.balance = balanceOf(account);
        userInfo.principal = principalOf(account);
        userInfo.available = withdrawableBalanceOf(account);

        Profit memory profit;
        (uint usd, uint shark, uint bnb) = profitOf(account);
        profit.usd = usd;
        profit.shark = shark;
        profit.bnb = bnb;
        userInfo.profit = profit;

        userInfo.poolTVL = tvl();

        APY memory poolAPY;
        (usd, shark, bnb) = apy();
        poolAPY.usd = usd;
        poolAPY.shark = shark;
        poolAPY.bnb = bnb;
        userInfo.poolAPY = poolAPY;

        return userInfo;
    }

    function priceShare() public override view returns(uint) {
        if (totalShares == 0) return 0;
        return balance().mul(1e18).div(totalShares);
    }

    function earned(address account) override public view returns (uint) {
        if (balanceOf(account) >= principalOf(account) + 1000) {
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    function _depositTo(uint _amount, address _to, address) private {
        require(_whitelist[msg.sender], "not whitelist");

        uint _pool = balance();
        IBEP20(PANTHER).safeTransferFrom(msg.sender, address(this), _amount);
        uint shares = 0;
        if (totalShares == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalShares)).div(_pool);
        }

        totalShares = totalShares.add(shares);
        _shares[_to] = _shares[_to].add(shares);

        PANTHER_MASTER_CHEF.withdraw(poolId, 0);
        uint balanceOfPanther = PANTHER.balanceOf(address(this));
        PANTHER_MASTER_CHEF.deposit(poolId, balanceOfPanther, 0xD9ebB6d95f3D8f3Da0b922bB05E0E79501C13554);
    }

    function deposit(uint _amount, address) override public {
        _depositTo(_amount, msg.sender, 0x0000000000000000000000000000000000000000);
    }

    function depositAll(address) override external {
        deposit(PANTHER.balanceOf(msg.sender), 0x0000000000000000000000000000000000000000);
    }

    function withdrawAll() override external {
        uint amount = sharesOf(msg.sender);
        withdraw(amount);
    }

    function harvest() override external {
        PANTHER_MASTER_CHEF.withdraw(poolId, 0);
        uint pantherAmount = PANTHER.balanceOf(address(this));
        PANTHER_MASTER_CHEF.deposit(poolId, pantherAmount, 0xD9ebB6d95f3D8f3Da0b922bB05E0E79501C13554);
    }

    // salvage purpose only
    function withdrawToken(address token, uint amount) external {
        require(msg.sender == keeper || msg.sender == owner(), 'auth');
        require(token != address(PANTHER));

        IBEP20(token).safeTransfer(msg.sender, amount);
    }

    function withdraw(uint256 _amount) override public {
        uint _withdraw = balance().mul(_amount).div(totalShares);
        totalShares = totalShares.sub(_amount);
        _shares[msg.sender] = _shares[msg.sender].sub(_amount);
        PANTHER_MASTER_CHEF.withdraw(poolId, _withdraw.sub(PANTHER.balanceOf(address(this))));
        // TODO: account for tax
        uint firstTax = _withdraw.mul(PANTHER.transferTaxRate()).div(10000);
        IBEP20(PANTHER).safeTransfer(msg.sender, _withdraw.sub(firstTax));
        PANTHER_MASTER_CHEF.deposit(poolId, PANTHER.balanceOf(address(this)), 0xD9ebB6d95f3D8f3Da0b922bB05E0E79501C13554);
    }

    function getReward() override external {
        revert("N/A");
    }
}