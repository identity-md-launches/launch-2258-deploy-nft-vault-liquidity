# Ink & Inference — portable launch source

This is launch SOURCE, not approval to deploy. It has not been independently audited,
uploaded, paid for or deployed by packaging. It does not include the real snapshot,
owner/paying wallet, private cutoff, keys, RPC credentials or completed launch inputs.

## Included

- All five production contracts and the test-only TestSeats helper.
- Every current Foundry test, fixed trait cases and synthetic snapshot proofs.
- Exact installed Solidity dependencies and available license/config metadata.
- `art/original-art.js`: the original algorithm, byte-for-byte, NOT replacement artwork.
- `script/UploadRenderer.s.sol`: uploads that file after stripping its module export line.
- `launch/`: draft Sepolia/Ethereum request bodies and deployment-order notes.
- `SETUP.md`, audit brief, provenance, hashes and isolated validation results.

This directory is the root of a self-contained Foundry repository. No sibling web app
or other workspace directory is needed. No unpinned dependency install script is used.

## Sepolia launch adaptation

[ADAPTATION.md](ADAPTATION.md) records this launch's exact contract order, constructor
arguments, owner, official Sepolia manager addresses, reproduced audit fixes, and the
owner's subsequent setup steps. The five requested constructor signatures are unchanged.

Vault admission now processes at most `MAX_ADMISSIONS = 100` deposits per reveal step.
This batch size keeps the tested worst-case step below 5 million gas. Keepers should
continue `reveal` or `revealNext` while pulls remain: a call can make admission progress
without delivering a portrait yet. Use `revealNext(1)` to work through a large backlog.
Pending trait rerolls must finish before transfer; metadata exposes `traitRerollBlock`.
Only `deposit` accepts an NFT in exchange for INK; direct safe transfers to the vault revert.

The packaged `SHA256SUMS`, `BYTECODE_HASHES.json`, and original validation records describe
the imported source. Audit fixes change those source/bytecode hashes; use the adapted
source and current Foundry output for this launch, with validation recorded in ADAPTATION.md.

## Build and test

Install Foundry using https://getfoundry.sh/ and use the version recorded in VALIDATION.txt.
Run at this directory's root:

```sh
forge build
forge test -vv
```

Solidity 0.8.26 may be downloaded by Foundry if not already installed. No RPC, wallet,
real metrics, Node dependencies or funded account is required to build/test.
The default profile is read-only. `FOUNDRY_PROFILE=preview forge test --mt test_writeTokenURIs` also writes
the rendered tokenURIs to `out-preview/` to open by eye; it is ignored and excluded from the archive.

The build uses Cancun, optimizer 200, no via-IR and bytecode_hash none, as in the source project.
Production bytecode was compared across two clean builds; see BYTECODE_HASHES.json.
Renderer/preview tests use the real original art; snapshot tests use invented metrics.
Do not claim this validates the actual mainnet snapshot or original snapshot-fetching pipeline.

## Publication and ownership

Publishing this directory makes the original art algorithm public, as well as contracts,
tests, dependency source and launch drafts. Review this boundary before GitHub upload.
Review owner-authored source licensing separately; no blanket project license was invented.
Retain dependency licenses. Do not deploy TestSeats on mainnet.

Read SETUP.md before signing anything. Read PACKAGING.md for portability changes.
The website/API and marketplace image-hosting service are not included in this package.
