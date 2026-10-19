// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {InkLiquidity} from "src/InkLiquidity.sol";

/// Local integration with the repository's actual v4 core/periphery. No RPC or mocked LP accounting.
/// These are test actors, not deployment arguments or a deployment manifest.
abstract contract LiquidityFixture is Test, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    uint256 internal constant PORTRAIT = 400_000e18;
    address internal owner = makeAddr("liquidity property owner");
    address internal trader = makeAddr("liquidity property trader");
    address internal constant TREASURY = 0xbc10B3662231c830d2ee10bc6359dB17bEa4b3d4;

    PoolManager internal manager;
    PositionManager internal posm;
    PoolSwapTest internal router;
    InkLiquidity internal liquidity;
    MockERC20 internal ink;
    MockERC20 internal imd;
    PoolKey internal key;
    bool internal inkIs0;

    function _setupLiquidity(bool inkFirst) internal {
        vm.chainId(11155111);
        vm.warp(1_800_000_000);
        inkIs0 = inkFirst;
        MockERC20 a = new MockERC20("Fixture A", "A", 18);
        MockERC20 b = new MockERC20("Fixture B", "B", 18);
        (MockERC20 low, MockERC20 high) = address(a) < address(b) ? (a, b) : (b, a);
        (ink, imd) = inkFirst ? (low, high) : (high, low);
        manager = new PoolManager(owner);
        posm = new PositionManager(
            manager,
            IAllowanceTransfer(deployPermit2()),
            100_000,
            IPositionDescriptor(address(0)),
            IWETH9(address(0))
        );
        router = new PoolSwapTest(manager);
        liquidity = new InkLiquidity(manager, posm, owner, TREASURY);
        key = PoolKey(
            Currency.wrap(address(low)), Currency.wrap(address(high)), 12_500, 200, IHooks(address(0))
        );
        manager.initialize(key, TickMath.getSqrtPriceAtTick(inkFirst ? int24(-129_000) : int24(129_000)));
        vm.prank(owner);
        liquidity.setPool(key, IERC20(address(ink)));
        vm.startPrank(trader);
        ink.approve(address(router), type(uint256).max);
        imd.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _list(uint256 amount) internal returns (uint256) {
        ink.mint(address(liquidity), amount);
        vm.prank(trader);
        return liquidity.addLiquidity();
    }

    function _trade(bool buyInk, uint256 amount) internal {
        MockERC20 input = buyInk ? imd : ink;
        input.mint(trader, amount);
        bool zeroForOne = buyInk ? !inkIs0 : inkIs0;
        vm.prank(trader);
        router.swap(
            key,
            SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _assertPosition(uint256 id) internal view {
        assertEq(posm.ownerOf(id), address(liquidity), "position must remain in permanent custody");
        assertEq(posm.getApproved(id), address(0), "position must not have a withdrawal delegate");
        assertGt(posm.getPositionLiquidity(id), 0, "listing must create nonzero liquidity");
        (PoolKey memory actual, PositionInfo info) = posm.getPoolAndPositionInfo(id);
        assertEq(
            PoolId.unwrap(actual.toId()), PoolId.unwrap(key.toId()), "position belongs to the configured pool"
        );
        assertLt(info.tickLower(), info.tickUpper());
        assertEq(info.tickLower() % key.tickSpacing, 0);
        assertEq(info.tickUpper() % key.tickSpacing, 0);
        if (inkIs0) assertGe(info.tickLower(), liquidity.releaseStartTick(), "INK price floor");
        else assertLe(info.tickUpper(), liquidity.releaseStartTick(), "INK price floor");
    }
}
