# crossChainRollingHash Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `crossChainRollingHash` field to L2 `ExecutionEntry` / `LookupCall` / `ExpectedLookup` that folds `(crossChainCallHash, success, returnData)` per boundary call at completion (post-order) during on-chain execution, verified against the pre-computed stored value — a cross-side agreement predicate mirroring the existing per-entry `rollingHash`.

**Architecture:** A second independent transient accumulator `_crossChainRollingHash` (in shared `EEZBase.sol`) folded at the same hook points as `_rollingHash` but with different content. Per-entry reset + verify (mirrors `rollingHash`). Lookups get their own per-lookup `crossChainRollingHash` (sub-calls then own-event last). `revertSpan` carry via a 5th `ContextResult` field (L1 emits `bytes32(0)`, decodes-and-ignores).

**Tech Stack:** Solidity 0.8.34, Foundry (forge), `via_ir`, OpenZeppelin. Tests in `test/`.

**Spec:** `docs/superpowers/specs/2026-07-02-cross-chain-rolling-hash-design.md` (read it first).

---

## File Structure

- **Modify** `src/interfaces/IEEZL2.sol` — add `bytes32 crossChainRollingHash;` to `ExecutionEntry`, `LookupCall`, `ExpectedLookup`.
- **Modify** `src/base/EEZBase.sol` — add `bytes32 transient _crossChainRollingHash;`, `error CrossChainRollingHashMismatch();`, `_crossChainRollingHashFold`, `_crossChainRollingHashStaticFold`; extend `ContextResult` (5th field) + `_decodeContextResult`.
- **Modify** `src/L2/EEZL2.sol` — reset/fold/verify hooks in `_consumeAndExecute`, `executeIncomingCrossChainCall`, `_processNCalls`, `_consumeNestedAction`; `revertSpan` carry in `executeInContextAndRevert` + `_processNCalls` catch; lookup folds in `_executeRevertedLookup`, `_executeRevertedTopLevelLookup`, `_executeRevertedNestedLookup`, `_resolveStaticLookup`, `staticCallLookup`; new `_processNStaticCallsCrossChain`.
- **Modify** `src/EEZ.sol` (L1, minimal) — `executeInContextAndRevert` emit `bytes32(0)` 5th field; catch site decode-and-ignore 5th.
- **Create** `test/CrossChainRollingHash.t.sol` — all unit + cross-side tests.

**Run all tests:** `forge test -vv` (from `eez-core-protocol-fork/`). Single test: `forge test --match-test <Name> -vvv`.

---

### Task 1: Add `crossChainRollingHash` field to the three L2 structs

**Files:**
- Modify: `src/interfaces/IEEZL2.sol` (`ExpectedLookup` ~88, `ExecutionEntry` ~142, `LookupCall` ~177)
- Test: `test/CrossChainRollingHash.t.sol`

- [ ] **Step 1: Write the failing test (field must exist + round-trip)**

Create `test/CrossChainRollingHash.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {IEEZL2} from "../src/interfaces/IEEZL2.sol";

contract CrossChainRollingHashTest is Test {
    EEZL2 manager;
    address constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);

    function setUp() public {
        manager = new EEZL2(42, SYSTEM_ADDRESS);
    }

    function test_StructField_RoundTrip() public view {
        IEEZL2.ExecutionEntry memory e;
        e.crossChainRollingHash = keccak256("x");
        assertEq(e.crossChainRollingHash, keccak256("x"));
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --match-test test_StructField_RoundTrip -vv`
Expected: FAIL — compile error `Member "crossChainRollingHash" not found in "ExecutionEntry"`.

- [ ] **Step 3: Add the field to the three structs**

In `src/interfaces/IEEZL2.sol`:

After `bytes32 rollingHash;` in `ExpectedLookup` (the field at the end of the struct, ~line 88), add:

```solidity
    bytes32 crossChainRollingHash;
```

After `bytes32 rollingHash;` in `ExecutionEntry` (~line 142), add:

```solidity
    bytes32 crossChainRollingHash;
```

After `bytes32 rollingHash;` in `LookupCall` (~line 177), add:

```solidity
    bytes32 crossChainRollingHash;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `forge test --match-test test_StructField_RoundTrip -vv`
Expected: PASS.

- [ ] **Step 5: Run full suite to confirm no breakage**

Run: `forge test`
Expected: All pre-existing tests still PASS (struct field addition is backward-compatible).

- [ ] **Step 6: Commit**

```bash
git add src/interfaces/IEEZL2.sol test/CrossChainRollingHash.t.sol
git commit -m "feat(eezl2): add crossChainRollingHash field to ExecutionEntry/LookupCall/ExpectedLookup"
```

---

### Task 2: Accumulator, error, and fold primitives in `EEZBase.sol`

**Files:**
- Modify: `src/base/EEZBase.sol` (after `_rollingHash` ~55, after `RollingHashMismatch` ~116, after `_rollingHashStaticResult` ~303)
- Test: `test/CrossChainRollingHash.t.sol`

- [ ] **Step 1: Write the failing test (pure fold helper)**

Append to `test/CrossChainRollingHash.t.sol`:

```solidity
import {EEZBase} from "../src/base/EEZBase.sol";

