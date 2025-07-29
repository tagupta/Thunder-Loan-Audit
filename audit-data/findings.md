### [H-1] Erroneous `ThunderLoan::updateExchangeRate` in the `ThunderLoan::deposit` function causes protocol to think it has more fees than it actually does, which blocks the redemptions and incorrectly sets the `AssetToken::s_exchangeRate`.

**Description:** In the ThunderLoan protocol, the `exchangeRate` is reponsible for calculating the exchange rate between the assetTokens and underlying tokens. In a way, it's reponsible for keeping track of how many fees to give to liquidity providers.

However, the `deposit` function updates this rate, without collecting any fee.

```js
    function deposit(IERC20 token, uint256 amount) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
        emit Deposit(msg.sender, token, amount);
        assetToken.mint(msg.sender, mintAmount);
@>      uint256 calculatedFee = getCalculatedFee(token, amount);
@>      assetToken.updateExchangeRate(calculatedFee);
        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }
```

**Impact:** There are several impacts, to this bug

1. The `ThunderLoan::redeem` is blocked if there is not enough tokens present in the `assetToken` contract.
2. Rewards are incorrectly calculated, leading to liquidity providers potentially getting away with redeeming more than intended.
3. This can eventually cause the draining of the tokens from the `assetToken` contract.

**Proof of Concept:**

1. LP deposits
2. User takes out a flashLoan
3. It is now impossible for LP to redeem tokens

<details>
<summary>Proof of code</summary>

Paste this code in [ThunderLoanTest.t.sol](../test/unit//ThunderLoanTest.t.sol)

```js
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
        thunderLoan.redeem(tokenA, type(uint256).max);
        vm.stopPrank();
    }

```

</details>

**Recommended Mitigation:** Remove the incorrect updated exchange lines from `ThunderLoan::deposit`

```diff
    function deposit(IERC20 token, uint256 amount) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
        emit Deposit(msg.sender, token, amount);
        assetToken.mint(msg.sender, mintAmount);
-       uint256 calculatedFee = getCalculatedFee(token, amount);
-       assetToken.updateExchangeRate(calculatedFee);
        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }
```

### [M-1] Using TSwap as price oracle leads to price and oracle manipulation attacks

**Description:** The TSwap pool is a contant product formula based AMM (automated market maker). The price of a token is determined by how many reserves are on either side of the pool. Because of this, it is easy for malicious users to manipulate the price of the token by buying or selling large amount of the token in the same transaction, esentially ignoring the protocol fees.

**Impact:** Liquidity providers will drastically reduce fees for providing liquidity.

**Proof of Concept:** The following all happens in 1 transaction.

1. Users takes a `flashLoan` from `ThunderLoan` contract of `50 tokenA`. They are charged the original fee `feeOne`.
2. Insteading of repaying the loan right away, users swaps these tokens with another token in the `tswap` pool, hence tanking the price of one pool token in weth:

```js
function getPriceInWeth(address token) public view returns (uint256) {
        address swapPoolOfToken = IPoolFactory(s_poolFactory).getPool(token);
        return ITSwapPool(swapPoolOfToken).getPriceOfOnePoolTokenInWeth();
    }
```

3. Now user takes out another flash loan of `50 tokenA`. The fees for this second flash loan, turns out to be really cheap due to the fact that `ThunderLoan` contract calculates price based on `TSwap` pool.

I have created a Proof-of-code (POC) in [ThunderLoanTest.t.sol](../test/unit/ThunderLoanTest.t.sol). It is too long to add here.

**Recommended Mitigation:** Consider using a different price oracle mechanism, like a chainlink pricefeed with a Uniswap TWAP fallback oracle.
