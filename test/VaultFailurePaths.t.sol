// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {InkPortraits} from "src/InkPortraits.sol";
import {InkVault} from "src/InkVault.sol";
import {TestSeats} from "src/testnet/TestSeats.sol";

/// A normal 18-decimal token with explicit, test-controlled external-call faults.
contract VaultFaultToken is ERC20("INK test fixture", "INK") {
    bool public rejectTransferFrom;
    address public rejectRecipient;
    address public callbackTarget;
    bytes public callbackData;
    bytes public callbackResult;
    bool public callbackSucceeded;

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function failTransferFrom(bool fail) external {
        rejectTransferFrom = fail;
    }

    function failTransferTo(address to) external {
        rejectRecipient = to;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == rejectRecipient) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (rejectTransferFrom) return false;
        if (callbackTarget != address(0)) {
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
        }
        return super.transferFrom(from, to, amount);
    }
}

contract VaultFailureSink {
    uint256 public additions;

    function addLiquidity() external returns (uint256) {
        return ++additions;
    }
}

/// forge-config: default.fuzz.runs = 1000
contract VaultFailurePathsTest is Test {
    uint256 internal constant P = 400_000e18;
    address internal owner = makeAddr("vault failure owner");
    address internal alice = makeAddr("vault failure alice");
    address internal bob = makeAddr("vault failure bob");
    TestSeats internal seats;
    InkPortraits internal portraits;
    InkVault internal vault;
    VaultFaultToken internal ink;
    VaultFailureSink internal sink;
    InkPortraits.AgentStats internal stats = InkPortraits.AgentStats(40, 9500, 300, 151, false);

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(100);
        seats = new TestSeats();
        portraits = new InkPortraits(owner);
        vault = new InkVault(portraits, seats, owner);
        ink = new VaultFaultToken();
        sink = new VaultFailureSink();
        vm.prank(alice);
        seats.mint(0);
        ink.mint(address(vault), 2000 * P);
        ink.mint(alice, 20 * P);
        ink.mint(bob, 20 * P);
        bytes32 leaf = keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        uint256(0),
                        stats.accepted,
                        stats.rateBps,
                        stats.turns,
                        stats.hoursTenths,
                        stats.outdated
                    )
                )
            )
        );
        vm.startPrank(owner);
        portraits.setVault(address(vault));
        vault.setInk(IERC20(address(ink)));
        vault.setup(leaf, uint64(block.timestamp + 1 hours), address(sink));
        vm.stopPrank();
        vm.startPrank(alice);
        ink.approve(address(vault), type(uint256).max);
        portraits.setApprovalForAll(address(vault), true);
        vm.stopPrank();
        vm.startPrank(bob);
        ink.approve(address(vault), type(uint256).max);
        portraits.setApprovalForAll(address(vault), true);
        vm.stopPrank();
    }

    function _claim() internal {
        vm.warp(vault.claimStart());
        vm.prank(alice);
        vault.claim(0, stats, new bytes32[](0));
    }

    function _release() internal {
        vm.warp(vault.claimEnd());
        vault.release();
    }

    function _mature() internal {
        uint256 entropyBlock = block.number + 1;
        vm.roll(block.number + 2);
        vm.setBlockhash(entropyBlock, keccak256(abi.encode("failure path entropy", entropyBlock)));
    }

    function _pullAndReveal(address who, uint256 n) internal {
        vm.prank(who);
        uint256 first = vault.pull(n);
        _mature();
        assertTrue(vault.reveal(first + n - 1));
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _transferFailure() internal view returns (bytes memory) {
        return abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(ink));
    }

    function test_claimWindowUsesInclusiveStartAndExclusiveEnd() public {
        vm.warp(vault.claimStart() - 1);
        vm.prank(alice);
        vm.expectRevert(InkVault.ClaimClosed.selector);
        vault.claim(0, stats, new bytes32[](0));
        assertEq(portraits.totalSupply(), 0);
        _claim();
        assertEq(portraits.ownerOf(0), alice);
        vm.warp(vault.claimEnd() - 1);
        vm.expectRevert(InkVault.ClaimStillOpen.selector);
        vault.release();
        vm.warp(vault.claimEnd());
        assertFalse(vault.claimOpen());
        vm.prank(alice);
        vm.expectRevert(InkVault.ClaimClosed.selector);
        vault.claim(0, stats, new bytes32[](0));
        vault.release();
        assertEq(ink.balanceOf(address(vault)), P);
        assertEq(ink.balanceOf(address(sink)), 1999 * P);
    }

    function testFuzz_claimRejectsEveryAlteredStatsField(uint8 field) public {
        vm.warp(vault.claimStart());
        InkPortraits.AgentStats memory forged = stats;
        field = uint8(bound(field, 0, 4));
        if (field == 0) forged.accepted++;
        else if (field == 1) forged.rateBps++;
        else if (field == 2) forged.turns++;
        else if (field == 3) forged.hoursTenths++;
        else forged.outdated = !forged.outdated;
        vm.prank(alice);
        vm.expectRevert(InkVault.InvalidProof.selector);
        vault.claim(0, forged, new bytes32[](0));
        assertEq(portraits.totalSupply(), 0);
        assertEq(ink.balanceOf(address(vault)), 2000 * P);
        vm.prank(alice);
        vault.claim(0, stats, new bytes32[](0));
        assertEq(portraits.ownerOf(0), alice, "failed proof does not consume the claim");
    }

    function test_seatApprovalDoesNotGrantClaimAndSeatTransferCannotDoubleClaim() public {
        vm.warp(vault.claimStart());
        vm.prank(alice);
        seats.approve(bob, 0);
        vm.prank(bob);
        vm.expectRevert(InkVault.NotSeatOwner.selector);
        vault.claim(0, stats, new bytes32[](0));
        _claim();
        vm.prank(bob);
        seats.transferFrom(alice, bob, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        vault.claim(0, stats, new bytes32[](0));
        assertEq(portraits.ownerOf(0), alice);
        assertEq(portraits.agentMinted(), 1);
        assertEq(portraits.agentBalanceOf(alice), 1);
        assertEq(portraits.agentBalanceOf(bob), 0);
    }

    function test_failedPullDoesNotChargeOrReserveAndCanRetry() public {
        _release();
        ink.failTransferFrom(true);
        uint256 before = ink.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(_transferFailure());
        vault.pull(2);
        assertEq(vault.pullCount(), 0);
        assertEq(vault.nextReveal(), 0);
        assertEq(ink.balanceOf(alice), before);
        assertEq(ink.balanceOf(address(vault)), 0);
        ink.failTransferFrom(false);
        _pullAndReveal(alice, 2);
        assertEq(portraits.balanceOf(alice), 2);
        assertEq(ink.balanceOf(address(vault)), 2 * P);
    }

    function test_allowanceFailureLeavesPullQueueUntouched() public {
        _release();
        vm.startPrank(alice);
        ink.approve(address(vault), P - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(vault), P - 1, P)
        );
        vault.pull(1);
        vm.stopPrank();
        assertEq(vault.pullCount(), 0);
        assertEq(ink.balanceOf(alice), 20 * P);
        assertEq(ink.balanceOf(address(vault)), 0);
    }

    function test_failedDepositPaymentRollsBackNftCustodyAndIncomingQueue() public {
        _release();
        _pullAndReveal(alice, 1);
        ink.failTransferTo(alice);
        uint256 before = ink.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(_transferFailure());
        vault.deposit(_one(10_000), 0);
        assertEq(portraits.ownerOf(10_000), alice);
        assertEq(vault.heldCount(), 0);
        assertEq(vault.waitingCount(), 0);
        assertEq(ink.balanceOf(address(vault)), P);
        assertEq(ink.balanceOf(alice), before);
    }

    function test_failedFeeTransferRollsBackEvenTheCompletedUserPayment() public {
        _release();
        _pullAndReveal(alice, 1);
        ink.failTransferTo(address(sink));
        uint256 userBefore = ink.balanceOf(alice);
        uint256 sinkBefore = ink.balanceOf(address(sink));
        vm.prank(alice);
        vm.expectRevert(_transferFailure());
        vault.deposit(_one(10_000), 0);
        assertEq(portraits.ownerOf(10_000), alice);
        assertEq(ink.balanceOf(alice), userBefore);
        assertEq(ink.balanceOf(address(sink)), sinkBefore);
        assertEq(ink.balanceOf(address(vault)), P);
        assertEq(vault.waitingCount(), 0);
    }

    function test_duplicateAndForeignNftsRevertTheWholeBatch() public {
        _release();
        _pullAndReveal(alice, 1);
        _pullAndReveal(bob, 1);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 10_000;
        ids[1] = 10_000;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC721Errors.ERC721IncorrectOwner.selector, alice, uint256(10_000), address(vault)
            )
        );
        vault.deposit(ids, 0);
        ids[1] = 10_001;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, alice, uint256(10_001), bob)
        );
        vault.deposit(ids, 0);
        assertEq(portraits.ownerOf(10_000), alice);
        assertEq(portraits.ownerOf(10_001), bob);
        assertEq(vault.heldCount(), 0);
        assertEq(ink.balanceOf(address(vault)), 2 * P);
        assertEq(ink.balanceOf(alice), 19 * P);
    }

    function test_failedTraitFeeDoesNotLockPortraitOrConsumeReroll() public {
        _release();
        _pullAndReveal(alice, 1);
        bytes32 beforeSeed = portraits.swarmSeed(10_000);
        ink.failTransferFrom(true);
        vm.prank(alice);
        vm.expectRevert(_transferFailure());
        vault.rerollTraits(10_000, P);
        assertEq(vault.traitRerollBlock(10_000), 0);
        assertEq(portraits.swarmSeed(10_000), beforeSeed);
        vm.prank(alice);
        portraits.transferFrom(alice, bob, 10_000);
        assertEq(portraits.ownerOf(10_000), bob);
    }

    function test_transferFromCallbackCannotReenterPull() public {
        _release();
        ink.setCallback(address(vault), abi.encodeCall(vault.pull, (1)));
        vm.prank(alice);
        vault.pull(1);
        assertFalse(ink.callbackSucceeded());
        assertEq(
            ink.callbackResult(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(vault.pullCount(), 1);
        assertEq(ink.balanceOf(address(vault)), P);
        assertEq(ink.balanceOf(alice), 19 * P);
    }

    function test_claimedAgentCanExitBeforeReleaseWithoutSpendingUnclaimedBacking() public {
        _claim();
        vm.prank(alice);
        assertEq(vault.deposit(_one(0), P), P);
        assertEq(ink.balanceOf(address(vault)), 1999 * P);
        assertEq(portraits.ownerOf(0), address(vault));
        assertEq(vault.heldCount(), 1);
        _release();
        assertEq(ink.balanceOf(address(sink)), 1999 * P);
        assertEq(ink.balanceOf(address(vault)), 0);
        assertEq(vault.swarmSlots() + vault.heldCount(), 2000);
    }

    function testFuzz_batchDepositConservesBackingForAllAllowedFees(
        uint16 base,
        uint16 discounted,
        uint8 rawCount,
        bool holder
    ) public {
        base = uint16(bound(base, 0, 500));
        discounted = uint16(bound(discounted, 0, base));
        uint256 n = bound(rawCount, 1, 8);
        if (holder) _claim();
        _release();
        _pullAndReveal(alice, n);
        vm.prank(owner);
        vault.setFees(base, discounted);
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = 10_000 + i;
        }
        uint256 userBefore = ink.balanceOf(alice);
        uint256 vaultBefore = ink.balanceOf(address(vault));
        uint256 sinkBefore = ink.balanceOf(address(sink));
        vm.prank(alice);
        uint256 paid = vault.deposit(ids, 0);
        uint256 feeReceived = ink.balanceOf(address(sink)) - sinkBefore;
        assertEq(paid + feeReceived, n * P, "no value created or lost in redemption");
        assertEq(ink.balanceOf(alice) - userBefore, paid);
        assertEq(vaultBefore - ink.balanceOf(address(vault)), n * P);
        assertGe(paid, n * P * 95 / 100);
        assertLe(paid, n * P);
        assertEq(vault.heldCount(), n);
        assertEq(ink.balanceOf(address(vault)), holder ? P : 0);
    }
}
