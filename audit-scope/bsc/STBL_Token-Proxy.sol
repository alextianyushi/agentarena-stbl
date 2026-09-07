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

import "../interfaces/ISTBL_Token.sol";

/**
 * @title STBL Token
 * @notice Implementation of the STBL governance token with stablecoin functionality
 * @dev Upgradeable ERC20 token with role-based access control, pausable transfers, and meta-transaction support
 * @dev Implements UUPS proxy pattern for upgradeability
 * @author STBL Protocol Team
 */
contract STBL_Token is
    Initializable,
    iSTBL_Token,
    AccessControlUpgradeable,
    ERC20PausableUpgradeable,
    ERC20PermitUpgradeable,
    ERC2771ContextUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    /** @notice Maximum supply cap for the STBL token */
    uint256 public constant MAX_CAP = 10 ** 28;

    /** @notice Error thrown when attempting to mint tokens beyond the maximum cap */
    error STBL_MaxCapReached();

    /** @notice Role identifier for bridge functionality */
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    /** @notice Role identifier for pause functionality */
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");

    /** @notice Role identifier for minting functionality */
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /** @notice Role identifier for upgrade functionality */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /** @notice Version number of the contract implementation */
    uint256 private _version;

    /** @notice Address of the trusted forwarder for meta-transactions */
    address private trustedForwarderAddress;

    /** @notice Reserved storage space to allow for layout changes in future versions */
    uint256[64] private __gap;

    /**
     * @notice Constructor that disables initializers to prevent implementation contract initialization
     * @dev This constructor is marked as unsafe for upgrades but is required for proper proxy pattern implementation
     * @dev Initializes with zero address forwarder to prevent accidental usage of implementation contract
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() ERC2771ContextUpgradeable(address(0)) {
        _disableInitializers();
    }

    /**
     * @notice Initializes the STBL governance token contract
     * @dev Sets up access control roles, initializes ERC20 token properties, and configures trusted forwarder
     * @dev Can only be called once during deployment via proxy initialization
     * @dev Grants DEFAULT_ADMIN_ROLE and UPGRADER_ROLE to the deployer
     */
    function initialize() public initializer {
        __AccessControl_init();
        __ERC20_init("STBL_Token - STBL Governance Token", "STBL");
        __ERC20Pausable_init();
        __ERC20Permit_init("STBL_Token - STBL Governance Token");
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(UPGRADER_ROLE, _msgSender());
        _setRoleAdmin(PAUSE_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(MINTER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(BRIDGE_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(UPGRADER_ROLE, DEFAULT_ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        trustedForwarderAddress = address(0);
    }

    /**
     * @notice Authorizes upgrades to the contract implementation
     * @dev Only callable by addresses with UPGRADER_ROLE
     * @dev Increments version number to track upgrades
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {
        _version = _version + 1;
        emit ContractUpgraded(newImplementation);
    }

    /**
     * @notice Returns the current implementation version
     * @dev Useful for tracking upgrade versions and ensuring correct deployment
     * @return uint256 Version identifier of the current implementation
     */
    function version() external view returns (uint256) {
        return _version;
    }

    /**
     * @notice Mints new tokens to a specified address
     * @dev Only callable by addresses with MINTER_ROLE when contract is not paused
     * @param _to Address to receive the minted tokens
     * @param _amt Amount of tokens to mint (in wei units)
     */
    function mint(
        address _to,
        uint256 _amt
    ) external whenNotPaused onlyRole(MINTER_ROLE) {
        if (IERC20(address(this)).totalSupply() + _amt > MAX_CAP)
            revert STBL_MaxCapReached();
        _mint(_to, _amt);
        emit MintEvent(_to, _amt);
    }

    /**
     * @notice Burns tokens from a specified address
     * @dev Only callable by addresses with MINTER_ROLE when contract is not paused
     * @dev Requires token approval from the target address
     * @param _from Address from which tokens will be burned
     * @param _amt Amount of tokens to burn (in wei units)
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
        if (IERC20(address(this)).totalSupply() + _amt > MAX_CAP)
            revert STBL_MaxCapReached();

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
     * @dev Only callable by addresses with PAUSE_ROLE
     * @dev Prevents all token transfers, minting, and burning until unpaused
     */
    function pause() external onlyRole(PAUSE_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses token transfers
     * @dev Only callable by addresses with PAUSE_ROLE
     * @dev Restores normal token functionality after being paused
     */
    function unpause() external onlyRole(PAUSE_ROLE) {
        _unpause();
    }

    /**
     * @notice Updates the trusted forwarder address for meta-transactions
     * @dev Only callable by the default admin role
     * @dev Emits a TrustedForwarderUpdated event with the previous and new forwarder addresses
     * @param _newForwarder The address of the new trusted forwarder contract
     */
    function updateTrustedForwarder(
        address _newForwarder
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address previousForwarder = trustedForwarderAddress;
        trustedForwarderAddress = _newForwarder;
        emit TrustedForwarderUpdated(previousForwarder, _newForwarder);
    }

    /**
     * @notice Returns the address of the trusted forwarder
     * @dev Override from ERC2771Context to provide custom forwarder address
     * @return address The trusted forwarder address used for meta-transactions
     */
    function trustedForwarder() public view virtual override returns (address) {
        return trustedForwarderAddress;
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
     * @notice Internal function that is called before any transfer of tokens
     * @dev Override required to resolve inheritance conflict between ERC20PausableUpgradeable and ERC20Upgradeable
     * @param from Address tokens are transferred from
     * @param to Address tokens are transferred to
     * @param amount Amount of tokens being transferred
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override(ERC20PausableUpgradeable, ERC20Upgradeable) {
        super._update(from, to, amount);
    }

    /**
     * @notice Override to resolve inheritance conflict between ERC2771Context and Context
     * @dev Returns the actual sender of the transaction, accounting for meta-transactions
     * @dev Prioritizes ERC2771Context implementation for proper meta-transaction support
     * @return address The actual sender address
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
     * @notice Override to resolve inheritance conflict between ERC2771Context and Context
     * @dev Returns the actual calldata of the transaction, accounting for meta-transactions
     * @dev Prioritizes ERC2771Context implementation for proper meta-transaction support
     * @return bytes calldata The actual transaction data
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
     * @notice Override to resolve inheritance conflict for ERC2771Context
     * @dev Returns the length of the context suffix for meta-transaction support
     * @dev Prioritizes ERC2771Context implementation for proper meta-transaction support
     * @return uint256 The context suffix length
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
