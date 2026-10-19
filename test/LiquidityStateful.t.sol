// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {InkLiquidity} from "src/InkLiquidity.sol";
import {LiquidityFixture} from "./helpers/LiquidityFixture.sol";

contract LiquiditySequenceHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    InkLiquidity public immutable liquidity;
    IPoolManager public immutable manager;
    PositionManager public immutable posm;
    PoolSwapTest public immutable router;
    MockERC20 public immutable ink;
    MockERC20 public immutable imd;
    address public immutable owner;
    bool public immutable inkIs0;
    PoolKey internal key;
    address[3] public actors;

    // Independent records of principal at creation and actual fee transfers, not inferred reserves.
    mapping(uint256 => uint128) public principalAtMint;
    uint256 public registeredPositions;
    uint256 public collectedImd;
    uint256 public collectedInk;
    uint256 public listedInk;
    uint256 public donatedInk;
    uint256 public successfulSwaps;
    uint256 public initialInkSupply;
    uint256 public initialImdSupply;

    constructor(InkLiquidity liq, PoolSwapTest router_, MockERC20 ink_, MockERC20 imd_, PoolKey memory key_) {
        liquidity = liq;
        manager = liq.poolManager();
        posm = PositionManager(payable(address(liq.positionManager())));
        router = router_;
        ink = ink_;
        imd = imd_;
        key = key_;
        owner = liq.owner();
        inkIs0 = address(ink_) < address(imd_);
        for (uint256 i; i < 3; ++i) {
            address actor = makeAddr(string.concat("liquidity sequence actor ", vm.toString(i)));
            actors[i] = actor;
            ink.mint(actor, 100_000_000e18);
            imd.mint(actor, 10_000e18);
            vm.startPrank(actor);
            ink.approve(address(router), type(uint256).max);
            imd.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        initialInkSupply = ink.totalSupply();
        initialImdSupply = imd.totalSupply();
        _registerPositions();
    }

    function _registerPositions() internal {
        uint256 n = liquidity.positionCount();
        for (uint256 i = registeredPositions; i < n; ++i) {
            uint256 id = liquidity.positions(i);
            uint128 principal = posm.getPositionLiquidity(id);
            assertGt(principal, 0);
            principalAtMint[id] = principal;
        }
        registeredPositions = n;
    }

    function donate(uint256 who, uint256 rawAmount) external {
        address actor = actors[who % 3];
        uint256 balance = ink.balanceOf(actor);
        uint256 cap = balance < 4_000_000e18 ? balance : 4_000_000e18;
        uint256 amount = bound(rawAmount, 0, cap);
        vm.prank(actor);
        ink.transfer(address(liquidity), amount);
        donatedInk += amount;
    }

    function add(uint256 who) external {
        uint256 before = ink.balanceOf(address(liquidity));
        uint256 min = liquidity.MIN_ADD();
        vm.prank(actors[who % 3]);
        if (before == 0) vm.expectRevert(InkLiquidity.NothingToAdd.selector);
        else if (before < min) vm.expectRevert(InkLiquidity.BelowMinAdd.selector);
        liquidity.addLiquidity();
        if (before < min) {
            assertEq(ink.balanceOf(address(liquidity)), before);
            assertEq(liquidity.positionCount(), registeredPositions);
            return;
        }
        assertGt(liquidity.positionCount(), registeredPositions, "successful listing must create a position");
        listedInk += before - ink.balanceOf(address(liquidity));
        _registerPositions();
    }

    function trade(uint256 who, bool buyInk, uint256 rawAmount) external {
        address actor = actors[who % 3];
        MockERC20 input = buyInk ? imd : ink;
        MockERC20 output = buyInk ? ink : imd;
        uint256 balance = input.balanceOf(actor);
        if (balance == 0) return;
        uint256 cap = buyInk ? 100e18 : 4_000_000e18;
        uint256 amount = bound(rawAmount, 1, balance < cap ? balance : cap);
        bool zeroForOne = buyInk ? !inkIs0 : inkIs0;
        int24 limitTick = liquidity.floorTick() + (zeroForOne ? int24(-60_000) : int24(60_000));
        uint160 limit = TickMath.getSqrtPriceAtTick(limitTick);
        (uint160 current,,,) = manager.getSlot0(key.toId());
        if (zeroForOne ? current <= limit : current >= limit) return;
        uint256 beforeOut = output.balanceOf(actor);
        vm.prank(actor);
        router.swap(
            key, SwapParams(zeroForOne, -int256(amount), limit), PoolSwapTest.TestSettings(false, false), ""
        );
        assertLe(balance - input.balanceOf(actor), amount, "exact input cannot overspend");
        assertGe(output.balanceOf(actor), beforeOut);
        if (output.balanceOf(actor) > beforeOut) successfulSwaps++;
    }

    function collect(uint256 who, uint256 start, uint256 count, bool clampEnd) external {
        uint256 n = liquidity.positionCount();
        start = bound(start, 0, n - 1);
        count = bound(count, 1, n - start);
        uint256 beforeInk = ink.balanceOf(address(liquidity));
        uint256 beforeImd = imd.balanceOf(liquidity.treasury());
        address actor = actors[who % 3];
        uint256 actorInk = ink.balanceOf(actor);
        uint256 actorImd = imd.balanceOf(actor);
        vm.prank(actor);
        (uint256 paid, uint256 kept) =
            liquidity.collectFees(start, clampEnd ? type(uint256).max : start + count);
        assertEq(imd.balanceOf(liquidity.treasury()) - beforeImd, paid);
        assertEq(ink.balanceOf(address(liquidity)) - beforeInk, kept);
        assertEq(ink.balanceOf(actor), actorInk, "keeper receives no INK");
        assertEq(imd.balanceOf(actor), actorImd, "keeper receives no IMD");
        collectedImd += paid;
        collectedInk += kept;
    }

    function changeWidth(uint24 rawWidth) external {
        int24 width = int24(uint24(bound(rawWidth, 200, 80_000)));
        vm.prank(owner);
        liquidity.setWidth(width);
    }

    function rejectRepricing(uint24 rawPremium) external {
        int24 before = liquidity.premium();
        vm.prank(owner);
        vm.expectRevert(InkLiquidity.BadPremium.selector);
        liquidity.setPremium(int24(uint24(bound(rawPremium, 0, 100_000))));
        assertEq(liquidity.premium(), before);
    }

    function rejectUnauthorizedAdmin(uint256 who) external {
        address actor = who % 4 == 3 ? liquidity.treasury() : actors[who % 3];
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor);
        vm.startPrank(actor);
        vm.expectRevert(denied);
        liquidity.setWidth(200);
        vm.expectRevert(denied);
        liquidity.setPremium(0);
        vm.expectRevert(denied);
        liquidity.transferOwnership(actor);
        vm.stopPrank();
    }
}

