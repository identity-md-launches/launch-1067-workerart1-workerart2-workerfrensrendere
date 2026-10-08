// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Base64} from "solady/utils/Base64.sol";
import {WorkerArt1, WorkerArt2} from "src/art/WorkerArt.sol";
import {WorkerArtIndex as Art} from "src/art/WorkerArtIndex.sol";
import {WorkerFrensRenderer} from "src/frens/WorkerFrensRenderer.sol";
import {FrenArtChunk1, FrenArtChunk2, FrenArtChunk3, FrenArtChunk4} from "./fixtures/SwarmArtChunks.sol";

contract WorkerArtReadProbe is WorkerFrensRenderer {
    constructor(address a, address b) WorkerFrensRenderer(a, b) {}

    function entry(uint256 i) external view returns (bytes memory) {
        return _entry(i);
    }
}

/// @notice Exercises the actual renderer offline with complete, hash-verified swarm runtimes.
/// No mocked reads or overridden rendering functions: expected.json is the artist's independent oracle.
contract WorkerArtOfflineTest is Test {
    address internal art1;
    address internal art2;
    WorkerFrensRenderer internal renderer;
    WorkerArtReadProbe internal probe;

    function setUp() public {
        address[4] memory fixtures = [
            address(new FrenArtChunk1()),
            address(new FrenArtChunk2()),
            address(new FrenArtChunk3()),
            address(new FrenArtChunk4())
        ];
        for (uint256 i; i < fixtures.length; ++i) {
            address target = _chunk(i);
            vm.etch(target, fixtures[i].code);
            assertEq(target.codehash, _expectedHash(i), "swarm fixture must match the pinned runtime hash");
        }
        art1 = address(new WorkerArt1());
        art2 = address(new WorkerArt2());
        renderer = new WorkerFrensRenderer(art1, art2);
        probe = new WorkerArtReadProbe(art1, art2);
    }

    function test_AllRevealedReferenceRendersOffline() public view {
        string memory refs = vm.readFile("script/art/data/expected.json");
        for (uint256 i; i < 7; ++i) {
            string memory path = string.concat(".revealed[", vm.toString(i), "]");
            uint24 combo = uint24(vm.parseJsonUint(refs, string.concat(path, ".combo")));
            uint256 seed = vm.parseJsonUint(refs, string.concat(path, ".seed"));
            bytes32 expected = vm.parseJsonBytes32(refs, string.concat(path, ".bmpSha256"));
            assertEq(sha256(renderer.bmp(combo, seed)), expected, "reference bitmap");
            (string memory json, bytes memory bitmap,) = _decodeURI(renderer.tokenURI(7, combo, seed));
            assertEq(vm.parseJsonString(json, ".name"), "Worker Fren #7");
            assertEq(sha256(bitmap), expected, "metadata embeds the reference bitmap");
        }
    }

    function test_AllPendingReferenceRendersOffline() public view {
        string memory refs = vm.readFile("script/art/data/expected.json");
        for (uint256 i; i < 3; ++i) {
            string memory path = string.concat(".pending[", vm.toString(i), "]");
            uint256 id = vm.parseJsonUint(refs, string.concat(path, ".tokenId"));
            (string memory json, bytes memory bitmap, bytes memory svg) = _decodeURI(renderer.pendingURI(id));
            assertEq(sha256(bitmap), vm.parseJsonBytes32(refs, string.concat(path, ".bmpSha256")));
            assertEq(vm.parseJsonString(json, ".name"), string.concat("Worker Fren #", vm.toString(id)));
            assertEq(vm.parseJsonString(json, ".attributes[0].trait_type"), "Status");
            assertEq(vm.parseJsonString(json, ".attributes[0].value"), "Unrevealed");
            _checkBitmap(bitmap, renderer.unrevealed(id), 4);
            for (uint256 c; c < 256; ++c) {
                uint256 p = 54 + c * 4;
                assertEq(bitmap[p], bitmap[p + 1], "grey blue/green");
                assertEq(bitmap[p + 1], bitmap[p + 2], "grey green/red");
                assertLe(uint8(bitmap[p]), 153, "pending colours dimmed to 60 percent");
            }
            _find(svg, bytes('values="0;-84;-168;-252;-84"'), 0);
            _find(svg, bytes('repeatCount="indefinite"'), 0);
        }
    }

    /// forge-config: default.fuzz.runs = 96
    function testFuzz_BitmapDecodesToCanvas(uint64 traits, uint256 seed) public view {
        uint24 combo = _validCombo(traits);
        bytes memory bitmap = renderer.bmp(combo, seed);
        _checkBitmap(bitmap, renderer.canvas(combo, seed), 1);
        assertEq(_slice(bitmap, 54, 1024), renderer.palette((combo >> 15) & 15), "BMP palette");
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_MetadataRoundTrip(uint256 id, uint64 traits, uint256 seed) public view {
        _checkMetadata(id, _validCombo(traits), seed);
    }

    function test_MetadataAtIntegerEdges() public view {
        _checkMetadata(0, 0, 0);
        _checkMetadata(type(uint256).max, _validCombo(type(uint64).max), type(uint256).max);
    }

    /// @dev Covers every face, hat, item, background and colour, including combinations disallowed by the collection
    /// but intentionally supported by the renderer's pending frames.
    function test_EveryTraitValueCanRender() public view {
        for (uint256 i; i < 39; ++i) {
            uint24 combo = uint24(
                (i / 13) | ((i % 13) << 2) | ((i % 4) << 6) | ((i % 3) << 8) | ((i % 6) << 10) | ((i % 3) << 13)
                    | ((i % 12) << 15) | ((i % 16) << 19)
            );
            _checkBitmap(renderer.bmp(combo, i), renderer.canvas(combo, i), 1);
        }
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_InvalidTraitsFailWithMissing(uint64 traits, uint256 field, uint8 value, uint256 seed) public {
        uint24 combo = _validCombo(traits);
        uint256[6] memory shifts = [uint256(0), 2, 8, 10, 13, 15];
        uint256[6] memory masks = [uint256(3), 15, 3, 7, 3, 15];
        uint256[6] memory firstInvalid = [uint256(3), 13, 3, 6, 3, 12];
        field = bound(field, 0, 5);
        uint256 invalid = bound(value, firstInvalid[field], masks[field]);
        combo = uint24((combo & ~(masks[field] << shifts[field])) | (invalid << shifts[field]));
        vm.expectRevert(WorkerFrensRenderer.Missing.selector);
        renderer.canvas(combo, seed);
        vm.expectRevert(WorkerFrensRenderer.Missing.selector);
        renderer.bmp(combo, seed);
        vm.expectRevert(WorkerFrensRenderer.Missing.selector);
        renderer.tokenURI(1, combo, seed);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_ConstructorRejectsAnyChangedByte(bool second, uint256 offset, uint8 difference) public {
        address target = second ? art2 : art1;
        bytes memory code = target.code;
        offset = bound(offset, 0, code.length - 1);
        code[offset] ^= bytes1(uint8(bound(difference, 1, 255)));
        vm.etch(target, code);
        try new WorkerFrensRenderer(art1, art2) {
            assertTrue(false, "constructor accepted altered art");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(WorkerFrensRenderer.BadArt.selector));
        }
    }

    /// @dev A successful read must not cache trust. Each used chunk is independently damaged, read, restored and read
    /// again. A single changed byte anywhere in the code, even outside the requested entry, invalidates the chunk.
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_ReadsRecheckHashes(uint256 chunk, uint256 offset, uint8 difference, uint256 seed) public {
        chunk = bound(chunk, 0, 5);
        uint256[6] memory entries = [uint256(0), 14, 25, 37, 39, 69];
        uint24[6] memory combos = [uint24(0), 5, 49, 46, 0, uint24(7 << 15)];
        address target = _chunk(chunk);
        bytes memory original = target.code;
        bytes32 entryHash = keccak256(probe.entry(entries[chunk]));
        bytes32 imageHash = keccak256(renderer.bmp(combos[chunk], seed));
        bytes memory corrupted = bytes.concat(original);
        offset = bound(offset, 0, corrupted.length - 1);
        corrupted[offset] ^= bytes1(uint8(bound(difference, 1, 255)));
        vm.etch(target, corrupted);
        _expectBadArt(entries[chunk], combos[chunk], seed);
        vm.etch(target, "");
        _expectBadArt(entries[chunk], combos[chunk], seed);
        vm.etch(target, original);
        assertEq(keccak256(probe.entry(entries[chunk])), entryHash, "entry restored");
        assertEq(keccak256(renderer.bmp(combos[chunk], seed)), imageHash, "render restored");
    }

    function test_PendingReadsRecheckBothNewChunks() public {
        bytes32 expected = keccak256(bytes(renderer.pendingURI(7)));
        for (uint256 i; i < 2; ++i) {
            address target = i == 0 ? art1 : art2;
            bytes memory original = target.code;
            vm.etch(target, hex"00");
            vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
            renderer.unrevealed(7);
            vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
            renderer.pendingURI(7);
            vm.etch(target, original);
            assertEq(keccak256(bytes(renderer.pendingURI(7))), expected);
        }
    }

    function test_ConstructorOnlyInspectsTheTwoNewChunks() public {
        for (uint256 i; i < 4; ++i) {
            vm.etch(_chunk(i), "");
        }
        bytes memory init = abi.encodePacked(type(WorkerFrensRenderer).creationCode, abi.encode(art1, art2));
        vm.startStateDiffRecording();
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(init, 32), mload(init))
        }
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertNotEq(deployed, address(0));
        uint256 inspected;
        for (uint256 i; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory a = accesses[i];
            if (a.accessor != deployed) continue;
            assertTrue(a.kind == VmSafe.AccountAccessKind.Extcodehash, "constructor did more than inspect code hashes");
            assertTrue(a.account == art1 || a.account == art2, "constructor touched an external dependency");
            inspected |= a.account == art1 ? 1 : 2;
        }
        assertEq(inspected, 3, "constructor checked both chunks");
        assertEq(WorkerFrensRenderer(deployed).art1(), art1);
        assertEq(WorkerFrensRenderer(deployed).art2(), art2);
        assertEq(WorkerFrensRenderer(deployed).palette(0), renderer.palette(0));
    }

    function _expectBadArt(uint256 entry, uint24 combo, uint256 seed) internal {
        vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
        probe.entry(entry);
        vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
        renderer.canvas(combo, seed);
        vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
        renderer.bmp(combo, seed);
        vm.expectRevert(WorkerFrensRenderer.BadArt.selector);
        renderer.tokenURI(1, combo, seed);
    }

    function _checkMetadata(uint256 id, uint24 combo, uint256 seed) internal view {
        (string memory json, bytes memory bitmap,) = _decodeURI(renderer.tokenURI(id, combo, seed));
        assertEq(vm.parseJsonString(json, ".name"), string.concat("Worker Fren #", vm.toString(id)));
        assertEq(vm.parseJson(json, ".attributes"), vm.parseJson(renderer.attributes(combo)));
        assertEq(bitmap, renderer.bmp(combo, seed));
    }

    function _checkBitmap(bytes memory bitmap, bytes memory canvas, uint256 frames) internal pure {
        uint256 height = 84 * frames;
        assertEq(bitmap.length, 1078 + 84 * height);
        assertEq(_le(bitmap, 0, 2), 0x4d42, "BM signature");
        assertEq(_le(bitmap, 2, 4), bitmap.length, "file size");
        assertEq(_le(bitmap, 6, 4), 0, "reserved");
        assertEq(_le(bitmap, 10, 4), 1078, "pixel offset");
        assertEq(_le(bitmap, 14, 4), 40, "DIB header size");
        assertEq(_le(bitmap, 18, 4), 84, "width");
        assertEq(_le(bitmap, 22, 4), height, "height");
        assertEq(_le(bitmap, 26, 2), 1, "planes");
        assertEq(_le(bitmap, 28, 2), 8, "bits per pixel");
        assertEq(_le(bitmap, 30, 4), 0, "uncompressed");
        assertEq(_le(bitmap, 34, 4), canvas.length, "pixel size");
        assertEq(_le(bitmap, 46, 4), 256, "palette entries");
        assertEq(canvas.length, 84 * height);
        for (uint256 y; y < height; ++y) {
            assertEq(_slice(bitmap, 1078 + y * 84, 84), _slice(canvas, (height - 1 - y) * 84, 84), "bottom-up row");
        }
    }

    function _decodeURI(string memory uri)
        internal
        pure
        returns (string memory json, bytes memory bitmap, bytes memory svg)
    {
        bytes memory raw = bytes(uri);
        assertEq(string(_slice(raw, 0, 29)), "data:application/json;base64,");
        json = string(Base64.decode(string(_slice(raw, 29, raw.length - 29))));
        bytes memory img = bytes(vm.parseJsonString(json, ".image"));
        assertEq(string(_slice(img, 0, 26)), "data:image/svg+xml;base64,");
        svg = Base64.decode(string(_slice(img, 26, img.length - 26)));
        bytes memory marker = bytes("data:image/bmp;base64,");
        uint256 start = _find(svg, marker, 0) + marker.length;
        uint256 end = _find(svg, bytes('"'), start);
        bitmap = Base64.decode(string(_slice(svg, start, end - start)));
    }

    function _find(bytes memory haystack, bytes memory needle, uint256 start) internal pure returns (uint256) {
        for (uint256 i = start; i + needle.length <= haystack.length; ++i) {
            bool matched = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return i;
        }
        revert("missing URI component");
    }

    function _slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory result) {
        require(start <= data.length && length <= data.length - start, "slice out of bounds");
        result = new bytes(length);
        assembly ("memory-safe") { mcopy(add(result, 32), add(add(data, 32), start), length) }
    }

    function _le(bytes memory data, uint256 offset, uint256 length) internal pure returns (uint256 value) {
        for (uint256 i; i < length; ++i) {
            value |= uint256(uint8(data[offset + i])) << (i * 8);
        }
    }

    function _validCombo(uint64 traits) internal pure returns (uint24) {
        return uint24(
            uint256(uint8(traits)) % 3 | (uint256(uint8(traits >> 8)) % 13) << 2 | (uint256(uint8(traits >> 16)) % 4)
                << 6 | (uint256(uint8(traits >> 24)) % 3) << 8 | (uint256(uint8(traits >> 32)) % 6) << 10
                | (uint256(uint8(traits >> 40)) % 3) << 13 | (uint256(uint8(traits >> 48)) % 12) << 15
                | (uint256(uint8(traits >> 56)) % 16) << 19
        );
    }

    function _chunk(uint256 i) internal view returns (address) {
        return [Art.SWARM_CHUNK1, Art.SWARM_CHUNK2, Art.SWARM_CHUNK3, Art.SWARM_CHUNK4, art1, art2][i];
    }

    function _expectedHash(uint256 i) internal pure returns (bytes32) {
        return vm.parseBytes32(string.concat("0x", string(_slice(Art.CHUNK_HASHES, i * 64, 64))));
    }
}
