// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

interface IRawFulfill {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @notice Test-only stand-in for the Chainlink VRF v2.5 coordinator.
///         Stores requests and lets the test choose when (and with which word) to answer.
contract VRFCoordinatorMock {
    uint256 public lastRequestId;
    mapping(uint256 requestId => address consumer) public consumerOf;

    event RandomWordsRequested(uint256 indexed requestId, address indexed consumer);
    event SubscriptionCreated(uint256 indexed subId, address owner);

    uint256 public lastSubId;
    mapping(uint256 subId => uint256 balance) public nativeBalance;
    mapping(uint256 subId => address[] consumers) private _consumers;

    // assinatura no mesmo formato do coordenador real (para ensaiar o deploy)
    function createSubscription() external returns (uint256 subId) {
        subId = ++lastSubId;
        emit SubscriptionCreated(subId, msg.sender);
    }

    function fundSubscriptionWithNative(uint256 subId) external payable {
        nativeBalance[subId] += msg.value;
    }

    function addConsumer(uint256 subId, address consumer) external {
        _consumers[subId].push(consumer);
    }

    function consumers(uint256 subId) external view returns (address[] memory) {
        return _consumers[subId];
    }

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata) external returns (uint256 requestId) {
        requestId = ++lastRequestId;
        consumerOf[requestId] = msg.sender;
        emit RandomWordsRequested(requestId, msg.sender);
    }

    function fulfill(uint256 requestId, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        IRawFulfill(consumerOf[requestId]).rawFulfillRandomWords(requestId, words);
    }
}