abstract contract LiquidityStateful is LiquidityFixture {
    LiquiditySequenceHandler internal handler;
    uint256 internal initialIdle;

    function _setupSequence(bool first) internal {
        _setupLiquidity(first);
        vm.prank(owner);
        liquidity.setPremium(7_000);
        _list(100_000_000e18);
        initialIdle = ink.balanceOf(address(liquidity));
        handler = new LiquiditySequenceHandler(liquidity, router, ink, imd, key);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.add.selector;
        selectors[2] = handler.trade.selector;
        selectors[3] = handler.collect.selector;
        selectors[4] = handler.changeWidth.selector;
        selectors[5] = handler.rejectRepricing.selector;
        selectors[6] = handler.rejectUnauthorizedAdmin.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function _trackedBalance(MockERC20 token) internal view returns (uint256 sum) {
        sum = token.balanceOf(address(manager)) + token.balanceOf(address(posm))
            + token.balanceOf(address(router)) + token.balanceOf(address(liquidity))
            + token.balanceOf(TREASURY);
        for (uint256 i; i < 3; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
    }

    function invariant_allTokensConservedAcrossTradingListingAndFees() public view {
        assertEq(ink.totalSupply(), handler.initialInkSupply());
        assertEq(imd.totalSupply(), handler.initialImdSupply());
        assertEq(_trackedBalance(ink), handler.initialInkSupply());
        assertEq(_trackedBalance(imd), handler.initialImdSupply());
        assertEq(
            ink.balanceOf(address(posm)) + imd.balanceOf(address(posm)),
            0,
            "no unsettled position-manager funds"
        );
        assertEq(ink.balanceOf(address(router)) + imd.balanceOf(address(router)), 0);
    }

    function invariant_positionsCannotLosePrincipalOrCustody() public view {
        assertEq(liquidity.positionCount(), handler.registeredPositions());
        assertEq(posm.balanceOf(address(liquidity)), liquidity.positionCount());
        uint256 previous;
        for (uint256 i; i < liquidity.positionCount(); ++i) {
            uint256 id = liquidity.positions(i);
            assertGt(id, previous, "unique, append-only position list");
            previous = id;
            _assertPosition(id);
            assertEq(
                posm.getPositionLiquidity(id),
                handler.principalAtMint(id),
                "no operation may remove liquidity"
            );
        }
    }

    function invariant_onlyImdFeesReachTreasuryAndInkCompounds() public view {
        assertEq(imd.balanceOf(TREASURY), handler.collectedImd());
        assertEq(ink.balanceOf(TREASURY), 0);
        assertEq(imd.balanceOf(address(liquidity)), 0);
        assertEq(
            ink.balanceOf(address(liquidity)) + handler.listedInk(),
            initialIdle + handler.donatedInk() + handler.collectedInk(),
            "idle + invested = change + donations + fees"
        );
        assertEq(liquidity.owner(), owner);
        assertEq(liquidity.treasury(), TREASURY);
        assertEq(liquidity.premium(), 7_000);
    }

    /// Deterministic coverage witness: setup alone cannot satisfy the handler's fee/custody properties.
    function test_sequenceActuallyTradesCollectsAndReinvests() public {
        handler.trade(0, true, 10 ether);
        handler.trade(1, false, 1_000_000e18);
        handler.collect(2, 0, 8, true);
        assertGt(handler.successfulSwaps(), 0);
        assertGt(handler.collectedImd(), 0);
        assertGt(handler.collectedInk(), 0);
        handler.donate(0, PORTRAIT);
        handler.add(1);
        assertGt(handler.listedInk(), 0);
        invariant_allTokensConservedAcrossTradingListingAndFees();
        invariant_positionsCannotLosePrincipalOrCustody();
        invariant_onlyImdFeesReachTreasuryAndInkCompounds();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LiquidityStatefulInk0Test is LiquidityStateful {
    function setUp() public {
        _setupSequence(true);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LiquidityStatefulInk1Test is LiquidityStateful {
    function setUp() public {
        _setupSequence(false);
    }
}
