// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";

import "pantherswap-peripheral/contracts/interfaces/IPantherRouter02.sol";
import '@pantherswap-libs/panther-swap-core/contracts/interfaces/IPantherPair.sol';
import '@pantherswap-libs/panther-swap-core/contracts/interfaces/IPantherFactory.sol';

abstract contract PantherSwap {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    IPantherRouter02 private constant ROUTER = IPantherRouter02(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F); // TODO: get from PANTHER after AMM
    IPantherFactory private constant factory = IPantherFactory(0xBCfCcbde45cE874adCB698cC183deBcF17952812); // TODO: get from PANTHER after AMM

    address internal constant panther = 0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7; // PANTHER
    address private constant _shark = 0xf7321385a461C4490d5526D83E63c366b149cB15; // SHARK
    address private constant _wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function sharkBNBFlipToken() internal view returns(address) {
        return factory.getPair(_shark, _wbnb);
    }

    function tokenToSharkBNB(address token, uint amount) internal returns(uint flipAmount) {
        if (token == panther) {
            flipAmount = _cakeToSharkBNBFlip(amount);
        } else {
            // flip
            flipAmount = _flipToSharkBNBFlip(token, amount);
        }
    }

    function _cakeToSharkBNBFlip(uint amount) private returns(uint flipAmount) {
        swapToken(panther, amount.div(2), _shark);
        swapToken(panther, amount.sub(amount.div(2)), _wbnb);

        flipAmount = generateFlipToken();
    }

    function _flipToSharkBNBFlip(address token, uint amount) private returns(uint flipAmount) {
        IPantherPair pair = IPantherPair(token);
        address _token0 = pair.token0();
        address _token1 = pair.token1();
        IBEP20(token).safeApprove(address(ROUTER), 0);
        IBEP20(token).safeApprove(address(ROUTER), amount);
        ROUTER.removeLiquidity(_token0, _token1, amount, 0, 0, address(this), block.timestamp);
        if (_token0 == _wbnb) {
            swapToken(_token1, IBEP20(_token1).balanceOf(address(this)), _shark);
            flipAmount = generateFlipToken();
        } else if (_token1 == _wbnb) {
            swapToken(_token0, IBEP20(_token0).balanceOf(address(this)), _shark);
            flipAmount = generateFlipToken();
        } else {
            swapToken(_token0, IBEP20(_token0).balanceOf(address(this)), _shark);
            swapToken(_token1, IBEP20(_token1).balanceOf(address(this)), _wbnb);
            flipAmount = generateFlipToken();
        }
    }

    function swapToken(address _from, uint _amount, address _to) private {
        if (_from == _to) return;

        address[] memory path;
        if (_from == _wbnb || _to == _wbnb) {
            path = new address[](2);
            path[0] = _from;
            path[1] = _to;
        } else {
            path = new address[](3);
            path[0] = _from;
            path[1] = _wbnb;
            path[2] = _to;
        }

        IBEP20(_from).safeApprove(address(ROUTER), 0);
        IBEP20(_from).safeApprove(address(ROUTER), _amount);
        ROUTER.swapExactTokensForTokens(_amount, 0, path, address(this), block.timestamp);
    }

    function generateFlipToken() private returns(uint liquidity) {
        uint amountADesired = IBEP20(_shark).balanceOf(address(this));
        uint amountBDesired = IBEP20(_wbnb).balanceOf(address(this));

        IBEP20(_shark).safeApprove(address(ROUTER), 0);
        IBEP20(_shark).safeApprove(address(ROUTER), amountADesired);
        IBEP20(_wbnb).safeApprove(address(ROUTER), 0);
        IBEP20(_wbnb).safeApprove(address(ROUTER), amountBDesired);

        (,,liquidity) = ROUTER.addLiquidity(_shark, _wbnb, amountADesired, amountBDesired, 0, 0, address(this), block.timestamp);

        // send dust
        IBEP20(_shark).transfer(msg.sender, IBEP20(_shark).balanceOf(address(this)));
        IBEP20(_wbnb).transfer(msg.sender, IBEP20(_wbnb).balanceOf(address(this)));
    }
}