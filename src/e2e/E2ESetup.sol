// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

// external contracts
import {OApp} from "@lz-oapp/OApp.sol";
import {OFT} from "@lz-oft/OFT.sol";
import {Origin} from "@lz-oapp/interfaces/IOAppReceiver.sol";
import {SendParam, OFTLimit, OFTFeeDetail, OFTReceipt, MessagingFee} from "@lz-oft/interfaces/IOFT.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {IVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/IVotesUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

// aragon contracts
import {IDAO} from "@aragon/osx/core/dao/IDAO.sol";
import {DAO} from "@aragon/osx/core/dao/DAO.sol";
import {Admin, AdminSetup} from "@aragon/admin/AdminSetup.sol";
import {Multisig, MultisigSetup} from "@aragon/multisig/MultisigSetup.sol";

// external test utils
import "forge-std/console2.sol";

// own the libs
import {ProposalRefEncoder} from "@libs/ProposalRefEncoder.sol";
import {ProxyLib} from "@libs/ProxyLib.sol";
import {TallyMath} from "@libs/TallyMath.sol";

// internal contracts
import {IVoteContainer} from "@interfaces/IVoteContainer.sol";

/// execution chain
import {ToucanVoting, ToucanVotingSetup, IToucanVoting, GovernanceERC20, GovernanceWrappedERC20} from "@toucan-voting/ToucanVotingSetup.sol";
import {ActionRelay, ToucanReceiver, ToucanReceiverSetup, GovernanceOFTAdapter} from "@execution-chain/setup/ToucanReceiverSetup.sol";

/// voting chain
import {GovernanceERC20VotingChain} from "@voting-chain/token/GovernanceERC20VotingChain.sol";
import {ToucanRelay, ToucanRelaySetup, OFTTokenBridge} from "@voting-chain/setup/ToucanRelaySetup.sol";
import {AdminXChain, AdminXChainSetup} from "@voting-chain/setup/AdminXChainSetup.sol";

// test utils
import {MockPluginSetupProcessor} from "@mocks/osx/MockPSP.sol";
import {MockDAOFactory, PluginSetupRef} from "@mocks/osx/MockDAOFactory.sol";
import "@helpers/OSxHelpers.sol";
import "forge-std/console2.sol";

interface ISetup {
    struct ChainBase {
        string chainName;
        // layer zero
        uint32 eid;
        uint256 chainid;
        address lzEndpoint;
        // OSX
        DAO dao;
        MockPluginSetupProcessor psp;
        MockDAOFactory daoFactory;
        // deployer
        address deployer;
        // we need admin to access the DAO
        MultisigSetup multisigSetup;
        Multisig multisig;
        PermissionLib.MultiTargetPermission[] adminUninstallPermissions;
    }

    struct VotingChain {
        ChainBase base;
        // contracts
        GovernanceERC20VotingChain token;
        ToucanRelay relay;
        AdminXChain adminXChain;
        OFTTokenBridge bridge;
        // setups
        AdminXChainSetup adminXChainSetup;
        ToucanRelaySetup relaySetup;
        //permissions
        PermissionLib.MultiTargetPermission[] toucanRelayPermissions;
        PermissionLib.MultiTargetPermission[] adminXChainPermissions;
        // agents
        address voter;
    }

    struct ExecutionChain {
        ChainBase base;
        // contracts
        GovernanceERC20 token;
        GovernanceOFTAdapter adapter;
        ToucanReceiver receiver;
        ActionRelay actionRelay;
        ToucanVoting voting;
        // setups
        ToucanReceiverSetup receiverSetup;
        ToucanVotingSetup votingSetup;
        // permissions
        PermissionLib.MultiTargetPermission[] receiverPermissions;
        PermissionLib.MultiTargetPermission[] votingPermissions;
        // agents
        address voter;
    }
}

contract SetupE2EBase is IVoteContainer, ISetup {
    using OptionsBuilder for bytes;
    using ProxyLib for address;
    using ProposalRefEncoder for uint256;
    using TallyMath for Tally;

    function _deployOSX(ChainBase memory base) internal {
        // deploy the mock PSP with the multisig  plugin
        base.multisigSetup = new MultisigSetup();
        base.psp = new MockPluginSetupProcessor(address(base.multisigSetup));
        base.daoFactory = new MockDAOFactory(base.psp);
    }

    function _deployDAOAndMSig(ChainBase memory base) internal {
        // use the OSx DAO factory with the Plugin
        address[] memory members = new address[](1);
        members[0] = base.deployer;

        // encode a 1/1 multisig that can be adjusted later
        bytes memory data = abi.encode(
            members,
            Multisig.MultisigSettings({onlyListed: true, minApprovals: 1})
        );

        base.dao = base.daoFactory.createDao(_mockDAOSettings(), _mockPluginSettings(data));

        // nonce 0 is something?
        // nonce 1 is implementation contract
        // nonce 2 is the msig contract behind the proxy
        base.multisig = Multisig(computeAddress(address(base.multisigSetup), 2));
    }
}

