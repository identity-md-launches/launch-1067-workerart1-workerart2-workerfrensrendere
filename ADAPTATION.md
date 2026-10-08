# Worker Frens ART launch adaptation

## Scope and deployment

This assignment prepares the independent **art** launch on Ethereum. The factory creates exactly these three
contracts, in order, in one transaction, with zero ETH and no initialization calls:

| Order | Contract | Source | Constructor arguments |
| --- | --- | --- | --- |
| 1 | `WorkerArt1` | `src/art/WorkerArt.sol` | none |
| 2 | `WorkerArt2` | `src/art/WorkerArt.sol` | none |
| 3 | `WorkerFrensRenderer` | `src/frens/WorkerFrensRenderer.sol` | `$contract:WorkerArt1`, `$contract:WorkerArt2` |

All three constructors are nonpayable. None of these contracts has an owner or any role, and the factory receives
no authority. The chunks return the existing art as runtime code: STOP followed by PUSH32 frames. The renderer's
constructor checks both chunks' code hashes against `WorkerArtIndex`, reverting with `BadArt` on a mismatch. It
makes no external calls and needs no existing Ethereum contracts to deploy. Each subsequent art read checks the
relevant chunk's hash, including reads of the swarm's seven chunks already on Ethereum.

The collection is a separate launch: `PlaceFrens`, then `PlaceModules($contract:PlaceFrens)`. Either launch may
happen first. Once both are deployed, the team wallet runs `script/frens/DeployFrens.s.sol` `setup()` with `MODULES`
set to the collection launch's `PlaceModules` and `RENDERER` set to the art launch's confirmed renderer address.
This is the existing collection setup boundary, not an initialization requirement of the three art contracts.

## Changes in this assignment

- **`launch.json`:** replaced the stale four-contract manifest with the three-contract art launch above. Removed
  the collection contracts from this launch, supplied the renderer's two backward references in the required order,
  and corrected the notes to describe the separate launches, hash checks and `RENDERER` handoff. Required by the
  brief and reproduced audit finding `2c9d5fa27834d3bef243813389f66b0f24fa0468bd3a052fc90147aca81f765f`.
- **`test/test_art_launch_manifest.py`:** added an offline regression check of the actual committed manifest's
  contract list, order, arguments and schema, plus constructor arity, nonpayability and dependency references against
  the ABIs produced by `forge build`. It rejects the original manifest. It uses only Python's standard library;
  run `python3 test/test_art_launch_manifest.py` after building. This runs separately because the unchanged Foundry
  configuration grants file reads only to the existing art and price data directories, not `launch.json`.
- **`ADAPTATION.md`:** replaced the previous launch's report and stale four-contract table with this assignment's
  scope, changes, audit dispositions and verification results.

No Solidity source, art data, salt, planned address, script, existing test, build configuration or dependency was
changed. The fixes merged from IMD job fd3018ee (launch 1043) remain as delivered. Those earlier changes include
keeping the last fren out, accounting for unswept IMD, releasing lapsed job payments, proportional swapper averaging,
rejecting skewed pre-placed swappers, enforcing the worker window, and pausing floor buys during collection setup
until distributor authorization. They are inherited behavior, not changes made by this assignment.

## Imported audit dispositions

### Medium: stale manifest (`2c9d5fa2…`) — reproduced and fixed

The original manifest listed `PlaceFrens`, `WorkerArt1`, `WorkerArt2`, `PlaceModules`, omitted
`WorkerFrensRenderer`, and supplied three arguments to the current one-argument `PlaceModules` constructor.
The source confirms that `PlaceModules` no longer creates a renderer. Thus deploying the original manifest would
leave the art launch incomplete, even though Solidity accepts surplus constructor argument words.

