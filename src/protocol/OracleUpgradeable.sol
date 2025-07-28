// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

import { ITSwapPool } from "../interfaces/ITSwapPool.sol";
import { IPoolFactory } from "../interfaces/IPoolFactory.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract OracleUpgradeable is Initializable {
    address private s_poolFactory;
    
    //@audit-info check for zero address is missing
    function __Oracle_init(address poolFactoryAddress) internal onlyInitializing {
        __Oracle_init_unchained(poolFactoryAddress);
    }

    //@audit-info check for zero address is missing
    function __Oracle_init_unchained(address poolFactoryAddress) internal onlyInitializing {
        s_poolFactory = poolFactoryAddress;
    }
    
    //@audit-q since we are calling the external contract, 
    // what if someone / I can manipulate the price?
    // can there be reentrancy attack?
    // check the test? -> Fork test | Mocks to interact with this protocol?
    //@audit-info you should use forked test for this
    function getPriceInWeth(address token) public view returns (uint256) {
        address swapPoolOfToken = IPoolFactory(s_poolFactory).getPool(token);
        return ITSwapPool(swapPoolOfToken).getPriceOfOnePoolTokenInWeth();
    }

    function getPrice(address token) external view returns (uint256) {
        return getPriceInWeth(token);
    }

    function getPoolFactoryAddress() external view returns (address) {
        return s_poolFactory;
    }
}
