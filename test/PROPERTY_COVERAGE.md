# Additional offline Foundry coverage

The existing `SepoliaLaunch.t.sol` rehearses the five constructors together through
a factory in the requested order. It checks the supplied owner, royalty receiver,
dependency references, runtime restrictions, and lack of factory/treasury privileges.
These additions build on that rehearsal without changing application logic.

| Suite | Properties and failure paths |
| --- | --- |
| `LiquidityFailurePaths.t.sol` | Both currency orderings; zero, one wei, just below and exactly at `MIN_ADD`; randomized ladder funding and premiums; external-call rollback/retry; collection idempotence; owner, treasury and keeper cannot transfer, approve or burn permanent positions. |
| `LiquidityStateful.t.sol` | Three actors randomly donate, list, swap, collect, change width and attempt forbidden administration/repricing. Every token remains accounted for; position liquidity and custody never decrease; only IMD fees reach the fixed treasury; INK fees remain available for reinvestment. |
| `VaultFailurePaths.t.sol` | Claim-window endpoints, altered Merkle data, seat operators and repeated claims; false-return ERC-20 calls, insufficient allowance, duplicate/foreign NFT batches, failed trait payments and reentrancy; batch redemption conservation over allowed fees. |
| `VaultInvariants.t.sol` | Existing handler now also exercises agent redemption during claims and unsolicited INK donations. Backing accounts for redeemed agents before release and reserves donated surplus throughout the lifecycle. A deterministic lifecycle confirms those branches execute. |
| `RendererStorageProperties.t.sol` | Binary chunk round trips, chunk order, the exact EIP-170 storage limit, oversize rollback, both metadata locks after ownership transfer, nonexistent token metadata and test-seat remint rejection. |

Liquidity integration uses the bundled **real PoolManager and PositionManager**,
with local 18-decimal ERC-20 fixtures and no hook. Existing `InkSystem.t.sol` covers
the hook integration. The new stateful liquidity suites use the launch-like opening
ticks of +/-129,000, a 7,000-tick premium, and swaps bounded to 60,000 ticks on
either side of the opening price. Assertions compare actual balances and each
position's principal recorded at creation; no simplified AMM replaces Uniswap.

Each new fuzz suite runs 1,000 cases. The new liquidity invariant suites run 256
sequences of 64 calls for each currency ordering; the extended vault suite runs
256 sequences of 120 calls. Run counts are inline in Solidity, including on concrete
test contracts because Foundry does not inherit configuration from abstract bases.
Unexpected handler reverts fail the run. Deterministic trading and redemption tests
provide witnesses that the fee and custody assertions are exercised after activity.

Run the offline checks with:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x30c0ab1ac1540e6eaab9ba63cfd59246c53b8045eb725ef734434a1fda72c635 forge test
```

No RPC, new dependency, deployment, key, or environment mutation is required.
Live Sepolia bytecode verification and fork execution against the official deployed
managers remain outside these offline checks. Existing network-dependent suites
retain their skip behavior when no RPC URL is configured.
