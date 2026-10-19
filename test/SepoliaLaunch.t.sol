// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {InkPortraits} from "../src/InkPortraits.sol";
import {InkVault} from "../src/InkVault.sol";
import {InkLiquidity} from "../src/InkLiquidity.sol";
import {InkRenderer} from "../src/InkRenderer.sol";

/// Test-only factory: one transaction, zero ETH, no initialization calls.
contract SepoliaFactoryProbe {
    function deployAll(bytes[] memory codes) external returns (address[] memory deployed) {
        deployed = new address[](codes.length);
        for (uint256 i; i < codes.length; i++) {
            bytes memory code = codes[i];
            bytes32 salt = bytes32(i);
            address created;
            assembly ("memory-safe") {
                created := create2(0, add(code, 32), mload(code), salt)
            }
            require(created != address(0), "constructor failed");
            deployed[i] = created;
        }
    }
}

contract SepoliaLaunchTest is Test {
    // Request values; Uniswap addresses from its official v4 deployments page, Sepolia 11155111.
    address constant OWNER = 0x824E12b38CfF2D3e7ad9607a0212f7F9Eb6a06E3;
    address constant TREASURY = 0xbc10B3662231c830d2ee10bc6359dB17bEa4b3d4;
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    SepoliaFactoryProbe internal factory;
    address[] internal apps;
    InkPortraits internal portraits;
    InkVault internal vault;
    InkLiquidity internal liquidity;
    InkRenderer internal renderer;

    function _predict(bytes memory code, uint256 salt) internal view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), bytes32(salt), keccak256(code))
                    )
                )
            )
        );
    }

    function setUp() public {
        vm.chainId(11155111);
        assertEq(POOL_MANAGER.code.length, 0, "constructors must work without live dependencies");
        assertEq(POSITION_MANAGER.code.length, 0);
        factory = new SepoliaFactoryProbe();
        bytes[] memory codes = new bytes[](5);
        codes[0] = vm.getCode("src/testnet/TestSeats.sol:TestSeats");
        codes[1] = abi.encodePacked(vm.getCode("src/InkPortraits.sol:InkPortraits"), abi.encode(OWNER));
        address predictedSeats = _predict(codes[0], 0);
        address predictedPortraits = _predict(codes[1], 1);
        codes[2] = abi.encodePacked(
            vm.getCode("src/InkVault.sol:InkVault"), abi.encode(predictedPortraits, predictedSeats, OWNER)
        );
        codes[3] = abi.encodePacked(
            vm.getCode("src/InkLiquidity.sol:InkLiquidity"),
            abi.encode(POOL_MANAGER, POSITION_MANAGER, OWNER, TREASURY)
        );
        codes[4] = abi.encodePacked(
            vm.getCode("src/InkRenderer.sol:InkRenderer"), abi.encode(predictedPortraits, OWNER)
        );
        for (uint256 i; i < codes.length; i++) {
            assertLe(codes[i].length, 49_152, "init code size");
        }
        apps = factory.deployAll(codes);
        for (uint256 i; i < apps.length; i++) {
            assertEq(apps[i], _predict(codes[i], i));
        }
        portraits = InkPortraits(apps[1]);
        vault = InkVault(apps[2]);
        liquidity = InkLiquidity(apps[3]);
        renderer = InkRenderer(apps[4]);
    }

    function test_factoryDeploymentPreservesOwnersRoyaltiesAndReferences() public view {
        assertEq(block.chainid, 11155111);
        for (uint256 i = 1; i < apps.length; i++) {
            assertEq(Ownable(apps[i]).owner(), OWNER);
            assertNotEq(Ownable(apps[i]).owner(), address(factory));
            assertNotEq(Ownable(apps[i]).owner(), TREASURY);
        }
        (address royaltyReceiver, uint256 royalty) = portraits.royaltyInfo(10_000, 100 ether);
        assertEq(royaltyReceiver, OWNER);
        assertEq(royalty, 0);
        assertEq(address(vault.portraits()), apps[1]);
        assertEq(address(vault.seats()), apps[0]);
        assertEq(address(renderer.portraits()), apps[1]);
        assertEq(address(liquidity.poolManager()), POOL_MANAGER);
        assertEq(address(liquidity.positionManager()), POSITION_MANAGER);
        assertEq(liquidity.treasury(), TREASURY);
    }

    function test_allFiveRuntimesMeetProtectedFloor() public view {
        for (uint256 i; i < apps.length; i++) {
            bytes memory code = apps[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576);
            for (uint256 pc; pc < code.length; pc++) {
                uint8 op = uint8(code[pc]);
                if (op >= 0x60 && op <= 0x7f) {
                    pc += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
            }
        }
    }

    function _denied(address caller, address target, bytes memory payload) internal {
        vm.prank(caller);
        (bool ok, bytes memory reason) = target.call(payload);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    }

    function test_factoryTreasuryAndOutsiderHaveNoAdminRole() public {
        address[3] memory callers = [address(factory), TREASURY, makeAddr("outsider")];
        PoolKey memory key;
        for (uint256 i; i < callers.length; i++) {
            address caller = callers[i];
            _denied(caller, apps[1], abi.encodeCall(portraits.setVault, (apps[2])));
            _denied(caller, apps[1], abi.encodeCall(portraits.setRenderer, (apps[4])));
            _denied(caller, apps[1], abi.encodeCall(portraits.lockRenderer, ()));
            _denied(caller, apps[1], abi.encodeCall(portraits.setContractURI, ("ipfs://collection")));
            _denied(caller, apps[2], abi.encodeCall(vault.setInk, (IERC20(caller))));
            _denied(
                caller,
                apps[2],
                abi.encodeCall(vault.setup, (keccak256("test"), uint64(block.timestamp), apps[3]))
            );
            _denied(caller, apps[2], abi.encodeCall(vault.setFees, (100, 50)));
            _denied(caller, apps[3], abi.encodeCall(liquidity.setPool, (key, IERC20(caller))));
            _denied(caller, apps[3], abi.encodeCall(liquidity.setWidth, (20_000)));
            _denied(caller, apps[3], abi.encodeCall(liquidity.setPremium, (0)));
            _denied(caller, apps[4], abi.encodeCall(renderer.addChunk, (bytes("test"))));
            _denied(caller, apps[4], abi.encodeCall(renderer.setPreviewBase, ("ipfs://previews/")));
            _denied(caller, apps[4], abi.encodeCall(renderer.lock, ()));
            for (uint256 j = 1; j < apps.length; j++) {
                _denied(caller, apps[j], abi.encodeCall(Ownable.transferOwnership, (caller)));
                _denied(caller, apps[j], abi.encodeCall(Ownable.renounceOwnership, ()));
            }
        }
    }

    function test_existingOwnerSetupRemainsRequiredAndAvailable() public {
        assertEq(portraits.vault(), address(0));
        assertEq(portraits.renderer(), address(0));
        assertFalse(vault.claimOpen());
        assertEq(renderer.chunkCount(), 0);
        assertEq(
            vm.parseJsonUint(renderer.tokenJSON(0), ".traitRerollBlock"),
            0,
            "agent metadata never needs a reroll lookup"
        );
        assertFalse(liquidity.poolSet());
        vm.expectRevert(InkVault.NotReleased.selector);
        vault.pull(1);
        vm.expectRevert(InkVault.InkNotSet.selector);
        vault.release();
        vm.expectRevert(InkLiquidity.PoolNotSet.selector);
        liquidity.addLiquidity();

        vm.startPrank(OWNER);
        portraits.setVault(apps[2]);
        portraits.setRenderer(apps[4]);
        portraits.setContractURI("ipfs://collection");
        portraits.lockRenderer();
        vm.stopPrank();
        assertEq(portraits.vault(), apps[2]);
        assertEq(portraits.renderer(), apps[4]);
        assertTrue(portraits.rendererLocked());
    }
}
