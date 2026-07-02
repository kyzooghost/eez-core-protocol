# crossChainRollingHash — Design

- **Date:** 2026-07-02
- **Status:** Approved (design); implementation pending
- **Scope:** L2 only (`EEZL2.sol` + `IEEZL2.sol` + shared `EEZBase.sol`)
- **PR target:** `eez-association/eez-core-protocol` (L1 mirror deferred)

## 1. Problem

`ExecutionEntry` has a per-entry `rollingHash` that folds each side's own
`incomingCalls`/nested events. Because the two chains' entries contain
*different* calls (one side's `expectedOutgoingCalls` = the other's
`incomingCalls`), `rollingHash` differs across sides and cannot act as a
cross-side agreement predicate.

The 2PC protocol needs a hash that **both sidecars compute identically** and
compare at COMMIT / COMMIT_ACK, so a mismatch aborts before committing. This is
`crossChainRollingHash` — a new field on `ExecutionEntry` (and, for
consistency, on the lookup structs).

## 2. Goals / Non-goals

**Goals**
- Add `crossChainRollingHash` as a stored field on `ExecutionEntry`,
  `LookupCall`, and `ExpectedLookup`.
- Compute it on-chain during execution (mirroring `rollingHash`: stored field
  ↔ transient accumulator ↔ end-of-execution compare).
- Fold one event per cross-chain boundary call, in execution order, as
  `keccak256(abi.encodePacked(prev, crossChainCallHash, success, returnData))`
  (raw fold — no positional tags).
- Cover lookups via per-lookup `crossChainRollingHash` (same pattern as
  per-lookup `rollingHash`), since static lookups resolve in view context and
  reverted lookups revert — neither can write the entry's transient
  accumulator.
- Passing Foundry unit tests (AAA, deterministic).

**Non-goals (deferred)**
- L1 `crossChainRollingHash` field + fold (`EEZ.sol` / `IEEZ.sol`) — follow-up
  PR. (The shared `ContextResult` wire format is extended now, with L1 emitting
  `bytes32(0)` until mirrored — see §4.5.)
- Tagged encoding scheme (raw fold chosen).
- Off-chain prover implementation (the field is pre-computed by the
  sidecar/test helper, same as `rollingHash` today).

## 3. Background: existing `rollingHash` pattern (the mirror target)

Confirmed from the code:

- `bytes32 transient _rollingHash;` — `src/base/EEZBase.sol:54-55`.
- `ExecutionEntry.rollingHash` stored field — `src/interfaces/IEEZL2.sol:142`,
  loaded with the entry via `_loadExecutionTable` (`EEZL2.sol:154`).
- Fold helpers in `EEZBase.sol:270-303`: `_rollingHashCallBegin/End`,
  `_rollingHashNestedBegin/End`, `_rollingHashStaticResult` (pure).
- Reset at entry start: `_consumeAndExecute:421` (`_rollingHash = bytes32(0)`);
  `executeIncomingCrossChainCall` relies on tx-start transient zero.
- Mutated in `_processNCalls` (`_rollingHashCallBegin/End` per flat call,
  `EEZL2.sol:458,480`) and `_consumeNestedAction`
  (`_rollingHashNestedBegin/End`, `EEZL2.sol:358-360`).
- Compare at end: `if (_rollingHash != entry.rollingHash) revert
  RollingHashMismatch()` at `_consumeAndExecute:427` and
  `executeIncomingCrossChainCall:277`.
- `revertSpan` sub-executions carry `_rollingHash` out via `ContextResult`
  (`EEZBase.sol:123,233-248`), restored at `_processNCalls:490`.
- Per-lookup `rollingHash` on `LookupCall` / `ExpectedLookup`, verified in the
  lookup's own context: `_executeRevertedLookup:561-583` (reset + check before
  revert), `_resolveStaticLookup:508-525` (pure fold via
  `_processNStaticCalls`).

`crossChainRollingHash` mirrors this 1:1 with a second, independent
accumulator and a different fold content.

## 4. Design

### 4.1 Struct additions (`src/interfaces/IEEZL2.sol`)

Add `bytes32 crossChainRollingHash;` immediately after the existing
`rollingHash` field on:

- `ExecutionEntry` (after line 142)
- `LookupCall` (after line 177)
- `ExpectedLookup` (after line 88)

