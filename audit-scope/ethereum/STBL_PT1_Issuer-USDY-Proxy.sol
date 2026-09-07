// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@stbl-protocol/stbl-contracts-evm-core/contracts/interfaces/ISTBL_Register.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/interfaces/ISTBL_Core.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/interfaces/ISTBL_YLD.sol";

import "./interfaces/ISTBL_PT1_AssetIssuer.sol";
import "./interfaces/ISTBL_PT1_AssetVault.sol";
import "./interfaces/ISTBL_PT1_AssetYieldDistributor.sol";
import "./interfaces/ISTBL_PT1_AssetOracle.sol";

import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_Structs.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_AssetDefinitionLib.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_MetadataLib.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_Errors.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_Errors.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_DecimalConverter.sol";

import "./lib/STBL_OracleLib.sol";
import "./lib/STBL_PT1_Asset_Errors.sol";

/**
 * @title STBL_PT1_Issuer
 * @notice Protocol Type 1 asset issuer contract that manages deposits and withdrawals for tokenized real-world assets
 * @dev Implements the iSTBL_PT1_AssetIssuer interface with UUPS upgradeable pattern and ERC2771 meta-transaction support
 * @dev This contract serves as the primary interface for users to deposit assets and receive yield-bearing NFTs
 * @author STBL Protocol
 * @custom:security-contact security@stbl.xyz
 */
