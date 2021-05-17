// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./interfaces/IStrategyV2.sol";
import "../strategy/shark/ISharkMinter.sol";
import "../strategy/shark/interfaces/ISharkChef.sol";



import "./PriceCalculatorBSC.sol";
import "../pool/SharkPool.sol";
import "../library/SafeDecimal.sol";


contract DashboardBSC is OwnableUpgradeable {
    using SafeMath for uint;
    using SafeDecimal for uint;

    PriceCalculatorBSC public constant priceCalculator = PriceCalculatorBSC(0xB528d09221C301E9D9F51f41FdC2f36639C570De);

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant SHARK = 0xf7321385a461C4490d5526D83E63c366b149cB15;
    address public constant PANTHER = 0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7;
    address public constant VaultPantherToPanther = 0xF33e3f7Ec6828ad5B1543E16497249c7248Ac65e;

    ISharkChef private constant sharkChef = ISharkChef(0x40e31876c4322bd033BAb028474665B12c4d04CE);
    SharkPool private constant sharkPool = SharkPool(0xCADc8CB26c8C7cB46500E61171b5F27e9bd7889D);

    /* ========== STATE VARIABLES ========== */

    mapping(address => PoolConstant.PoolTypes) public poolTypes;
    mapping(address => uint) public pancakePoolIds;
    mapping(address => bool) public perfExemptions;

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __Ownable_init();
    }

    /* ========== Restricted Operation ========== */

    function setPoolType(address pool, PoolConstant.PoolTypes poolType) public onlyOwner {
        poolTypes[pool] = poolType;
    }

    function setPancakePoolId(address pool, uint pid) public onlyOwner {
        pancakePoolIds[pool] = pid;
    }

    function setPerfExemption(address pool, bool exemption) public onlyOwner {
        perfExemptions[pool] = exemption;
    }

    /* ========== View Functions ========== */

    function poolTypeOf(address pool) public view returns (PoolConstant.PoolTypes) {
        return poolTypes[pool];
    }

    /* ========== Utilization Calculation ========== */

    function utilizationOfPool(address pool) public view returns (uint liquidity, uint utilized) {
        if (poolTypes[pool] == PoolConstant.PoolTypes.Venus) {
            // return VaultVenus(payable(pool)).getUtilizationInfo();
            return (0, 0);
        }
        return (0, 0);
    }

    /* ========== Profit Calculation ========== */

    function calculateProfit(address pool, address account) public view returns (uint profit, uint profitInBNB) {
        PoolConstant.PoolTypes poolType = poolTypes[pool];
        profit = 0;
        profitInBNB = 0;

        if (poolType == PoolConstant.PoolTypes.SharkStake) {
            // profit as bnb
            (profit,) = priceCalculator.valueOfAsset(address(sharkPool.rewardsToken()), sharkPool.earned(account));
            profitInBNB = profit;
        }
        else if (poolType == PoolConstant.PoolTypes.Shark) {
            // profit as shark
            profit = sharkChef.pendingShark(pool, account);
            (profitInBNB,) = priceCalculator.valueOfAsset(SHARK, profit);
        }
        else if (poolType == PoolConstant.PoolTypes.PantherStake || poolType == PoolConstant.PoolTypes.FlipToFlip || poolType == PoolConstant.PoolTypes.Venus) {
            // profit as underlying
            IStrategy strategy = IStrategy(pool);
            profit = strategy.earned(account);
            (profitInBNB,) = priceCalculator.valueOfAsset(strategy.stakingToken(), profit);
        }
        else if (poolType == PoolConstant.PoolTypes.FlipToPanther || poolType == PoolConstant.PoolTypes.SharkBNB) {
            // profit as cake
            IStrategy strategy = IStrategy(pool);
            profit = strategy.earned(account).mul(IStrategy(strategy.rewardsToken()).priceShare()).div(1e18);
            (profitInBNB,) = priceCalculator.valueOfAsset(PANTHER, profit);
        }
    }

    function profitOfPool(address pool, address account) public view returns (uint profit, uint shark) {
        (uint profitCalculated, uint profitInBNB) = calculateProfit(pool, account);
        profit = profitCalculated;
        shark = 0;

        if (!perfExemptions[pool]) {
            IStrategy strategy = IStrategy(pool);
            if (address(strategy.minter()) != address(0)) {
                profit = profit.mul(70).div(100);
                shark = ISharkMinter(strategy.minter()).amountSharkToMint(profitInBNB.mul(30).div(100));
            }

            if (strategy.sharkChef() != address(0)) {
                shark = shark.add(sharkChef.pendingShark(pool, account));
            }
        }
    }

    /* ========== TVL Calculation ========== */

    function tvlOfPool(address pool) public view returns (uint tvl) {
        if (poolTypes[pool] == PoolConstant.PoolTypes.SharkStake) {
            (, tvl) = priceCalculator.valueOfAsset(address(sharkPool.stakingToken()), sharkPool.balance());
        }
        else {
            IStrategy strategy = IStrategy(pool);
            (, tvl) = priceCalculator.valueOfAsset(strategy.stakingToken(), strategy.balance());

            if (strategy.rewardsToken() == VaultPantherToPanther) {
                IStrategy rewardsToken = IStrategy(strategy.rewardsToken());
                uint rewardsInPanther = rewardsToken.balanceOf(pool).mul(rewardsToken.priceShare()).div(1e18);
                (, uint rewardsInUSD) = priceCalculator.valueOfAsset(address(PANTHER), rewardsInPanther);
                tvl = tvl.add(rewardsInUSD);
            }
        }
    }

    /* ========== Pool Information ========== */

    function infoOfPool(address pool, address account) public view returns (PoolConstant.PoolInfoBSC memory) {
        PoolConstant.PoolInfoBSC memory poolInfo;

        IStrategy strategy = IStrategy(pool);
        (uint pBASE, uint pSHARK) = profitOfPool(pool, account);
        (uint liquidity, uint utilized) = utilizationOfPool(pool);

        poolInfo.pool = pool;
        poolInfo.balance = strategy.balanceOf(account);
        poolInfo.principal = strategy.principalOf(account);
        poolInfo.available = strategy.withdrawableBalanceOf(account);
        poolInfo.tvl = tvlOfPool(pool);
        poolInfo.utilized = utilized;
        poolInfo.liquidity = liquidity;
        poolInfo.pBASE = pBASE;
        poolInfo.pSHARK = pSHARK;

        PoolConstant.PoolTypes poolType = poolTypeOf(pool);
        if (poolType != PoolConstant.PoolTypes.SharkStake && address(strategy.minter()) != address(0)) {
            ISharkMinter minter = ISharkMinter(strategy.minter());
            poolInfo.depositedAt = strategy.depositedAt(account);
            poolInfo.feeDuration = minter.WITHDRAWAL_FEE_FREE_PERIOD();
            poolInfo.feePercentage = minter.WITHDRAWAL_FEE();
        }
        return poolInfo;
    }

    function poolsOf(address account, address[] memory pools) public view returns (PoolConstant.PoolInfoBSC[] memory) {
        PoolConstant.PoolInfoBSC[] memory results = new PoolConstant.PoolInfoBSC[](pools.length);
        for (uint i = 0; i < pools.length; i++) {
            results[i] = infoOfPool(pools[i], account);
        }
        return results;
    }

    /* ========== Portfolio Calculation ========== */

    function stakingTokenValueInUSD(address pool, address account) internal view returns (uint tokenInUSD) {
        PoolConstant.PoolTypes poolType = poolTypes[pool];

        address stakingToken;
        if (poolType == PoolConstant.PoolTypes.SharkStake) {
            stakingToken = SHARK;
        } else {
            stakingToken = IStrategy(pool).stakingToken();
        }

        if (stakingToken == address(0)) return 0;
        (, tokenInUSD) = priceCalculator.valueOfAsset(stakingToken, IStrategy(pool).principalOf(account));
    }

    function portfolioOfPoolInUSD(address pool, address account) internal view returns (uint) {
        uint tokenInUSD = stakingTokenValueInUSD(pool, account);
        (, uint profitInBNB) = calculateProfit(pool, account);
        uint profitInSHARK = 0;

        if (!perfExemptions[pool]) {
            IStrategy strategy = IStrategy(pool);
            if (address(strategy.minter()) != address(0)) {
                profitInBNB = profitInBNB.mul(70).div(100);
                profitInSHARK = ISharkMinter(strategy.minter()).amountSharkToMint(profitInBNB.mul(30).div(100));
            }

            if ((poolTypes[pool] == PoolConstant.PoolTypes.Shark || poolTypes[pool] == PoolConstant.PoolTypes.SharkBNB
            || poolTypes[pool] == PoolConstant.PoolTypes.FlipToFlip)
                && strategy.sharkChef() != address(0)) {
                profitInSHARK = profitInSHARK.add(sharkChef.pendingShark(pool, account));
            }
        }

        (, uint profitBNBInUSD) = priceCalculator.valueOfAsset(WBNB, profitInBNB);
        (, uint profitSHARKInUSD) = priceCalculator.valueOfAsset(SHARK, profitInSHARK);
        return tokenInUSD.add(profitBNBInUSD).add(profitSHARKInUSD);
    }

    function portfolioOf(address account, address[] memory pools) public view returns (uint deposits) {
        deposits = 0;
        for (uint i = 0; i < pools.length; i++) {
            deposits = deposits.add(portfolioOfPoolInUSD(pools[i], account));
        }
    }
}
