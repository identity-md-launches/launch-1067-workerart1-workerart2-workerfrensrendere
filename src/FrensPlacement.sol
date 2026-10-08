// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FrensCode} from "./FrensCode.sol";
import {FrensPlan} from "./FrensPlan.sol";

/// @dev What PlaceModules reads of the swapper it placed (FrenSwapper)
interface IPlacedSwapper {
    function rateAverage() external view returns (uint256);
    function averagedAt() external view returns (uint256);
    function spotRate() external view returns (uint256);
}

/// @dev Creates a contract through the standard CREATE2 deployer, so where it lands depends only on the salt and the
///      code (FrensPlan's addresses), not on who runs the launch. Where that deployer doesn't exist (IMD first runs a
///      launch on a fresh chain) it creates the same contract with this contract's own CREATE2: another address, the
///      same contract. If the planned address already holds the contract (anyone can place these exact bytes there,
///      and it is then the very contract this would create), it is used as it is.
abstract contract Placer {
    error PlaceFailed();

    function _place(bytes32 salt, bytes memory init) internal returns (address a) {
        address deployer = FrensPlan.CREATE2_DEPLOYER;
        if (deployer.code.length == 0) {
            assembly ("memory-safe") {
                a := create2(0, add(init, 32), mload(init), salt)
            }
            if (a == address(0)) revert PlaceFailed();
            return a;
        }
        a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(init))))));
        if (a.code.length != 0) return a;
        (bool ok,) = deployer.call(abi.encodePacked(salt, init));
        if (!ok || a.code.length == 0) revert PlaceFailed();
    }
}

/// @title PlaceFrens - the IMD swarm's collection launch of Worker Frens, part one: the price table and the collection
/// @dev The collection launch: PlaceFrens, then PlaceModules. The art launch, separately: WorkerArt1, WorkerArt2 (the
///      new art, as code: src/art/WorkerArt.sol), then WorkerFrensRenderer over them.
/// @notice Its constructor creates the frens' price curve (FrenPrices) and the collection (IMD6900Frens, named Worker
///         Frens) at FrensPlan's addresses (0x6900… for the frens), for the team wallet (owner and governor), with the
///         swarm's keeper and relayer. It calls nothing that existed before it but the CREATE2 deployer, and only if it is
///         there. After the launch the owner wires the frens (script/frens/DeployFrens.s.sol setup()).
contract PlaceFrens is Placer {
    address public immutable prices;
    address public immutable frens;

    constructor() {
        address p = _place(FrensPlan.PRICES_SALT, FrensCode.PRICES);
        prices = p;
        frens = _place(
            FrensPlan.FRENS_SALT,
            abi.encodePacked(
                FrensCode.FRENS,
                abi.encode(
                    FrensPlan.OWNER,
                    FrensPlan.IMD,
                    FrensPlan.IMD6900,
                    FrensPlan.IDENTITY,
                    FrensPlan.PERMIT2,
                    FrensPlan.X402_PROXY,
                    FrensPlan.IMD_PAY_TO,
                    FrensPlan.KEEPER,
                    FrensPlan.RELAYER,
                    p
                )
            )
        );
    }
}

/// @title PlaceModules - the IMD swarm's collection launch of Worker Frens, part two: the frens' swapper, minter and gate
/// @notice Its constructor creates, for the frens PlaceFrens placed: the floor's swapper (FrenSwapper, 0x6900…), the
///         ETH mint (FrenMinter) and the workers' and WL's window (FrenWorkerGate, the team wallet's), at FrensPlan's
///         addresses. The launch passes it PlaceFrens (`$contract:PlaceFrens`). The art (WorkerArt1, WorkerArt2 and
///         WorkerFrensRenderer) is a launch of its own: every contract of a launch is created in one transaction, and
///         the collection and its art together need more than EIP-7825's 2^24 gas. The team wallet points the frens at
///         that launch's renderer (setup()).
/// @dev It never wires the frens wrong: a swapper it finds already placed at 0x6900… is taken only if its price average
///      is the pool's price now (within 2x); otherwise the launch creates its own (a plain CREATE from this contract,
///      so nobody can have put anything there), seeded at this block's price, and that one is the frens' swapper
///      (`swapper()`), not FrensPlan.SWAPPER_AT.
contract PlaceModules is Placer {
    address public immutable frens;
    address public immutable swapper;
    address public immutable minter;
    address public immutable gate;

    constructor(PlaceFrens placed) {
        address f = placed.frens();
        frens = f;
        bytes memory init = abi.encodePacked(
            FrensCode.SWAPPER,
            abi.encode(
                FrensPlan.POOL_MANAGER, FrensPlan.IMD, FrensPlan.IMD6900, f, FrensPlan.PAIR_HOOK, FrensPlan.POOL4_HOOK
            )
        );
        address s = _place(FrensPlan.SWAPPER_SALT, init);
        if (!_soundSwapper(s)) {
            assembly ("memory-safe") {
                s := create(0, add(init, 32), mload(init))
            }
            if (s == address(0)) revert PlaceFailed();
        }
        swapper = s;
        minter = _place(
            FrensPlan.MINTER_SALT,
            abi.encodePacked(
                FrensCode.MINTER, abi.encode(FrensPlan.POOL_MANAGER, f, FrensPlan.POOL4_HOOK, FrensPlan.PAIR_HOOK)
            )
        );
        gate = _place(
            FrensPlan.GATE_SALT,
            abi.encodePacked(FrensCode.GATE, abi.encode(FrensPlan.OWNER, f, FrensPlan.IDENTITY, FrensPlan.IMD6900))
        );
    }

    /// @dev The swapper's slow price average starts at the IMD6900/$IMD pool's price in the block that creates it, and
    ///      the frens value their floor at the lower of it and the pool's price. Anyone may place the exact swapper
    ///      before the launch, in a block whose price they pushed: the launch takes only one whose average is the
    ///      pool's price now, within 2x. Nothing seeded (no pool manager here, or the pool not open): nothing to check.
    function _soundSwapper(address s) internal view returns (bool) {
        if (IPlacedSwapper(s).averagedAt() == 0) return true;
        uint256 avg = IPlacedSwapper(s).rateAverage();
        uint256 spot = IPlacedSwapper(s).spotRate();
        return avg * 2 >= spot && avg <= spot * 2;
    }
}