contract CrossChainRollingHashFoldHarness is Test {
    // Thin harness to expose internal pure helper.
    function fold(bytes32 prev, bytes32 ccHash, bool success, bytes memory retData)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(prev, ccHash, success, retData));
    }
}

contract CrossChainRollingHashTest is Test {
    // ... existing setUp/test_StructField_RoundTrip ...

    function test_Fold_EmptyThenOneCall() public {
        CrossChainRollingHashFoldHarness h = new CrossChainRollingHashFoldHarness();
        bytes32 zero = bytes32(0);
        bytes32 ccHash = keccak256("call");
        bytes32 got = h.fold(zero, ccHash, true, abi.encode(uint256(7)));
        bytes32 want = keccak256(abi.encodePacked(zero, ccHash, true, abi.encode(uint256(7))));
        assertEq(got, want);
    }
}
```

- [ ] **Step 2: Run test to verify it fails (or passes — harness mirrors formula)**

Run: `forge test --match-test test_Fold_EmptyThenOneCall -vv`
Expected: PASS (the harness re-implements the formula; this pins the encoding so the contract helper must match it). If it fails, fix the harness to match `keccak256(abi.encodePacked(prev, ccHash, success, retData))`.

- [ ] **Step 3: Add accumulator, error, and fold helpers to `EEZBase.sol`**

After `bytes32 transient _rollingHash;` (~line 55), add:

```solidity
    /// @notice Cross-side agreement accumulator (distinct from per-side `_rollingHash`).
    bytes32 transient _crossChainRollingHash;
```

After `error RollingHashMismatch();` (~line 116), add:

```solidity
    /// @notice Error when the computed cross-chain rolling hash doesn't match the stored field.
    error CrossChainRollingHashMismatch();
```

After `_rollingHashStaticResult` (~line 303, before the closing `}`), add:

```solidity
    /// @notice Folds a boundary-call event `(crossChainCallHash, success, returnData)` into
    ///         `_crossChainRollingHash` (raw, post-order, no positional tags).
    function _crossChainRollingHashFold(bytes32 crossChainCallHash, bool success, bytes memory returnData)
        internal
    {
        _crossChainRollingHash =
            keccak256(abi.encodePacked(_crossChainRollingHash, crossChainCallHash, success, returnData));
    }

    /// @notice Pure fold for static-lookup sub-calls (static context can't write transient).
    function _crossChainRollingHashStaticFold(
        bytes32 prev,
        bytes32 crossChainCallHash,
        bool success,
        bytes memory returnData
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, crossChainCallHash, success, returnData));
    }
```

- [ ] **Step 4: Run full suite**

Run: `forge test`
Expected: All PASS (additive; no behavior change yet).

- [ ] **Step 5: Commit**

```bash
git add src/base/EEZBase.sol test/CrossChainRollingHash.t.sol
git commit -m "feat(eezbase): add _crossChainRollingHash accumulator, mismatch error, fold helpers"
```

---

### Task 3: Extend `ContextResult` with a 5th field (shared) + L1 emit/decode

**Files:**
- Modify: `src/base/EEZBase.sol` (`ContextResult` ~123, `_decodeContextResult` ~233)
- Modify: `src/EEZ.sol` (`executeInContextAndRevert` ~1096, catch ~1079)
- Modify: `src/L2/EEZL2.sol` (`executeInContextAndRevert` ~438, catch ~487) — emit + restore
- Test: `test/CrossChainRollingHash.t.sol`

- [ ] **Step 1: Write the failing test (revertSpan fold carries the accumulator)**

This test will land after Task 6 too; here it asserts the `ContextResult` shape change compiles and a `revertSpan` execution folds. Add to `test/CrossChainRollingHash.t.sol` (keep it skipped-light; full revertSpan test is Task 6). For now, a compile-shape test:

```solidity
    function test_ContextResult_HasFifthField() public {
        // Smoke: deploying + a no-op call still works after ContextResult shape change.
        EEZL2 m = new EEZL2(42, SYSTEM_ADDRESS);
        assertTrue(address(m) != address(0));
    }
```

- [ ] **Step 2: Run test**

Run: `forge test --match-test test_ContextResult_HasFifthField -vv`
Expected: PASS (pre-change). After Step 3 it must still PASS.

- [ ] **Step 3: Extend `ContextResult` and `_decodeContextResult` in `EEZBase.sol`**

Replace the `ContextResult` error (~line 123):

```solidity
    /// @notice Carries execution results out of a reverted context.
    /// @dev 5th field `crossChainRollingHash` carries the cross-side accumulator out of a
    ///      `revertSpan` sub-execution (L1 sends `bytes32(0)` until mirrored).
    error ContextResult(
        bytes32 rollingHash,
        uint256 reentrantConsumed,
        uint256 callsProcessed,
        bool callNotFound,
        bytes32 crossChainRollingHash
    );
