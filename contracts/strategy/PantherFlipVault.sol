// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../library/RewardsDistributionRecipient.sol";
import "../library/Pausable.sol";
import "./interfaces/IStrategyHelper.sol";
import "./interfaces/IMasterChef.sol";
import "./interfaces/IPantherVault.sol";
import "./shark/ISharkMinter.sol";
import "./interfaces/IStrategy.sol";
import "./shark/ISharkReferral.sol";

contract PantherFlipVault is IStrategy, RewardsDistributionRecipient, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    /* ========== STATE VARIABLES ========== */
    address public override rewardsToken; // This ought to be set as PANTHER vault, so we can compound recursively
    address public override stakingToken; // This ought to be set as the FLIP/LP pool
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public rewardsDuration = 24 hours;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    

    /* ========== PANTHER     ============= */
    address private constant PANTHER = 0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7;
    IMasterChef private constant PANTHER_MASTER_CHEF = IMasterChef(0x058451C62B96c594aD984370eDA8B6FD7197bbd4);
    uint public poolId;
    address public keeper = 0x2F18BB0CaB431aF5B7BD012FAA08B0ee0d0F3B0f;
    mapping (address => uint) public override depositedAt;

    /* ========== BUNNY HELPER / MINTER ========= */
    IStrategyHelper public helper = IStrategyHelper(0xd9bAfd0024d931D103289721De0D43077e7c2B49);
    ISharkMinter public override minter;

    address public override sharkChef = 0x115BebB4CE6B95340aa84ba967193F1aF03ebC73;
    
    // Shark referral contract address
    ISharkReferral public sharkReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 1000;
    // Max referral commission rate: 10%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;
    // Added SHARK minting boost rate: 500%
    uint16 public boostRate = 50000;

    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    /* ========== CONSTRUCTOR ========== */

    constructor(uint _pid) public {
        (address _token,,,) = PANTHER_MASTER_CHEF.poolInfo(_pid);
        stakingToken = _token;
        IBEP20(stakingToken).safeApprove(address(PANTHER_MASTER_CHEF), uint(~0));
        poolId = _pid;

        rewardsDistribution = msg.sender;
        setMinter(ISharkMinter(0x24811d747eA8fF21441CbF035c9C5396C7B23783));
        setRewardsToken(0xbBEbdE8157eecCd1788a2aF6C24A8CFdf9869362);
    }

    /* ========== VIEWS ========== */
    function totalSupply() external override view returns (uint256) {
        return _totalSupply;
    }

    function balance() override public view returns (uint) {
        return _totalSupply;
    }
    
    function priceShare() public override view returns(uint) {
        return balance().mul(1e18).div(_totalSupply);
    }

    function balanceOf(address account) override external view returns (uint256) {
        return _balances[account];
    }

    function principalOf(address account) override external view returns (uint256) {
        return _balances[account];
    }

    function withdrawableBalanceOf(address account) override public view returns (uint) {
        return _balances[account];
    }

    // return pantherAmount, sharkAmount, 0
    function profitOf(address account) override public view returns (uint _usd, uint _shark, uint _bnb) {
        uint pantherVaultPrice = IPantherVault(rewardsToken).priceShare();
        uint _earned = earned(account);
        uint amount = _earned.mul(pantherVaultPrice).div(1e18);

        if (address(minter) != address(0) && minter.isMinter(address(this))) {
            uint performanceFee = minter.performanceFee(amount);
            // panther amount
            _usd = amount.sub(performanceFee);

            uint bnbValue = helper.tvlInBNB(PANTHER, performanceFee);
            // shark amount
            _shark = minter.amountSharkToMint(bnbValue);
        } else {
            _usd = amount;
            _shark = 0;
        }

        _bnb = 0;
    }

    function tvl() override public view returns (uint) {
        uint stakingTVL = helper.tvl(address(stakingToken), _totalSupply);

        uint price = IPantherVault(rewardsToken).priceShare();
        uint earned = IPantherVault(rewardsToken).balanceOf(address(this)).mul(price).div(1e18);
        uint rewardTVL = helper.tvl(PANTHER, earned);

        return stakingTVL.add(rewardTVL);
    }

    function tvlStaking() external view returns (uint) {
        return helper.tvl(address(stakingToken), _totalSupply);
    }

    function tvlReward() external view returns (uint) {
        uint price = IPantherVault(rewardsToken).priceShare();
        uint earned = IPantherVault(rewardsToken).balanceOf(address(this)).mul(price).div(1e18);
        return helper.tvl(PANTHER, earned);
    }

    function apy() override public view returns(uint _usd, uint _shark, uint _bnb) {
        uint dailyAPY = helper.compoundingAPY(poolId, 365 days).div(365);

        uint pantherAPY = helper.compoundingAPY(0, 1 days);
        uint pantherDailyAPY = helper.compoundingAPY(0, 365 days).div(365);

        // let x = 0.5% (daily flip apr)
        // let y = 0.87% (daily panther apr)
        // sum of yield of the year = x*(1+y)^365 + x*(1+y)^364 + x*(1+y)^363 + ... + x
        // ref: https://en.wikipedia.org/wiki/Geometric_series
        // = x * (1-(1+y)^365) / (1-(1+y))
        // = x * ((1+y)^365 - 1) / (y)

        _usd = dailyAPY.mul(pantherAPY).div(pantherDailyAPY);
        _shark = 0;
        _bnb = 0;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
        rewardPerTokenStored.add(
            lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
        );
    }

    function earned(address account) public override view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function _deposit(uint256 amount, address _to, address _referrer) private nonReentrant notPaused updateReward(_to) {
        require(amount > 0, "amount");

        if (amount > 0 && address(sharkReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            sharkReferral.recordReferral(msg.sender, _referrer);
        }

        _totalSupply = _totalSupply.add(amount);
        _balances[_to] = _balances[_to].add(amount);
        depositedAt[_to] = block.timestamp;
        IBEP20(stakingToken).safeTransferFrom(msg.sender, address(this), amount);
        PANTHER_MASTER_CHEF.deposit(poolId, amount, 0xD9ebB6d95f3D8f3Da0b922bB05E0E79501C13554);
        emit Staked(_to, amount);

        _harvest();
    }

    function deposit(uint256 amount, address _referrer) override public {
        _deposit(amount, msg.sender, _referrer);
    }

    function depositAll(address _referrer) override external {
        deposit(IBEP20(stakingToken).balanceOf(msg.sender), _referrer);
    }

    function withdraw(uint256 amount) override public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "amount");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        PANTHER_MASTER_CHEF.withdraw(poolId, amount);

        if (address(minter) != address(0) && minter.isMinter(address(this))) {
            uint _depositedAt = depositedAt[msg.sender];
            uint withdrawalFee = minter.withdrawalFee(amount, _depositedAt);
            if (withdrawalFee > 0) {
                uint performanceFee = withdrawalFee.div(100);
                uint mintedShark = minter.mintFor(address(stakingToken), withdrawalFee.sub(performanceFee), performanceFee, msg.sender, _depositedAt, boostRate);
                payReferralCommission(msg.sender, mintedShark);
                amount = amount.sub(withdrawalFee);
            }
        }

        IBEP20(stakingToken).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);

        _harvest();
    }

    function withdrawAll() override external {
        uint _withdraw = withdrawableBalanceOf(msg.sender);
        if (_withdraw > 0) {
            withdraw(_withdraw);
        }
        getReward();
    }

    function getReward() override public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            IPantherVault(rewardsToken).withdraw(reward);
            uint pantherBalance = IBEP20(PANTHER).balanceOf(address(this));

            if (address(minter) != address(0) && minter.isMinter(address(this))) {
                uint performanceFee = minter.performanceFee(pantherBalance);
                uint mintedShark = minter.mintFor(PANTHER, 0, performanceFee, msg.sender, depositedAt[msg.sender], boostRate);
                payReferralCommission(msg.sender, mintedShark);
                pantherBalance = pantherBalance.sub(performanceFee);
            }

            IBEP20(PANTHER).safeTransfer(msg.sender, pantherBalance);
            emit RewardPaid(msg.sender, pantherBalance);
        }
    }

    function harvest() override public {
        PANTHER_MASTER_CHEF.withdraw(poolId, 0);
        _harvest();
    }

    function _harvest() private {
        uint pantherAmount = IBEP20(PANTHER).balanceOf(address(this));
        uint _before = IPantherVault(rewardsToken).sharesOf(address(this));
        IPantherVault(rewardsToken).deposit(pantherAmount);
        uint amount = IPantherVault(rewardsToken).sharesOf(address(this)).sub(_before);
        if (amount > 0) {
            _notifyRewardAmount(amount);
        }
    }

    function info(address account) override external view returns(UserInfo memory) {
        UserInfo memory userInfo;

        userInfo.balance = _balances[account];
        userInfo.principal = _balances[account];
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

    /* ========== RESTRICTED FUNCTIONS ========== */
    function setKeeper(address _keeper) external {
        require(msg.sender == _keeper || msg.sender == owner(), 'auth');
        require(_keeper != address(0), 'zero address');
        keeper = _keeper;
    }

    function setMinter(ISharkMinter _minter) public onlyOwner {
        // can zero
        minter = _minter;
        if (address(_minter) != address(0)) {
            IBEP20(PANTHER).safeApprove(address(_minter), 0);
            IBEP20(PANTHER).safeApprove(address(_minter), uint(~0));

            IBEP20(stakingToken).safeApprove(address(_minter), 0);
            IBEP20(stakingToken).safeApprove(address(_minter), uint(~0));
        }
    }

    function setRewardsToken(address _rewardsToken) private onlyOwner {
        require(address(rewardsToken) == address(0), "set rewards token already");

        rewardsToken = _rewardsToken;

        IBEP20(PANTHER).safeApprove(_rewardsToken, 0);
        IBEP20(PANTHER).safeApprove(_rewardsToken, uint(~0));
    }

    function setHelper(IStrategyHelper _helper) external onlyOwner {
        require(address(_helper) != address(0), "zero address");
        helper = _helper;
    }

    function setBoostRate(uint16 _boostRate) override public onlyOwner {
        require(_boostRate >= 10000, 'boost rate must be minimally 100%');
        boostRate = _boostRate;
    }

    function notifyRewardAmount(uint256 reward) override public onlyRewardsDistribution {
        _notifyRewardAmount(reward);
    }

    function _notifyRewardAmount(uint256 reward) private updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint _balance = IPantherVault(rewardsToken).sharesOf(address(this));
        require(rewardRate <= _balance.div(rewardsDuration), "reward");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    function recoverBEP20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken) && tokenAddress != address(rewardsToken), "tokenAddress");
        IBEP20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(periodFinish == 0 || block.timestamp > periodFinish, "period");
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
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

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}