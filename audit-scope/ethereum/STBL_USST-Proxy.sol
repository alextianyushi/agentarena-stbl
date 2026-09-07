// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/ISTBL_USST.sol";
import "../lib/STBL_Errors.sol";

/**
 * @title STBL USST Token
 * @author STBL Team
 * @notice Implementation of the STBL USST stablecoin with pausable functionality, access control, and meta-transaction support
 * @dev This contract implements an upgradeable ERC20 token with the following features:
 *      - Role-based access control for different operations
 *      - Pausable transfers for emergency situations
 *      - Blacklist functionality to prevent certain addresses from transacting
 *      - Bridge functionality for cross-chain operations
 *      - Meta-transaction support via ERC2771Context
 *      - UUPS upgradeable proxy pattern
 * @custom:security-contact security@stbl.io
 */
contract STBL_USST is
    Initializable,
    iSTBL_USST,
    AccessControlUpgradeable,
    ERC20PausableUpgradeable,
    ERC20PermitUpgradeable,
    ERC2771ContextUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /** @notice Role identifier for bridge functionality - allows cross-chain mint/burn operations */
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    /** @notice Role identifier for pause functionality - allows pausing/unpausing the contract */
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");

    /** @notice Role identifier for minting functionality - allows minting and burning tokens */
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /** @notice Role identifier for blacklist management - allows adding/removing addresses from blacklist */
    bytes32 public constant LIST_MANAGER_ROLE = keccak256("LIST_MANAGER_ROLE");

    /** @notice Role identifier for upgrade functionality - allows upgrading the contract implementation */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /** @notice Version number of the contract implementation, incremented on each upgrade */
    uint256 private _version;

    /** @notice Mapping to track blacklisted addresses that cannot send or receive tokens */
    mapping(address => bool) private _blacklisted;

    /** @notice Address of the trusted forwarder for meta-transactions (ERC2771) */
    address private trustedForwarderAddress;

    /** @notice Reserved storage space for future upgrades */
    uint256[64] private __gap;

    /**
     * @notice Constructor that disables initializers to prevent implementation contract initialization
     * @dev This constructor sets the trusted forwarder to address(0) and disables initializers
     *      to ensure the implementation contract cannot be initialized directly
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() ERC2771ContextUpgradeable(address(0)) {
        _disableInitializers();
    }

    /**
     * @notice Initializes the STBL USST token contract
     * @dev This function replaces the constructor for upgradeable contracts.
     *      Sets up all inherited contracts, grants initial roles to the deployer,
     *      and configures the trusted forwarder. Can only be called once.
     * @custom:oz-upgrades-initializer
     */
    function initialize() public initializer {
        __AccessControl_init();
        __ERC20_init("STBL_USST - USST Token", "USST");
        __ERC20Pausable_init();
        __ERC20Permit_init("STBL_USST - USST Token");
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(UPGRADER_ROLE, _msgSender());
        _setRoleAdmin(PAUSE_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(MINTER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(BRIDGE_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(LIST_MANAGER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(UPGRADER_ROLE, DEFAULT_ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        trustedForwarderAddress = address(0);
    }

    /**
     * @notice Authorizes upgrades to the contract implementation
     * @dev This function is called by the UUPS proxy before upgrading.
     *      Only addresses with UPGRADER_ROLE can authorize upgrades.
     *      Increments the version number for tracking purposes.
     * @param newImplementation Address of the new implementation contract (unused but required by interface)
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {
        _version = _version + 1;
        emit ContractUpgraded(newImplementation);
    }

    /**
     * @notice Returns the current implementation version
     * @dev This version number is incremented each time the contract is upgraded.
     *      Useful for tracking which version of the contract is currently deployed.
     * @return The current version number of the implementation
     */
    function version() external view returns (uint256) {
        return _version;
    }

    /**
     * @notice Checks if an address is blacklisted
     * @dev Blacklisted addresses cannot send or receive tokens
     * @param _account The address to check
     * @return True if the address is blacklisted, false otherwise
     */
    function isBlacklisted(address _account) external view returns (bool) {
        return _blacklisted[_account];
    }

    /**
     * @notice Mints new tokens to a specified address
     * @dev Only callable by addresses with MINTER_ROLE when the contract is not paused.
     *      Creates new tokens and adds them to the total supply.
     * @param _to The address that will receive the minted tokens
     * @param _amt The amount of tokens to mint
     */
    function mint(
        address _to,
        uint256 _amt
    ) external whenNotPaused onlyRole(MINTER_ROLE) {
        _mint(_to, _amt);
        emit MintEvent(_to, _amt);
    }

    /**
     * @notice Burns tokens from a specified address
     * @dev Only callable by addresses with MINTER_ROLE when the contract is not paused.
     *      First transfers tokens from the specified address to this contract,
     *      then burns them, reducing the total supply.
     * @param _from The address from which tokens will be burned
     * @param _amt The amount of tokens to burn
     */
    function burn(
        address _from,
        uint256 _amt
    ) external whenNotPaused onlyRole(MINTER_ROLE) {
        IERC20(address(this)).safeTransferFrom(_from, address(this), _amt);
        _burn(address(this), _amt);
        emit BurnEvent(_from, _amt);
    }

    /**
     * @notice Mints new tokens for bridge operations
     * @dev Only callable by addresses with BRIDGE_ROLE when the contract is not paused.
     *      Used for cross-chain bridge operations. Emits a BridgeMint event with additional data.
     * @param _to The address that will receive the minted tokens
     * @param _amt The amount of tokens to mint
     * @param _data Additional data related to the bridge operation (e.g., source chain info)
     * @custom:event Emits BridgeMint event
     */
    function bridgeMint(
        address _to,
        uint256 _amt,
        bytes memory _data
    ) external whenNotPaused onlyRole(BRIDGE_ROLE) {
        _mint(_to, _amt);
        emit BridgeMint(_to, _amt, _data);
    }

    /**
     * @notice Burns tokens for bridge operations
     * @dev Only callable by addresses with BRIDGE_ROLE when the contract is not paused.
     *      Used for cross-chain bridge operations. Emits a BridgeBurn event with additional data.
     * @param _from The address from which tokens will be burned
     * @param _amt The amount of tokens to burn
     * @param _data Additional data related to the bridge operation (e.g., destination chain info)
     * @custom:event Emits BridgeBurn event
     */
    function bridgeBurn(
        address _from,
        uint256 _amt,
        bytes memory _data
    ) external whenNotPaused onlyRole(BRIDGE_ROLE) {
        IERC20(address(this)).safeTransferFrom(_from, address(this), _amt);
        _burn(address(this), _amt);
        emit BridgeBurn(_from, _amt, _data);
    }

    /**
     * @notice Pauses all token transfers
     * @dev Only callable by addresses with PAUSE_ROLE.
     *      When paused, all transfers, mints, and burns are blocked.
     *      Used for emergency situations or maintenance.
     * @custom:event Emits Paused event
     */
    function pause() external onlyRole(PAUSE_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses token transfers
     * @dev Only callable by addresses with PAUSE_ROLE.
     *      Restores normal token functionality after being paused.
     * @custom:event Emits Unpaused event
     */
    function unpause() external onlyRole(PAUSE_ROLE) {
        _unpause();
    }

    /**
     * @notice Adds an address to the blacklist
     * @dev Only callable by addresses with LIST_MANAGER_ROLE.
     *      Blacklisted addresses cannot send or receive tokens.
     * @param _account The address to be blacklisted
     * @custom:event Emits Blacklisted event
     */
    function enableBlacklist(
        address _account
    ) external onlyRole(LIST_MANAGER_ROLE) {
        _blacklisted[_account] = true;
        emit Blacklisted(_account);
    }

    /**
     * @notice Removes an address from the blacklist
     * @dev Only callable by addresses with LIST_MANAGER_ROLE.
     *      Restores the ability for the address to send and receive tokens.
     * @param _account The address to be removed from the blacklist
     * @custom:event Emits Unblacklisted event
     */
    function disableBlacklist(
        address _account
    ) external onlyRole(LIST_MANAGER_ROLE) {
        _blacklisted[_account] = false;
        emit Unblacklisted(_account);
    }

    /**
     * @notice Updates the trusted forwarder address for meta-transactions
     * @dev Only callable by addresses with DEFAULT_ADMIN_ROLE.
     *      The trusted forwarder is used for ERC2771 meta-transaction support.
     *      Set to address(0) to disable meta-transaction functionality.
     * @param _newForwarder The new trusted forwarder address
     * @custom:event Emits TrustedForwarderUpdated event
     */
    function updateTrustedForwarder(
        address _newForwarder
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address previousForwarder = trustedForwarderAddress;
        trustedForwarderAddress = _newForwarder;
        emit TrustedForwarderUpdated(previousForwarder, _newForwarder);
    }

    /**
     * @notice Internal hook that validates token transfers before execution
     * @dev Overrides the ERC20 _update function to add blacklist validation.
     *      Prevents blacklisted addresses from sending or receiving tokens.
     *      Called before every transfer, mint, and burn operation.
     * @param from The address sending tokens (address(0) for minting)
     * @param to The address receiving tokens (address(0) for burning)
     * @param amount The amount of tokens being transferred
     * @custom:error STBL_USST_SenderBlacklisted if sender is blacklisted
     * @custom:error STBL_USST_RecipientBlacklisted if recipient is blacklisted
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override(ERC20PausableUpgradeable, ERC20Upgradeable) {
        if (_blacklisted[from]) revert STBL_USST_SenderBlacklisted(from);
        if (_blacklisted[to]) revert STBL_USST_RecipientBlacklisted(to);
        super._update(from, to, amount);
    }

    /**
     * @notice Returns the current nonce for an address for permit functionality
     * @dev Overrides nonces from ERC20PermitUpgradeable to resolve inheritance conflict
     * @param owner The address to get the nonce for
     * @return The current nonce for the given address
     */
    function nonces(
        address owner
    )
        public
        view
        virtual
        override(ERC20PermitUpgradeable, IERC20Permit)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    /**
     * @notice Returns the address of the trusted forwarder
     * @dev Used by ERC2771Context to determine if a transaction is a meta-transaction.
     *      Meta-transactions allow users to interact with the contract without paying gas directly.
     * @return The address of the current trusted forwarder
     */
    function trustedForwarder() public view virtual override returns (address) {
        return trustedForwarderAddress;
    }

    /**
     * @notice Resolves inheritance conflict between ERC2771Context and Context for _msgSender
     * @dev Returns the actual sender of the transaction, accounting for meta-transactions.
     *      If the transaction comes from the trusted forwarder, extracts the real sender from calldata.
     * @return The actual sender address
     */
    function _msgSender()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    /**
     * @notice Resolves inheritance conflict between ERC2771Context and Context for _msgData
     * @dev Returns the actual calldata of the transaction, accounting for meta-transactions.
     *      If the transaction comes from the trusted forwarder, removes the appended sender address.
     * @return The actual transaction calldata
     */
    function _msgData()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    /**
     * @notice Resolves inheritance conflict for ERC2771Context context suffix length
     * @dev Returns the length of the context suffix for meta-transaction support.
     *      Used internally by ERC2771Context to properly parse meta-transaction data.
     * @return The length of the context suffix in bytes
     */
    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