### 4.2 Accumulator + fold primitive (`src/base/EEZBase.sol`)

- `bytes32 transient _crossChainRollingHash;` (alongside `_rollingHash`).
- `error CrossChainRollingHashMismatch();`
- Fold helper (internal):

```solidity
function _crossChainRollingHashFold(bytes32 crossChainCallHash, bool success, bytes memory returnData) internal {
    _crossChainRollingHash = keccak256(
        abi.encodePacked(_crossChainRollingHash, crossChainCallHash, success, returnData)
    );
}
```

A pure variant for static-lookup sub-calls (no transient write), mirroring
`_rollingHashStaticResult`:

```solidity
function _crossChainRollingHashStaticFold(bytes32 prev, bytes32 crossChainCallHash, bool success, bytes memory returnData) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(prev, crossChainCallHash, success, returnData));
}
```

### 4.3 Entry-level hooks + verification (`src/L2/EEZL2.sol`)

**Scope (Q4): `crossChainRollingHash` is per-entry.** One `ExecutionEntry` =
one cross-chain call, with its nested callbacks encoded in that entry's flat
`incomingCalls[]` / `expectedOutgoingCalls[]` (§3.7 point 2). One tx (initiator:
`loadExecutionTable` + `executeCrossChainCall`; recipient:
`executeIncomingCrossChainCall`) = one entry. The on-line accumulator is reset
and verified **per entry** (mirroring `rollingHash`). For the (edge-case)
multi-entry tx — multiple top-level invocations of a cross-chain call in one
tx, e.g. `EEZL2.t.sol:485-500` loads 2 entries consumed by 2 `proxy.call`s —
each entry's `crossChainRollingHash` is verified independently per entry
on-chain. The 2PC **session-level** COMMIT hash (one per bundle) is derived
off-chain by the sidecar from the entries' `crossChainRollingHash` values (for
the common 1-entry tx, it is just that entry's hash); defining the multi-entry
aggregation is a sidecar/2PC-layer follow-up, not an on-chain contract
concern.

The entry outer (whose `crossChainCallHash == proxyEntryHash`) is
`incomingCalls[0]` on L2 and is folded by the incoming-call hook below — it is
**not** folded separately, so there is no double-count.

**Fold-timing principle (Q3): fold every boundary call at its COMPLETION
(post-order).** Completion order is the same on both sides (same call tree →
same post-order), and `returnData`/`success` are available at completion for
all call types (incoming: observed at `CALL_END`; outgoing: pre-computed
`nested.returnData`; outer: `entry.returnData`). Folding at fire/`CALL_BEGIN`
would make outgoing fold at start and incoming at end, producing different
orders on the two sides (traced: B `call3,call2,call1` vs A `call1,call3,call2`)
— so post-order is required for cross-side consistency.

- **Reset** `_crossChainRollingHash = bytes32(0)` where `_rollingHash` is
  reset: `_consumeAndExecute` (~421) and the tx-start path of
  `executeIncomingCrossChainCall` (add an explicit reset for symmetry).
- **Incoming flat call** (`_processNCalls`, at each `CALL_END` ~480, in the
  `revertSpan == 0` branch, after execution):

```solidity
bytes32 ccHash = computeCrossChainCallHash(
    ROLLUP_ID, cc.targetAddress, cc.value, cc.data, cc.sourceAddress, cc.sourceRollupId
);
_crossChainRollingHashFold(ccHash, success, retData);
```

- **Outgoing reentrant** (`_consumeNestedAction` success path, at the **end**
  of the function — after `_processNCalls(nested.callCount)` and
  `_rollingHashNestedEnd`, immediately before `return nested.returnData`
  ~361):

```solidity
_crossChainRollingHashFold(crossChainCallHash, true, nested.returnData);
```

  (Folds at completion, not at the match-start — see the principle above.)
  `success` is `true` for a matched `ExpectedOutgoingCrossChainCall`.

- **Verify** at entry end, alongside the `RollingHashMismatch` check:
  `_consumeAndExecute` (~427) and `executeIncomingCrossChainCall` (~277):

```solidity
if (_crossChainRollingHash != entry.crossChainRollingHash) revert CrossChainRollingHashMismatch();
```

### 4.4 Lookup-level (mirror per-lookup `rollingHash`, with own-event extension)

