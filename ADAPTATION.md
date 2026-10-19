# Sepolia contracts-only launch adaptation

## Scope and deployment handoff

This change prepares the five requested application contracts for the IMD deployment step.
No transaction was signed or broadcast. No launch token, hook, pool, fee router, proxy,
upgrade authority, additional owner, or `launch.json` was added. Build configuration and
vendored dependencies are unchanged.

Chain: **Sepolia, 11155111**. `$owner` is
**`0x824e12b38cff2d3e7ad9607a0212f7f9eb6a06e3`**. The manifest step must preserve this order:

| Order | Source / contract | Constructor arguments, in order |
| --- | --- | --- |
| 1 | `src/testnet/TestSeats.sol:TestSeats` | None |
| 2 | `src/InkPortraits.sol:InkPortraits` | `$owner` |
| 3 | `src/InkVault.sol:InkVault` | `$contract:InkPortraits`, `$contract:TestSeats`, `$owner` |
| 4 | `src/InkLiquidity.sol:InkLiquidity` | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`, `0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4`, `$owner`, `0xbc10b3662231c830d2ee10bc6359db17bea4b3d4` |
| 5 | `src/InkRenderer.sol:InkRenderer` | `$contract:InkPortraits`, `$owner` |

The first two InkLiquidity arguments are the Sepolia PoolManager and PositionManager in
[Uniswap's official v4 deployment table](https://developers.uniswap.org/docs/protocols/v4/deployments#sepolia-11155111),
consulted during this adaptation. An attempted live JSON-RPC check at
`https://ethereum-sepolia-rpc.publicnode.com` returned **HTTP 403 Forbidden**. Addresses
are verified against the official documentation, but live bytecode and Sepolia position
minting were not verified in this run. They remain explicit constructor arguments;
constructors do not call them or require deployed code. The deployer should confirm their
code and the PositionManager's `poolManager()` before launch.

The treasury is solely the existing fee recipient. It receives no owner, admin, mint,
withdrawal, or upgrade role. All four Ownable contracts and the unchanged zero-bps
ERC-2981 royalty recipient use `$owner`. TestSeats has no owner role. Constructors already
had the requested static argument counts (0, 1, 3, 4, 2), accept no ETH, and need no
factory initialization calls; their signatures and ownership behavior are unchanged.

## Changes and reproduced findings

The four regression scenarios in `test/AuditRegression.t.sol` were run against the
original sources before any production edits. All four failed their safety assertions:
large-queue reveal exhausted its gas budget, and the other three operations unexpectedly
succeeded. The same scenarios pass after the fixes.

1. **`c9ef94239ac554e450013ca46291d2a44b6b49d94a820c4aaf4bd4313e3cbc82` — reproduced and fixed.**
   `src/InkVault.sol` limits each admission step to the named constant
   `MAX_ADMISSIONS = 100`. Incomplete admission persists and emits `AdmissionProgress`;
   `reveal` returns false and `revealNext` stops without counting that pull as revealed.
   Callers can continue using either entry point. The draw waits for **all** deposits
   eligible for that pull, preserving FIFO order, the strict deposit-block cutoff, the
   candidate order, and the original entropy/selection rule. Expired hashes still renew
   under the existing rule. No INK is refunded, charged, or moved by partial admission.
   The 2,000-deposit regression exercises actual pulls and deposits, caps each continuation
   at 5,000,000 gas, and delivers both the affected pull and the following pull. Its
   largest measured step was 3,453,631 gas including call overhead. Additional tests cover
   both entry points, batch boundaries, later/same-block deposits, and hash expiry halfway
   through admission. A caller asking to reveal many pulls at once still chooses its own
   batch size; `revealNext(1)` is the bounded path through the queue.

2. **`b0a5b130b312d0e6efa1bfa28084434a54f661f2e19cf16c8d02890de11e849c` — reproduced and fixed.**
   `src/InkVault.sol:onERC721Received` now reverts `UseDeposit`. The supported `deposit`
   path uses `transferFrom`, accounts for the NFT, and pays the original refund and fee.
   Tests cover both safe-transfer overloads, unrelated NFTs, unchanged custody on revert,
   and a successful paid deposit. The existing receiver assertion in
   `test/InkSystem.t.sol` was updated to require this rejection. An explicit unsafe
   ERC-721 `transferFrom` bypasses receiver checks by design: users must use `deposit`
   to receive INK; this patch does not add a recovery power.

