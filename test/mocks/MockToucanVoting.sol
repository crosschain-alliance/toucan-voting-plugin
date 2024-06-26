// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ITokenVoting} from "@aragon/token-voting/ITokenVoting.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {IVoteContainer} from "@interfaces/IVoteContainer.sol";

contract MockToucanVoting {
    function vote(uint256, IVoteContainer.Tally memory, bool) public {}

    mapping(uint256 => ITokenVoting.Proposal) internal proposals;
    bool open_;

    function setProposalData(
        uint256 proposalId,
        bool executed,
        ITokenVoting.ProposalParameters memory parameters,
        ITokenVoting.Tally memory tally,
        IDAO.Action[] memory actions,
        uint256 allowFailureMap,
        address[] memory lastVoters,
        ITokenVoting.Tally[] memory lastVotes,
        bool open
    ) public {
        ITokenVoting.Proposal storage proposal = proposals[proposalId];
        proposal.executed = executed;
        proposal.parameters = parameters;
        proposal.tally = tally;
        proposal.allowFailureMap = allowFailureMap;

        for (uint256 i = 0; i < actions.length; i++) {
            proposal.actions.push(actions[i]);
        }

        for (uint256 i = 0; i < lastVoters.length; i++) {
            proposal.voters[lastVoters[i]] = lastVotes[i];
        }

        open_ = open;
    }

    function setExecuted(uint256 proposalId, bool executed) public {
        proposals[proposalId].executed = executed;
    }

    function setParameters(
        uint256 proposalId,
        ITokenVoting.ProposalParameters memory parameters
    ) public {
        proposals[proposalId].parameters = parameters;
    }

    function setVotingMode(uint256 proposalId, ITokenVoting.VotingMode votingMode) public {
        proposals[proposalId].parameters.votingMode = votingMode;
    }

    function setSupportThreshold(uint256 proposalId, uint32 supportThreshold) public {
        proposals[proposalId].parameters.supportThreshold = supportThreshold;
    }

    function setStartDate(uint256 proposalId, uint64 startDate) public {
        proposals[proposalId].parameters.startDate = startDate;
    }

    function setEndDate(uint256 proposalId, uint64 endDate) public {
        proposals[proposalId].parameters.endDate = endDate;
    }

    function setSnapshotBlock(uint256 proposalId, uint64 snapshotBlock) public {
        proposals[proposalId].parameters.snapshotBlock = snapshotBlock;
    }

    function setMinVotingPower(uint256 proposalId, uint256 minVotingPower) public {
        proposals[proposalId].parameters.minVotingPower = minVotingPower;
    }

    function setTally(uint256 proposalId, ITokenVoting.Tally memory tally) public {
        proposals[proposalId].tally = tally;
    }

    function setActions(uint256 proposalId, IDAO.Action[] memory actions) public {
        delete proposals[proposalId].actions;
        for (uint256 i = 0; i < actions.length; i++) {
            proposals[proposalId].actions.push(actions[i]);
        }
    }

    function setAllowFailureMap(uint256 proposalId, uint256 allowFailureMap) public {
        proposals[proposalId].allowFailureMap = allowFailureMap;
    }

    function setLastVotes(
        uint256 proposalId,
        address[] memory lastVoters,
        ITokenVoting.Tally[] memory lastVotes
    ) public {
        require(lastVoters.length == lastVotes.length, "Mismatched array lengths");
        for (uint256 i = 0; i < lastVoters.length; i++) {
            proposals[proposalId].voters[lastVoters[i]] = lastVotes[i];
        }
    }

    function setOpen(bool open) public {
        open_ = open;
    }

    function getProposal(
        uint256 _proposalId
    )
        public
        view
        virtual
        returns (
            bool open,
            bool executed,
            ITokenVoting.ProposalParameters memory parameters,
            ITokenVoting.Tally memory tally,
            IDAO.Action[] memory actions,
            uint256 allowFailureMap
        )
    {
        ITokenVoting.Proposal storage proposal_ = proposals[_proposalId];

        open = _isProposalOpen(proposal_);
        executed = proposal_.executed;
        parameters = proposal_.parameters;
        tally = proposal_.tally;
        actions = proposal_.actions;
        allowFailureMap = proposal_.allowFailureMap;
    }

    function _isProposalOpen(ITokenVoting.Proposal storage) internal view returns (bool) {
        return open_;
    }
}