**Decision (Q2): each lookup's `crossChainRollingHash` folds the lookup's
sub-calls first, then the lookup's OWN event last (post-order, per the Q3
principle).** So: each sub-call's `(crossChainCallHash, success, retData)`
folded as it completes, then `(lookupCallHash, !failed, returnData)` folded
last when the lookup completes. This commits to the lookup as a boundary call
AND its sub-calls' boundary events, in a cross-side-consistent post-order. It
diverges from `rollingHash` (sub-calls-only) because `crossChainRollingHash`
must commit to every boundary call. The lookup's own event is not folded at
the entry level (reverted reverts → writes undone; static is view → can't
write), so there is no double-count.

- **Reverted lookup** (`_executeRevertedLookup`, `EEZL2.sol:561-583`): add
  `bytes32 crossChainRollingHash`, `bytes32 lookupCallHash`, `bool failed`
  params; reset `_crossChainRollingHash = bytes32(0)`; the sub-`_processNCalls`
  folds each sub-call (at completion); then fold
  `(lookupCallHash, !failed, returnData)`; check **before** the final
  `revert(returnData)`:

```solidity
_crossChainRollingHashFold(lookupCallHash, !failed, returnData);
if (_crossChainRollingHash != crossChainRollingHash) revert CrossChainRollingHashMismatch();
```

  Thread the params from `_executeRevertedTopLevelLookup` (reads
  `sc.crossChainRollingHash`, `sc.crossChainCallHash`, `sc.failed`,
  `sc.returnData`) and `_executeRevertedNestedLookup` (reads
  `el.crossChainRollingHash`, `el.crossChainCallHash`, `el.failed`,
  `el.returnData`).

- **Static lookup** (`_resolveStaticLookup`, `EEZL2.sol:508-525`): static
  context cannot write transient, so use the pure fold. Add a pure companion
  to `_processNStaticCalls` that folds each static sub-call's
  `(crossChainCallHash, success, retData)` (at completion) via
  `_crossChainRollingHashStaticFold`, then folds
  `(lookupCallHash, !failed, returnData)` last; returns the hash; compare to
  the lookup's `crossChainRollingHash`. Thread `lookupCallHash`, `failed`,
  `crossChainRollingHash` into `_resolveStaticLookup`.

### 4.5 `revertSpan` / `ContextResult` carry

`revertSpan > 0` runs an isolated sub-execution that reverts state but
reports `_rollingHash` + cursors back via `ContextResult` so the outer frame
**adopts** the fold (the calls did execute; their boundary events count).
`crossChainRollingHash` behaves the same — the `revertSpan` calls' boundary
events fold into the entry's accumulator. **Decision (Q1): commit to
`revertSpan` calls (carry across), mirroring `rollingHash` — do NOT omit
them.**

Changes:
- Extend `ContextResult` with a 5th element: `_crossChainRollingHash`
  (`EEZBase.sol` struct `:123` + encoder/decoder). **This is a shared-protocol
  change** (`ContextResult` is in shared `EEZBase`, used by both L1 and L2),
  so the PR is "L2 feature + minimal shared `ContextResult` extension", not
  strictly L2-only.
- `executeInContextAndRevert` (`EEZL2.sol:438-443`) emits the 5th element
  (`_crossChainRollingHash`).
- L1 `executeInContextAndRevert` (`EEZ.sol:1099`) emits the 5th element as
  `bytes32(0)` (L1 has no `_crossChainRollingHash` yet — deferred). The shared
  `_decodeContextResult` returns the 5th value; L1's catch site
  (`EEZ.sol:1084`) decodes-and-ignores it (one-line accept-and-discard); L2's
  catch site (`EEZL2.sol:490`) restores `_crossChainRollingHash` alongside
  `_rollingHash`.
- The 5th field is forward-compatible: when L1 is later mirrored, L1 starts
  emitting its real `_crossChainRollingHash` with no further wire change.

### 4.6 Independence from `rollingHash`

The two accumulators are independent. A wrong `crossChainRollingHash` with a
correct `rollingHash` reverts `CrossChainRollingHashMismatch` (not
`RollingHashMismatch`), and vice-versa. Tests assert both directions.

## 5. Fold event summary

