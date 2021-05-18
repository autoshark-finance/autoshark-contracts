// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "./ISharkMinter.sol";
import "../../interfaces/IStakingRewards.sol";
import "./PantherSwap.sol";
import "../../strategy/interfaces/IStrategyHelper.sol";

contract SharkMinter is ISharkMinter, Ownable, PantherSwap {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    BEP20 private constant shark = BEP20(0xf7321385a461C4490d5526D83E63c366b149cB15); // SHARK
    address public constant dev = 0xD9ebB6d95f3D8f3Da0b922bB05E0E79501C13554;
    IBEP20 private constant WBNB = IBEP20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    uint public override WITHDRAWAL_FEE_FREE_PERIOD = 3 days;
    uint public override WITHDRAWAL_FEE = 50;
    uint public constant FEE_MAX = 10000;

    uint public PERFORMANCE_FEE = 3000; // 30%

    uint public override sharkPerProfitBNB;
    uint public sharkPerSharkBNBFlip;

    address public constant sharkPool = 0x5F7de53f6dF023d1c64046e9C4A2b8a1a0EC95C6;
    IStrategyHelper public helper = IStrategyHelper(0xBd17385A935C8D77d15DB2E2C0e1BDE82fdFCe44);

    mapping (address => bool) private _minters;

    modifier onlyMinter {
        require(isMinter(msg.sender) == true, "not minter");
        _;
    }

    constructor() public {
        sharkPerProfitBNB = 10e18;
        sharkPerSharkBNBFlip = 6e18;
        shark.approve(sharkPool, uint(~0));
    }

    function transferSharkOwner(address _owner) external onlyOwner {
        Ownable(address(shark)).transferOwnership(_owner);
    }

    function setWithdrawalFee(uint _fee) external onlyOwner {
        require(_fee < 500, "wrong fee");   // less 5%
        WITHDRAWAL_FEE = _fee;
    }

    function setPerformanceFee(uint _fee) external onlyOwner {
        require(_fee < 5000, "wrong fee");
        PERFORMANCE_FEE = _fee;
    }

    function setWithdrawalFeeFreePeriod(uint _period) external onlyOwner {
        WITHDRAWAL_FEE_FREE_PERIOD = _period;
    }

    function setMinter(address minter, bool canMint) external onlyOwner {
        if (canMint) {
            _minters[minter] = canMint;
        } else {
            delete _minters[minter];
        }
    }

    function setSharkPerProfitBNB(uint _ratio) external onlyOwner {
        sharkPerProfitBNB = _ratio;
    }

    function setSharkPerSharkBNBFlip(uint _sharkPerSharkBNBFlip) external onlyOwner {
        sharkPerSharkBNBFlip = _sharkPerSharkBNBFlip;
    }

    function setHelper(IStrategyHelper _helper) external onlyOwner {
        require(address(_helper) != address(0), "zero address");
        helper = _helper;
    }

    function isMinter(address account) override view public returns(bool) {
        if (shark.getOwner() != address(this)) {
            return false;
        }

        if (block.timestamp < 1605585600) { // 12:00 SGT 17th November 2020
            return false;
        }
        return _minters[account];
    }

    function amountSharkToMint(uint bnbProfit) override view public returns(uint) {
        return bnbProfit.mul(sharkPerProfitBNB).div(1e18);
    }

    function amountSharkToMintForSharkBNB(uint amount, uint duration) override view public returns(uint) {
        return amount.mul(sharkPerSharkBNBFlip).mul(duration).div(365 days).div(1e18);
    }

    function withdrawalFee(uint amount, uint depositedAt) override view external returns(uint) {
        if (depositedAt.add(WITHDRAWAL_FEE_FREE_PERIOD) > block.timestamp) {
            return amount.mul(WITHDRAWAL_FEE).div(FEE_MAX);
        }
        return 0;
    }

    function performanceFee(uint profit) override view public returns(uint) {
        return profit.mul(PERFORMANCE_FEE).div(FEE_MAX);
    }

    function mintFor(address flip, uint _withdrawalFee, uint _performanceFee, address to, uint, uint boostRate) override external onlyMinter returns(uint mintAmount) {
        uint feeSum = _performanceFee.add(_withdrawalFee);
        IBEP20(flip).safeTransferFrom(msg.sender, address(this), feeSum);

        uint sharkBNBAmount = tokenToSharkBNB(flip, IBEP20(flip).balanceOf(address(this)));
        address flipToken = sharkBNBFlipToken();
        IBEP20(flipToken).safeTransfer(sharkPool, sharkBNBAmount);
        IStakingRewards(sharkPool).notifyRewardAmount(sharkBNBAmount);

        uint contribution = helper.tvlInBNB(flipToken, sharkBNBAmount).mul(_performanceFee).div(feeSum);
        uint mintShark = amountSharkToMint(contribution).mul(boostRate).div(10000);
        mint(mintShark, to);
        mintAmount = mintShark;
    }

    function mintForSharkBNB(uint amount, uint duration, address to) override external onlyMinter returns(uint mintAmount) {
        uint mintShark = amountSharkToMintForSharkBNB(amount, duration);
        mintAmount = mintShark;
        if (mintShark == 0) {
            return mintAmount;
        }
        mint(mintShark, to);
    }

    function mint(uint amount, address to) override public onlyMinter {
        shark.mint(amount);
        shark.transfer(to, amount);

        uint sharkForDev = amount.mul(15).div(100);
        shark.mint(sharkForDev);
        IStakingRewards(sharkPool).stakeTo(sharkForDev, dev);
    }
}