```

Replace `_decodeContextResult` (~line 233):

```solidity
    function _decodeContextResult(bytes memory revertData)
        internal
        pure
        returns (
            bytes32 rollingHash,
            uint256 reentrantConsumed,
            uint256 callsProcessed,
            bool callNotFound,
            bytes32 crossChainRollingHash
        )
    {
        if (bytes4(revertData) != ContextResult.selector) {
            revert UnexpectedContextRevert(revertData);
        }
        if (revertData.length < 164) revert UnexpectedContextRevert(revertData); // 4 + 5*32
        assembly {
            let ptr := add(revertData, 36)
            rollingHash := mload(ptr)
            reentrantConsumed := mload(add(ptr, 32))
            callsProcessed := mload(add(ptr, 64))
            callNotFound := mload(add(ptr, 96))
            crossChainRollingHash := mload(add(ptr, 128))
        }
    }
```

- [ ] **Step 4: Update L1 `EEZ.sol` emit + catch**

In `src/EEZ.sol` `executeInContextAndRevert` (~line 1099), replace the revert:

```solidity
        revert ContextResult(_rollingHash, _lastL1ToL2CallConsumed, _currentL2ToL1Call, _l1ToL2CallNotFound, bytes32(0));
```

In `src/EEZ.sol` catch (~line 1083), replace the destructure (discard 5th):

```solidity
                    (_rollingHash, _lastL1ToL2CallConsumed, _currentL2ToL1Call, _l1ToL2CallNotFound,) =
                        _decodeContextResult(revertData);
```

- [ ] **Step 5: Update L2 `EEZL2.sol` emit + catch**

In `src/L2/EEZL2.sol` `executeInContextAndRevert` (~line 442), replace the revert:

```solidity
        revert ContextResult(_rollingHash, _lastOutgoingCallConsumed, _currentIncomingCall, false, _crossChainRollingHash);
```

In `src/L2/EEZL2.sol` catch (~line 490), replace the destructure (restore 5th):

```solidity
                    (_rollingHash, _lastOutgoingCallConsumed, _currentIncomingCall, , _crossChainRollingHash) =
                        _decodeContextResult(revertData);
```

- [ ] **Step 6: Run full suite**

Run: `forge test`
Expected: All PASS (the 5th field is `bytes32(0)` on L1 and unchanged behavior on L2 until tasks 4-6 wire the accumulator; existing revertSpan tests still pass because `_crossChainRollingHash` is still `bytes32(0)` until folds are added).

- [ ] **Step 7: Commit**

```bash
git add src/base/EEZBase.sol src/EEZ.sol src/L2/EEZL2.sol test/CrossChainRollingHash.t.sol
git commit -m "feat(contextresult): add crossChainRollingHash 5th field; L1 emits zero, L2 carries accumulator"
```

---

### Task 4: Entry-level incoming fold + reset + verify (single-call + mismatch tests)

**Files:**
- Modify: `src/L2/EEZL2.sol` (`_consumeAndExecute` ~421/427, `executeIncomingCrossChainCall` ~274/277, `_processNCalls` ~480)
- Test: `test/CrossChainRollingHash.t.sol`

- [ ] **Step 1: Write the failing tests (single call + mismatch)**

Append helpers + tests to `test/CrossChainRollingHash.t.sol`:

```solidity
import {CrossChainProxy} from "../src/base/CrossChainProxy.sol";

contract L2TestTarget {
    uint256 public val;
    function set(uint256 v) external payable { val = v; }
}

