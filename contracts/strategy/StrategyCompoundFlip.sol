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

import '@pantherswap-libs/panther-swap-core/contracts/interfaces/IPantherPair.sol';
import "pantherswap-peripheral/contracts/interfaces/IPantherRouter02.sol";
import "./interfaces/IStrategy.sol";
import "./interfaces/IMasterChef.sol";
import "./shark/ISharkMinter.sol";
import "./interfaces/IPantherToken.sol";
import "./interfaces/IStrategyHelper.sol";
import "./shark/ISharkReferral.sol";

contract StrategyCompoundFLIP is IStrategy, Ownable {
    using SafeBEP20 for IBEP20;
    using SafeBEP20 for IPantherToken;
    using SafeMath for uint256;

    IPantherRouter02 private constant ROUTER = IPantherRouter02(0x24f7C33ae5f77e2A9ECeed7EA858B4ca2fa1B7eC);
    IPantherToken private constant PANTHER = IPantherToken(0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7);
    IBEP20 private constant WBNB = IBEP20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IMasterChef private constant PANTHER_MASTER_CHEF = IMasterChef(0x058451C62B96c594aD984370eDA8B6FD7197bbd4);

    address public keeper = 0x793074D9799DC3c6039F8056F1Ba884a73462051;

    uint public poolId;
    uint private constant DUST = 1000;
    IBEP20 public token;

    address private _token0;
    address private _token1;

    uint public totalShares;
    mapping (address => uint) private _shares;
    mapping (address => uint) private _principal;
    mapping (address => uint) public override depositedAt;

    ISharkMinter public override minter;
    IStrategyHelper public helper = IStrategyHelper(0xBd17385A935C8D77d15DB2E2C0e1BDE82fdFCe44);
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

    constructor(uint _pid) public {
        if (_pid != 0) {
            (address _token,,,) = PANTHER_MASTER_CHEF.poolInfo(_pid);
            setFlipToken(_token);
            poolId = _pid;
        }

        PANTHER.safeApprove(address(ROUTER), 0);
        PANTHER.safeApprove(address(ROUTER), uint(~0));
    }

    function setFlipToken(address _token) public onlyOwner {
        require(address(token) == address(0), 'flip token set already');
        token = IBEP20(_token);
        _token0 = IPantherPair(_token).token0();
        _token1 = IPantherPair(_token).token1();

        token.safeApprove(address(PANTHER_MASTER_CHEF), uint(~0));

        IBEP20(_token0).safeApprove(address(ROUTER), 0);
        IBEP20(_token0).safeApprove(address(ROUTER), uint(~0));
        IBEP20(_token1).safeApprove(address(ROUTER), 0);
        IBEP20(_token1).safeApprove(address(ROUTER), uint(~0));
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
            token.safeApprove(address(_minter), 0);
            token.safeApprove(address(_minter), uint(~0));
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
        (uint amount,) = PANTHER_MASTER_CHEF.userInfo(poolId, address(this));
        return token.balanceOf(address(this)).add(amount);
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

        return helper.profitOf(minter, address(token), _balance.sub(principal));
    }

    function tvl() override public view returns (uint) {
        return helper.tvl(address(token), balance());
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

    function earned(address account) override public view returns (uint) {
        if (balanceOf(account) >= principalOf(account) + DUST) {
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    function _depositTo(uint _amount, address _to, address _referrer) private {
        uint _pool = balance();
        uint _before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), _amount);
        uint _after = token.balanceOf(address(this));
        
        _amount = _after.sub(_before); // Additional check for deflationary tokens
        uint shares = 0;
        if (totalShares == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalShares)).div(_pool);
        }

        if (shares > 0 && address(sharkReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            sharkReferral.recordReferral(msg.sender, _referrer);
        }

        totalShares = totalShares.add(shares);
        _shares[_to] = _shares[_to].add(shares);
        _principal[_to] = _principal[_to].add(_amount);
        depositedAt[_to] = block.timestamp;

        PANTHER_MASTER_CHEF.deposit(poolId, _amount, 0xD9ebB6d95f3D8f3Da0b922bB05E0E79501C13554);
    }

    function deposit(uint _amount, address _referrer) override public {
        _depositTo(_amount, msg.sender, _referrer);
    }

    function depositAll(address _referrer) override external {
        deposit(token.balanceOf(msg.sender), _referrer);
    }

    function withdrawAll() override external {
        uint _withdraw = balanceOf(msg.sender);

        totalShares = totalShares.sub(_shares[msg.sender]);
        delete _shares[msg.sender];

        uint _before = token.balanceOf(address(this));
        PANTHER_MASTER_CHEF.withdraw(poolId, _withdraw);
        uint _after = token.balanceOf(address(this));
        _withdraw = _after.sub(_before);

        uint principal = _principal[msg.sender];
        uint depositTimestamp = depositedAt[msg.sender];
        delete _principal[msg.sender];
        delete depositedAt[msg.sender];

        if (address(minter) != address(0) && minter.isMinter(address(this)) && _withdraw > principal) {
            uint profit = _withdraw.sub(principal);
            uint withdrawalFee = minter.withdrawalFee(_withdraw, depositTimestamp);
            uint performanceFee = minter.performanceFee(profit);

            minter.mintFor(address(token), withdrawalFee, performanceFee, msg.sender, depositTimestamp, boostRate);

            token.safeTransfer(msg.sender, _withdraw.sub(withdrawalFee).sub(performanceFee));
        } else {
            token.safeTransfer(msg.sender, _withdraw);
        }
    }

    function harvest() override external {
        require(msg.sender == keeper || msg.sender == owner(), 'auth');

        PANTHER_MASTER_CHEF.withdraw(poolId, 0);
        uint pantherAmount = PANTHER.balanceOf(address(this));
        uint pantherForToken0 = pantherAmount.div(2);
        pantherToToken(_token0, pantherForToken0);
        pantherToToken(_token1, pantherAmount.sub(pantherForToken0));
        uint liquidity = generateFlipToken();
        PANTHER_MASTER_CHEF.deposit(poolId, liquidity, 0xD9ebB6d95f3D8f3Da0b922bB05E0E79501C13554);
    }

    function pantherToToken(address _token, uint amount) private {
        if (_token == address(PANTHER)) return;
        address[] memory path;
        if (_token == address(WBNB)) {
            path = new address[](2);
            path[0] = address(PANTHER);
            path[1] = _token;
        } else {
            path = new address[](3);
            path[0] = address(PANTHER);
            path[1] = address(WBNB);
            path[2] = _token;
        }

        ROUTER.swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp);
    }

    function generateFlipToken() private returns(uint liquidity) {
        uint amountADesired = IBEP20(_token0).balanceOf(address(this));
        uint amountBDesired = IBEP20(_token1).balanceOf(address(this));

        (,,liquidity) = ROUTER.addLiquidity(_token0, _token1, amountADesired, amountBDesired, 0, 0, address(this), block.timestamp);

        // send dust
        IBEP20(_token0).safeTransfer(msg.sender, IBEP20(_token0).balanceOf(address(this)));
        IBEP20(_token1).safeTransfer(msg.sender, IBEP20(_token1).balanceOf(address(this)));
    }

    function withdraw(uint256) override external {
        revert("Use withdrawAll");
    }

    function getReward() override external {
        revert("Use withdrawAll");
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