contract SetupExecutionChainE2E is SetupE2EBase {
    function _prepareSetupToucanVoting(ExecutionChain memory chain) internal {
        GovernanceERC20.MintSettings memory mintSettings = GovernanceERC20.MintSettings(
            new address[](1),
            new uint256[](1)
        );
        mintSettings.receivers[0] = address(this);
        mintSettings.amounts[0] = 0;

        GovernanceERC20 baseToken = new GovernanceERC20(
            IDAO(address(chain.base.dao)),
            "Test Token",
            "TT",
            mintSettings
        );

        chain.votingSetup = new ToucanVotingSetup(
            new ToucanVoting(),
            baseToken,
            new GovernanceWrappedERC20(
                IERC20Upgradeable(address(baseToken)),
                "Wrapped Test Token",
                "WTT"
            )
        );

        // push to the PSP
        chain.base.psp.queueSetup(address(chain.votingSetup));

        // prep the data
        IToucanVoting.VotingSettings memory votingSettings = IToucanVoting.VotingSettings({
            votingMode: IToucanVoting.VotingMode.VoteReplacement,
            supportThreshold: 1e5,
            minParticipation: 1e5,
            minDuration: 2 hours,
            minProposerVotingPower: 1 ether
        });

        ToucanVotingSetup.TokenSettings memory tokenSettings = ToucanVotingSetup.TokenSettings({
            addr: address(0),
            symbol: "CRAB",
            name: "Rust Token"
        });

        mintSettings.receivers[0] = chain.voter;
        mintSettings.amounts[0] = 1_000_000 ether;

        bytes memory data = abi.encode(votingSettings, tokenSettings, mintSettings, false);

        (
            address votingPluginAddress,
            IPluginSetup.PreparedSetupData memory votingPluginPreparedSetupData
        ) = chain.base.psp.prepareInstallation(
                address(chain.base.dao),
                _mockPrepareInstallationParams(data)
            );

        chain.votingPermissions = votingPluginPreparedSetupData.permissions;

        chain.voting = ToucanVoting(votingPluginAddress);
        address[] memory helpers = votingPluginPreparedSetupData.helpers;
        chain.token = GovernanceERC20(helpers[0]);
    }

    function _prepareSetupReceiver(ExecutionChain memory chain) internal {
        // deploy receiver and set it as next address for PSP to use
        chain.receiverSetup = new ToucanReceiverSetup(
            new ToucanReceiver(),
            new GovernanceOFTAdapter(),
            new ActionRelay()
        );
        chain.base.psp.queueSetup(address(chain.receiverSetup));

        // prepare the installation
        bytes memory data = abi.encode(address(chain.base.lzEndpoint), address(chain.voting));

        (
            address receiverPluginAddress,
            IPluginSetup.PreparedSetupData memory receiverPluginPreparedSetupData
        ) = chain.base.psp.prepareInstallation(
                address(chain.base.dao),
                _mockPrepareInstallationParams(data)
            );

        chain.receiverPermissions = receiverPluginPreparedSetupData.permissions;

        chain.receiver = ToucanReceiver(payable(receiverPluginAddress));
        address[] memory helpers = receiverPluginPreparedSetupData.helpers;
        chain.adapter = GovernanceOFTAdapter(helpers[0]);
        chain.actionRelay = ActionRelay(helpers[1]);
    }

    function _executionActions(
        ExecutionChain memory chain,
        VotingChain memory votingChain
    ) internal view returns (IDAO.Action[] memory) {
        IDAO.Action[] memory actions = new IDAO.Action[](5);

        // action 0: apply the tokenVoting installation
        actions[0] = IDAO.Action({
            to: address(chain.base.psp),
            value: 0,
            data: abi.encodeCall(
                chain.base.psp.applyInstallation,
                (
                    address(chain.base.dao),
                    _mockApplyInstallationParams(address(chain.voting), chain.votingPermissions)
                )
            )
        });

        // action 1: apply the receiver installation
        actions[1] = IDAO.Action({
            to: address(chain.base.psp),
            value: 0,
            data: abi.encodeCall(
                chain.base.psp.applyInstallation,
                (
                    address(chain.base.dao),
                    _mockApplyInstallationParams(address(chain.receiver), chain.receiverPermissions)
                )
            )
        });

        // action 2,3,4: set the peers
        actions[2] = IDAO.Action({
            to: address(chain.receiver),
            value: 0,
            data: abi.encodeCall(
                chain.receiver.setPeer,
                (votingChain.base.eid, addressToBytes32(address(votingChain.relay)))
            )
        });

        actions[3] = IDAO.Action({
            to: address(chain.actionRelay),
            value: 0,
            data: abi.encodeCall(
                chain.actionRelay.setPeer,
                (votingChain.base.eid, addressToBytes32(address(votingChain.adminXChain)))
            )
        });

        actions[4] = IDAO.Action({
            to: address(chain.adapter),
            value: 0,
            data: abi.encodeCall(
                chain.adapter.setPeer,
                (votingChain.base.eid, addressToBytes32(address(votingChain.bridge)))
            )
        });

        // wrap the actions in grant/revoke root permissions
        return wrapGrantRevokeRoot(chain.base.dao, address(chain.base.psp), actions);
    }
}