3. **`ff3bd9078e952868fabf14b3ab80f34c04fb126267274a242df57ea747badd10` — uninitialized-floor defect reproduced and fixed.**
   `src/InkLiquidity.sol:setPool` requires nonzero `sqrtPriceX96` from the selected pool
   before committing `poolSet`, the key, INK, or `floorTick`. A real local PoolManager
   test rejects an uninitialized pool, initializes it at tick 129,000, retries successfully,
   and confirms the existing one-time setting cannot be overwritten. A separate test
   accepts an initialized pool at tick zero. All existing floor
   and liquidity economics tests still pass. The owner still chooses the hook and paired
   currency: the expected future hook address is not a constructor input in this brief,
   and this launch creates neither hook nor pool. An initialized wrong pool is therefore
   still an owner configuration risk; no expected hook/token address was invented or
   silently hardcoded. Validate the complete later launch's PoolKey before `setPool`.

4. **`5574e8bc99748c59f09b594989c88c65b955480b24699a8dea0701c0a30c3a24` — reproduced and fixed.**
   `src/InkPortraits.sol:_update` rejects transfers of an existing swarm portrait while
   its configured vault reports a pending trait reroll. This also covers approved
   operators and both safe-transfer overloads. The holder alone requests the reroll;
   anyone can reveal it. There is no administrative freeze switch, new role, cancellation,
   or change to fees/randomness. Minting and agent transfers do not query the reroll state.
   `src/InkRenderer.sol:tokenJSON` includes numeric `traitRerollBlock` (zero for agents or
   no pending repaint). Tests cover visible pending/renewed/completed states, unchanged
   approvals after rejection, and successful transfers after permissionless completion.
   `test/VaultInvariants.t.sol` now expects the specific rejection during random transfers
   of pending portraits, while continuing to exercise all transfers and custody invariants.

## Other imported audit entries

- **`770ef424206b5b98daf7099cb0779774d2947d7f4ad1f7271ea3c3f7f35ab73b` — setup dependency confirmed; intentionally retained.**
  The exact constructor-only deployment is tested in `test/SepoliaLaunch.t.sol`.
  The vault initially refuses pulls/release, liquidity refuses additions, and the renderer
  has no script. Moving the existing owner setup into constructors would conflict with
  the explicitly requested signatures and deployment order, circular NFT/vault reference,
  later token/hook launch, and uploaded art. The request's behavior-preservation rule
  takes precedence over the generic reference's fully-configured-constructor language.
  Existing owner-only setup and presentation settings remain, with negative authorization
  tests for the factory, treasury, and an unrelated address. The owner can still transfer
  or renounce its existing Ownable roles; no authority was added.

- **`80009a67b9f619821d13a7683408a5ac526acfd39e3bbb12b808d4574afd75d2` — spot dependence confirmed; profitable exploit not reproduced.**
  `test_permissionlessListingTracksSpotAboveReleaseFloor` in `test/InkSystem.t.sol`
  buys INK, adds fee liquidity, sells to move the price, and adds again. The new listing
  moves with spot and still respects the release floor. The existing manipulated-price
  and ladder tests also pass. This confirms the reported design tradeoff, not an
  economically profitable attack. No TWAP, new caller role, or pricing redesign was added.

- **`9b350d6a0f95e945ff032fffe1afb628fa022cbf39dc1b884043f2cb41246159` — operational dependency reproduced; retained.**
  `test_releaseFailureRollsBackUntilLiquidityIsConfigured` verifies that `PoolNotSet`
  propagates, `released` remains false, all 800M fixture INK remains in the vault, and
  pulls stay closed. The original pool-lock behavior and lack of time fallback remain.
  Configure and simulate actual liquidity before the claim window ends. The original
  `InkNotSet` error for missing setup is also retained to avoid unrelated ABI changes.

