// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test } from "forge-std/Test.sol";
import { AssetToken } from "src/Protocol/AssetToken.sol";

contract Handler is Test {
    AssetToken asset;

    constructor(address _asset) {
        asset = AssetToken(_asset);
    }

    function updateExchangeRate() external { }
}
