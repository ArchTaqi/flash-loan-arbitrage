// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./uniswap/IUniswapV2Router.sol";
import "./uniswap/v3/ISwapRouter.sol";

import "./dodo/IDODO.sol";

import "./interfaces/IFlashloan.sol";

import "./base/DodoBase.sol";
import "./dodo/IDODOProxy.sol";
import "./base/FlashloanValidation.sol";
import "./base/Withdraw.sol";

import "./libraries/Part.sol";
import "./libraries/RouteUtils.sol";

contract Flashloan is IFlashloan, DodoBase, FlashloanValidation, Withdraw {

    // safematch is deprecated, use signedmatch now.
    // using SignedMath for uint256;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Events
    event SentProfit(address recipient, uint256 profit);
    event SwapFinished(address token, uint256 amount);


    /**
     * @dev Indicates a flash loan transaction with DODO protocol
     * @param params Struct containing parameter for the flash loan
     */
    function executeFlashloan(
        FlashParams memory params
    ) external checkParams(params) {
        // Encode the callback data to be send in the flash loan execution
        // this includes sender's address, flash loan pool, loan amount, and routes for token swaps.
        bytes memory data = abi.encode(
            FlashParams({
                flashLoanPool: params.flashLoanPool,
                loanAmount: params.loanAmount,
                routes: params.routes
            })
        );

        address loanToken = RouteUtils.getInitialToken(params.routes[0]);
        console.log(
            "Contract balance before borrow",
            IERC20(loanToken).balanceOf(address(this))
        );

        // equals when we are borrowing the base token.
        uint256 baseAmount = IDODO(params.flashLoanPool)._BASE_TOKEN() ==
            loanToken
            ? params.loanAmount
            : 0;
        IDODO(params.flashLoanPool).Flashloan(
            baseAmount,
            quoteAmount,
            adress(this),
            data
        );
    }




    function dodoFlashLoan(FlashParams memory params)
        external
        checkParams(params)
    {
        bytes memory data = abi.encode(
            FlashCallbackData({
                me: msg.sender,
                flashLoanPool: params.flashLoanPool,
                loanAmount: params.loanAmount,
                routes: params.routes
            })
        );
        address loanToken = RouteUtils.getInitialToken(params.routes[0]);
        IDODO(params.flashLoanPool).flashLoan(
            IDODO(params.flashLoanPool)._BASE_TOKEN_() == loanToken
                ? params.loanAmount
                : 0,
            IDODO(params.flashLoanPool)._BASE_TOKEN_() == loanToken
                ? 0
                : params.loanAmount,
            address(this),
            data
        );
    }

    function _flashLoanCallBack(
        address,
        uint256,
        uint256,
        bytes calldata data
    ) internal override {
        // Decode the recieved data to get flash loan details
        FlashParams memory decoded = abi.decode(data, (FlashParams));
        // Identify the initial loan token from the decoded routes
        address loanToken = RouteUtils.getInitialToken(decoded.routes[0]);
        // Ensue that the contract has received the loan amount.
        require(
            IERC20(loanToken).balanceOf(address(this)) >= decoded.loanAmount,
            "Failed to borrow loan token"
        );
        console.log(
            IERC20(loanToken).balanceOf(address(this)),
            "Contract Balance after Borrowing"
        );
        // Execute the logic for routing the loan through different swaps
        // routeLoop()

        routeLoop(decoded.routes, decoded.loanAmount);

        emit SwapFinished(
            loanToken,
            IERC20(loanToken).balanceOf(address(this))
        );

        require(
            IERC20(loanToken).balanceOf(address(this)) >= decoded.loanAmount,
            "Not enough amount to return loan"
        );
        //Return funds
        IERC20(loanToken).transfer(decoded.flashLoanPool, decoded.loanAmount);

        // send all loanToken to msg.sender
        uint256 remained = IERC20(loanToken).balanceOf(address(this));
        IERC20(loanToken).transfer(decoded.me, remained);
        emit SentProfit(decoded.me, remained);
    }

    /**
     * @dev Iterates over an array of routes and executes swaps
     * @param routes An array of Route structs, each defining a swap path.
     * @param totalAmount The total amount of the loan to be distributed across the routes.
     */
    function routeLoop(
        Route[] memory routes,
        uint256 totalAmount
    ) internal checkTotalRoutePart(routes) {
        for (uint256 i = 0; i < routes.length; i++) {
            // Calculate the amount to be used in the current route based on its part of the total loan.
            //  if rountes[i].part is 10000 (100%), then the amount to be used is the total amount.
            //  This helps if you want to use a percentage of the total amount for this swap and keep the rest for other purposes.
            // The partToAmountIn function from the Part library is used for this calculation.
            uint256 amountIn = Part.partToAmountIn(routes[i].part, totalAmount);
            console.log(totalAmount, "LOAN TOKEN AMOUNT TO SWAP");
            hopLoop(routes[i], amountIn);
        }
    }

    /**
     * @dev Process a single route by iterating over each hop within the route. each hop represents a token swap operation using a specific protocol.
     * @param route The Route struct representing a single route for token swaps.
     * @param totalAmount The amount of tokens to be swapped in this route.
     */
    function hopLoop(Route memory route, uint256 totalAmount) internal {
        uint256 amountIn = totalAmount;
        for (uint256 i = 0; i < route.hops.length; i++) {
            // Executes the token swap for the current hop and updates the amount for the next hop.`
            // The pickProtocol function determines the specific protocol to use for the swap.`
            amountIn = pickProtocol(route.hops[i], amountIn);
        }
    }

    function pickProtocol(Hop memory hop, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        if (hop.protocol == 0) {
            amountOut = uniswapV3(hop.data, amountIn, hop.path);
        } else if (hop.protocol < 8) {
            amountOut = uniswapV2(hop.data, amountIn, hop.path);
        } else {
            amountOut = dodoV2Swap(hop.data, amountIn, hop.path);
        }
    }

    function uniswapV3(
        bytes memory data,
        uint256 amountIn,
        address[] memory path
    ) internal returns (uint256 amountOut) {
        (address router, uint24 fee) = abi.decode(data, (address, uint24));
        ISwapRouter swapRouter = ISwapRouter(router);
        approveToken(path[0], address(swapRouter), amountIn);

        // single swaps
        amountOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: path[0],
                tokenOut: path[1],
                fee: fee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function uniswapV2(
        bytes memory data,
        uint256 amountIn,
        address[] memory path
    ) internal returns (uint256 amountOut) {
        address router = abi.decode(data, (address));
        approveToken(path[0], router, amountIn);
        return
            IUniswapV2Router(router).swapExactTokensForTokens(
                amountIn,
                1,
                path,
                address(this),
                block.timestamp
            )[1];
    }

    function dodoV2Swap(
        bytes memory data,
        uint256 amountIn,
        address[] memory path
    ) internal returns (uint256 amountOut) {
        (address dodoV2Pool, address dodoApprove, address dodoProxy) = abi
            .decode(data, (address, address, address));
        address[] memory dodoPairs = new address[](1); //one-hop
        dodoPairs[0] = dodoV2Pool;
        uint256 directions = IDODO(dodoV2Pool)._BASE_TOKEN_() == path[0]
            ? 0
            : 1;
        approveToken(path[0], dodoApprove, amountIn);
        amountOut = IDODOProxy(dodoProxy).dodoSwapV2TokenToToken(
            path[0],
            path[1],
            amountIn,
            1,
            dodoPairs,
            directions,
            false,
            block.timestamp
        );
    }

    /**
     * takes 3 params, token itself, toAdress which we will approve, and the amount
     * @param token T
     * @param to
     */
    function approveToken(
        address token,
        address to,
        uint256 amountIn
    ) internal {
        require(IERC20(token).approve(to, amountIn), "approve failed");
    }
}