A scratch Foundry reproduction deploys those four contracts, including the surplus argument words, and prices the
whole transaction using the repository's formula: creations, 21,000 base gas, EIP-7623 calldata rates, and
`300,000 + 7 * inputBytes` launcher overhead. The raw-CREATE scratch harness measures 22,000,689 gas, exceeding
the 16,777,216 cap. This reproduces the over-limit finding, not the audit's exact 23,761,253 measurement: the
scratch harness loads creation bytecode through Foundry instead of embedding it through Solidity `new`. The existing
`test_EachLaunchFitsOneTransaction` instead prices each split launch and requires 1,000,000 gas of headroom.
The delivered manifest selects exactly the art contracts that test measures; no gas-sensitive source changes are
needed. The manifest regression fails before the fix and passes afterward.

### Info: art contract coverage (`acc54b8e…`) — no defect reported or reproduced

Reviewed the chunk constructors and framing, index and hashes, renderer constructor and drawing/read paths, collection
placement boundary, and setup's `RENDERER` input against the brief. The existing tests cover fresh-chain factory
deployment, `BadArt` for wrong or reordered chunks and changed code, readback of the art data, runtime/initcode limits,
and admission scanning with PUSH data skipped. The fork suite compares seven revealed frens and three unrevealed
cards against the art kit's reference BMP hashes in `script/art/data/expected.json` and exercises all layers.
No source fix is warranted by this informational finding. No imported defect was dismissed as non-reproducible.

## Verification

Using Foundry 1.8.3 and the unchanged project configuration (Solidity 0.8.30, via-IR, optimizer 200, Cancun,
`bytecode_hash = "none"):

- `forge build --offline`: passed; existing compiler/lint warnings remain.
- `forge test --offline`: **174 passed, 0 failed, 5 skipped**, including one scratch gas reproduction. The other
  173 passing tests are the repository's existing suite; the five skipped suites require `MAINNET_RPC_URL`.
- `python3 test/test_art_launch_manifest.py`: **2 passed**. Both checks also rejected the original manifest:
  the wrong contract list and `PlaceModules`' three arguments against its compiled one-argument ABI.
- `forge test --offline --match-test test_EachLaunchFitsOneTransaction -vv`: passed as part of the targeted gas run.
  Collection: **12,308,310** gas; art: **13,605,058** gas. The art leaves **3,172,158** gas below 2^24, exceeding the
  required 1,000,000 margin.
- `MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --offline --match-contract FrensPlacementForkTest -vv`:
  **5 passed, 1 failed** at block 26,148,978. Both drawing tests, the renderer setup test and the whole-road test
  passed. `test_fork_WorkersFirstThenPublic` fails at the existing Ethereum timelock's `scheduleBatch`, before
  collection setup: `TimelockUnexpectedOperationState(bytes32,bytes32)` (`0x5ead8eb5`). A read of that operation at
  block 26,148,985 confirms state 1 (Waiting): this exact batch is already scheduled. No contract, salt or test was
  changed to bypass that live-state condition.
- Re-ran the same unmodified six-test fork suite against an Anvil RPC fork pinned to the audit's Ethereum block
  **26,148,881** (`0x18f0011`): **6 passed, 0 failed**. Reproduce by starting
  `anvil --silent --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26148881 --port 18545`, then
  running `MAINNET_RPC_URL=http://127.0.0.1:18545 forge test --offline --match-contract FrensPlacementForkTest -vv`.
  The reference BMP hashes match for all seven revealed frens and three unrevealed cards. Revealed metadata costs
  3,711,139–4,190,689 gas; pending metadata costs 13,057,672–13,651,113 gas.
- Independently fetched all seven swarm chunks at block **26,148,957** and checked their code hashes against
  `WorkerArtIndex`: all match. These RPC checks are optional verification, not offline build dependencies.
- `git diff --check` passed, and a diff check confirmed no changes to `src/`, `script/`, the salts, build settings
  or vendored dependencies. No submitted file depends on `.imd/reads` or `test/scratch/`.

The supplied protected harness was read as an input. Its constructor-only CREATE2 probe and runtime admission
checks are already represented by the repository's factory and admission tests, compiled with the project's pinned
Solidity version. No production deployment, broadcast, dependency installation, Slither or Mythril run was performed.
