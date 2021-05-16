// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "./interfaces/IStrategy.sol";
import "./interfaces/IMasterChef.sol";
import "./shark/ISharkMinter.sol";
import "./interfaces/IStrategyHelper.sol";
import "./interfaces/IPantherToken.sol";
import "./shark/ISharkReferral.sol";

contract StrategyCompoundPantherV2 is IStrategy, Ownable {
    using SafeBEP20 for IBEP20;
    using SafeBEP20 for IPantherToken;
    using SafeMath for uint256;

    IPantherToken private constant PANTHER = IPantherToken(0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7); // PANTHER
    IMasterChef private constant PANTHER_MASTER_CHEF = IMasterChef(0x058451C62B96c594aD984370eDA8B6FD7197bbd4); // PANTHER CHEF

    address public keeper = 0x2F18BB0CaB431aF5B7BD012FAA08B0ee0d0F3B0f;

    uint public poolId = 9;
    uint private constant DUST = 1000;

    uint public totalShares;
    mapping (address => uint) private _shares;
    mapping (address => uint) private _principal;
    mapping (address => uint) public override depositedAt;

    ISharkMinter public override minter;
    IStrategyHelper public helper = IStrategyHelper(0xd9bAfd0024d931D103289721De0D43077e7c2B49);
    address public override sharkChef = 0x115BebB4CE6B95340aa84ba967193F1aF03ebC73;
    
    // Shark referral contract address
    ISharkReferral public sharkReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 1000;
    // Max referral commission rate: 10%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;
    // Added SHARK minting boost rate: 150%
    uint16 public boostRate = 50000;
    
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    constructor() public {
        PANTHER.safeApprove(address(PANTHER_MASTER_CHEF), uint(~0));

        setMinter(ISharkMinter(0x24811d747eA8fF21441CbF035c9C5396C7B23783));
    }

    function setKeeper(address _keeper) external {
        require(msg.sender == _keeper || msg.sender == owner(), 'auth');
        require(_keeper != address(0), 'zero address');
        keeper = _keeper;
    }

    function setMinter(ISharkMinter _minter) public onlyOwner {
        // can zero
        minter = _minter;
        if (address(_minter) != address(0)) {
            PANTHER.safeApprove(address(_minter), 0);
            PANTHER.safeApprove(address(_minter), uint(~0));
        }
    }
    
     function setPoolId(uint _poolId) public onlyOwner {
        poolId = _poolId;
    }

    function setHelper(IStrategyHelper _helper) external {
        require(msg.sender == address(_helper) || msg.sender == owner(), 'auth');
        require(address(_helper) != address(0), "zero address");

        helper = _helper;
    }
    
    function setBoostRate(uint16 _boostRate) override public onlyOwner {
        require(_boostRate >= 10000, 'boost rate must be minimally 100%');
        boostRate = _boostRate;
    }

    /* ========== VIEWS ========== */

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
        return _principal[account];
    }

    function profitOf(address account) override public view returns (uint _usd, uint _shark, uint _bnb) {
        uint _balance = balanceOf(account);
        uint principal = principalOf(account);
        if (principal >= _balance) {
            // something wrong...
            return (0, 0, 0);
        }

        return helper.profitOf(minter, address(PANTHER), _balance.sub(principal));
    }

    function tvl() override public view returns (uint) {
        return helper.tvl(address(PANTHER), balance());
    }

    function apy() override public view returns(uint _usd, uint _shark, uint _bnb) {
        return helper.apy(minter, poolId);
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

    function priceShare() override external view returns(uint) {
        if (totalShares == 0) return 1e18;
        return balance().mul(1e18).div(totalShares);
    }

    function earned(address account) override public view returns (uint) {
        if (balanceOf(account) >= principalOf(account) + DUST) {
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    function _depositTo(uint _amount, address _to, address _referrer) private {
        uint _pool = balance();
        PANTHER.safeTransferFrom(msg.sender, address(this), _amount);
        uint shares = 0;
        uint firstTax = _amount.mul(PANTHER.transferTaxRate()).div(10000);
        uint secondTax = _amount.sub(firstTax).mul(PANTHER.transferTaxRate()).div(10000);
        uint transferTax = firstTax.add(secondTax);
        if (totalShares == 0) {
            shares = _amount.sub(transferTax);
        } else {
            uint sharesAfterTax = _amount.sub(transferTax);
            shares = (sharesAfterTax.mul(totalShares)).div(_pool);
        }
        
        // shares are also the same as amount, after it has been taxed
        if (shares > 0 && address(sharkReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            sharkReferral.recordReferral(msg.sender, _referrer);
        }

        totalShares = totalShares.add(shares);
        _shares[_to] = _shares[_to].add(shares);
        _principal[_to] = _principal[_to].add(shares);
        depositedAt[_to] = block.timestamp;

        harvest();
    }

    function deposit(uint _amount, address _referrer) override public {
        require(_amount >= DUST, "too few coins committed");
        _depositTo(_amount, msg.sender, _referrer);
    }

    function depositAll(address referrer) override external {
        deposit(PANTHER.balanceOf(msg.sender), referrer);
    }

    function withdrawAll() override external {
        uint _withdraw = balanceOf(msg.sender);

        totalShares = totalShares.sub(_shares[msg.sender]);
        delete _shares[msg.sender];

        uint pantherBalance = PANTHER.balanceOf(address(this));

        if (_withdraw > pantherBalance) {
            PANTHER_MASTER_CHEF.withdraw(poolId, _withdraw.sub(pantherBalance));
        }

        uint principal = _principal[msg.sender];
        uint depositTimestamp = depositedAt[msg.sender];
        uint firstTax = _withdraw.mul(PANTHER.transferTaxRate()).div(10000);
        uint secondTax = _withdraw.sub(firstTax).mul(PANTHER.transferTaxRate()).div(10000);
        uint transferTax = firstTax.add(secondTax);
        uint withdrawAfterTax = _withdraw.sub(transferTax);

        delete _principal[msg.sender];
        delete depositedAt[msg.sender];

        if (address(minter) != address(0) && minter.isMinter(address(this)) && withdrawAfterTax > principal) {
            uint profit = withdrawAfterTax.sub(principal);
            uint withdrawalFee = minter.withdrawalFee(withdrawAfterTax, depositTimestamp);
            uint performanceFee = minter.performanceFee(profit);

            uint mintedShark = minter.mintFor(address(PANTHER), withdrawalFee, performanceFee, msg.sender, depositTimestamp, boostRate);
            payReferralCommission(msg.sender, mintedShark);

            PANTHER.safeTransfer(msg.sender, withdrawAfterTax.sub(withdrawalFee).sub(performanceFee));
        } else {
            PANTHER.safeTransfer(msg.sender, withdrawAfterTax);
        }

        harvest();
    }

    // We dont need to check if we can harvest cos PANTHER chef will check for us
    // If there's funds, in our wallet, we want to put it to work immediately
    function harvest() override public {
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

    function withdraw(uint256) override external {
        revert("Use withdrawAll");
    }

    function _withdrawTokenWithCorrection(uint amount) private {
        uint pantherBalance = PANTHER.balanceOf(address(this));
        if (pantherBalance < amount) {
            PANTHER_MASTER_CHEF.withdraw(poolId, amount.sub(pantherBalance));
        }
    }

    function _cleanupIfDustShares() private {
        uint shares = _shares[msg.sender];
        if (shares > 0 && shares < DUST) {
            totalShares = totalShares.sub(shares);
            delete _shares[msg.sender];
        }
    }

    // TODO: Check and make sure taxes are accounted for
    function getReward() external override {
        uint amount = earned(msg.sender);
        
        uint shares = Math.min(amount.mul(totalShares).div(balance()), _shares[msg.sender]);
        totalShares = totalShares.sub(shares);
        _shares[msg.sender] = _shares[msg.sender].sub(shares);
        _cleanupIfDustShares();

        _withdrawTokenWithCorrection(amount);
        uint depositTimestamp = depositedAt[msg.sender];
        uint performanceFee = minter.performanceFee(amount);
        if (performanceFee > DUST) {
            uint mintedShark = minter.mintFor(address(PANTHER), 0, performanceFee, msg.sender, depositTimestamp, boostRate);
            payReferralCommission(msg.sender, mintedShark);
            amount = amount.sub(performanceFee);
        }

        PANTHER.safeTransfer(msg.sender, amount);

        harvest();
    }
    
    
    /**
     * Referral code
     */
    
    // Update the shark referral contract address by the owner
    function setSharkReferral(ISharkReferral _sharkReferral) public onlyOwner {
        sharkReferral = _sharkReferral;
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate) public onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");
        referralCommissionRate = _referralCommissionRate;
    }

    // Pay referral commission to the referrer who referred this user, based on profit
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(sharkReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = sharkReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                minter.mint(commissionAmount, _user);
                minter.mint(commissionAmount, referrer);
                
                sharkReferral.recordReferralCommission(referrer, commissionAmount);
                sharkReferral.recordReferralCommission(_user, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
                emit ReferralCommissionPaid(referrer, _user, commissionAmount);
            }
        }
    }
}