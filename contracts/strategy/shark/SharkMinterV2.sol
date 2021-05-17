// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import '@pantherswap-libs/panther-swap-core/contracts/interfaces/IPantherPair.sol';

import "./interfaces/ISharkMinterV2.sol";
import "../../interfaces/IStakingRewards.sol";
import "../../v2/PriceCalculatorBSC.sol";
import "../../zap/ZapPanther.sol";

contract SharkMinterV2 is ISharkMinterV2, OwnableUpgradeable {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANTS ============= */

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // Binance WBNB
    address public constant SHARK = 0xf7321385a461C4490d5526D83E63c366b149cB15; // TODO: change to shark address
    address public constant SHARK_BNB = 0x7Bb89460599Dbf32ee3Aa50798BBcEae2A5F7f6a; // TODO: change (aka as Pancake LPs)
    address public constant SHARK_POOL = 0x5c58ce91d03DDB892ced37087e99660e48CA13d1; // TODO: change (aka as Shark pool) -> our shark pool?

    address public constant DEPLOYER = 0xe87f02606911223C2Cf200398FFAF353f60801F7;
    address private constant TIMELOCK = 0x85c9162A51E03078bdCd08D4232Bab13ed414cC3;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint public constant FEE_MAX = 10000;

    ZapPanther public constant zapBSC = ZapPanther(0xCBEC8e7AB969F6Eb873Df63d04b4eAFC353574b1);
    PriceCalculatorBSC public constant priceCalculator = PriceCalculatorBSC(0x542c06a5dc3f27e0fbDc9FB7BC6748f26d54dDb0);

    /* ========== STATE VARIABLES ========== */

    address public sharkChef;
    mapping(address => bool) private _minters;
    address public _deprecated_helper; // deprecated

    uint public PERFORMANCE_FEE;
    uint public override WITHDRAWAL_FEE_FREE_PERIOD;
    uint public override WITHDRAWAL_FEE;

    uint public override sharkPerProfitBNB;
    uint public sharkPerSharkBNBFlip;   // will be deprecated

    /* ========== MODIFIERS ========== */

    modifier onlyMinter {
        require(isMinter(msg.sender) == true, "SharkMinterV2: caller is not the minter");
        _;
    }

    modifier onlySharkChef {
        require(msg.sender == sharkChef, "SharkMinterV2: caller not the shark chef");
        _;
    }

    receive() external payable {}

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        WITHDRAWAL_FEE_FREE_PERIOD = 3 days;
        WITHDRAWAL_FEE = 50;
        PERFORMANCE_FEE = 3000;

        sharkPerProfitBNB = 5e18;
        sharkPerSharkBNBFlip = 6e18;

        IBEP20(SHARK).approve(SHARK_POOL, uint(-1));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function transferSharkOwner(address _owner) external onlyOwner {
        Ownable(SHARK).transferOwnership(_owner);
    }

    function setWithdrawalFee(uint _fee) external onlyOwner {
        require(_fee < 500, "wrong fee");
        // less 5%
        WITHDRAWAL_FEE = _fee;
    }

    function setPerformanceFee(uint _fee) external onlyOwner {
        require(_fee < 5000, "wrong fee");
        PERFORMANCE_FEE = _fee;
    }

    function setWithdrawalFeeFreePeriod(uint _period) external onlyOwner {
        WITHDRAWAL_FEE_FREE_PERIOD = _period;
    }

    function setMinter(address minter, bool canMint) external override onlyOwner {
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

    function setSharkChef(address _sharkChef) external onlyOwner {
        require(sharkChef == address(0), "SharkMinterV2: setSharkChef only once");
        sharkChef = _sharkChef;
    }

    /* ========== VIEWS ========== */

    function isMinter(address account) public view override returns (bool) {
        if (IBEP20(SHARK).getOwner() != address(this)) {
            return false;
        }
        return _minters[account];
    }

    function amountSharkToMint(uint bnbProfit) public view override returns (uint) {
        return bnbProfit.mul(sharkPerProfitBNB).div(1e18);
    }

    function amountSharkToMintForSharkBNB(uint amount, uint duration) public view override returns (uint) {
        return amount.mul(sharkPerSharkBNBFlip).mul(duration).div(365 days).div(1e18);
    }

    function withdrawalFee(uint amount, uint depositedAt) external view override returns (uint) {
        if (depositedAt.add(WITHDRAWAL_FEE_FREE_PERIOD) > block.timestamp) {
            return amount.mul(WITHDRAWAL_FEE).div(FEE_MAX);
        }
        return 0;
    }

    function performanceFee(uint profit) public view override returns (uint) {
        return profit.mul(PERFORMANCE_FEE).div(FEE_MAX);
    }

    /* ========== V1 FUNCTIONS ========== */

    function mintFor(address asset, uint _withdrawalFee, uint _performanceFee, address to, uint) external payable override onlyMinter {
        uint feeSum = _performanceFee.add(_withdrawalFee);
        _transferAsset(asset, feeSum);

        if (asset == SHARK) {
            IBEP20(SHARK).safeTransfer(DEAD, feeSum);
            return;
        }

        uint sharkBNBAmount = _zapAssetsToSharkBNB(asset);
        if (sharkBNBAmount == 0) return;

        IBEP20(SHARK_BNB).safeTransfer(SHARK_POOL, sharkBNBAmount);
        IStakingRewards(SHARK_POOL).notifyRewardAmount(sharkBNBAmount);

        (uint valueInBNB,) = priceCalculator.valueOfAsset(SHARK_BNB, sharkBNBAmount);
        uint contribution = valueInBNB.mul(_performanceFee).div(feeSum);
        uint mintShark = amountSharkToMint(contribution);
        if (mintShark == 0) return;
        _mint(mintShark, to);
    }

    // @dev will be deprecated
    function mintForSharkBNB(uint amount, uint duration, address to) external override onlyMinter {
        uint mintShark = amountSharkToMintForSharkBNB(amount, duration);
        if (mintShark == 0) return;
        _mint(mintShark, to);
    }

    /* ========== V2 FUNCTIONS ========== */

    function mint(uint amount) external override onlySharkChef {
        if (amount == 0) return;
        _mint(amount, address(this));
    }

    function safeSharkTransfer(address _to, uint _amount) external override onlySharkChef {
        if (_amount == 0) return;

        uint bal = IBEP20(SHARK).balanceOf(address(this));
        if (_amount <= bal) {
            IBEP20(SHARK).safeTransfer(_to, _amount);
        } else {
            IBEP20(SHARK).safeTransfer(_to, bal);
        }
    }

    // @dev should be called when determining mint in governance. Shark is transferred to the timelock contract.
    function mintGov(uint amount) external override onlyOwner {
        if (amount == 0) return;
        _mint(amount, TIMELOCK);
    }

    /* ========== PRIVATE FUNCTIONS ========== */

    function _transferAsset(address asset, uint amount) private {
        if (asset == address(0)) {
            // case) transferred BNB
            require(msg.value >= amount);
        } else {
            IBEP20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _zapAssetsToSharkBNB(address asset) private returns (uint) {
        if (asset != address(0) && IBEP20(asset).allowance(address(this), address(zapBSC)) == 0) {
            IBEP20(asset).safeApprove(address(zapBSC), uint(-1));
        }

        if (asset == address(0)) {
            zapBSC.zapIn{value : address(this).balance}(SHARK_BNB);
        }
        else if (keccak256(abi.encodePacked(IPantherPair(asset).symbol())) == keccak256("Panther-LP")) {
            zapBSC.zapOut(asset, IBEP20(asset).balanceOf(address(this)));

            IPantherPair pair = IPantherPair(asset);
            address token0 = pair.token0();
            address token1 = pair.token1();
            if (token0 == WBNB || token1 == WBNB) {
                address token = token0 == WBNB ? token1 : token0;
                if (IBEP20(token).allowance(address(this), address(zapBSC)) == 0) {
                    IBEP20(token).safeApprove(address(zapBSC), uint(-1));
                }
                zapBSC.zapIn{value : address(this).balance}(SHARK_BNB);
                zapBSC.zapInToken(token, IBEP20(token).balanceOf(address(this)), SHARK_BNB);
            } else {
                if (IBEP20(token0).allowance(address(this), address(zapBSC)) == 0) {
                    IBEP20(token0).safeApprove(address(zapBSC), uint(-1));
                }
                if (IBEP20(token1).allowance(address(this), address(zapBSC)) == 0) {
                    IBEP20(token1).safeApprove(address(zapBSC), uint(-1));
                }

                zapBSC.zapInToken(token0, IBEP20(token0).balanceOf(address(this)), SHARK_BNB);
                zapBSC.zapInToken(token1, IBEP20(token1).balanceOf(address(this)), SHARK_BNB);
            }
        }
        else {
            zapBSC.zapInToken(asset, IBEP20(asset).balanceOf(address(this)), SHARK_BNB);
        }

        return IBEP20(SHARK_BNB).balanceOf(address(this));
    }

    function _mint(uint amount, address to) private {
        BEP20 tokenSHARK = BEP20(SHARK);

        tokenSHARK.mint(amount);
        if (to != address(this)) {
            tokenSHARK.transfer(to, amount);
        }

        uint sharkForDev = amount.mul(15).div(100);
        tokenSHARK.mint(sharkForDev);
        IStakingRewards(SHARK_POOL).stakeTo(sharkForDev, DEPLOYER);
    }
}
