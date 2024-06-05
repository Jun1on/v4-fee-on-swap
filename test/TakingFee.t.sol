// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {TakingFee} from "../src/TakingFee.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract TakingFeeTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    TakingFee takingFee;
    PoolId poolId;

    address constant TREASURY = address(0x1234567890123456789012345678901234567890);
    uint128 private constant TOTAL_BIPS = 10000;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(TakingFee).creationCode, abi.encode(address(manager), 25, TREASURY));
        takingFee = new TakingFee{salt: salt}(IPoolManager(address(manager)), 25, TREASURY);
        require(address(takingFee) == hookAddress, "TakingFeeTest: hook address mismatch");
        require(takingFee.swapFeeBips() == 25, "TakingFeeTest: swapFeeBips mismatch");
        require(takingFee.treasury() == TREASURY, "TakingFeeTest: treasury mismatch");

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(address(takingFee)));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        // Provide liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-60, 60, 10 ether, 0), ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-120, 120, 10 ether, 0), ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10 ether, 0),
            ZERO_BYTES
        );
    }

    function testSwapHooks() public {
        // positions were created in setup()
        assertEq(currency0.balanceOf(TREASURY), 0);
        assertEq(currency1.balanceOf(TREASURY), 0);

        // Perform a test swap //
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative number indicates exact input swap!
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        // ------------------- //

        uint128 output = uint128(swapDelta.amount1());

        uint128 expectedFee = output * TOTAL_BIPS/(TOTAL_BIPS - takingFee.swapFeeBips()) - output;

        assertEq(currency0.balanceOf(TREASURY), 0);
        assertEq(currency1.balanceOf(TREASURY), expectedFee);
    
        // Perform a test swap //
        bool zeroForOne2 = true;
        int256 amountSpecified2 = 1e18; // negative number indicates exact input swap!
        BalanceDelta swapDelta2 = swap(key, zeroForOne2, amountSpecified2, ZERO_BYTES);
        // ------------------- //
        
        uint128 input = uint128(-swapDelta2.amount0());

        uint128 expectedFee2 = (input * takingFee.swapFeeBips()) / (TOTAL_BIPS + takingFee.swapFeeBips());

        assertEq(currency0.balanceOf(TREASURY), expectedFee2);
        assertEq(currency1.balanceOf(TREASURY), expectedFee);
    }
}
