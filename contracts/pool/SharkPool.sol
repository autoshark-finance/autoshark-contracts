// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/Math.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./RewardsDistributionRecipient.sol";
import "../interfaces/IStakingRewards.sol";
import "./Pausable.sol";
import "../strategy/interfaces/IStrategy.sol";
import "../strategy/interfaces/IStrategyHelper.sol";
import "pantherswap-peripheral/contracts/interfaces/IPantherRouter02.sol";
import "../strategy/shark/ISharkReferral.sol";

interface IPresale {
    function totalBalance() view external returns(uint);
    function flipToken() view external returns(address);
}

contract SharkPool is IStrategy, RewardsDistributionRecipient, ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    /* ========== STATE VARIABLES ========== */

    address public override rewardsToken; // shark/bnb flip
    address public override constant stakingToken = 0xf7321385a461C4490d5526D83E63c366b149cB15;   // shark
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public rewardsDuration = 90 days;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    mapping(address => bool) private _stakePermission;

    /* ========== PRESALE ============== */
    address private constant presaleContract = 0x000000000000000000000000000000000000dEaD; // Dead address cos we aren't looking to do presale
    address private constant deadAddress = 0x000000000000000000000000000000000000dEaD;
    mapping(address => uint256) private _presaleBalance;
    uint private constant timestamp2HoursAfterPresaleEnds = 1605585600 + (2 hours);
    uint private constant timestamp90DaysAfterPresaleEnds = 1605585600 + (90 days);

    /* ========== SHARK HELPER ========= */
    IStrategyHelper public helper = IStrategyHelper(0xBd17385A935C8D77d15DB2E2C0e1BDE82fdFCe44);
    IPantherRouter02 private constant ROUTER = IPantherRouter02(0x24f7C33ae5f77e2A9ECeed7EA858B4ca2fa1B7eC);
    
    // Shark referral contract address
    ISharkReferral public sharkReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 1000;
    // Max referral commission rate: 10%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;
    // Added SHARK minting boost rate: 150%
    uint16 public boostRate = 15000;

    mapping (address => uint) public override depositedAt;
    ISharkMinter public override minter;
    address public override sharkChef = 0x115BebB4CE6B95340aa84ba967193F1aF03ebC73;
    
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    /* ========== CONSTRUCTOR ========== */

    constructor() public {
        rewardsDistribution = msg.sender;

        _stakePermission[msg.sender] = true;
        _stakePermission[presaleContract] = true;

        IBEP20(stakingToken).safeApprove(address(ROUTER), uint(~0));
    }

    /* ========== VIEWS ========== */

    function totalSupply() override external view returns (uint256) {
        return _totalSupply;
    }

    function balance() override external view returns (uint) {
        return _totalSupply;
    }

    function balanceOf(address account) override external view returns (uint256) {
        return _balances[account];
    }

    function presaleBalanceOf(address account) external view returns(uint256) {
        return _presaleBalance[account];
    }

    function principalOf(address account) override external view returns (uint256) {
        return _balances[account];
    }

    function priceShare() override external view returns (uint256) {
        revert("No implementation");
    }

    function withdrawableBalanceOf(address account) override public view returns (uint) {
        if (block.timestamp > timestamp90DaysAfterPresaleEnds) {
            // unlock all presale shark after 90 days of presale
            return _balances[account];
        } else if (block.timestamp < timestamp2HoursAfterPresaleEnds) {
            return _balances[account].sub(_presaleBalance[account]);
        } else {
            uint soldInPresale = IPresale(presaleContract).totalBalance().div(2).mul(3); // mint 150% of presale for making flip token
            uint sharkSupply = IBEP20(stakingToken).totalSupply().sub(IBEP20(stakingToken).balanceOf(deadAddress));
            if (soldInPresale >= sharkSupply) {
                return _balances[account].sub(_presaleBalance[account]);
            }
            uint sharkNewMint = sharkSupply.sub(soldInPresale);
            if (sharkNewMint >= soldInPresale) {
                return _balances[account];
            }

            uint lockedRatio = (soldInPresale.sub(sharkNewMint)).mul(1e18).div(soldInPresale);
            uint lockedBalance = _presaleBalance[account].mul(lockedRatio).div(1e18);
            return _balances[account].sub(lockedBalance);
        }
    }

    function profitOf(address account) override public view returns (uint _usd, uint _shark, uint _bnb) {
        _usd = 0;
        _shark = 0;
        _bnb = helper.tvlInBNB(address(rewardsToken), earned(account));
    }

    function tvl() override public view returns (uint) {
        uint price = helper.tokenPriceInBNB(address(stakingToken));
        return _totalSupply.mul(price).div(1e18);
    }

    function apy() override public view returns(uint _usd, uint _shark, uint _bnb) {
        uint tokenDecimals = 1e18;
        uint __totalSupply = _totalSupply;
        if (__totalSupply == 0) {
            __totalSupply = tokenDecimals;
        }

        uint rewardPerTokenPerSecond = rewardRate.mul(tokenDecimals).div(__totalSupply);
        uint sharkPrice = helper.tokenPriceInBNB(address(stakingToken));
        uint flipPrice = helper.tvlInBNB(address(rewardsToken), 1e18);

        _usd = 0;
        _shark = 0;
        _bnb = rewardPerTokenPerSecond.mul(365 days).mul(flipPrice).div(sharkPrice);
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
        _totalSupply = _totalSupply.add(amount);
        _balances[_to] = _balances[_to].add(amount);
        IBEP20(stakingToken).safeTransferFrom(msg.sender, address(this), amount);
        
        if (amount > 0 && address(sharkReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            sharkReferral.recordReferral(msg.sender, _referrer);
        }
        
        emit Staked(_to, amount);
    }

    function deposit(uint _amount, address _referrer) override public {
        _deposit(_amount, msg.sender, _referrer);
    }
    
    function depositAll(address referrer) override external {
        deposit(IBEP20(stakingToken).balanceOf(msg.sender), referrer);
    }

    function withdraw(uint256 amount) override public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "amount");
        require(amount <= withdrawableBalanceOf(msg.sender), "locked");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        IBEP20(stakingToken).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
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
            reward = _flipToWBNB(reward);
            IBEP20(ROUTER.WETH()).safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function _flipToWBNB(uint amount) private returns(uint reward) {
        address wbnb = ROUTER.WETH();
        (uint rewardShark,) = ROUTER.removeLiquidity(
            address(stakingToken), wbnb,
            amount, 0, 0, address(this), block.timestamp);
        address[] memory path = new address[](2);
        path[0] = address(stakingToken);
        path[1] = wbnb;
        ROUTER.swapExactTokensForTokens(rewardShark, 0, path, address(this), block.timestamp);

        reward = IBEP20(wbnb).balanceOf(address(this));
    }

    function harvest() override external {}

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
    function setRewardsToken(address _rewardsToken) external onlyOwner {
        require(address(rewardsToken) == address(0), "set rewards token already");

        rewardsToken = _rewardsToken;
        IBEP20(_rewardsToken).safeApprove(address(ROUTER), uint(~0));
    }

    function setHelper(IStrategyHelper _helper) external onlyOwner {
        require(address(_helper) != address(0), "zero address");
        helper = _helper;
    }

    function setBoostRate(uint16 _boostRate) override public onlyOwner {
        require(_boostRate >= 10000, 'boost rate must be minimally 100%');
        boostRate = _boostRate;
    }

    function setStakePermission(address _address, bool permission) external onlyOwner {
        _stakePermission[_address] = permission;
    }

    function stakeTo(uint256 amount, address _to) external canStakeTo {
        _deposit(amount, _to, deadAddress);
        if (msg.sender == presaleContract) {
            _presaleBalance[_to] = _presaleBalance[_to].add(amount);
        }
    }

    function notifyRewardAmount(uint256 reward) override external onlyRewardsDistribution updateReward(address(0)) {
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
        uint _balance = IBEP20(rewardsToken).balanceOf(address(this));
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

    modifier canStakeTo() {
        require(_stakePermission[msg.sender], 'auth');
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}