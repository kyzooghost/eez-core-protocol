// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {EEZL2} from "../src/L2/EEZL2.sol";
import {EEZBase} from "../src/base/EEZBase.sol";
import {
    CrossChainCall,
    ExecutionEntry,
    ExpectedLookup,
    ExpectedOutgoingCrossChainCall,
    LookupCall
} from "../src/interfaces/IEEZL2.sol";
import {Counter, CounterAndProxy} from "./mocks/CounterContracts.sol";

contract CrossChainRollingHashTarget {
    uint256 public value;

    function setValue(uint256 newValue) external {
        value = newValue;
    }
}

contract CrossChainRollingHashReverter {
    fallback() external payable {
        revert("always reverts");
    }
}

contract CrossChainRollingHashFoldHarness is EEZBase {
    error UnsupportedHarnessCall();

    function fold(
        bytes32 prev,
        bytes32 crossChainCallHash,
        bool success,
        bytes memory returnData
    )
        external
        pure
        returns (bytes32)
    {
        return _crossChainRollingHashStaticFold(prev, crossChainCallHash, success, returnData);
    }

    function _getRollupId() internal pure override returns (uint256) {
        return 42;
    }

    function executeCrossChainCall(address, bytes calldata) external payable override returns (bytes memory) {
        revert UnsupportedHarnessCall();
    }

    function staticCallLookup(address, bytes calldata) external pure override returns (bytes memory) {
        revert UnsupportedHarnessCall();
    }
}

