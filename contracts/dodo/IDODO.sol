// This is a file copied from https://github.com/DODOEX/dodo-example/blob/main/solidity/contracts/DODOFlashloan.sol
/*
    Copyright 2021 DODO ZOO.
    SPDX-License-Identifier: Apache-2.0
*/
pragma solidity ^0.8;
// pragma solidity 0.6.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {IERC20} from "./intf/IERC20.sol";

interface IDODO {

    /**
     * @dev baseAmount or quoteAmount one of them will always be zero.
     * @param baseAmount If we are borrowing basetoken then baseAmount will be greater than zero
     * @param quoteAmount if we are borrwoing quote amount then quoteamount will be greater than zero
     * @param assetTo
     * @param data
     */
    function flashLoan(
        uint256 baseAmount,
        uint256 quoteAmount,
        address assetTo,
        bytes calldata data
    ) external;

    function _BASE_TOKEN_() external view returns (address);
    function _BASE_RESERVE_() external view returns (uint112);
    function _QUOTE_TOKEN_() external view returns (address);
    function _QUOTE_RESERVE_() external view returns (uint112);
}