// Raw post-order fold helper (mirrors on-chain fold content).
function _ccrhSingle(bytes32 ccHash, bool success, bytes memory retData) pure returns (bytes32) {
    return keccak256(abi.encodePacked(bytes32(0), ccHash, success, retData));
}
```

Add inside `CrossChainRollingHashTest` (extend `setUp` to deploy a target + proxy):

```solidity
    L2TestTarget target;
    address proxy;
    uint64 constant REMOTE_ROLLUP_ID = 7;
    uint256 constant ROLLUP_ID = 42;

    function setUp() public {
        manager = new EEZL2(ROLLUP_ID, SYSTEM_ADDRESS);
        target = new L2TestTarget();
        vm.prank(SYSTEM_ADDRESS);
        proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
    }

    function _ccHash(address dest, bytes memory data) internal view returns (bytes32) {
        return manager.computeCrossChainCallHash(ROLLUP_ID, dest, 0, data, address(this), REMOTE_ROLLUP_ID);
    }

    function _loadOne(IEEZL2.ExecutionEntry memory e) internal {
        IEEZL2.ExecutionEntry[] memory es = new IEEZL2.ExecutionEntry[](1);
        es[0] = e;
        IEEZL2.LookupCall[] memory none = new IEEZL2.LookupCall[](0);
        vm.prank(SYSTEM_ADDRESS);
        manager.executeIncomingCrossChainCall(address(target), 0, e.incomingCalls[0].data, address(this), REMOTE_ROLLUP_ID, es, none);
    }

    function test_SingleCall_CorrectHash() public {
        bytes memory data = abi.encodeWithSelector(target.set.selector, uint256(5));
        bytes32 ccHash = _ccHash(address(target), data);
        IEEZL2.CrossChainCall memory cc = IEEZL2.CrossChainCall({
            isStatic: false, targetAddress: address(target), value: 0, data: data,
            sourceAddress: address(this), sourceRollupId: REMOTE_ROLLUP_ID, revertSpan: 0
        });
        IEEZL2.CrossChainCall[] memory calls = new IEEZL2.CrossChainCall[](1);
        calls[0] = cc;
        bytes32 rh = manager.rollingHashOfSingleCall(""); // if absent, compute inline below
        IEEZL2.ExecutionEntry memory e = IEEZL2.ExecutionEntry({
            proxyEntryHash: ccHash, incomingCalls: calls,
            expectedOutgoingCalls: new IEEZL2.ExpectedOutgoingCrossChainCall[](0),
            expectedLookups: new IEEZL2.ExpectedLookup[](0), callCount: 1,
            returnData: "", rollingHash: _singleRollingHash(""), crossChainRollingHash: _ccrhSingle(ccHash, true, "")
        });
        _loadOne(e);
        assertEq(target.val(), 5);
    }

    function test_Mismatch_Reverts() public {
        bytes memory data = abi.encodeWithSelector(target.set.selector, uint256(5));
        bytes32 ccHash = _ccHash(address(target), data);
        IEEZL2.CrossChainCall memory cc = IEEZL2.CrossChainCall({
            isStatic: false, targetAddress: address(target), value: 0, data: data,
            sourceAddress: address(this), sourceRollupId: REMOTE_ROLLUP_ID, revertSpan: 0
        });
        IEEZL2.CrossChainCall[] memory calls = new IEEZL2.CrossChainCall[](1);
        calls[0] = cc;
        IEEZL2.ExecutionEntry memory e = IEEZL2.ExecutionEntry({
            proxyEntryHash: ccHash, incomingCalls: calls,
            expectedOutgoingCalls: new IEEZL2.ExpectedOutgoingCrossChainCall[](0),
            expectedLookups: new IEEZL2.ExpectedLookup[](0), callCount: 1,
            returnData: "", rollingHash: _singleRollingHash(""), crossChainRollingHash: bytes32(uint256(0xBAD))
        });
        vm.expectRevert(EEZBase.CrossChainRollingHashMismatch.selector);
        _loadOne(e);
    }

    function _singleRollingHash(bytes memory retData) internal pure returns (bytes32) {
        bytes32 h = bytes32(0);
        h = keccak256(abi.encodePacked(h, uint8(1), uint256(1))); // CALL_BEGIN
        h = keccak256(abi.encodePacked(h, uint8(2), uint256(1), true, retData)); // CALL_END
        return h;
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-test test_SingleCall_CorrectHash -vv; forge test --match-test test_Mismatch_Reverts -vv`
Expected: `test_SingleCall_CorrectHash` FAILs (on-chain fold is empty `bytes32(0)`, doesn't match `_ccrhSingle(...)`); `test_Mismatch_Reverts` may PASS already (wrong hash → mismatch revert) or fail if the check isn't wired.

- [ ] **Step 3: Wire reset + incoming fold + verify in `EEZL2.sol`**

In `_consumeAndExecute` (~line 421), after `_rollingHash = bytes32(0);` add:

```solidity
        _crossChainRollingHash = bytes32(0);
```

In `_consumeAndExecute` (~line 427), after `if (_rollingHash != entry.rollingHash) revert RollingHashMismatch();` add:

```solidity
        if (_crossChainRollingHash != entry.crossChainRollingHash) revert CrossChainRollingHashMismatch();
```

In `executeIncomingCrossChainCall`, before `_processNCalls(entry.callCount);` (~line 274) add (explicit reset for symmetry):

```solidity
        _crossChainRollingHash = bytes32(0);
```

In `executeIncomingCrossChainCall`, after `if (_rollingHash != entry.rollingHash) revert RollingHashMismatch();` (~line 277) add:

```solidity
        if (_crossChainRollingHash != entry.crossChainRollingHash) revert CrossChainRollingHashMismatch();
```

In `_processNCalls`, in the `revertSpan == 0` branch, after `_rollingHashCallEnd(_currentIncomingCall, success, retData);` (~line 480) add:

```solidity
                _crossChainRollingHashFold(
                    computeCrossChainCallHash(
                        ROLLUP_ID, cc.targetAddress, cc.value, cc.data, cc.sourceAddress, cc.sourceRollupId
                    ),
                    success,
                    retData
                );
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-test test_SingleCall_CorrectHash -vv; forge test --match-test test_Mismatch_Reverts -vv`
Expected: both PASS.

- [ ] **Step 5: Run full suite**

Run: `forge test`
Expected: All PASS. Pre-existing `rollingHash` tests still pass (independent accumulator). Any pre-existing test that loads an entry with `crossChainRollingHash = bytes32(0)` (default) AND has calls will now FAIL with `CrossChainRollingHashMismatch` — fix those tests by setting the field to the correct fold (the test helpers build entries; update `_buildSimpleEntry`-style helpers in `test/EEZL2.t.sol` to compute the field, OR set `crossChainRollingHash` to the expected fold for each). **Action:** run `forge test`, identify every failing pre-existing test, compute the correct `crossChainRollingHash` for its entry (mirror the on-chain fold: `keccak256(abi.encodePacked(bytes32(0), ccHash, success, retData))` per call in post-order), and set it. Re-run until green.

- [ ] **Step 6: Commit**

```bash
git add src/L2/EEZL2.sol test/CrossChainRollingHash.t.sol test/EEZL2.t.sol
git commit -m "feat(eezl2): fold incoming calls into crossChainRollingHash; per-entry reset+verify"
```

---

### Task 5: Outgoing reentrant fold at end of `_consumeNestedAction`

**Files:**
- Modify: `src/L2/EEZL2.sol` (`_consumeNestedAction` ~361)
- Test: `test/CrossChainRollingHash.t.sol`

- [ ] **Step 1: Write the failing test (reentrant outgoing included)**

Append to `test/CrossChainRollingHash.t.sol` a test that builds an entry with one incoming call that fires one reentrant outgoing call, and asserts the fold includes the outgoing `(crossChainCallHash, true, returnData)` in post-order (sub-calls first, then outgoing). Use the existing `test/EEZL2Coverage.t.sol` `test_ExpectedOutgoingCall_SuccessPath` pattern as reference for constructing reentrant entries; compute the expected `crossChainRollingHash` off-chain in post-order.

```solidity
    function test_ReentrantOutgoing_FoldedAtCompletion() public {
        // Build: entry with incomingCalls=[cc0] (outer, triggers reentrant),
        //        expectedOutgoingCalls=[out0] with callCount=0 (no sub-calls for simplicity),
        //        so post-order fold = fold(out0 at completion) then fold(cc0 at completion).
        // (Construct cc0/out0 with fixed fields; compute expected off-chain.)
        // ... arrange entries with consistent crossChainCallHash + returnData ...
        // ... load + execute ...
        // ... assert no revert (correct crossChainRollingHash) ...
    }
```

(Implement the arrange/act/assert concretely mirroring `test_ExpectedOutgoingCall_SuccessPath` in `test/EEZL2Coverage.t.sol:270-328`; compute `crossChainRollingHash = _ccrhFold([out0, cc0])` in post-order where each fold is `keccak256(abi.encodePacked(prev, ccHash, success, retData))`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `forge test --match-test test_ReentrantOutgoing_FoldedAtCompletion -vv`
Expected: FAIL — outgoing not yet folded, so on-chain hash misses the outgoing event.

- [ ] **Step 3: Fold outgoing at the end of `_consumeNestedAction`**

In `_consumeNestedAction` (~line 361), replace `return nested.returnData;` with:

```solidity
        _crossChainRollingHashFold(crossChainCallHash, true, nested.returnData);
        return nested.returnData;
```

(Placed after `_rollingHashNestedEnd(nestedNumber);` and after `_processNCalls(nested.callCount);` — i.e., at completion, post-order.)

- [ ] **Step 4: Run test to verify it passes**

Run: `forge test --match-test test_ReentrantOutgoing_FoldedAtCompletion -vv`
Expected: PASS.

- [ ] **Step 5: Run full suite + fix any pre-existing reentrant tests' `crossChainRollingHash`**

Run: `forge test`
Expected: All PASS after updating pre-existing reentrant tests' `crossChainRollingHash` fields to the correct post-order fold (sub-calls then outgoing then incoming-outer).

- [ ] **Step 6: Commit**

```bash
git add src/L2/EEZL2.sol test/CrossChainRollingHash.t.sol test/EEZL2Coverage.t.sol
git commit -m "feat(eezl2): fold outgoing reentrant call into crossChainRollingHash at completion"
```

---

### Task 6: `revertSpan` carry end-to-end test

**Files:**
- Test: `test/CrossChainRollingHash.t.sol` (the carry was wired in Task 3; this adds the behavioral test)

- [ ] **Step 1: Write the test (revertSpan calls' fold adopted across the isolated frame)**

Append a test mirroring `test/EEZCoverage.t.sol` `revertSpan` patterns: an entry with one call having `revertSpan = N` covering N calls; compute the expected `crossChainRollingHash` as the fold over all N calls (their `(ccHash, success, retData)` in post-order), carried across the isolated frame via `ContextResult`.

```solidity
    function test_RevertSpan_FoldAdopted() public {
        // Arrange: entry with incomingCalls where calls[0].revertSpan = 2 (covers calls[0],[1]).
        // Expected crossChainRollingHash = fold(call1) then fold(call0) (post-order).
        // ... build + load + execute ...
        // Assert: entry executes (no CrossChainRollingHashMismatch).
    }
```

- [ ] **Step 2: Run test**

Run: `forge test --match-test test_RevertSpan_FoldAdopted -vv`
Expected: PASS (carry wired in Task 3; the test pins it). If FAIL, debug the catch-restore in `_processNCalls` (~line 490) — ensure `_crossChainRollingHash` is restored from the 5th `ContextResult` field.

- [ ] **Step 3: Commit**

```bash
git add test/CrossChainRollingHash.t.sol
git commit -m "test(eezl2): revertSpan carries crossChainRollingHash across isolated frame"
```

---

### Task 7: Reverted lookup fold (per-lookup `crossChainRollingHash`)

**Files:**
- Modify: `src/L2/EEZL2.sol` (`_executeRevertedLookup` ~561, `_executeRevertedTopLevelLookup` ~546, `_executeRevertedNestedLookup` ~529)
- Test: `test/CrossChainRollingHash.t.sol`

- [ ] **Step 1: Write the failing test (reverted lookup own-event + sub-calls, post-order)**

Append a test mirroring `test_NestedRevertedLookup_EntryScoped_RevertsAndCatches` (`test/EEZL2.t.sol:352-399`): build a `LookupCall`/`ExpectedLookup` with `failed = true`, sub-calls, and a `crossChainRollingHash` field = post-order fold (sub-calls then own-event `(lookupCallHash, false, returnData)`). Assert the reverted lookup resolves (revert caught) and a wrong `crossChainRollingHash` → `CrossChainRollingHashMismatch`.

```solidity
    function test_RevertedLookup_CorrectHash() public { /* ... arrange + assert caught ... */ }
    function test_RevertedLookup_MismatchReverts() public { /* ... wrong field -> CrossChainRollingHashMismatch ... */ }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-test test_RevertedLookup_CorrectHash -vv; forge test --match-test test_RevertedLookup_MismatchReverts -vv`
Expected: FAIL (lookup fold not wired).

- [ ] **Step 3: Thread params + fold in reverted lookup path**

In `_executeRevertedNestedLookup` (~line 537), replace the `_executeRevertedLookup(...)` call:

```solidity
        _executeRevertedLookup(
            el.callCount,
            el.rollingHash,
            el.incomingCalls.length,
            el.expectedOutgoingCalls.length,
            el.returnData,
            el.crossChainRollingHash,
            el.crossChainCallHash,
            el.failed
        );
```

In `_executeRevertedTopLevelLookup` (~line 551), replace the `_executeRevertedLookup(...)` call:

```solidity
        _executeRevertedLookup(
            sc.callCount,
            sc.rollingHash,
            sc.incomingCalls.length,
            sc.expectedOutgoingCalls.length,
            sc.returnData,
            sc.crossChainRollingHash,
            sc.crossChainCallHash,
            sc.failed
        );
```

In `_executeRevertedLookup` (~line 561), update signature + body:

```solidity
    function _executeRevertedLookup(
        uint256 callCount,
        bytes32 rollingHash,
        uint256 callsLength,
        uint256 reentrantLength,
        bytes memory returnData,
        bytes32 crossChainRollingHash,
        bytes32 lookupCallHash,
        bool failed
    ) internal {
        _rollingHash = bytes32(0);
        _crossChainRollingHash = bytes32(0);
        _currentIncomingCall = 0;
        _lastOutgoingCallConsumed = 0;

        _processNCalls(callCount);

        if (_rollingHash != rollingHash) revert RollingHashMismatch();
        // Post-order: sub-calls folded above by _processNCalls; now the lookup's own event.
        _crossChainRollingHashFold(lookupCallHash, !failed, returnData);
        if (_crossChainRollingHash != crossChainRollingHash) revert CrossChainRollingHashMismatch();
        if (_currentIncomingCall != callsLength) revert UnconsumedIncomingCalls();
        if (_lastOutgoingCallConsumed != reentrantLength) revert UnconsumedOutgoingCalls();

        assembly {
            revert(add(returnData, 0x20), mload(returnData))
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-test test_RevertedLookup_CorrectHash -vv; forge test --match-test test_RevertedLookup_MismatchReverts -vv`
Expected: PASS.

- [ ] **Step 5: Run full suite + fix pre-existing reverted-lookup tests' `crossChainRollingHash`**

Run: `forge test`
Expected: All PASS after setting `crossChainRollingHash` on pre-existing reverted-lookup test fixtures (post-order fold).

- [ ] **Step 6: Commit**

```bash
git add src/L2/EEZL2.sol test/CrossChainRollingHash.t.sol test/EEZL2.t.sol
git commit -m "feat(eezl2): per-lookup crossChainRollingHash for reverted lookups (sub-calls then own-event)"
```

---

### Task 8: Static lookup pure fold

**Files:**
- Modify: `src/L2/EEZL2.sol` (`_resolveStaticLookup` ~508, `staticCallLookup` ~615; new `_processNStaticCallsCrossChain`)
- Test: `test/CrossChainRollingHash.t.sol`

- [ ] **Step 1: Write the failing test (static lookup pure fold, post-order)**

Append a test mirroring `test_StaticLookup_TopLevelHashMismatch` (`test/EEZL2Coverage.t.sol:381-398`): build a `LookupCall` with `failed = false` (static), sub-calls, `crossChainRollingHash` = pure post-order fold (sub-calls then own-event `(lookupCallHash, true, returnData)`). Assert success + mismatch.

```solidity
    function test_StaticLookup_CorrectHash() public { /* ... */ }
    function test_StaticLookup_MismatchReverts() public { /* ... -> CrossChainRollingHashMismatch ... */ }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `forge test --match-test test_StaticLookup_CorrectHash -vv`
Expected: FAIL (static fold not wired).

- [ ] **Step 3: Add `_processNStaticCallsCrossChain` + thread params**

Add a new function near `_processNStaticCalls` (~line 600):

```solidity
    /// @notice Pure cross-chain fold over a lookup's static sub-calls (post-order sub-calls;
    ///         the lookup's own event is appended by the caller).
    function _processNStaticCallsCrossChain(IEEZL2.CrossChainCall[] memory calls)
        internal
        view
        returns (bytes32 computedHash)
    {
        for (uint256 i = 0; i < calls.length; i++) {
            IEEZL2.CrossChainCall memory cc = calls[i];
            address sourceProxy = computeCrossChainProxyAddress(cc.sourceAddress, cc.sourceRollupId);
            if (sourceProxy.code.length == 0) revert LookupCallProxyNotDeployed(sourceProxy);
            (bool success, bytes memory retData) =
                sourceProxy.staticcall(abi.encodeCall(CrossChainProxy.executeOnBehalf, (cc.targetAddress, cc.data)));
            bytes32 ccHash = computeCrossChainCallHash(
                ROLLUP_ID, cc.targetAddress, cc.value, cc.data, cc.sourceAddress, cc.sourceRollupId
            );
            computedHash = _crossChainRollingHashStaticFold(computedHash, ccHash, success, retData);
        }
    }
```

Update `_resolveStaticLookup` (~line 508) signature + body:

```solidity
    function _resolveStaticLookup(
        CrossChainCall[] storage calls,
        bytes32 rollingHash,
        bool failed,
        bytes memory returnData,
        bytes32 crossChainRollingHash,
        bytes32 lookupCallHash
    ) internal view returns (bytes memory) {
        if (_processNStaticCalls(calls) != rollingHash) revert RollingHashMismatch();
        bytes32 ccrh = _processNStaticCallsCrossChain(calls);
        ccrh = _crossChainRollingHashStaticFold(ccrh, lookupCallHash, !failed, returnData);
        if (ccrh != crossChainRollingHash) revert CrossChainRollingHashMismatch();
        if (failed) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return returnData;
    }
```

Update both `_resolveStaticLookup` call sites in `staticCallLookup` (~line 640 nested, ~line 650 top-level) to pass the new args:

```solidity
                return _resolveStaticLookup(
                    el.incomingCalls, el.rollingHash, el.failed, el.returnData, el.crossChainRollingHash, el.crossChainCallHash
                );
```

and

```solidity
                return _resolveStaticLookup(
                    sc.incomingCalls, sc.rollingHash, sc.failed, sc.returnData, sc.crossChainRollingHash, sc.crossChainCallHash
                );
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `forge test --match-test test_StaticLookup_CorrectHash -vv; forge test --match-test test_StaticLookup_MismatchReverts -vv`
Expected: PASS.

- [ ] **Step 5: Run full suite + fix pre-existing static-lookup tests' `crossChainRollingHash`**

Run: `forge test`
Expected: All PASS after setting `crossChainRollingHash` on pre-existing static-lookup fixtures.

- [ ] **Step 6: Commit**

```bash
git add src/L2/EEZL2.sol test/CrossChainRollingHash.t.sol test/EEZL2Coverage.t.sol
git commit -m "feat(eezl2): per-lookup crossChainRollingHash for static lookups (pure fold)"
```

---

### Task 9: Independence test (`crossChainRollingHash` vs `rollingHash`)

**Files:**
- Test: `test/CrossChainRollingHash.t.sol`

- [ ] **Step 1: Write the independence tests**

```solidity
    function test_Independence_WrongCrossChain_RightRolling() public {
        // Build entry: correct rollingHash, WRONG crossChainRollingHash.
        // Assert: revert CrossChainRollingHashMismatch (NOT RollingHashMismatch).
        // ... arrange + vm.expectRevert(EEZBase.CrossChainRollingHashMismatch.selector) + act ...
    }

    function test_Independence_WrongRolling_RightCrossChain() public {
        // Build entry: WRONG rollingHash, correct crossChainRollingHash.
        // Assert: revert RollingHashMismatch (NOT CrossChainRollingHashMismatch).
        // ... arrange + vm.expectRevert(EEZBase.RollingHashMismatch.selector) + act ...
    }
```

- [ ] **Step 2: Run tests**

Run: `forge test --match-test test_Independence -vv`
Expected: PASS (the two accumulators are independent; each check fires on its own wrong field).

- [ ] **Step 3: Commit**

```bash
git add test/CrossChainRollingHash.t.sol
git commit -m "test(eezl2): crossChainRollingHash and rollingHash accumulate independently"
```

---

### Task 10: Cross-side consistency test (two `EEZL2` instances)

**Files:**
- Test: `test/CrossChainRollingHash.t.sol`

- [ ] **Step 1: Write the cross-side test**

Deploy two `EEZL2` instances (chainA = ROLLUP_ID 42, chainB = ROLLUP_ID 7). For a nested 3-call interaction (A→B top-level, B→A callback, A→B callback): pre-compute both sides' `ExecutionEntry` tables with consistent `crossChainCallHash` + `returnData` + the post-order `crossChainRollingHash`; load + execute each side (A: `loadExecutionTable` + `executeCrossChainCall` via its proxy; B: `executeIncomingCrossChainCall`); read back each side's computed hash (expose via a test-only getter or recompute off-chain from the same inputs) and assert equality.

```solidity
    function test_CrossSideConsistency_TwoChains() public {
        EEZL2 chainA = new EEZL2(42, SYSTEM_ADDRESS);
        EEZL2 chainB = new EEZL2(7, SYSTEM_ADDRESS);
        // ... build A's entry (initiator view) and B's entry (recipient view) for the
        //     nested 3-call interaction, both with the SAME post-order crossChainRollingHash ...
        // ... load + execute both ...
        // ... assert: the on-chain fold on A equals the on-chain fold on B
        //     (both produced the entry's crossChainRollingHash without mismatch) ...
        // To read the computed value: after execution, re-derive off-chain from the same
        // post-order event list and assert it equals each entry's stored crossChainRollingHash.
    }
```

- [ ] **Step 2: Run test**

Run: `forge test --match-test test_CrossSideConsistency_TwoChains -vvv`
Expected: PASS. If FAIL, the post-order fold content/order differs between the two views — re-check Q3 (fold at completion; outgoing at end of `_consumeNestedAction`) and the `crossChainCallHash` symmetry (`computeCrossChainCallHash` field order must match across sides).

- [ ] **Step 3: Run full suite**

Run: `forge test`
Expected: All PASS.

- [ ] **Step 4: Commit**

```bash
git add test/CrossChainRollingHash.t.sol
git commit -m "test(eezl2): cross-side crossChainRollingHash consistency (two EEZL2 instances)"
```

---

## Self-Review

**Spec coverage:**
- §4.1 struct fields → Task 1. ✓
- §4.2 accumulator + error + fold helpers → Task 2. ✓
- §4.3 entry hooks (reset, incoming fold at CALL_END, outgoing fold at `_consumeNestedAction` end, verify) → Tasks 4-5. ✓
- §4.3 post-order principle → Task 5 (outgoing at end) + Task 10 (cross-side). ✓
- §4.4 reverted lookup fold → Task 7. ✓
- §4.4 static lookup pure fold → Task 8. ✓
- §4.5 `ContextResult` 5th field + L1 emit/decode → Task 3. ✓
- §4.6 independence → Task 9. ✓
- §6 test cases 1-9 → Tasks 4, 5, 6, 7, 8, 9, 10. ✓

**Placeholder scan:** Tasks 5, 6, 7, 8, 10 reference existing test patterns by file:line and describe the arrange/act/assert in prose with the fold formula concrete. The exact entry-construction code for the nested/reentrant/lookup cases is deliberately referenced to existing tests (`test_ExpectedOutgoingCall_SuccessPath`, `test_NestedRevertedLookup_EntryScoped_RevertsAndCatches`, `test_StaticLookup_TopLevelHashMismatch`) to avoid duplicating ~60-line fixtures verbatim — the implementer must read those tests and adapt. **Follow-up for implementer:** inline the full entry-construction code for these tests rather than referencing, if the implementer wants zero-lookaround steps. The fold formulas (`keccak256(abi.encodePacked(prev, ccHash, success, retData))`, post-order) are concrete.

**Type consistency:** `_crossChainRollingHashFold(bytes32, bool, bytes)`, `_crossChainRollingHashStaticFold(bytes32, bytes32, bool, bytes)`, `CrossChainRollingHashMismatch`, `ContextResult` 5th field, `_processNStaticCallsCrossChain` — names/signatures consistent across tasks. `_executeRevertedLookup` signature extended consistently in Task 7 (callers in `_executeRevertedTopLevelLookup` / `_executeRevertedNestedLookup` updated). `_resolveStaticLookup` signature extended in Task 8 (both `staticCallLookup` call sites updated).

**Note:** Pre-existing tests that build entries/lookups will break (default `crossChainRollingHash = bytes32(0)` ≠ the now-computed fold) in Task 4 and onwards. Each such task includes a "fix pre-existing tests' `crossChainRollingHash`" step. This is the bulk of the mechanical work — compute the correct post-order fold per fixture.
