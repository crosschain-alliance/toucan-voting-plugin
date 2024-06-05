// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import {IERC20Metadata, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IDAO} from "@aragon/osx-commons-contracts/src/dao/IDAO.sol";
import {IOFT} from "@lz-oft/interfaces/IOFT.sol";

import {OApp} from "@lz-oapp/OApp.sol";
import {OFTCore} from "@lz-oft/OFTCore.sol";
import {Origin} from "@lz-oapp/interfaces/IOAppReceiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DaoAuthorizable} from "@aragon/osx-commons-contracts/src/permission/auth/DaoAuthorizable.sol";

import {IERC20MintableBurnableUpgradeable as IERC20MintableBurnable} from "@interfaces/IERC20MintableBurnable.sol";

/// @title OFTTokenBridge
/// @author Aragon Association
/// @notice A mint/burn bridge for tokens being transferred to new chains
/// We assume the first chain implements a lock/unlock bridge, and where
/// new tokens are minted. These bridges can be deployed to other EVM chains
/// which will mint new tokens while the others are locked.
/// This implementation uses layer zero as the messaging layer between chains,
/// But the underlying token can be any ERC20 token.
contract OFTTokenBridge is OFTCore, DaoAuthorizable {
    using SafeERC20 for IERC20;

    IERC20MintableBurnable internal immutable underlyingToken_;

    /// @param _token The address of the ERC-20 token to be adapted.
    /// @param _lzEndpoint The LayerZero endpoint address.
    /// @param _dao The delegate capable of making OApp configurations inside of the endpoint.
    constructor(
        address _token,
        address _lzEndpoint,
        address _dao
    ) OFTCore(IERC20Metadata(_token).decimals(), _lzEndpoint, _dao) DaoAuthorizable(IDAO(_dao)) {
        underlyingToken_ = IERC20MintableBurnable(_token);
    }

    // /// @dev overrides the default behavior of 6 decimals as we only use EVM chains
    // /// TODO some weirdness with trying to return the decimals as the override function is pure
    // function sharedDecimals() public pure override returns (uint8) {
    //     return 18;
    // }

    /// @notice Retrieves interfaceID and the version of the OFT.
    /// @return interfaceId The interface ID for IOFT.
    /// @return version Indicates a cross-chain compatible msg encoding with other OFTs.
    /// @dev If a new feature is added to the OFT cross-chain msg encoding, the version will be incremented.
    /// ie. localOFT version(x,1) CAN send messages to remoteOFT version(x,1)
    function oftVersion() external pure virtual returns (bytes4 interfaceId, uint64 version) {
        return (type(IOFT).interfaceId, 1);
    }

    /// @dev Retrieves the address of the underlying ERC20 implementation.
    /// @return The address of the adapted ERC-20 token.
    function token() external view returns (address) {
        return address(underlyingToken_);
    }

    /// @notice Indicates whether the OFT contract requires approval of the 'token()' to send.
    /// @return requiresApproval Needs approval of the underlying token implementation.
    function approvalRequired() external pure virtual returns (bool) {
        return true;
    }

    /// @notice Burns tokens from the sender's specified balance, ie. pull method.
    /// @param _amountLD The amount of tokens to send in local decimals.
    /// @param _minAmountLD The minimum amount to send in local decimals.
    /// @param _dstEid The destination chain ID.
    /// @return amountSentLD The amount sent in local decimals.
    /// @return amountReceivedLD The amount received in local decimals on the remote.
    /// @dev msg.sender will need to approve this _amountLD of tokens to be burned by this contract.
    function _debit(
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal virtual override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);
        underlyingToken_.burn(msg.sender, amountSentLD);
    }

    /// @notice Credits tokens to the specified address by minting
    /// @param _to The address to credit the tokens to.
    /// @param _amountLD The amount of tokens to credit in local decimals.
    /// @return amountReceivedLD The amount of tokens ACTUALLY received in local decimals.
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 /*_srcEid*/
    ) internal virtual override returns (uint256 amountReceivedLD) {
        underlyingToken_.mint(_to, _amountLD);
        return _amountLD;
    }
}