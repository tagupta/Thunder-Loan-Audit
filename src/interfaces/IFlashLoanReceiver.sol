// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.20;
//@audit-info unused import
//@audit-q check if IThunderLoan is used anywhere through the IFlashLoanReceiver, yes and this is a bad practice
// we must remove the import from 'MockFlashLoanReceiver.sol'

import { IThunderLoan } from "./IThunderLoan.sol";

/**
 * @dev Inspired by Aave:
 * https://github.com/aave/aave-v3-core/blob/master/contracts/flashloan/interfaces/IFlashLoanReceiver.sol
 */
//@audit-info natspec?
interface IFlashLoanReceiver {
    function executeOperation(
        //@audit-q is this the token that being borrowed? - yes
        address token,
        //@audit-q is this the amount of tokens? - yes
        uint256 amount,
        uint256 fee,
        address initiator,
        bytes calldata params
    )
        external
        returns (bool);
}
