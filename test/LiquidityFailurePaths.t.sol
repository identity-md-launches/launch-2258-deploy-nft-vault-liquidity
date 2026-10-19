// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LiquidityFixture} from "./helpers/LiquidityFixture.sol";
import {InkLiquidity} from "src/InkLiquidity.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC721Permit_v4} from "v4-periphery/src/interfaces/IERC721Permit_v4.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

abstract contract LiquidityFailurePaths is LiquidityFixture {
    function test_thresholdRejectsZeroAndDustWithoutMovingFunds() public {
        vm.expectRevert(InkLiquidity.NothingToAdd.selector);
        liquidity.addLiquidity();
        ink.mint(address(liquidity), 1);
        vm.expectRevert(InkLiquidity.BelowMinAdd.selector);
        liquidity.addLiquidity();
        ink.mint(address(liquidity), PORTRAIT - 2);
        vm.expectRevert(InkLiquidity.BelowMinAdd.selector);
        liquidity.addLiquidity();
        assertEq(ink.balanceOf(address(liquidity)), PORTRAIT - 1);
        assertEq(ink.balanceOf(address(manager)), 0);
        assertEq(liquidity.positionCount(), 0);
        ink.mint(address(liquidity), 1);
        liquidity.addLiquidity();
        assertEq(liquidity.positionCount(), 8);
        for (uint256 i; i < 8; ++i) {
            _assertPosition(liquidity.positions(i));
        }
        assertEq(ink.balanceOf(address(liquidity)) + ink.balanceOf(address(manager)), PORTRAIT);
    }

    function testFuzz_ladderConservesEveryWei(uint256 amount, uint24 premium) public {
        amount = bound(amount, PORTRAIT, 800_000_000e18);
        premium = uint24(bound(premium, 0, 100_000));
        vm.prank(owner);
        liquidity.setPremium(int24(premium));
        uint256 first = _list(amount);
        assertEq(first, liquidity.positions(0));
        assertEq(liquidity.positionCount(), 8);
        for (uint256 i; i < 8; ++i) {
            _assertPosition(liquidity.positions(i));
            assertEq(liquidity.positions(i), first + i, "one position per band");
        }
        assertEq(ink.balanceOf(address(manager)) + ink.balanceOf(address(liquidity)), amount);
        assertEq(ink.balanceOf(address(posm)), 0, "rounding change is swept back");
        assertEq(ink.balanceOf(TREASURY), 0, "treasury never receives INK principal");
        assertEq(ink.balanceOf(owner), 0);
        assertEq(imd.balanceOf(address(manager)), 0, "listing is entirely INK funded");
    }

    function test_positionManagerFailureRollsBackAndCanBeRetried() public {
        ink.mint(address(liquidity), PORTRAIT);
        uint256 next = posm.nextTokenId();
        bytes memory failure = abi.encodeWithSignature("Error(string)", "injected position manager failure");
        vm.mockCallRevert(
            address(posm), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), failure
        );
        vm.expectRevert(failure);
        liquidity.addLiquidity();
        assertEq(ink.balanceOf(address(liquidity)), PORTRAIT);
        assertEq(ink.balanceOf(address(posm)), 0);
        assertEq(ink.balanceOf(address(manager)), 0);
        assertEq(liquidity.positionCount(), 0);
        assertEq(posm.nextTokenId(), next);
        vm.clearMockedCalls();
        assertEq(liquidity.addLiquidity(), next);
        _assertPosition(next);
    }

    function test_feeCollectionLeavesAllPositionPrincipalAndCustodyIntact() public {
        _list(100_000_000e18);
        _trade(true, 10 ether);
        _trade(false, 1_000_000e18);
        uint128[] memory beforeLiquidity = new uint128[](8);
        for (uint256 i; i < 8; ++i) {
            beforeLiquidity[i] = posm.getPositionLiquidity(liquidity.positions(i));
        }
        uint256 inkBefore = ink.balanceOf(address(liquidity));
        uint256 treasuryBefore = imd.balanceOf(TREASURY);
        uint256 callerInk = ink.balanceOf(trader);
        uint256 callerImd = imd.balanceOf(trader);
        vm.prank(trader);
        (uint256 paid, uint256 retained) = liquidity.collectFees(0, type(uint256).max);
        assertGt(paid, 0, "exercise nonzero IMD fees");
        assertGt(retained, 0, "exercise nonzero INK fees");
        assertEq(imd.balanceOf(TREASURY), treasuryBefore + paid);
        assertEq(ink.balanceOf(address(liquidity)), inkBefore + retained);
        assertEq(ink.balanceOf(trader), callerInk);
        assertEq(imd.balanceOf(trader), callerImd);
        for (uint256 i; i < 8; ++i) {
            uint256 id = liquidity.positions(i);
            assertEq(
                posm.getPositionLiquidity(id), beforeLiquidity[i], "collection cannot withdraw principal"
            );
            _assertPosition(id);
        }
        (paid, retained) = liquidity.collectFees(0, 8);
        assertEq(paid, 0, "fees cannot be claimed twice");
        assertEq(retained, 0);
    }

    function test_invalidFeeRangesRevertWithoutMovingFunds() public {
        vm.expectRevert(InkLiquidity.NothingToCollect.selector);
        liquidity.collectFees(0, 1);
        _list(PORTRAIT);
        vm.expectRevert(InkLiquidity.NothingToCollect.selector);
        liquidity.collectFees(0, 0);
        vm.expectRevert(InkLiquidity.NothingToCollect.selector);
        liquidity.collectFees(8, type(uint256).max);
        vm.expectRevert(InkLiquidity.NothingToCollect.selector);
        liquidity.collectFees(type(uint256).max, 1);
        assertEq(liquidity.positionCount(), 8);
        assertEq(ink.balanceOf(address(manager)) + ink.balanceOf(address(liquidity)), PORTRAIT);
        assertEq(imd.balanceOf(TREASURY), 0);
    }

    function test_ownerTreasuryAndCallerCannotTransferApproveOrBurnLockedPosition() public {
        uint256 id = _list(PORTRAIT);
        uint128 principal = posm.getPositionLiquidity(id);
        address[3] memory callers = [owner, TREASURY, trader];
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(id, uint128(0), uint128(0), bytes(""));
        bytes memory burn = abi.encode(abi.encodePacked(uint8(Actions.BURN_POSITION)), params);
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert("NOT_AUTHORIZED");
            posm.transferFrom(address(liquidity), callers[i], id);
            vm.expectRevert(IERC721Permit_v4.Unauthorized.selector);
            posm.approve(callers[i], id);
            vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, callers[i]));
            posm.modifyLiquidities(burn, block.timestamp);
            vm.stopPrank();
            _assertPosition(id);
            assertEq(posm.getPositionLiquidity(id), principal);
        }
    }
}

/// forge-config: default.fuzz.runs = 1000
contract LiquidityFailurePathsInk0Test is LiquidityFailurePaths {
    function setUp() public {
        _setupLiquidity(true);
    }
}

/// forge-config: default.fuzz.runs = 1000
contract LiquidityFailurePathsInk1Test is LiquidityFailurePaths {
    function setUp() public {
        _setupLiquidity(false);
    }
}