- **`8a91fcf85220ee2ee5f8dee358e9cb1be602da9f2d4146df2324030698743237` — coverage statement, not a defect.**
  Read the five requested contracts, the hook interaction, tests, and supplied protected
  checks/security checklist. Independently ran the original and adapted Foundry suites.
  This is not a replacement for the final independent audit. No Slither or Mythril run
  is claimed for this adaptation, and no production snapshot or browser artwork review
  was performed. Existing fixture-based trait parity and byte-exact script storage tests
  passed. Optional fork tests are not evidence of real Sepolia execution when skipped.

## Owner operations after the factory deployment

Preserve the project's existing sequence. Only the designated owner performs its setters:

1. Check the confirmed deployment addresses, ownership, royalty recipient, immutable
   dependencies, and treasury; set Portraits' vault and renderer to the deployed contracts.
2. Upload the existing original art, set the chosen preview/collection metadata, check
   token rendering, and use the existing irreversible renderer locks when ready.
3. After the separate INK/hook/pool launch, verify its actual token, hook, currencies,
   fee, tick spacing, initialized opening price, and vault funding. Set INK on the vault;
   configure any intended existing premium before `setPool` enables liquidity additions.
   Then call `setPool` with the verified key. The existing `script/InkSteps.sol` constants
   are **mainnet** addresses; do not use that script unchanged for this Sepolia launch.
4. Use the actual approved snapshot root and claim start in `setup`, with the deployed
   liquidity address. These are owner-settable future values, not fabricated launch inputs.
   Confirm the actual PositionManager path works before the 24-hour window ends.
5. After the window, anyone can call `release`. Keepers continue `reveal`/`revealNext`
   while pulls remain pending, even when a call only admits deposits. Watch `PullRenewed`
   for a new entropy wait and `AdmissionProgress` for work that can continue immediately.
   Use `deposit` for NFT refunds and finish pending trait rerolls before transferring.

## File inventory and validation

- Production changes: `src/InkVault.sol`, `src/InkPortraits.sol`, `src/InkLiquidity.sol`,
  `src/InkRenderer.sol`, only for the reproduced findings described above.
- Regression coverage: new `test/AuditRegression.t.sol`; adjusted/extended
  `test/InkSystem.t.sol` and `test/VaultInvariants.t.sol` as described above.
- New `test/SepoliaLaunch.t.sol`: all five CREATE2 deployments in one factory call on an
  empty local chain with the Sepolia chain ID and actual requested arguments; reference
  predictions, explicit ownership/royalties, authorization, init/runtime sizes, and an
  opcode-aware scan excluding PUSH data for DELEGATECALL/CALLCODE/SELFDESTRUCT.
- `README.md`: points to this handoff, documents the new admission constant and keeper
  behavior, and distinguishes the imported packaging hashes from the adapted source.
- This `ADAPTATION.md`: change rationale, audit disposition, addresses, and operating notes.

All checks use the project's existing default Foundry configuration. Tests use
`FOUNDRY_FUZZ_SEED=0x30c0ab1ac1540e6eaab9ba63cfd59246c53b8045eb725ef734434a1fda72c635`.
The original suite passed **55**, failed **0**, and skipped **28** tests before edits.
Final checks:

- `forge build`: passed, Solidity 0.8.26, unchanged default profile.
- `forge build --sizes`: passed. Runtime sizes are TestSeats **3,814**, InkPortraits
  **8,078**, InkVault **10,617**, InkLiquidity **9,724**, and InkRenderer **12,721** bytes,
  each below 24,576. Constructor arguments also fit the init-code limit.
- `forge test` with the seed above: **71 passed, 0 failed, 28 skipped**, across 15 suites.
  This includes 256 admission fuzz cases and the seven vault invariants over 64 runs /
  7,680 handler calls, with zero unexpected reverts. The skipped cases are the existing
  optional fork/snapshot/fee-handoff tests requiring additional external inputs.
- All five compiled constructor ABIs are nonpayable with the required static argument
  counts. Their creation and runtime bytecode have no unresolved library links.
- The local factory test's PUSH-aware forbidden-opcode scan passes for all five deployed
  runtimes. `git diff --check` passes. Existing compiler shift-width and script-shadowing
  warnings remain; no dependencies or compiler settings were changed to suppress them.

The protected deployment checks themselves require manifest-generated environment inputs
from the subsequent step. The local launch tests independently rehearse their deployment,
runtime-size, forbidden-opcode, reference, and ownership requirements without such inputs.
