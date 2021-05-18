// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "./interfaces/ICakeMasterChef.sol";
import "./shark/ISharkMinter.sol";
import "./interfaces/IStrategyHelper.sol";
import "./interfaces/IStrategy.sol";
import "./shark/ISharkReferral.sol";

contract StrategyCompoundCake is IStrategy, Ownable {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint256;

    IBEP20 private constant CAKE = IBEP20(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82);
    ICakeMasterChef private constant CAKE_MASTER_CHEF = ICakeMasterChef(0x73feaa1eE314F8c655E354234017bE2193C9E24E);

    address public keeper = 0xB4697cCDC82712d12616c7738F162ceC9DCEC4E8;

    uint public constant poolId = 0;
    uint private constant DUST = 1000;

    uint public totalShares;
    mapping (address => uint) private _shares;
    mapping (address => uint) private _principal;
    mapping (address => uint) public override depositedAt;

    ISharkMinter public override minter;
    IStrategyHelper public helper = IStrategyHelper(0xBd17385A935C8D77d15DB2E2C0e1BDE82fdFCe44); // CAKE strategy
    address public override sharkChef = 0x115BebB4CE6B95340aa84ba967193F1aF03ebC73;
    
    // Shark referral contract address
    ISharkReferral public sharkReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 1000;
    // Max referral commission rate: 10%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;
    // Added SHARK minting boost rate: 300%
    uint16 public boostRate = 30000;
    
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    constructor() public {
        CAKE.safeApprove(address(CAKE_MASTER_CHEF), uint(~0));
    }

    function setKeeper(address _keeper) external {
        require(msg.sender == _keeper || msg.sender == owner(), 'auth');
        require(_keeper != address(0), 'zero address');
        keeper = _keeper;
    }

    function setMinter(ISharkMinter _minter) external onlyOwner {
        // can zero
        minter = _minter;
        if (address(_minter) != address(0)) {
            CAKE.safeApprove(address(_minter), 0);
            CAKE.safeApprove(address(_minter), uint(~0));
        }
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
        (uint amount,) = CAKE_MASTER_CHEF.userInfo(poolId, address(this));
        return CAKE.balanceOf(address(this)).add(amount);
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

    function earned(address account) public override view returns (uint) {
        if (balanceOf(account) >= principalOf(account) + DUST) {
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    function profitOf(address account) override public view returns (uint _usd, uint _shark, uint _bnb) {
        uint _balance = balanceOf(account);
        uint principal = principalOf(account);
        if (principal >= _balance) {
            // something wrong...
            return (0, 0, 0);
        }

        return helper.profitOf(minter, address(CAKE), _balance.sub(principal));
    }

    function tvl() override public view returns (uint) {
        return helper.tvl(address(CAKE), balance());
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

    function priceShare() public override view returns(uint) {
        return balance().mul(1e18).div(totalShares);
    }

    function _depositTo(uint _amount, address _to, address _referrer) private {
        uint _pool = balance();
        CAKE.safeTransferFrom(msg.sender, address(this), _amount);
        uint shares = 0;
        if (totalShares == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalShares)).div(_pool);
        }

        // shares are also the same as amount
        if (shares > 0 && address(sharkReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            sharkReferral.recordReferral(msg.sender, _referrer);
        }

        totalShares = totalShares.add(shares);
        _shares[_to] = _shares[_to].add(shares);
        _principal[_to] = _principal[_to].add(_amount);
        depositedAt[_to] = block.timestamp;

        uint balanceOfCake = CAKE.balanceOf(address(this));
        CAKE_MASTER_CHEF.enterStaking(balanceOfCake);
    }

    function deposit(uint _amount, address _referrer) override public {
        _depositTo(_amount, msg.sender, _referrer);
    }

    function depositAll(address referrer) override external {
        deposit(CAKE.balanceOf(msg.sender), referrer);
    }

    function withdrawAll() override external {
        uint _withdraw = balanceOf(msg.sender);

        totalShares = totalShares.sub(_shares[msg.sender]);
        delete _shares[msg.sender];
        CAKE_MASTER_CHEF.leaveStaking(_withdraw.sub(CAKE.balanceOf(address(this))));

        uint principal = _principal[msg.sender];
        uint depositTimestamp = depositedAt[msg.sender];
        delete _principal[msg.sender];
        delete depositedAt[msg.sender];

        if (address(minter) != address(0) && minter.isMinter(address(this)) && _withdraw > principal) {
            uint profit = _withdraw.sub(principal);
            uint withdrawalFee = minter.withdrawalFee(_withdraw, depositTimestamp);
            uint performanceFee = minter.performanceFee(profit);

            minter.mintFor(address(CAKE), withdrawalFee, performanceFee, msg.sender, depositTimestamp, boostRate);

            CAKE.safeTransfer(msg.sender, _withdraw.sub(withdrawalFee).sub(performanceFee));
        } else {
            CAKE.safeTransfer(msg.sender, _withdraw);
        }

        CAKE_MASTER_CHEF.enterStaking(CAKE.balanceOf(address(this)));
    }

    function harvest() override public {
        require(msg.sender == keeper || msg.sender == owner(), 'auth');

        CAKE_MASTER_CHEF.leaveStaking(0);
        uint cakeAmount = CAKE.balanceOf(address(this));
        CAKE_MASTER_CHEF.enterStaking(cakeAmount);
    }
    

    // salvage purpose only
    function withdrawToken(address token, uint amount) external {
        require(msg.sender == keeper || msg.sender == owner(), 'auth');
        require(token != address(CAKE));

        IBEP20(token).safeTransfer(msg.sender, amount);
    }

    function withdraw(uint256) override external {
        revert("Use withdrawAll");
    }

     function _withdrawTokenWithCorrection(uint amount) private {
        uint cakeBalance = CAKE.balanceOf(address(this));
        if (cakeBalance < amount) {
            CAKE_MASTER_CHEF.withdraw(poolId, amount.sub(cakeBalance));
        }
    }

    function _cleanupIfDustShares() private {
        uint shares = _shares[msg.sender];
        if (shares > 0 && shares < DUST) {
            totalShares = totalShares.sub(shares);
            delete _shares[msg.sender];
        }
    }

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
            minter.mintFor(address(CAKE), 0, performanceFee, msg.sender, depositTimestamp, boostRate);
            amount = amount.sub(performanceFee);
        }

        CAKE.safeTransfer(msg.sender, amount);

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