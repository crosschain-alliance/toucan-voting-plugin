// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.17;

import {IOAppCore} from "@lz-oapp/OAppCore.sol";
import {IDAO} from "@aragon/osx/core/dao/IDAO.sol";
import {IVoteContainer} from "@interfaces/IVoteContainer.sol";
import {DaoUnauthorized} from "@aragon/osx/core/utils/auth.sol";

import {ToucanVoting, IToucanVoting} from "@toucan-voting/ToucanVoting.sol";
import {GovernanceERC20} from "@toucan-voting/ERC20/governance/GovernanceERC20.sol";
import {ToucanReceiver} from "@execution-chain/crosschain/ToucanReceiver.sol";
import {ProposalRefEncoder, ProposalReference} from "@libs/ProposalRefEncoder.sol";
import {TallyMath, OverflowChecker} from "@libs/TallyMath.sol";

import {MockLzEndpointMinimal} from "@mocks/MockLzEndpoint.sol";
import {DAO, createTestDAO} from "@mocks/MockDAO.sol";
import {MockToucanReceiver} from "@mocks/MockToucanReceiver.sol";

import {deployToucanReceiver, deployMockToucanReceiver} from "@utils/deployers.sol";
import {ToucanReceiverBaseTest} from "./ToucanReceiverBase.t.sol";

import "forge-std/Test.sol";

/// @dev single chain testing for the relay
contract TestToucanReceiverVotingPower is ToucanReceiverBaseTest {
    using ProposalRefEncoder for uint256;
    using ProposalRefEncoder for ProposalReference;
    using TallyMath for Tally;
    using OverflowChecker for Tally;

    address bridge = address(0xb71d4e);

    function setUp() public override {
        super.setUp();

        vm.label(bridge, "MOCK_BRIDGE");
        vm.prank(bridge);
        {
            // delegate to the receiver
            token.delegate(address(receiver));
        }
    }

    function testFuzz_noVotingPowerIfNoProposalDataExists(
        uint256 _proposalId,
        uint256 _validProposalId,
        Tally memory _votes,
        uint32 _snapshotBlock
    ) public {
        vm.assume(_proposalId != _validProposalId);
        plugin.setSnapshotBlock(_validProposalId, _snapshotBlock);
        assertFalse(receiver.hasEnoughVotingPowerForNewVotes(_proposalId, _votes));
    }

    // contract has a balance but it was from tokens bridged too late
    function testFuzz_noVotingPowerAtBlock(
        uint256 _proposalId,
        Tally memory _votes,
        uint32 _snapshotBlock,
        uint32 _rollTo, // bounded by ERC20Votes clock
        uint224 _mint // bounded by ERC20Votes max delegation
    ) public {
        // block num must be > snapshot block or will revert with future lookup
        vm.assume(_rollTo > _snapshotBlock);
        vm.assume(_snapshotBlock != 0);
        // votes will be summed
        vm.assume(!_votes.overflows());

        plugin.setSnapshotBlock(_proposalId, _snapshotBlock);

        // we need to roll before we mint or the contract will have voting power
        vm.roll(_rollTo);
        token.mint(address(bridge), _mint);

        assertFalse(receiver.hasEnoughVotingPowerForNewVotes(_proposalId, _votes));
    }

    function testFuzz_sufficientVotingPowerAtBlock(
        uint256 _proposalId,
        Tally memory _votes,
        uint32 _snapshotBlock,
        uint32 _rollTo, // bounded by ERC20Votes clock
        uint224 _mint // bounded by ERC20Votes max delegation
    ) public {
        // block num must be > snapshot block or will revert with future lookup
        vm.assume(_rollTo > _snapshotBlock);
        vm.assume(!_votes.overflows());
        // we don't consider genesis to be a valid snapshot block
        vm.assume(_snapshotBlock != 0);

        // equivalent to saying: the voting power will be enough for the votes
        vm.assume(_mint >= _votes.sum());

        plugin.setSnapshotBlock(_proposalId, _snapshotBlock);

        // technically not needed but why not
        vm.roll(_snapshotBlock);
        token.mint(address(bridge), _mint);
        vm.roll(_rollTo);

        assertTrue(receiver.hasEnoughVotingPowerForNewVotes(_proposalId, _votes));
    }

    function testFuzz_insufficientVotingPowerAtBlockExistingState(
        uint256 _proposalId,
        Tally memory _votes,
        uint32 _snapshotBlock,
        uint32 _rollTo, // bounded by ERC20Votes clock
        uint224 _mint, // bounded by ERC20Votes max delegation
        uint8 _divisor
    ) public {
        // block num must be > snapshot block or will revert with future lookup
        vm.assume(_rollTo > _snapshotBlock);
        vm.assume(_snapshotBlock != 0);
        vm.assume(_divisor != 0);

        // we will need to sum these so they can't overflow
        vm.assume(!_votes.overflows());

        // votes should be mintable but less than required
        _votes = _boundVotes(_votes);
        vm.assume(_mint < _votes.sum());

        // we can divide the existing votes into two new tallies
        // there are no checks on zero voting in the view function
        Tally memory existingVotes = _votes.div(_divisor);

        // set the state
        receiver.setAggregateVotes(_proposalId, existingVotes);
        plugin.setSnapshotBlock(_proposalId, _snapshotBlock);

        // mint and give power
        token.mint(address(bridge), _mint);
        vm.roll(_rollTo);

        // should still not be enough for the new votes
        assertFalse(receiver.hasEnoughVotingPowerForNewVotes(_proposalId, _votes));
    }

    function testFuzz_sufficientVotingPowerAtBlockExistingState(
        uint256 _proposalId,
        Tally memory _votes,
        Tally memory _newVotes,
        uint32 _snapshotBlock,
        uint32 _rollTo, // bounded by ERC20Votes clock
        uint224 _mint, // bounded by ERC20Votes max delegation
        uint8 _divisor
    ) public {
        // block num must be > snapshot block or will revert with future lookup
        vm.assume(_rollTo > _snapshotBlock);
        vm.assume(_snapshotBlock != 0);
        vm.assume(_divisor != 0);

        // we will need to sum these so they can't overflow
        vm.assume(!_votes.overflows());
        vm.assume(!_newVotes.overflows());

        // votes should be mintable and sufficient
        _votes = _boundVotes(_votes);
        _newVotes = _boundVotes(_newVotes);

        // the votes replace each other, meaning as long as
        // both are <= _mint we are good
        vm.assume(_mint >= _votes.sum());
        vm.assume(_mint >= _newVotes.sum());

        // set the state
        receiver.setAggregateVotes(_proposalId, _votes);
        plugin.setSnapshotBlock(_proposalId, _snapshotBlock);

        // mint and give power
        token.mint(address(bridge), _mint);
        vm.roll(_rollTo);

        // should be enough for the new votes
        assertTrue(receiver.hasEnoughVotingPowerForNewVotes(_proposalId, _newVotes));
    }

    function _boundVotes(Tally memory _votes) internal pure returns (Tally memory) {
        uint224 max = type(uint224).max;
        if (_votes.sum() > max) {
            _votes.yes = max / 3;
            _votes.no = max / 3;
            _votes.abstain = max / 3;
        }
        return _votes;
    }
}
