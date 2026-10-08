// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {WorkerArt1, WorkerArt2} from "src/art/WorkerArt.sol";
import {WorkerFrensRenderer} from "src/frens/WorkerFrensRenderer.sol";

/// @dev The chunks begin with STOP, so calls (including ETH transfers) succeed without executing the art bytes.
/// Track value actually sent, while different callers try to change the art or pay the nonpayable renderer.
contract WorkerArtCallHandler is Test {
    address[2] public chunks;
    address[3] public actors;
    uint256[2] public ghostDeposited;
    WorkerFrensRenderer public immutable renderer;

    constructor(address a, address b, WorkerFrensRenderer r) {
        chunks = [a, b];
        actors = [address(0xA11CE), address(0xB0B), address(0xCAFE)];
        renderer = r;
    }

    function sendToChunk(uint256 chunkSeed, uint256 actorSeed, uint96 amount, bytes calldata payload) external {
        uint256 i = bound(chunkSeed, 0, 1);
        address actor = actors[bound(actorSeed, 0, 2)];
        uint256 value = bound(amount, 0, 1 ether);
        vm.deal(actor, value);
        vm.prank(actor);
        (bool ok, bytes memory result) = chunks[i].call{value: value}(payload);
        assertTrue(ok, "STOP data chunk call failed");
        assertEq(result.length, 0, "data chunk executed a function");
        ghostDeposited[i] += value;
    }

    function tryToChangeArt(uint256 actorSeed, uint256 operation, address replacement) external {
        bytes[5] memory payloads = [
            abi.encodeWithSignature("transferOwnership(address)", replacement),
            abi.encodeWithSignature("setArt(address,address)", replacement, replacement),
            abi.encodeWithSignature("setRenderer(address)", replacement),
            abi.encodeWithSignature("grantRole(bytes32,address)", bytes32(0), replacement),
            abi.encodeWithSignature("owner()")
        ];
        bytes memory payload = payloads[bound(operation, 0, payloads.length - 1)];
        address actor = actors[bound(actorSeed, 0, 2)];
        for (uint256 i; i < 2; ++i) {
            vm.prank(actor);
            (bool ok, bytes memory result) = chunks[i].call(payload);
            assertTrue(ok);
            assertEq(result.length, 0, "chunk has no role or configuration interface");
        }
        vm.prank(actor);
        (bool accepted,) = address(renderer).call(payload);
        assertFalse(accepted, "renderer exposed an administrative function");
    }

    function payRenderer(uint256 actorSeed, uint96 amount, uint256 background) external {
        address actor = actors[bound(actorSeed, 0, 2)];
        uint256 value = bound(amount, 1, 1 ether);
        bytes memory payload = abi.encodeCall(renderer.palette, (bound(background, 0, 11)));
        vm.deal(actor, value);
        vm.prank(actor);
        (bool accepted,) = address(renderer).call{value: value}(payload);
        assertFalse(accepted, "nonpayable renderer accepted ETH");
        assertEq(actor.balance, value, "rejected payment was not refunded");
    }
}

contract WorkerArtInvariantsTest is Test {
    address internal art1;
    address internal art2;
    WorkerFrensRenderer internal renderer;
    WorkerArtCallHandler internal handler;
    bytes32[3] internal initialCodeHashes;
    bytes32[12] internal initialPalettes;

    function setUp() public {
        art1 = address(new WorkerArt1());
        art2 = address(new WorkerArt2());
        renderer = new WorkerFrensRenderer(art1, art2);
        initialCodeHashes = [art1.codehash, art2.codehash, address(renderer).codehash];
        for (uint256 i; i < 12; ++i) {
            initialPalettes[i] = keccak256(renderer.palette(i));
        }
        handler = new WorkerArtCallHandler(art1, art2, renderer);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.sendToChunk.selector;
        selectors[1] = handler.tryToChangeArt.selector;
        selectors[2] = handler.payRenderer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_CodeAndArtNeverChangeThroughCalls() public view {
        assertEq(art1.codehash, initialCodeHashes[0]);
        assertEq(art2.codehash, initialCodeHashes[1]);
        assertEq(address(renderer).codehash, initialCodeHashes[2]);
        assertEq(renderer.art1(), art1);
        assertEq(renderer.art2(), art2);
        for (uint256 i; i < 12; ++i) {
            assertEq(keccak256(renderer.palette(i)), initialPalettes[i]);
        }
    }

    /// @dev These data contracts do not promise withdrawals or keep user balances. This checks conservation of
    /// unsolicited ETH under their STOP runtime, not a custody or redeemability guarantee.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 48
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_OnlySuccessfulChunkPaymentsRemain() public view {
        assertEq(art1.balance, handler.ghostDeposited(0));
        assertEq(art2.balance, handler.ghostDeposited(1));
        assertEq(address(renderer).balance, 0);
    }

    function test_CallSequenceExercisesEveryHandlerAndPaymentBoundary() public {
        handler.sendToChunk(0, 0, 0, "");
        handler.sendToChunk(0, 1, 1, hex"ffffffff");
        handler.sendToChunk(1, 2, 1 ether, abi.encodeWithSignature("withdraw()"));
        handler.tryToChangeArt(0, 1, address(0));
        handler.tryToChangeArt(1, 0, address(handler));
        handler.payRenderer(2, 1, 0);
        handler.payRenderer(0, 1 ether, 11);
        assertEq(handler.ghostDeposited(0), 1);
        assertEq(handler.ghostDeposited(1), 1 ether);
        invariant_CodeAndArtNeverChangeThroughCalls();
        invariant_OnlySuccessfulChunkPaymentsRemain();
    }
}