contract STBL_PT1_Issuer is
    Initializable,
    iSTBL_PT1_AssetIssuer,
    ERC2771ContextUpgradeable,
    UUPSUpgradeable
{
    using STBL_AssetDefinitionLib for AssetDefinition;
    using STBL_OracleLib for iSTBL_PT1_AssetOracle;
    using STBL_MetadataLib for YLD_Metadata;
    using DecimalConverter for uint256;

    /** @notice Role identifier for contract upgrade authorization */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /** @notice Role identifier for Splitter role authorization */
    bytes32 public constant SPLITTER_ROLE = keccak256("SPLITTER_ROLE");

    /** @notice Current implementation version number for tracking upgrades */
    uint256 private _version;

    /** @notice Registry contract interface providing access to all system components and configuration */
    iSTBL_Register private registry;

    /** @notice Unique identifier for the specific asset type managed by this issuer instance */
    uint256 private assetID;

    /**
     * @dev Storage gap reserved for future state variables in upgradeable contracts
     * @notice This gap ensures storage layout compatibility when adding new state variables in future versions
     */
    uint256[64] private __gap;

    /**
     * @notice Ensures the asset is properly configured and active before allowing operations
     * @dev Validates that the asset definition exists in the registry and is marked as active
     * @custom:reverts STBL_Asset_NotInitialized if the asset is not properly initialized or has been deactivated
     */
    modifier isSetupDone() {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);
        if (!AssetData.isActive()) revert STBL_Asset_NotInitialized(assetID);
        _;
    }

    /**
     * @notice Contract constructor that initializes the ERC2771Context with a null trusted forwarder
     * @dev The trusted forwarder will be configured during the initialize() call via the registry
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() ERC2771ContextUpgradeable(address(0)) {}

    /**
     * @notice Initializes the issuer contract with asset configuration and access controls
     * @dev Sets up UUPS upgradeability, access control roles, and links to the protocol registry
     * @dev This function can only be called once during proxy deployment
     * @param _id The unique asset identifier this issuer will manage
     * @param _registry Address of the STBL protocol registry contract
     * @custom:security Only the deployer receives initial admin and upgrader roles
     */
    function initialize(uint256 _id, address _registry) public initializer {
        __UUPSUpgradeable_init();

        registry = iSTBL_Register(_registry);
        assetID = _id;
    }

    /**
     * @notice Authorizes contract upgrades to new implementation addresses
     * @dev Implements UUPS upgrade authorization pattern with role-based access control
     * @dev Automatically increments version number on successful upgrades
     * @param newImplementation Address of the new contract implementation to upgrade to
     * @custom:security Requires UPGRADER_ROLE which is managed by the protocol registry
     */
    function _authorizeUpgrade(address newImplementation) internal override {
        if (!registry.hasRole(UPGRADER_ROLE, _msgSender()))
            revert STBL_UnauthorizedCaller();
        _version = _version + 1;
        emit ContractUpgraded(newImplementation);
    }

    /**
     * @notice Returns the current contract implementation version
     * @dev Useful for tracking which version of the contract is currently deployed
     * @return The version number, incremented with each upgrade
     */
    function version() external view returns (uint256) {
        return _version;
    }

    /**
     * @notice Deposits real-world assets and mints a yield-bearing NFT to the caller
     * @dev Wrapper function that calls iDeposit with the message sender as the recipient
     * @param assetValue Amount of assets to deposit, specified in the asset's native decimal precision
     * @return nftID The unique identifier of the minted NFT that represents ownership of the deposited assets
     */
    function deposit(uint256 assetValue) external returns (uint256) {
        return iDeposit(assetValue, _msgSender());
    }

    /**
     * @notice Deposits real-world assets and mints a yield-bearing NFT to a specified sender
     * @dev Wrapper function that calls iDeposit with a custom sender address
     * @param assetValue Amount of assets to deposit, specified in the asset's native decimal precision
     * @param _sender The address that will receive the ownership NFT
     * @return nftID The unique identifier of the minted NFT that represents ownership of the deposited assets
     */
    function deposit(
        uint256 assetValue,
        address _sender
    ) external returns (uint256) {
        return iDeposit(assetValue, _sender);
    }

    /**
     * @notice Withdraws deposited assets by burning the caller's yield-bearing NFT
     * @dev Wrapper function that calls iWithdraw with the message sender as the owner
     * @param _tokenID The unique identifier of the NFT to burn in exchange for withdrawing the underlying assets
     */
    function withdraw(uint256 _tokenID) external {
        iWithdraw(_tokenID, _msgSender());
    }

    /**
     * @notice Withdraws deposited assets by burning a specified sender's yield-bearing NFT
     * @dev Wrapper function that calls iWithdraw with a custom sender address
     * @param _tokenID The unique identifier of the NFT to burn in exchange for withdrawing the underlying assets
     * @param _sender The address of the account withdrawing assets
     */
    function withdraw(uint256 _tokenID, address _sender) external {}

    /**
     * @notice Deposits real-world assets and mints a yield-bearing NFT representing ownership
     * @dev Orchestrates the full deposit flow: validation, metadata generation, vault deposit, NFT minting, and staking setup
     * @dev The deposited assets are transferred to the asset vault and an NFT is minted to represent ownership and yield rights
     * @param assetValue Amount of assets to deposit, specified in the asset's native decimal precision
     * @param sender The address of the account depositing assets and receiving the ownership NFT
     * @return nftID The unique identifier of the minted NFT that represents ownership of the deposited assets
     * @custom:requirements
     * - Asset must be properly initialized and active in the registry
     * - Deposit amount must be greater than zero
     * - Caller must have sufficient asset token balance
     * - Caller must have approved this contract to transfer the specified amount
     * @custom:effects
     * - Transfers asset tokens from caller to the protocol vault
     * - Mints an NFT to the caller representing ownership and yield rights
     * - Enables staking for the NFT in the yield distribution system
     * - Records deposit metadata including fees, timestamps, and valuations
     * @custom:emits depositAsset Event containing caller address, NFT ID, and complete metadata
     */
    function iDeposit(
        uint256 assetValue,
        address sender
    ) internal isSetupDone returns (uint256) {
        if (assetValue == 0)
            revert STBL_Asset_InvalidDepositAmount(assetID, assetValue);
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);

        YLD_Metadata memory MetaData = generateMetaData(assetValue);

        iSTBL_PT1_AssetVault(AssetData.vault).depositERC20(sender, MetaData);

        uint256 nftID = iSTBL_Core(registry.fetchCore()).put(sender, MetaData);

        iSTBL_PT1_AssetYieldDistributor(AssetData.rewardDistributor)
            .enableStaking(
                nftID,
                MetaData.stableValueNet + MetaData.haircutAmount
            );

        emit depositAsset(sender, nftID, MetaData);

        return nftID;
    }

    /**
     * @notice Withdraws deposited assets by burning the corresponding yield-bearing NFT
     * @dev Handles the complete withdrawal process: validation, reward claiming, asset transfer, staking cleanup, and NFT burning
     * @dev Claims any accumulated yield rewards before transferring the original deposited assets back to the user
     * @param _tokenID The unique identifier of the NFT to burn in exchange for withdrawing the underlying assets
     * @param _sender The address of the account withdrawing assets and receiving the ownership NFT
     * @custom:requirements
     * - Asset must be properly initialized and active in the registry
     * - Caller must be the current owner of the specified NFT
     * - NFT must belong to this specific asset type
     * - NFT must not be marked as disabled in the system
     * - The minimum lock duration must have elapsed since the original deposit
     * @custom:effects
     * - Claims any pending yield rewards for the NFT holder
     * - Transfers the underlying assets from vault back to the caller
     * - Disables staking for the NFT in the yield distribution system
     * - Burns the NFT, removing it from circulation permanently
     * @custom:reverts STBL_Asset_InvalidAsset if NFT doesn't belong to this asset or caller is not the owner
     * @custom:reverts STBL_YLDDisabled if the NFT has been marked as disabled by the protocol
     * @custom:reverts STBL_Asset_WithdrawDurationNotReached if attempting withdrawal before the minimum lock period expires
     * @custom:emits withdrawAsset Event containing caller address, NFT ID, and metadata at time of withdrawal
     */
    function iWithdraw(uint256 _tokenID, address _sender) internal isSetupDone {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);

        YLD_Metadata memory MetaData = iSTBL_YLD(registry.fetchYLDToken())
            .getNFTData(_tokenID);

        /** Check for Valid Asset ID */
        if (MetaData.assetID != assetID)
            revert STBL_Asset_InvalidAsset(MetaData.assetID);

        /** Check for Owner of NFT */
        if (iSTBL_YLD(registry.fetchYLDToken()).ownerOf(_tokenID) != _sender)
            revert STBL_Asset_IncorrectOwner(_tokenID, _sender);

        /** Check if NFT is disabled */
        if (MetaData.isDisabled) revert STBL_YLDDisabled(_tokenID);

        /** Checks withdraw should happen post duration has passed */
        if (
            (MetaData.depositTimestamp + MetaData.Fees.yieldDuration) >
            block.timestamp
        ) revert STBL_Asset_WithdrawDurationNotReached(assetID, _tokenID);

        iSTBL_PT1_AssetYieldDistributor(AssetData.rewardDistributor).claim(
            _tokenID
        );

        iSTBL_PT1_AssetVault(AssetData.vault).withdrawERC20(_sender, MetaData);

        iSTBL_PT1_AssetYieldDistributor(AssetData.rewardDistributor)
            .disableStaking(
                _tokenID,
                MetaData.stableValueNet + MetaData.haircutAmount
            );

        iSTBL_Core(registry.fetchCore()).exit(
            assetID,
            _sender,
            _tokenID,
            MetaData.stableValueNet
        );

        emit withdrawAsset(_sender, _tokenID, MetaData);
    }

    /**
     * @notice Enables yield generation for a specific NFT
     * @dev Activates staking for an NFT in the yield distribution system to start earning rewards
     * @param _tokenID The unique identifier of the NFT to enable yield generation for
     * @custom:security Requires SPLITTER_ROLE for access control
     */
    function enableYield(uint256 _tokenID) external {
        if (!registry.hasRole(SPLITTER_ROLE, _msgSender()))
            revert STBL_UnauthorizedCaller();

        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);

        YLD_Metadata memory MetaData = iSTBL_YLD(registry.fetchYLDToken())
            .getNFTData(_tokenID);

        iSTBL_PT1_AssetYieldDistributor(AssetData.rewardDistributor)
            .enableStaking(
                _tokenID,
                MetaData.stableValueNet + MetaData.haircutAmount
            );
    }

    /**
     * @notice Disables yield generation for a specific NFT
     * @dev Deactivates staking for an NFT in the yield distribution system to stop earning rewards
     * @param _tokenID The unique identifier of the NFT to disable yield generation for
     * @custom:security Requires SPLITTER_ROLE for access control
     */
    function disableYield(uint256 _tokenID) external {
        if (!registry.hasRole(SPLITTER_ROLE, _msgSender()))
            revert STBL_UnauthorizedCaller();

        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);
        YLD_Metadata memory MetaData = iSTBL_YLD(registry.fetchYLDToken())
            .getNFTData(_tokenID);

        iSTBL_PT1_AssetYieldDistributor(AssetData.rewardDistributor)
            .disableStaking(
                _tokenID,
                MetaData.stableValueNet + MetaData.haircutAmount
            );
    }

    /**
     * @notice Generates comprehensive metadata for a new asset deposit including fee calculations and valuations
     * @dev Creates a complete YLD_Metadata structure capturing all deposit parameters, fee snapshots, and USD valuations at deposit time
     * @dev This metadata is permanently stored with the NFT and used throughout the asset's lifecycle for calculations and withdrawals
     * @param assetValue The amount of assets being deposited, specified in the asset's native decimal precision
     * @return MetaData A fully populated YLD_Metadata structure containing:
     *   - Asset identification and deposit timestamp
     *   - Normalized asset value in 18-decimal format
     *   - Snapshot of all fee parameters at deposit time
     *   - USD gross valuation from oracle pricing
     *   - Calculated fee amounts in both asset and USD terms
     *   - Net USD value after all fee deductions
     * @custom:calculations
     * - Normalizes asset value from native decimals to standardized 18-decimal format
     * - Queries asset oracle for current USD pricing information
     * - Calculates deposit fees, withdrawal fees, haircut amounts, and insurance fees
     * - Computes final net stable value that determines yield generation basis
     */
    function generateMetaData(
        uint256 assetValue
    ) internal view returns (YLD_Metadata memory MetaData) {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);

        MetaData.assetID = assetID;
        MetaData.assetValue = assetValue.normalizeToDecimals18(
            DecimalConverter.getTokenDecimals(AssetData.token)
        );
        MetaData.depositTimestamp = block.timestamp;
        MetaData.isDisabled = false;

        /** Snapshot of values */
        MetaData.Fees.depositFee = AssetData.depositFees;
        MetaData.Fees.withdrawFee = AssetData.withdrawFees;
        MetaData.Fees.hairCut = AssetData.cut;
        MetaData.Fees.insuranceFee = AssetData.insuranceFees;
        MetaData.Fees.duration = AssetData.duration;
        MetaData.Fees.yieldDuration = AssetData.yieldDuration;

        /** Determine USD Gross Value */
        MetaData.stableValueGross = iSTBL_PT1_AssetOracle(AssetData.oracle)
            .fetchForwardPrice(MetaData.assetValue);

        /** Fees Priced in Stable Value */
        MetaData = MetaData.calculateDepositFees();

        MetaData.haircutAmountAssetValue = iSTBL_PT1_AssetOracle(
            AssetData.oracle
        ).fetchInversePrice(MetaData.haircutAmount);

        /** Determine USD Net Value (USP Minted) */
        MetaData.stableValueNet = (MetaData.stableValueGross -
            (MetaData.depositfeeAmount +
                MetaData.haircutAmount +
                MetaData.insurancefeeAmount));

        return MetaData;
    }

    /**
     * @notice Retrieves the trusted forwarder address for ERC2771 meta-transaction support
     * @dev Delegates to the registry to get the current trusted forwarder configuration
     * @dev The trusted forwarder enables gasless transactions by allowing approved relayers to submit transactions on behalf of users
     * @return The address of the currently configured trusted forwarder contract
     */
    function trustedForwarder() public view virtual override returns (address) {
        return registry.trustedForwarder();
    }

    /**
     * @notice Retrieves the asset ID managed by this vault instance
     * @dev Returns the unique identifier for the asset type this vault handles
     * @return The asset ID associated with this vault
     */
    function fetchAssetID() external view returns (uint256) {
        return assetID;
    }

    /**
     * @notice Retrieves the protocol registry contract address
     * @dev Returns the registry contract that provides system configuration and access control
     * @return The address of the protocol registry contract
     */
    function fetchRegistry() external view returns (address) {
        return address(registry);
    }

    /**
     * @notice Resolves message sender in the context of potential meta-transactions
     * @dev Overrides both Context and ERC2771Context to handle inheritance conflicts
     * @dev Returns the actual transaction originator when using meta-transactions via trusted forwarder
     * @return The address of the actual message sender, accounting for meta-transaction forwarding
     */
    function _msgSender()
        internal
        view
        override(ERC2771ContextUpgradeable)
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    /**
     * @notice Resolves message data in the context of potential meta-transactions
     * @dev Overrides both Context and ERC2771Context to handle inheritance conflicts
     * @dev Returns the actual transaction calldata when using meta-transactions via trusted forwarder
     * @return The actual transaction calldata, accounting for meta-transaction forwarding
     */
    function _msgData()
        internal
        view
        override(ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    /**
     * @notice Returns the context suffix length for ERC2771 meta-transaction support
     * @dev Overrides both Context and ERC2771Context to handle inheritance conflicts
     * @dev Used internally by ERC2771Context to properly decode meta-transaction data
     * @return The length of the context suffix appended to meta-transaction calldata
     */
    function _contextSuffixLength()
        internal
        view
        override(ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }
}
