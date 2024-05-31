pragma solidity ^0.8.20;

import {ToucanReceiver} from "@execution-chain/crosschain/ToucanReceiver.sol";
import {Origin} from "@lz-oapp/interfaces/IOAppReceiver.sol";

contract MockToucanReceiver is ToucanReceiver {
    constructor(
        address _governanceToken,
        address _lzEndpoint,
        address _dao,
        address _votingPlugin
    ) ToucanReceiver(_governanceToken, _lzEndpoint, _dao, _votingPlugin) {}

    struct VotesByChain {
        uint chainId;
        Tally votes;
    }

    function setState(
        uint _proposalId,
        Tally memory aggregateVotes,
        VotesByChain[] memory _votesByChain
    ) public {
        votes[_proposalId].aggregateVotes = aggregateVotes;
        for (uint i = 0; i < _votesByChain.length; i++) {
            votes[_proposalId].votesByChain[_votesByChain[i].chainId] = _votesByChain[i].votes;
        }
    }

    function setAggregateVotes(uint _proposalId, Tally memory _aggregateVotes) public {
        votes[_proposalId].aggregateVotes = _aggregateVotes;
    }

    function receiveVotes(uint _votingChainId, uint _proposalId, Tally memory _votes) public {
        _receiveVotes(_votingChainId, _proposalId, _votes);
    }

    function _lzReceive(bytes calldata message, Origin calldata o, bytes calldata d) external {
        bytes32 g;
        address e;
        _lzReceive(o, g, message, e, d);
    }
}
