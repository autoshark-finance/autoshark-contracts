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

import "./interfaces/IStrategy.sol";
import "./interfaces/IMasterChef.sol";
import "./shark/ISharkMinter.sol";
import "./interfaces/IStrategyHelper.sol";
import "./shark/ISharkReferral.sol";

contract SharkBNBPool is IStrategy, Ownable {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint256;

    IBEP20 private constant SHARK = IBEP20(0xf7321385a461C4490d5526D83E63c366b149cB15); // SHARK
    IBEP20 private constant PANTHER = IBEP20(0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7); // PANTHER
    IBEP20 private constant WBNB = IBEP20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    IBEP20 public token;
    uint private constant DUST = 1000;

    uint public totalShares;
    mapping (address => uint) private _shares;
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
    // Added SHARK minting boost rate: 150%
    uint16 public boostRate = 15000;

    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);

    constructor() public {
    }

    function setFlipToken(address _token) public onlyOwner {
        require(address(token) == address(0), 'flip token set already');
        token = IBEP20(_token);
    }

    function setMinter(ISharkMinter _minter) external onlyOwner {
        minter = _minter;
        if (address(_minter) != address(0)) {
            token.safeApprove(address(_minter), 0);
            token.safeApprove(address(_minter), uint(~0));
        }
    }

    function setHelper(IStrategyHelper _helper) external onlyOwner {
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
        return token.balanceOf(address(this));
    }

    function balanceOf(address account) override public view returns(uint) {
        return _shares[account];
    }

    function withdrawableBalanceOf(address account) override public view returns (uint) {
        return _shares[account];
    }

    function sharesOf(address account) public view returns (uint) {
        return _shares[account];
    }

    function principalOf(address account) override public view returns (uint) {
        return _shares[account];
    }

    function earned(address account) public override view returns (uint) {
        if (balanceOf(account) >= principalOf(account) + DUST) {
            return balanceOf(account).sub(principalOf(account));
        } else {
            return 0;
        }
    }

    function profitOf(address account) override public view returns (uint _usd, uint _shark, uint _bnb) {
        if (address(minter) == address(0) || !minter.isMinter(address(this))) {
            return (0, 0, 0);
        }
        return (0, minter.amountSharkToMintForSharkBNB(balanceOf(account), block.timestamp.sub(depositedAt[account])), 0);
    }

    function tvl() override public view returns (uint) {
        return helper.tvl(address(token), balance());
    }

    function apy() override public view returns(uint _usd, uint _shark, uint _bnb) {
        if (address(minter) == address(0) || !minter.isMinter(address(this))) {
            return (0, 0, 0);
        }

        uint amount = 1e18;
        uint shark = minter.amountSharkToMintForSharkBNB(amount, 365 days);
        uint _tvl = helper.tvlInBNB(address(token), amount);
        uint sharkPrice = helper.tokenPriceInBNB(address(SHARK));

        return (shark.mul(sharkPrice).div(_tvl), 0, 0);
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

    function depositTo(uint256, uint256 _amount, address _to, address _referrer) external {
        require(msg.sender == 0x641414e2a04c8f8EbBf49eD47cc87dccbA42BF07 || msg.sender == owner(), "not presale contract");
        _depositTo(_amount, _to, _referrer);
    }

    function _depositTo(uint _amount, address _to, address _referrer) private {
        token.safeTransferFrom(msg.sender, address(this), _amount);

        uint amount = _shares[_to];
        if (amount != 0 && depositedAt[_to] != 0) {
            uint duration = block.timestamp.sub(depositedAt[_to]);
            mintShark(amount, duration);
        }

        // shares are also the same as amount, after it has been taxed
        if (_amount > 0 && address(sharkReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            sharkReferral.recordReferral(msg.sender, _referrer);
        }

        totalShares = totalShares.add(_amount);
        _shares[_to] = _shares[_to].add(_amount);
        depositedAt[_to] = block.timestamp;
    }

    function deposit(uint _amount, address _referrer) override public {
        _depositTo(_amount, msg.sender, _referrer);
    }

    function depositAll(address referrer) override external {
        deposit(token.balanceOf(msg.sender), referrer);
    }

    function withdrawAll() override external {
        uint _withdraw = balanceOf(msg.sender);

        totalShares = totalShares.sub(_shares[msg.sender]);
        delete _shares[msg.sender];
        uint depositTimestamp = depositedAt[msg.sender];
        delete depositedAt[msg.sender];

        uint mintedShark = mintShark(_withdraw, block.timestamp.sub(depositTimestamp));
        payReferralCommission(msg.sender, mintedShark);

        token.safeTransfer(msg.sender, _withdraw);
    }

    function mintShark(uint amount, uint duration) private returns(uint mintAmount) {
        if (address(minter) == address(0) || !minter.isMinter(address(this))) {
            return 0;
        }

        mintAmount = minter.mintForSharkBNB(amount, duration, msg.sender);
    }

    function harvest() override external {

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