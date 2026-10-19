// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {InkPortraits} from "src/InkPortraits.sol";
import {InkRenderer} from "src/InkRenderer.sol";
import {TestSeats} from "src/testnet/TestSeats.sol";

/// forge-config: default.fuzz.runs = 1000
contract RendererStoragePropertiesTest is Test {
    address internal owner = makeAddr("renderer properties owner");
    address internal nextOwner = makeAddr("renderer properties successor");
    InkPortraits internal portraits;
    InkRenderer internal renderer;

    function setUp() public {
        portraits = new InkPortraits(owner);
        renderer = new InkRenderer(portraits, owner);
        vm.prank(owner);
        portraits.setRenderer(address(renderer));
    }

    function testFuzz_chunkRoundTripPreservesBinaryDataAndOrder(bytes memory first, bytes memory second)
        public
    {
        // The fuzzer's ordinary byte arrays are small; use a deterministic boundary test for MAX_CHUNK.
        if (first.length > 4096) first = _prefix(first, 4096);
        if (second.length > 4096) second = _prefix(second, 4096);
        vm.startPrank(owner);
        renderer.addChunk(first);
        address a = renderer.chunks(0);
        renderer.addChunk(second);
        address b = renderer.chunks(1);
        vm.stopPrank();
        assertNotEq(a, b, "appending does not overwrite the earlier code blob");
        assertEq(a.code.length, first.length + 1);
        assertEq(b.code.length, second.length + 1);
        assertEq(a.code[0], bytes1(0), "data runtime begins with STOP");
        assertEq(b.code[0], bytes1(0));
        assertEq(renderer.script(), bytes.concat(first, second));
        assertEq(renderer.chunkCount(), 2);
    }

    function _prefix(bytes memory input, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = input[i];
        }
    }

    function test_maximumChunkFitsEip170AndNextByteRevertsAtomically() public {
        bytes memory full = new bytes(renderer.MAX_CHUNK());
        for (uint256 i; i < full.length; ++i) {
            full[i] = bytes1(uint8(i));
        }
        bytes memory tooLarge = bytes.concat(full, hex"ff");
        vm.startPrank(owner);
        renderer.addChunk(full);
        vm.expectRevert(InkRenderer.ChunkTooLarge.selector);
        renderer.addChunk(tooLarge);
        vm.stopPrank();
        assertEq(renderer.chunkCount(), 1);
        assertEq(renderer.chunks(0).code.length, 24_576);
        assertEq(renderer.script(), full);
    }

    function test_artAndPointerLocksSurviveOwnershipTransfer() public {
        vm.startPrank(owner);
        renderer.addChunk(bytes("window.SwarmArt={render:function(){}};"));
        renderer.setPreviewBase("ipfs://portrait-previews/");
        renderer.lock();
        portraits.lockRenderer();
        renderer.transferOwnership(nextOwner);
        portraits.transferOwnership(nextOwner);
        vm.stopPrank();
        bytes32 scriptHash = keccak256(renderer.script());
        vm.startPrank(nextOwner);
        vm.expectRevert(InkRenderer.IsLocked.selector);
        renderer.addChunk("replacement");
        vm.expectRevert(InkRenderer.IsLocked.selector);
        renderer.setPreviewBase("ipfs://replacement/");
        vm.expectRevert(InkPortraits.Locked.selector);
        portraits.setRenderer(nextOwner);
        vm.stopPrank();
        assertTrue(renderer.locked());
        assertTrue(portraits.rendererLocked());
        assertEq(keccak256(renderer.script()), scriptHash);
        assertEq(renderer.previewBase(), "ipfs://portrait-previews/");
        assertEq(portraits.renderer(), address(renderer));
    }

    function test_failedEmptyLockRemainsConfigurableByOwnerOnly() public {
        vm.prank(owner);
        vm.expectRevert(InkRenderer.NoScript.selector);
        renderer.lock();
        assertFalse(renderer.locked());
        vm.prank(nextOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nextOwner));
        renderer.addChunk("unauthorized");
        assertEq(renderer.chunkCount(), 0);
        vm.startPrank(owner);
        renderer.addChunk("usable script");
        renderer.lock();
        vm.stopPrank();
        assertTrue(renderer.locked());
        assertEq(renderer.script(), bytes("usable script"));
    }

    function testFuzz_nonexistentPortraitCannotExposeCollectionTokenUri(uint256 tokenId) public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, tokenId));
        portraits.tokenURI(tokenId);
    }

    function test_testSeatsCannotRemintASeatAfterItChangesHands() public {
        TestSeats seats = new TestSeats();
        vm.prank(owner);
        seats.mint(1999);
        vm.prank(owner);
        seats.transferFrom(owner, nextOwner, 1999);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        seats.mint(1999);
        assertEq(seats.ownerOf(1999), nextOwner);
        assertEq(seats.balanceOf(owner), 0);
        assertEq(seats.balanceOf(nextOwner), 1);
    }
}