| Event | Hook site | Folded values |
|---|---|---|
| Incoming flat call executed | `_processNCalls` ~478 | `(computeCrossChainCallHash(...), success, retData)` |
| Outgoing reentrant resolved | `_consumeNestedAction` ~354-361 | `(crossChainCallHash param, true, nested.returnData)` |
| Reverted lookup sub-call | `_executeRevertedLookup` sub-`_processNCalls` | per-lookup accumulator, checked before revert |
| Static lookup sub-call | `_resolveStaticLookup` pure companion | pure fold, compared to lookup field |
| `revertSpan` sub-execution | `ContextResult` carry | adopted by outer frame |
| Entry verification | `_consumeAndExecute` ~427, `executeIncomingCrossChainCall` ~277 | `_crossChainRollingHash == entry.crossChainRollingHash` |

## 6. Tests (`test/`, Foundry, AAA, deterministic)

Mirror the existing `test/EEZL2.t.sol` rolling-hash helper style
(`_rollingHashSingleCall`, `_buildSimpleEntry`, `_loadSingleEntry`). Add a
parallel `_crossChainRollingHashSingleCall` helper that computes the expected
raw fold off-chain.

Cases:
1. **Single incoming call** — correct `crossChainRollingHash` → entry
   executes and returns `returnData`.
2. **`CrossChainRollingHashMismatch` reverts** — wrong field value → revert.
3. **Multi-call incoming** — cumulative raw fold over the call chain.
4. **Reentrant outgoing call** — outgoing `(crossChainCallHash, true,
   returnData)` folded at completion (end of `_consumeNestedAction`).
5. **Reverted lookup** — per-lookup `crossChainRollingHash` (sub-calls then
   own-event last) verified (success + mismatch).
6. **Static lookup** — pure-fold `crossChainRollingHash` verified (success +
   mismatch).
7. **`revertSpan`** — fold adopted across the isolated frame (via
   `ContextResult` 5th field).
8. **Independence** — wrong `crossChainRollingHash` + correct `rollingHash`
   → `CrossChainRollingHashMismatch`; wrong `rollingHash` + correct
   `crossChainRollingHash` → `RollingHashMismatch`.
9. **Cross-side consistency (two `EEZL2` instances) (Q5)** — deploy two
   `EEZL2` contracts (chain A = initiator, chain B = recipient, both L2). For
   a nested 3-call interaction (A→B top-level, B→A callback, A→B callback),
   pre-compute both sides' `ExecutionEntry` tables, load + execute each side
   (A: `loadExecutionTable` + `executeCrossChainCall` via proxy; B:
   `executeIncomingCrossChainCall`), and assert
   `A.entry.crossChainRollingHash == B.entry.crossChainRollingHash` — both
   computed on-chain during execution. This pins the Q3 post-order property
   end-to-end with real on-chain folds on both sides (no off-chain
   simulation). It's the test that fails if the post-order reasoning is wrong.

Each test: Arrange (build entries with pre-computed fields), Act (load +
invoke), Assert (return value or expected revert). Deterministic — no
time/random dependence; all hashes computed from fixed inputs.

## 7. Complexity notes

- The `ContextResult` 5th-field change (§4.5) and the static-lookup pure fold
  (§4.4) are the most involved parts; the rest is mechanical mirroring of
  `rollingHash` hook points.
- `computeCrossChainCallHash` is `pure` (`EEZBase.sol:201-214`), so computing
  it per incoming call in `_processNCalls` adds no state and minimal gas.

## 8. References

- `src/base/EEZBase.sol`: `CALL_BEGIN`/`CALL_END`/`NESTED_BEGIN`/`NESTED_END`
  (38-41), `_rollingHash` (54-55), fold helpers (270-303),
  `computeCrossChainCallHash` (201-214), `ContextResult` (123, 233-248),
  `RollingHashMismatch` (115-116).
- `src/L2/EEZL2.sol`: `_consumeAndExecute` (408-435),
  `executeIncomingCrossChainCall` (232-289), `_consumeNestedAction`
  (346-384), `_processNCalls` (447-498), `_resolveStaticLookup` (508-525),
  `_executeRevertedLookup` (561-583), `staticCallLookup` (615-655),
  `_loadExecutionTable` (148-161).
- `src/interfaces/IEEZL2.sol`: `ExecutionEntry` (124-143), `LookupCall`
  (158-178), `ExpectedLookup` (69-89).
- Spec: `eez-discovery/besu-spec.md` §3.8.
- Tests: `test/EEZL2.t.sol`, `test/EEZL2Coverage.t.sol`.
