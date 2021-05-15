// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

/*
  ___ _  _   _   ___ _  __  _ _ 
 / __| || | /_\ | _ \ |/ / | | |
 \__ \ __ |/ _ \|   / ' <  |_|_|
 |___/_||_/_/ \_\_|_\_|\_\ (_|_)
*/

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";

import "pantherswap-peripheral/contracts/interfaces/IPantherRouter02.sol";
import '@pantherswap-libs/panther-swap-core/contracts/interfaces/IPantherPair.sol';

contract ZapPanther is Ownable {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    address private constant PANTHER = 0x1f546aD641B56b86fD9dCEAc473d1C7a357276B7; // PANTHER
    address private constant SHARK = 0xf7321385a461C4490d5526D83E63c366b149cB15; // SHARK
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address private constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address private constant DAI = 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3;
    address private constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address private constant VAI = 0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7;

    IPantherRouter02 private constant ROUTER = IPantherRouter02(0x24f7C33ae5f77e2A9ECeed7EA858B4ca2fa1B7eC);

    mapping(address => bool) private notFlip;
    address[] public tokens;

    receive() external payable {}

    constructor() public {
        setNotFlip(PANTHER);
        setNotFlip(SHARK);
        setNotFlip(WBNB);
        setNotFlip(BUSD);
        setNotFlip(USDT);
        setNotFlip(DAI);
        setNotFlip(USDC);
        setNotFlip(VAI);
    }

    function isFlip(address _address) public view returns(bool) {
        return !notFlip[_address];
    }

    function zapInToken(address _from, uint amount, address _to) external {
        IBEP20(_from).safeTransferFrom(msg.sender, address(this), amount);
        _approveTokenIfNeeded(_from);

        if (isFlip(_to)) {
            IPantherPair pair = IPantherPair(_to);
            address token0 = pair.token0();
            address token1 = pair.token1();
            if (_from == token0 || _from == token1) {
                // swap half amount for other
                address other = _from == token0 ? token1 : token0;
                _approveTokenIfNeeded(other);
                uint sellAmount = amount.div(2);
                uint otherAmount = _swap(_from, sellAmount, other, address(this));
                ROUTER.addLiquidity(_from, other, amount.sub(sellAmount), otherAmount, 0, 0, msg.sender, block.timestamp);
            } else {
                uint bnbAmount = _swapTokenForBNB(_from, amount, address(this));
                _bnbToFlip(_to, bnbAmount, msg.sender);
            }
        } else {
            _swap(_from, amount, _to, msg.sender);
        }
    }

    function zapIn(address _to) external payable {
        _bnbToFlip(_to, msg.value, msg.sender);
    }

    function _bnbToFlip(address flip, uint amount, address receiver) private {
        if (!isFlip(flip)) {
            _swapBNBForToken(flip, amount, receiver);
        } else {
            // flip
            IPantherPair pair = IPantherPair(flip);
            address token0 = pair.token0();
            address token1 = pair.token1();
            if (token0 == WBNB || token1 == WBNB) {
                address token = token0 == WBNB ? token1 : token0;
                uint swapValue = amount.div(2);
                uint tokenAmount = _swapBNBForToken(token, swapValue, address(this));

                _approveTokenIfNeeded(token);
                ROUTER.addLiquidityETH{ value: amount.sub(swapValue) }(token, tokenAmount, 0, 0, receiver, block.timestamp);
            } else {
                uint swapValue = amount.div(2);
                uint token0Amount = _swapBNBForToken(token0, swapValue, address(this));
                uint token1Amount = _swapBNBForToken(token1, amount.sub(swapValue), address(this));
                _approveTokenIfNeeded(token0);
                _approveTokenIfNeeded(token1);
                ROUTER.addLiquidity(token0, token1, token0Amount, token1Amount, 0, 0, receiver, block.timestamp);
            }
        }
    }

    function zapOut(address _from, uint amount) external {
        IBEP20(_from).safeTransferFrom(msg.sender, address(this), amount);
        _approveTokenIfNeeded(_from);

        if (!isFlip(_from)) {
            _swapTokenForBNB(_from, amount, msg.sender);
        } else {
            IPantherPair pair = IPantherPair(_from);
            address token0 = pair.token0();
            address token1 = pair.token1();
            if (token0 == WBNB || token1 == WBNB) {
                ROUTER.removeLiquidityETH(token0!=WBNB?token0:token1, amount, 0, 0, msg.sender, block.timestamp);
            } else {
                ROUTER.removeLiquidity(token0, token1, amount, 0, 0, msg.sender, block.timestamp);
            }
        }
    }

    function _approveTokenIfNeeded(address token) private {
        if (IBEP20(token).allowance(address(this), address(ROUTER)) == 0) {
            IBEP20(token).safeApprove(address(ROUTER), uint(~0));
        }
    }

    function _swapBNBForToken(address token, uint value, address receiver) private returns (uint){
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = token;
        uint[] memory amounts = ROUTER.swapExactETHForTokens{ value: value }(0, path, receiver, block.timestamp);
        return amounts[1];
    }

    function _swap(address _from, uint amount, address _to, address receiver) private returns(uint) {
        if (_from == WBNB) {
            return _swapWBNBForToken(_to, amount, receiver);
        } else if (_to == WBNB) {
            return _swapTokenForWBNB(_from, amount, receiver);
        } else {
            return _swapTokenForToken(_from, amount, _to, receiver);
        }
    }

    function _swapWBNBForToken(address token, uint amount, address receiver) private returns (uint){
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = token;
        uint[] memory amounts = ROUTER.swapExactTokensForTokens(amount, 0, path, receiver, block.timestamp);
        return amounts[1];
    }

    function _swapTokenForBNB(address token, uint amount, address receiver) private returns (uint) {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WBNB;
        uint[] memory amounts = ROUTER.swapExactTokensForETH(amount, 0, path, receiver, block.timestamp);
        return amounts[1];
    }

    function _swapTokenForWBNB(address token, uint amount, address receiver) private returns (uint) {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WBNB;

        uint[] memory amounts = ROUTER.swapExactTokensForTokens(amount, 0, path, receiver, block.timestamp);
        return amounts[1];
    }

    function _swapTokenForToken(address from, uint amount, address to, address receiver) private returns(uint) {
        address[] memory path = new address[](3);
        path[0] = from;
        path[1] = WBNB;
        path[2] = to;

        uint[] memory amounts = ROUTER.swapExactTokensForTokens(amount, 0, path, receiver, block.timestamp);
        return amounts[2];
    }

    // ------------------------------------------ RESTRICTED
    function setNotFlip(address token) public onlyOwner {
        bool needPush = notFlip[token] == false;
        notFlip[token] = true;
        if (needPush) {
            tokens.push(token);
        }
    }

    function removeToken(uint i) external onlyOwner {
        address token = tokens[i];
        notFlip[token] = false;
        tokens[i] = tokens[tokens.length-1];
        tokens.pop();
    }

    function sweep() external onlyOwner {
        for (uint i=0; i<tokens.length; i++) {
            address token = tokens[i];
            if (token == address(0)) continue;
            uint amount = IBEP20(token).balanceOf(address(this));
            if (amount > 0) {
                _swapTokenForBNB(token, amount, owner());
            }
        }
    }

    function withdraw(address token) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(address(this).balance);
            return;
        }

        IBEP20(token).transfer(owner(), IBEP20(token).balanceOf(address(this)));
    }
}