// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { BaseTest, ThunderLoan } from "./BaseTest.t.sol";
import { AssetToken } from "../../src/protocol/AssetToken.sol";
import { MockFlashLoanReceiver } from "../mocks/MockFlashLoanReceiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';

contract ThunderLoanTest is BaseTest {
    uint256 constant AMOUNT = 10e18;
    uint256 constant DEPOSIT_AMOUNT = AMOUNT * 100;
    address liquidityProvider = address(123);
    address user = address(456);
    MockFlashLoanReceiver mockFlashLoanReceiver;

    function setUp() public override {
        super.setUp();
        vm.prank(user);
        mockFlashLoanReceiver = new MockFlashLoanReceiver(address(thunderLoan));
    }

    function testInitializationOwner() public view{
        assertEq(thunderLoan.owner(), address(this));
    }

    function testSetAllowedTokens() public {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        assertEq(thunderLoan.isAllowedToken(tokenA), true);
    }

    function testOnlyOwnerCanSetTokens() public {
        vm.prank(liquidityProvider);
        vm.expectRevert();
        thunderLoan.setAllowedToken(tokenA, true);
    }

    function testSettingTokenCreatesAsset() public {
        vm.prank(thunderLoan.owner());
        AssetToken assetToken = thunderLoan.setAllowedToken(tokenA, true);
        assertEq(address(thunderLoan.getAssetFromToken(tokenA)), address(assetToken));
    }

    function testCantDepositUnapprovedTokens() public {
        tokenA.mint(liquidityProvider, AMOUNT);
        tokenA.approve(address(thunderLoan), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ThunderLoan.ThunderLoan__NotAllowedToken.selector, address(tokenA)));
        thunderLoan.deposit(tokenA, AMOUNT);
    }

    modifier setAllowedToken() {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        _;
    }

    function testDepositMintsAssetAndUpdatesBalance() public setAllowedToken {
        tokenA.mint(liquidityProvider, AMOUNT);

        vm.startPrank(liquidityProvider);
        tokenA.approve(address(thunderLoan), AMOUNT);
        thunderLoan.deposit(tokenA, AMOUNT);
        vm.stopPrank();

        AssetToken asset = thunderLoan.getAssetFromToken(tokenA);
        assertEq(tokenA.balanceOf(address(asset)), AMOUNT);
        assertEq(asset.balanceOf(liquidityProvider), AMOUNT);
    }

    modifier hasDeposits() {
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), DEPOSIT_AMOUNT);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testFlashLoan() public setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        vm.startPrank(user);
        tokenA.mint(address(mockFlashLoanReceiver), AMOUNT);
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        vm.stopPrank();

        assertEq(mockFlashLoanReceiver.getBalanceDuring(), amountToBorrow + AMOUNT);
        assertEq(mockFlashLoanReceiver.getBalanceAfter(), AMOUNT - calculatedFee);
    }
    
    //@audit-poc
    function test_Deposit_And_Redeem() external setAllowedToken{
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), DEPOSIT_AMOUNT);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT);
        vm.stopPrank();

        //get exchange rate
        AssetToken assetToken = thunderLoan.getAssetFromToken(IERC20(tokenA));
        uint256 exchangeRate = AssetToken(assetToken).getExchangeRate();
        console.log("AssetToken: exchangeRate on deposit 1 - ", exchangeRate); //1.003 ether

        vm.startPrank(user);
        tokenA.mint(user, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), DEPOSIT_AMOUNT);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT);
        vm.stopPrank();

        exchangeRate = AssetToken(assetToken).getExchangeRate();
        console.log("AssetToken: exchangeRate on deposit 2 - ", exchangeRate); //1.0045 ether

        vm.startPrank(user);
        thunderLoan.redeem(IERC20(tokenA), type(uint256).max);
        vm.stopPrank();

        exchangeRate = AssetToken(assetToken).getExchangeRate();
        console.log("New user balance: ", IERC20(tokenA).balanceOf(user));
        console.log("AssetToken: exchangeRate on deposit 3 - ", exchangeRate); //1.0045 ether

        vm.startPrank(liquidityProvider);
        uint256 tokensAvailable = tokenA.balanceOf(address(assetToken));
        uint256 tokensUserCanRedeem = (assetToken.balanceOf(liquidityProvider) * exchangeRate) / assetToken.EXCHANGE_RATE_PRECISION();
        bytes memory expectedError = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(assetToken), tokensAvailable, tokensUserCanRedeem);
        vm.expectRevert(expectedError);
        thunderLoan.redeem(IERC20(tokenA), type(uint256).max);
        vm.stopPrank();

        exchangeRate = AssetToken(assetToken).getExchangeRate();
        console.log("AssetToken: exchangeRate on deposit 4 - ", exchangeRate); 
    }
    //@audit-poc
    function test_Deposit_Redeem_using_flashLoan() external setAllowedToken hasDeposits{
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        uint256 exchangeRate  = AssetToken(thunderLoan.getAssetFromToken(tokenA)).getExchangeRate();
        vm.startPrank(user);
        console.log("Fee, Exchange rate: before flashLoan - ", calculatedFee, exchangeRate);
        tokenA.mint(address(mockFlashLoanReceiver), AMOUNT);
        // console.log("calculatedFee: ", calculatedFee);
        // bytes memory call1 = abi.encodeCall(ThunderLoan.deposit, (tokenA, amountToBorrow));
        // bytes memory call2 = abi.encodeCall(ThunderLoan.redeem, (tokenA, type(uint256).max));
        // bytes memory callData = abi.encode(call1, call2);
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        exchangeRate  = AssetToken(thunderLoan.getAssetFromToken(tokenA)).getExchangeRate();
        console.log("Fee, Exchange rate: before flashLoan - ", calculatedFee, exchangeRate);

        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        exchangeRate  = AssetToken(thunderLoan.getAssetFromToken(tokenA)).getExchangeRate();
        console.log("Fee, Exchange rate: before flashLoan - ", calculatedFee, exchangeRate);

        vm.stopPrank();
    }
}  
