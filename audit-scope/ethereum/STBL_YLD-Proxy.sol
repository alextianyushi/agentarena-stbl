// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "../lib/STBL_Structs.sol";
import "../lib/STBL_Errors.sol";
import "../interfaces/ISTBL_YLD.sol";

/**
 * @title STBL YLD - Yield Bearing NFT Token
 * @notice Implementation of a yield-bearing NFT token with comprehensive metadata support and meta-transaction capabilities
 * @dev Extends ERC721Pausable with role-based access control, ERC2771Context for meta-transactions, and custom metadata management
 * @author STBL Team
 * @custom:version 1.0.0
 * @custom:security-contact security@stbl.finance
 */
contract STBL_YLD is
    Initializable,
    iSTBL_YLD,
    AccessControlUpgradeable,
    ERC721PausableUpgradeable,
    ERC2771ContextUpgradeable,
    UUPSUpgradeable
{
    /** @notice Role identifier for minting and burning functionality */
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /** @notice Role identifier for pause/unpause functionality */
    bytes32 public constant PAUSE_ROLE = keccak256("PAUSE_ROLE");
    /** @notice Role identifier for upgrade functionality */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /** @notice Version number of the contract implementation */
    uint256 private _version;

    /** @notice Base URI for token metadata */
    string private baseURI;
    /** @notice Counter for NFT token IDs, incremented for each new mint */
    uint256 public nftCtr;
    /** @notice Mapping of token IDs to their complete metadata structures */
    mapping(uint256 => YLD_Metadata) private nftMetaData;

    /** @notice Address of the trusted forwarder for meta-transactions */
    address private trustedForwarderAddress;

    using Strings for uint256;

    /**
     * @dev Storage gap for future upgrades
     * @notice Reserved storage space to allow for layout changes in future versions
     */
    uint256[64] private __gap;

    /**
     * @notice Disables initializers to prevent implementation contract initialization
     * @dev This constructor is marked as unsafe for upgrades but is required for proper proxy pattern implementation
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() ERC2771ContextUpgradeable(address(0)) {
        _disableInitializers();
    }

    /**
     * @notice Initializes the STBL YLD NFT contract
     * @dev Sets up roles, initializes counters, and configures base URI. Can only be called once during deployment
     * @param _uri Base URI for token metadata endpoints
     * @custom:event Emits various RoleGranted events during initialization
     */
    function initialize(string memory _uri) public initializer {
        __AccessControl_init();
        __ERC721_init("STBL_YLD - Yield Bearing NFT", "YLD");
        __ERC721Pausable_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(UPGRADER_ROLE, _msgSender());
        _setRoleAdmin(MINTER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(PAUSE_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(UPGRADER_ROLE, DEFAULT_ADMIN_ROLE);

        baseURI = _uri;
        nftCtr = 0;
        trustedForwarderAddress = address(0);
    }

    /**
     * @notice Authorizes upgrades to the contract implementation
     * @dev Only callable by addresses with UPGRADER_ROLE. Increments version number on each upgrade
     * @param newImplementation Address of the new implementation contract
     * @custom:security This function controls contract upgrades and should be carefully managed
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {
        _version = _version + 1;
        emit ContractUpgraded(newImplementation);
    }

    /**
     * @notice Returns the current implementation version
     * @dev Useful for tracking upgrade versions and contract state
     * @return The version number of the current implementation
     */
    function version() external view returns (uint256) {
        return _version;
    }

    /**
     * @notice Updates the base URI for token metadata
     * @dev Changes the base URI used for constructing token metadata URLs. Only callable by addresses with DEFAULT_ADMIN_ROLE
     * @param _uri The new base URI to set for token metadata
     * @custom:event Does not emit an event - consider adding one for transparency
     */
    function setBaseURI(
        string memory _uri
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        baseURI = _uri;
    }

    /**
     * @notice Pauses all token transfers and operations
     * @dev Emergency function to halt all contract operations when security issues are detected. Only callable by addresses with PAUSE_ROLE
     * @custom:security Critical security function that should be used sparingly
     * @custom:event Emits Paused event from PausableUpgradeable
     */
    function pause() external onlyRole(PAUSE_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses token transfers and operations
     * @dev Resumes normal contract operations after security issues have been resolved. Only callable by addresses with PAUSE_ROLE
     * @custom:event Emits Unpaused event from PausableUpgradeable
     */
    function unpause() external onlyRole(PAUSE_ROLE) {
        _unpause();
    }

    /**
     * @notice Returns the base URI for token metadata
     * @dev Internal function that can be overridden by inheriting contracts
     * @return The base URI used for constructing token metadata URLs
     */
    function _baseURI() internal view virtual override returns (string memory) {
        return baseURI;
    }

    /**
     * @notice Returns the complete URI for a specific token's metadata
     * @dev Overrides the standard ERC721 tokenURI to return custom metadata URIs stored in nftMetaData mapping
     * @param _tokenID The ID of the token to query
     * @return The complete URI for the token's metadata endpoint
     * @custom:throws May revert if tokenID does not exist or metadata is not properly set
     */
    function tokenURI(
        uint256 _tokenID
    ) public view virtual override(ERC721Upgradeable) returns (string memory) {
        return string(abi.encodePacked(baseURI, _tokenID.toString()));
    }

    /**
     * @notice Retrieves the complete metadata structure for a specific NFT
     * @dev Public getter for accessing detailed NFT metadata including yield information and disabled status
     * @param _tokenID The ID of the token to query
     * @return The complete YLD_Metadata structure for the token
     * @custom:gas This function returns a struct which may be gas-intensive for large metadata
     */
    function getNFTData(
        uint256 _tokenID
    ) external view returns (YLD_Metadata memory) {
        return nftMetaData[_tokenID];
    }

    /**
     * @notice Mints a new yield-bearing NFT token
     * @dev Creates a new NFT with associated metadata and increments the token counter. Only callable when not paused by addresses with MINTER_ROLE
     * @param _to Address to mint the NFT to
     * @param _metadata Complete metadata structure associated with the NFT
     * @return The ID of the newly minted NFT
     * @custom:event Emits MintEvent with recipient, token ID, and metadata
     * @custom:security Ensure _metadata is properly validated before calling this function
     */
    function mint(
        address _to,
        YLD_Metadata memory _metadata
    ) external whenNotPaused onlyRole(MINTER_ROLE) returns (uint256) {
        unchecked {
            nftCtr += 1;
        }
        _safeMint(_to, nftCtr);

        nftMetaData[nftCtr] = _metadata;
        nftMetaData[nftCtr].uri = string(
            abi.encodePacked(baseURI, nftCtr.toString())
        );

        emit MintEvent(_to, nftCtr, nftMetaData[nftCtr]);
        return nftCtr;
    }

    /**
     * @notice Burns an NFT permanently
     * @dev Removes the NFT from circulation and marks its metadata as disabled. Only callable when not paused by addresses with MINTER_ROLE
     * @param _from Address that currently owns the NFT
     * @param _id Token ID to burn
     * @custom:event Emits BurnEvent with owner and token ID
     * @custom:throws Reverts with STBL_YLD_NotOwner if _from is not the owner of the token
     */
    function burn(
        address _from,
        uint256 _id
    ) external whenNotPaused onlyRole(MINTER_ROLE) {
        if (ownerOf(_id) != _from) revert STBL_YLD_NotOwner(_id);

        _update(address(0), _id, _from);

        nftMetaData[_id].isDisabled = true;

        emit BurnEvent(_from, _id);
    }

    /**
     * @notice Disables an NFT, preventing transfers while maintaining ownership
     * @dev Sets the disabled flag to prevent transfers without burning the token. Only callable when not paused by addresses with DEFAULT_ADMIN_ROLE
     * @param _id Token ID to disable
     * @custom:event Emits NFTDisabled event
     * @custom:throws Reverts with STBL_YLD_AlreadyDisabled if the NFT is already disabled
     */
    function disableNFT(
        uint256 _id
    ) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        if (nftMetaData[_id].isDisabled != false)
            revert STBL_YLD_AlreadyDisabled(_id);
        nftMetaData[_id].isDisabled = true;
        emit NFTDisabled(_id);
    }

    /**
     * @notice Enables a previously disabled NFT, allowing transfers again
     * @dev Removes the disabled flag to restore normal transfer functionality. Only callable when not paused by addresses with DEFAULT_ADMIN_ROLE
     * @param _id Token ID to enable
     * @custom:event Emits NFTEnabled event
     * @custom:throws Reverts with STBL_YLD_AlreadyEnabled if the NFT is already enabled
     */
    function enableNFT(
        uint256 _id
    ) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        if (nftMetaData[_id].isDisabled != true)
            revert STBL_YLD_AlreadyEnabled(_id);
        nftMetaData[_id].isDisabled = false;
        emit NFTEnabled(_id);
    }

    /**
     * @notice Checks if the contract supports a given interface
     * @dev Implementation of ERC165 to declare supported interfaces including AccessControl, ERC721, and ERC2771Context
     * @param interfaceId The interface identifier to check
     * @return True if the interface is supported, false otherwise
     */
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        virtual
        override(AccessControlUpgradeable, ERC721Upgradeable, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IAccessControl).interfaceId ||
            super.supportsInterface(interfaceId) ||
            interfaceId == type(ERC2771ContextUpgradeable).interfaceId;
    }

    /**
     * @notice Updates the trusted forwarder address for meta-transactions
     * @dev Changes the forwarder used for ERC2771 meta-transaction support. Only callable by addresses with DEFAULT_ADMIN_ROLE
     * @param _newForwarder Address of the new trusted forwarder contract
     * @custom:event Emits TrustedForwarderUpdated with previous and new forwarder addresses
     * @custom:security Ensure the new forwarder contract is trusted and properly audited
     */
    function updateTrustedForwarder(
        address _newForwarder
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address previousForwarder = trustedForwarderAddress;
        trustedForwarderAddress = _newForwarder;
        emit TrustedForwarderUpdated(previousForwarder, _newForwarder);
    }

    /**
     * @notice Returns the address of the trusted forwarder for meta-transactions
     * @dev Public getter for the trusted forwarder address used in ERC2771Context
     * @return The current trusted forwarder address
     */
    function trustedForwarder() public view virtual override returns (address) {
        return trustedForwarderAddress;
    }

    /**
     * @notice Returns the actual sender of the transaction, accounting for meta-transactions
     * @dev Overrides to resolve inheritance conflict between ERC2771Context and Context
     * @return The actual sender address, which may differ from msg.sender in meta-transactions
     * @custom:inheritance Resolves conflict between ContextUpgradeable and ERC2771ContextUpgradeable
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
     * @notice Returns the actual calldata of the transaction, accounting for meta-transactions
     * @dev Overrides to resolve inheritance conflict between ERC2771Context and Context
     * @return The actual transaction data, which may be modified in meta-transactions
     * @custom:inheritance Resolves conflict between ContextUpgradeable and ERC2771ContextUpgradeable
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
     * @notice Returns the length of the context suffix for meta-transaction support
     * @dev Overrides to resolve inheritance conflict for ERC2771Context
     * @return The context suffix length used in meta-transaction processing
     * @custom:inheritance Resolves conflict between ContextUpgradeable and ERC2771ContextUpgradeable
     */
    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }

    /**
     * @notice Extends standard ERC721 _update function with disabled NFT validation
     * @dev Prevents transfers of disabled NFTs while allowing burns. Only operates when contract is not paused
     * @param to Recipient address (address(0) for burns)
     * @param tokenId Token being transferred
     * @param auth Address authorized to perform the transfer
     * @return The previous owner of the token
     * @custom:throws Reverts with STBL_YLD_TransferDisabled if attempting to transfer a disabled NFT
     * @custom:security Burns are still allowed for disabled NFTs as they transfer to address(0)
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override whenNotPaused returns (address) {
        if (nftMetaData[tokenId].isDisabled)
            revert STBL_YLD_TransferDisabled(tokenId);
        return super._update(to, tokenId, auth);
    }
}