contract SetupVotingChainE2E is SetupE2EBase {
    function _prepareSetupRelay(VotingChain memory chain, ExecutionChain memory e) internal {
        // setup the voting chain: we need 2 setup contracts for the toucanRelay and the adminXChain
        chain.relaySetup = new ToucanRelaySetup(
            new ToucanRelay(),
            new OFTTokenBridge(),
            new GovernanceERC20VotingChain(IDAO(address(chain.base.dao)), "TestToken", "TT")
        );

        // set it on the mock psp
        chain.base.psp.queueSetup(address(chain.relaySetup));

        ToucanRelaySetup.InstallationParams memory params = ToucanRelaySetup.InstallationParams({
            lzEndpoint: address(chain.base.lzEndpoint),
            tokenName: "Voting Rust Token",
            tokenSymbol: "vCRAB",
            dstEid: e.base.eid,
            votingBridgeBuffer: 20 minutes
        });

        // prepare the installation
        bytes memory data = abi.encode(params);
        (
            address toucanRelayAddress,
            IPluginSetup.PreparedSetupData memory toucanRelaySetupData
        ) = chain.base.psp.prepareInstallation(
                address(chain.base.dao),
                _mockPrepareInstallationParams(data)
            );

        chain.toucanRelayPermissions = toucanRelaySetupData.permissions;

        chain.relay = ToucanRelay(toucanRelayAddress);
        address[] memory helpers = toucanRelaySetupData.helpers;
        chain.token = GovernanceERC20VotingChain(helpers[0]);
        chain.bridge = OFTTokenBridge(helpers[1]);
    }

    function _prepareSetupAdminXChain(VotingChain memory chain) internal {
        // setup the voting chain: we need 2 setup contracts for the toucanRelay and the adminXChain
        chain.adminXChainSetup = new AdminXChainSetup(new AdminXChain());

        // set it on the mock psp
        chain.base.psp.queueSetup(address(chain.adminXChainSetup));

        // prepare the installation
        bytes memory data = abi.encode(address(chain.base.lzEndpoint));
        (
            address adminXChainAddress,
            IPluginSetup.PreparedSetupData memory adminXChainSetupData
        ) = chain.base.psp.prepareInstallation(
                address(chain.base.dao),
                _mockPrepareInstallationParams(data)
            );

        chain.adminXChainPermissions = adminXChainSetupData.permissions;
        chain.adminXChain = AdminXChain(payable(adminXChainAddress));
    }

    function _votingActions(
        VotingChain memory chain,
        ExecutionChain memory executionChain
    ) internal view returns (IDAO.Action[] memory) {
        IDAO.Action[] memory actions = new IDAO.Action[](5);

        // action 0: apply the toucanRelay installation
        actions[0] = IDAO.Action({
            to: address(chain.base.psp),
            value: 0,
            data: abi.encodeCall(
                chain.base.psp.applyInstallation,
                (
                    address(chain.base.dao),
                    _mockApplyInstallationParams(address(chain.relay), chain.toucanRelayPermissions)
                )
            )
        });

        // action 1: apply the adminXChain installation
        actions[1] = IDAO.Action({
            to: address(chain.base.psp),
            value: 0,
            data: abi.encodeCall(
                chain.base.psp.applyInstallation,
                (
                    address(chain.base.dao),
                    _mockApplyInstallationParams(
                        address(chain.adminXChain),
                        chain.adminXChainPermissions
                    )
                )
            )
        });

        // action 2,3,4: set the peers
        actions[2] = IDAO.Action({
            to: address(chain.relay),
            value: 0,
            data: abi.encodeCall(
                chain.relay.setPeer,
                (executionChain.base.eid, addressToBytes32(address(executionChain.receiver)))
            )
        });

        actions[3] = IDAO.Action({
            to: address(chain.adminXChain),
            value: 0,
            data: abi.encodeCall(
                chain.adminXChain.setPeer,
                (executionChain.base.eid, addressToBytes32(address(executionChain.actionRelay)))
            )
        });

        actions[4] = IDAO.Action({
            to: address(chain.bridge),
            value: 0,
            data: abi.encodeCall(
                chain.bridge.setPeer,
                (executionChain.base.eid, addressToBytes32(address(executionChain.adapter)))
            )
        });

        // wrap the actions in grant/revoke root permissions
        return wrapGrantRevokeRoot(chain.base.dao, address(chain.base.psp), actions);
    }
}