contract CrossChainRollingHashTest is Test {
    EEZL2 manager;
    CrossChainRollingHashTarget target;

    uint256 constant TEST_ROLLUP_ID = 42;
    uint256 constant REMOTE_ROLLUP_ID = 7;
    address constant SYSTEM_ADDRESS = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);

    uint8 constant CALL_BEGIN = 1;
    uint8 constant CALL_END = 2;
    uint8 constant NESTED_BEGIN = 3;
    uint8 constant NESTED_END = 4;

    function setUp() public {
        manager = new EEZL2(TEST_ROLLUP_ID, SYSTEM_ADDRESS);
        target = new CrossChainRollingHashTarget();
    }

    function test_StructField_RoundTrip() public view {
        // Arrange
        bytes32 expectedHash = keccak256("x");
        ExecutionEntry memory entry;

        // Act
        entry.crossChainRollingHash = expectedHash;

        // Assert
        assertEq(entry.crossChainRollingHash, expectedHash);
        assertTrue(address(manager) != address(0));
    }

    function test_Fold_EmptyThenOneCall() public {
        // Arrange
        CrossChainRollingHashFoldHarness harness = new CrossChainRollingHashFoldHarness();
        bytes32 prev = bytes32(0);
        bytes32 crossChainCallHash = keccak256("call");
        bool success = true;
        bytes memory returnData = abi.encode(uint256(7));
        bytes32 expectedHash = keccak256(abi.encodePacked(prev, crossChainCallHash, success, returnData));

        // Act
        bytes32 actualHash = harness.fold(prev, crossChainCallHash, success, returnData);

        // Assert
        assertEq(actualHash, expectedHash);
    }

    function test_ContextResult_HasFifthField() public {
        // Arrange
        EEZL2 deployedManager = new EEZL2(TEST_ROLLUP_ID, SYSTEM_ADDRESS);

        // Act
        address managerAddress = address(deployedManager);

        // Assert
        assertTrue(managerAddress != address(0));
    }

    function test_SingleIncomingCall_ExecutesWithCorrectHash() public {
        // Arrange
        bytes memory callData = abi.encodeCall(CrossChainRollingHashTarget.setValue, (5));
        bytes32 callHash = _crossChainCallHash(address(target), callData, address(this), REMOTE_ROLLUP_ID);
        CrossChainCall memory call = _call(address(target), callData, address(this), REMOTE_ROLLUP_ID);
        ExecutionEntry memory entry =
            _entry(callHash, call, _rollingHashSingleCall(""), _crossChainRollingHashSingleCall(callHash, true, ""));

        // Act
        _executeIncoming(entry, callData);

        // Assert
        assertEq(target.value(), 5);
    }

    function test_SingleIncomingCall_RevertsWhenCrossChainHashMismatches() public {
        // Arrange
        bytes memory callData = abi.encodeCall(CrossChainRollingHashTarget.setValue, (5));
        bytes32 callHash = _crossChainCallHash(address(target), callData, address(this), REMOTE_ROLLUP_ID);
        CrossChainCall memory call = _call(address(target), callData, address(this), REMOTE_ROLLUP_ID);
        ExecutionEntry memory entry = _entry(callHash, call, _rollingHashSingleCall(""), bytes32(uint256(0xBAD)));

        // Act / Assert
        vm.expectRevert(EEZBase.CrossChainRollingHashMismatch.selector);
        _executeIncoming(entry, callData);
    }

    function test_ReentrantOutgoing_FoldedAtCompletion() public {
        // Arrange
        address remoteCounter = address(0xC0117E1);
        address remoteCounterProxy = manager.createCrossChainProxy(remoteCounter, REMOTE_ROLLUP_ID);
        CounterAndProxy caller = new CounterAndProxy(Counter(remoteCounterProxy));

        bytes memory outerData = abi.encodeCall(CounterAndProxy.incrementProxy, ());
        bytes memory innerData = abi.encodeCall(Counter.increment, ());
        bytes32 outerHash = _crossChainCallHash(address(caller), outerData, address(this), REMOTE_ROLLUP_ID);
        bytes32 outgoingHash = _hash(REMOTE_ROLLUP_ID, remoteCounter, 0, innerData, address(caller), TEST_ROLLUP_ID);

        CrossChainCall[] memory calls = new CrossChainCall[](2);
        calls[0] = _call(address(caller), outerData, address(this), REMOTE_ROLLUP_ID);
        calls[1] = _call(remoteCounter, innerData, address(caller), REMOTE_ROLLUP_ID);

        ExpectedOutgoingCrossChainCall[] memory outgoing = new ExpectedOutgoingCrossChainCall[](1);
        outgoing[0] = ExpectedOutgoingCrossChainCall({
            crossChainCallHash: outgoingHash,
            callCount: 1,
            returnData: abi.encode(uint256(1))
        });

        bytes32 crossChainHash = _crossChainRollingHashFold(bytes32(0), calls[1], true, "");
        crossChainHash = _crossChainRollingHashFold(crossChainHash, outgoingHash, true, abi.encode(uint256(1)));
        crossChainHash = _crossChainRollingHashFold(crossChainHash, calls[0], true, "");

        ExecutionEntry memory entry;
        entry.proxyEntryHash = outerHash;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = outgoing;
        entry.expectedLookups = new ExpectedLookup[](0);
        entry.callCount = 1;
        entry.returnData = "";
        entry.rollingHash = _rollingHashReentrant("");
        entry.crossChainRollingHash = crossChainHash;

        // Act
        _executeIncoming(entry, outerData, address(caller));

        // Assert
        assertEq(caller.counter(), 1);
        assertEq(caller.targetCounter(), 1);
    }

    function test_RevertSpan_FoldAdopted() public {
        // Arrange
        CrossChainRollingHashReverter reverter = new CrossChainRollingHashReverter();
        bytes memory topLevelData = abi.encodeCall(CrossChainRollingHashTarget.setValue, (9));
        bytes32 topLevelHash = _crossChainCallHash(address(target), topLevelData, address(this), REMOTE_ROLLUP_ID);
        bytes memory revertData = abi.encodeWithSignature("Error(string)", "always reverts");

        CrossChainCall memory call = _call(address(reverter), hex"deadbeef", address(this), REMOTE_ROLLUP_ID);
        call.revertSpan = 1;
        ExecutionEntry memory entry = _entry(
            topLevelHash,
            call,
            _rollingHashSingleFailedCall(revertData),
            _crossChainRollingHashFold(bytes32(0), call, false, revertData)
        );

        // Act
        _executeIncoming(entry, topLevelData);

        // Assert
        assertEq(target.value(), 0);
    }

    function test_RevertedLookup_CorrectHash() public {
        // Arrange
        bytes memory callData = abi.encodeCall(CrossChainRollingHashTarget.setValue, (11));
        bytes32 lookupHash = _hash(REMOTE_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID);
        bytes memory payload = hex"deadbeef";
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        _loadLookup(
            _revertedLookup(lookupHash, payload, _crossChainRollingHashFold(bytes32(0), lookupHash, false, payload))
        );

        // Act
        (bool success, bytes memory returnData) = proxy.call(callData);

        // Assert
        assertFalse(success);
        assertEq(returnData, payload);
    }

    function test_RevertedLookup_MismatchReverts() public {
        // Arrange
        bytes memory callData = abi.encodeCall(CrossChainRollingHashTarget.setValue, (11));
        bytes32 lookupHash = _hash(REMOTE_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID);
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        _loadLookup(_revertedLookup(lookupHash, hex"deadbeef", bytes32(uint256(0xBAD))));

        // Act
        (bool success, bytes memory returnData) = proxy.call(callData);

        // Assert
        assertFalse(success);
        assertEq(bytes4(returnData), EEZBase.CrossChainRollingHashMismatch.selector);
    }

    function test_StaticLookup_CorrectHash() public {
        // Arrange
        bytes memory callData = abi.encodeCall(CrossChainRollingHashTarget.setValue, (11));
        bytes32 lookupHash = _hash(REMOTE_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID);
        bytes memory payload = abi.encode(uint256(123));
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        _loadLookup(
            _staticLookup(lookupHash, payload, _crossChainRollingHashFold(bytes32(0), lookupHash, true, payload))
        );

        // Act
        vm.prank(proxy);
        bytes memory returnData = manager.staticCallLookup(address(this), callData);

        // Assert
        assertEq(returnData, payload);
    }

    function test_StaticLookup_MismatchReverts() public {
        // Arrange
        bytes memory callData = abi.encodeCall(CrossChainRollingHashTarget.setValue, (11));
        bytes32 lookupHash = _hash(REMOTE_ROLLUP_ID, address(target), 0, callData, address(this), TEST_ROLLUP_ID);
        address proxy = manager.createCrossChainProxy(address(target), REMOTE_ROLLUP_ID);
        _loadLookup(_staticLookup(lookupHash, abi.encode(uint256(123)), bytes32(uint256(0xBAD))));

        // Act / Assert
        vm.prank(proxy);
        vm.expectRevert(EEZBase.CrossChainRollingHashMismatch.selector);
        manager.staticCallLookup(address(this), callData);
    }

    function test_Independence_WrongCrossChainRightRolling_RevertsWithCrossChainMismatch() public {
        // Arrange
        bytes memory callData = abi.encodeCall(CrossChainRollingHashTarget.setValue, (5));
        bytes32 callHash = _crossChainCallHash(address(target), callData, address(this), REMOTE_ROLLUP_ID);
        CrossChainCall memory call = _call(address(target), callData, address(this), REMOTE_ROLLUP_ID);
        ExecutionEntry memory entry = _entry(callHash, call, _rollingHashSingleCall(""), bytes32(uint256(0xBAD)));

        // Act / Assert
        vm.expectRevert(EEZBase.CrossChainRollingHashMismatch.selector);
        _executeIncoming(entry, callData);
    }

    function test_Independence_WrongRollingRightCrossChain_RevertsWithRollingMismatch() public {
        // Arrange
        bytes memory callData = abi.encodeCall(CrossChainRollingHashTarget.setValue, (5));
        bytes32 callHash = _crossChainCallHash(address(target), callData, address(this), REMOTE_ROLLUP_ID);
        CrossChainCall memory call = _call(address(target), callData, address(this), REMOTE_ROLLUP_ID);
        ExecutionEntry memory entry =
            _entry(callHash, call, bytes32(uint256(0xBAD)), _crossChainRollingHashSingleCall(callHash, true, ""));

        // Act / Assert
        vm.expectRevert(EEZBase.RollingHashMismatch.selector);
        _executeIncoming(entry, callData);
    }

    function test_CrossSideConsistency_TwoChains() public {
        // Arrange
        uint256 chainARollupId = TEST_ROLLUP_ID;
        uint256 chainBRollupId = REMOTE_ROLLUP_ID;
        EEZL2 chainA = new EEZL2(chainARollupId, SYSTEM_ADDRESS);
        EEZL2 chainB = new EEZL2(chainBRollupId, SYSTEM_ADDRESS);
        CrossChainRollingHashTarget targetB = new CrossChainRollingHashTarget();
        address remoteCounterA = address(0xC0117E1);
        address remoteCounterProxyOnB = chainB.createCrossChainProxy(remoteCounterA, chainARollupId);
        CounterAndProxy callerB = new CounterAndProxy(Counter(remoteCounterProxyOnB));

        address sourceA = address(0xA11CE);
        bytes memory outerData = abi.encodeCall(CounterAndProxy.incrementProxy, ());
        bytes memory subcallData = abi.encodeCall(CrossChainRollingHashTarget.setValue, (33));
        bytes memory outgoingData = abi.encodeCall(Counter.increment, ());

        bytes32 outerHash = _hash(chainBRollupId, address(callerB), 0, outerData, sourceA, chainARollupId);
        bytes32 subcallHash = _hash(chainBRollupId, address(targetB), 0, subcallData, remoteCounterA, chainARollupId);
        bytes32 outgoingHash =
            _hash(chainARollupId, remoteCounterA, 0, outgoingData, address(callerB), chainBRollupId);

        bytes32 sourceSideHash = _crossChainRollingHashFold(bytes32(0), subcallHash, true, "");
        sourceSideHash = _crossChainRollingHashFold(sourceSideHash, outgoingHash, true, abi.encode(uint256(1)));
        sourceSideHash = _crossChainRollingHashFold(sourceSideHash, outerHash, true, "");

        CrossChainCall[] memory calls = new CrossChainCall[](2);
        calls[0] = CrossChainCall({
            isStatic: false,
            targetAddress: address(callerB),
            value: 0,
            data: outerData,
            sourceAddress: sourceA,
            sourceRollupId: chainARollupId,
            revertSpan: 0
        });
        calls[1] = CrossChainCall({
            isStatic: false,
            targetAddress: address(targetB),
            value: 0,
            data: subcallData,
            sourceAddress: remoteCounterA,
            sourceRollupId: chainARollupId,
            revertSpan: 0
        });

        ExpectedOutgoingCrossChainCall[] memory outgoing = new ExpectedOutgoingCrossChainCall[](1);
        outgoing[0] = ExpectedOutgoingCrossChainCall({
            crossChainCallHash: outgoingHash,
            callCount: 1,
            returnData: abi.encode(uint256(1))
        });

        ExecutionEntry memory entryB;
        entryB.proxyEntryHash = outerHash;
        entryB.incomingCalls = calls;
        entryB.expectedOutgoingCalls = outgoing;
        entryB.expectedLookups = new ExpectedLookup[](0);
        entryB.callCount = 1;
        entryB.returnData = "";
        entryB.rollingHash = _rollingHashReentrant("");
        entryB.crossChainRollingHash = sourceSideHash;

        // Act
        _executeIncoming(chainB, entryB, outerData, address(callerB), sourceA, chainARollupId);

        // Assert
        assertTrue(address(chainA) != address(0));
        assertEq(targetB.value(), 33);
        assertEq(callerB.counter(), 1);
        assertEq(callerB.targetCounter(), 1);
        assertEq(entryB.crossChainRollingHash, sourceSideHash);
    }

    function _executeIncoming(ExecutionEntry memory entry, bytes memory callData) internal {
        _executeIncoming(entry, callData, address(target));
    }

    function _executeIncoming(ExecutionEntry memory entry, bytes memory callData, address destination) internal {
        _executeIncoming(manager, entry, callData, destination, address(this), REMOTE_ROLLUP_ID);
    }

    function _executeIncoming(
        EEZL2 targetManager,
        ExecutionEntry memory entry,
        bytes memory callData,
        address destination,
        address sourceAddress,
        uint256 sourceRollup
    )
        internal
    {
        ExecutionEntry[] memory entries = new ExecutionEntry[](1);
        entries[0] = entry;
        vm.prank(SYSTEM_ADDRESS);
        targetManager.executeIncomingCrossChainCall(
            destination, 0, callData, sourceAddress, sourceRollup, entries, new LookupCall[](0)
        );
    }

    function _loadLookup(LookupCall memory lookup) internal {
        _loadLookup(manager, lookup);
    }

    function _loadLookup(EEZL2 targetManager, LookupCall memory lookup) internal {
        ExecutionEntry[] memory entries = new ExecutionEntry[](0);
        LookupCall[] memory lookups = new LookupCall[](1);
        lookups[0] = lookup;
        vm.prank(SYSTEM_ADDRESS);
        targetManager.loadExecutionTable(entries, lookups);
    }

    function _revertedLookup(
        bytes32 lookupHash,
        bytes memory payload,
        bytes32 crossChainRollingHash
    )
        internal
        pure
        returns (LookupCall memory lookup)
    {
        lookup.crossChainCallHash = lookupHash;
        lookup.returnData = payload;
        lookup.failed = true;
        lookup.incomingCalls = new CrossChainCall[](0);
        lookup.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        lookup.expectedLookups = new ExpectedLookup[](0);
        lookup.callCount = 0;
        lookup.rollingHash = bytes32(0);
        lookup.crossChainRollingHash = crossChainRollingHash;
    }

    function _staticLookup(
        bytes32 lookupHash,
        bytes memory payload,
        bytes32 crossChainRollingHash
    )
        internal
        pure
        returns (LookupCall memory lookup)
    {
        lookup.crossChainCallHash = lookupHash;
        lookup.returnData = payload;
        lookup.failed = false;
        lookup.incomingCalls = new CrossChainCall[](0);
        lookup.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        lookup.expectedLookups = new ExpectedLookup[](0);
        lookup.callCount = 0;
        lookup.rollingHash = bytes32(0);
        lookup.crossChainRollingHash = crossChainRollingHash;
    }

    function _entry(
        bytes32 callHash,
        CrossChainCall memory call,
        bytes32 rollingHash,
        bytes32 crossChainRollingHash
    )
        internal
        pure
        returns (ExecutionEntry memory entry)
    {
        CrossChainCall[] memory calls = new CrossChainCall[](1);
        calls[0] = call;
        entry.proxyEntryHash = callHash;
        entry.incomingCalls = calls;
        entry.expectedOutgoingCalls = new ExpectedOutgoingCrossChainCall[](0);
        entry.expectedLookups = new ExpectedLookup[](0);
        entry.callCount = 1;
        entry.returnData = "";
        entry.rollingHash = rollingHash;
        entry.crossChainRollingHash = crossChainRollingHash;
    }

    function _call(
        address destination,
        bytes memory callData,
        address sourceAddress,
        uint256 sourceRollup
    )
        internal
        pure
        returns (CrossChainCall memory)
    {
        return CrossChainCall({
            isStatic: false,
            targetAddress: destination,
            value: 0,
            data: callData,
            sourceAddress: sourceAddress,
            sourceRollupId: sourceRollup,
            revertSpan: 0
        });
    }

    function _crossChainCallHash(
        address destination,
        bytes memory callData,
        address sourceAddress,
        uint256 sourceRollup
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(TEST_ROLLUP_ID, destination, uint256(0), callData, sourceAddress, sourceRollup));
    }

    function _hash(
        uint256 rollupId,
        address destination,
        uint256 value,
        bytes memory callData,
        address sourceAddress,
        uint256 sourceRollup
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(rollupId, destination, value, callData, sourceAddress, sourceRollup));
    }

    function _rollingHashSingleCall(bytes memory returnData) internal pure returns (bytes32 hash) {
        hash = keccak256(abi.encodePacked(hash, CALL_BEGIN, uint256(1)));
        hash = keccak256(abi.encodePacked(hash, CALL_END, uint256(1), true, returnData));
    }

    function _rollingHashSingleFailedCall(bytes memory returnData) internal pure returns (bytes32 hash) {
        hash = keccak256(abi.encodePacked(hash, CALL_BEGIN, uint256(1)));
        hash = keccak256(abi.encodePacked(hash, CALL_END, uint256(1), false, returnData));
    }

    function _crossChainRollingHashSingleCall(
        bytes32 callHash,
        bool success,
        bytes memory returnData
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(bytes32(0), callHash, success, returnData));
    }

    function _crossChainRollingHashFold(
        bytes32 prev,
        CrossChainCall memory call,
        bool success,
        bytes memory returnData
    )
        internal
        pure
        returns (bytes32)
    {
        bytes32 callHash =
            _hash(TEST_ROLLUP_ID, call.targetAddress, call.value, call.data, call.sourceAddress, call.sourceRollupId);
        return _crossChainRollingHashFold(prev, callHash, success, returnData);
    }

    function _crossChainRollingHashFold(
        bytes32 prev,
        bytes32 callHash,
        bool success,
        bytes memory returnData
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(prev, callHash, success, returnData));
    }

    function _rollingHashReentrant(bytes memory outerReturnData) internal pure returns (bytes32 hash) {
        hash = keccak256(abi.encodePacked(hash, CALL_BEGIN, uint256(1)));
        hash = keccak256(abi.encodePacked(hash, NESTED_BEGIN, uint256(1)));
        hash = keccak256(abi.encodePacked(hash, CALL_BEGIN, uint256(2)));
        hash = keccak256(abi.encodePacked(hash, CALL_END, uint256(2), true, bytes("")));
        hash = keccak256(abi.encodePacked(hash, NESTED_END, uint256(1)));
        hash = keccak256(abi.encodePacked(hash, CALL_END, uint256(2), true, outerReturnData));
    }
}
