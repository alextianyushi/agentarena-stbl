// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@stbl-protocol/stbl-contracts-evm-core/contracts/interfaces/ISTBL_Register.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/interfaces/ISTBL_Core.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/interfaces/ISTBL_YLD.sol";

import "./interfaces/ISTBL_LT1_AssetIssuer.sol";
import "./interfaces/ISTBL_LT1_AssetVault.sol";
import "./interfaces/ISTBL_LT1_AssetYieldDistributor.sol";
import "./interfaces/ISTBL_LT1_AssetOracle.sol";

import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_Structs.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_AssetDefinitionLib.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_MetadataLib.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_Errors.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_Errors.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_DecimalConverter.sol";

import "./lib/STBL_OracleLib.sol";
import "./lib/STBL_LT1_Asset_Errors.sol";

/**
 * @title USDY_Issuer
 * @notice Asset issuer contract for USDY tokens that handles deposits and withdrawals
 * @dev Implements the iSTBL_AssetIssuer interface and supports meta-transactions via ERC2771Context
 * @author STBL Protocol
 */
contract STBL_LT1_Issuer is
    Initializable,
    iSTBL_LT1_AssetIssuer,
    ERC2771ContextUpgradeable,
    UUPSUpgradeable
{
    using STBL_AssetDefinitionLib for AssetDefinition;
    using STBL_OracleLib for iSTBL_LT1_AssetOracle;
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
     * @notice Modifier to check if asset setup is complete
     * @dev Verifies the asset is properly set up and not disabled
     * @custom:reverts STBL_Asset_NotInitialized If the asset is not properly initialized or is inactive
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
     * @notice Deposits assets and mints corresponding NFT
     * @dev Validates deposit amount, generates metadata, deposits assets to vault, mints NFT, and enables staking
     * @param assetValue Amount of assets to deposit (in asset's native decimals)
     * @param _sender The address of the account depositing assets and receiving the ownership NFT
     * @return nftID The ID of the minted NFT representing ownership of the deposited assets
     * @custom:requirements
     * - Asset must be properly initialized and active
     * - Deposit amount must be greater than zero
     * - Caller must have sufficient asset balance and approval
     * @custom:effects
     * - Transfers assets from caller to vault
     * - Mints NFT to caller
     * - Enables staking for yield distribution
     * @custom:emits depositAsset Emitted when assets are successfully deposited with sender address, NFT ID, and metadata
     */
    function iDeposit(
        uint256 assetValue,
        address _sender
    ) internal isSetupDone returns (uint256) {
        if (assetValue == 0)
            revert STBL_Asset_InvalidDepositAmount(assetID, assetValue);
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);

        YLD_Metadata memory MetaData = generateMetaData(assetValue);

        iSTBL_LT1_AssetVault(AssetData.vault).depositERC20(_sender, MetaData);

        uint256 nftID = iSTBL_Core(registry.fetchCore()).put(_sender, MetaData);

        iSTBL_LT1_AssetYieldDistributor(AssetData.rewardDistributor)
            .enableStaking(
                nftID,
                MetaData.stableValueNet + MetaData.haircutAmount
            );

        emit depositAsset(_sender, nftID, MetaData);

        return nftID;
    }

    /**
     * @notice Withdraws assets by burning the corresponding NFT
     * @dev Claims any pending rewards, withdraws assets from vault, disables staking, and burns NFT
     * @param _tokenID ID of the NFT to burn and withdraw assets for
     * @param _sender The address of the account withdrawing assets and receiving the ownership NFT
     * @custom:requirements
     * - Asset must be properly initialized and active
     * - Caller must be the owner of the NFT
     * - NFT must belong to this asset type
     * - NFT must not be disabled
     * - Minimum lock duration must have passed since deposit
     * @custom:effects
     * - Claims any pending yield rewards
     * - Transfers assets from vault to caller
     * - Disables staking for the NFT
     * - Burns the NFT
     * @custom:reverts STBL_Asset_InvalidAsset If NFT doesn't belong to this asset or caller is not owner
     * @custom:reverts STBL_YLDDisabled If the NFT is disabled
     * @custom:reverts STBL_Asset_WithdrawDurationNotReached If attempting to withdraw before lock duration expires
     * @custom:emits withdrawAsset Emitted when assets are successfully withdrawn with sender address, NFT ID, and metadata
     */
    function iWithdraw(uint256 _tokenID, address _sender) internal isSetupDone {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);

        YLD_Metadata memory MetaData = iSTBL_YLD(registry.fetchYLDToken())
            .getNFTData(_tokenID);

        // Check for Valid Asset ID
        if (MetaData.assetID != assetID)
            revert STBL_Asset_InvalidAsset(MetaData.assetID);

        // Check for Owner of NFT
        if (iSTBL_YLD(registry.fetchYLDToken()).ownerOf(_tokenID) != _sender)
            revert STBL_Asset_InvalidAsset(MetaData.assetID);

        // Check if NFT is disabled
        if (MetaData.isDisabled) revert STBL_YLDDisabled(_tokenID);

        //should revert when withdraw duration has expired
        if (
            (MetaData.depositTimestamp + MetaData.Fees.duration) <
            block.timestamp
        ) revert STBL_Asset_WithdrawDurationNotReached(assetID, _tokenID);

        //ensures that users must wait for yield duration to withdraw assets
        if (
            (MetaData.depositTimestamp + MetaData.Fees.yieldDuration) >
            block.timestamp
        ) revert STBL_Asset_YieldDurationNotReached(assetID, _tokenID);

        iSTBL_LT1_AssetYieldDistributor(AssetData.rewardDistributor).claim(
            _tokenID
        );

        iSTBL_LT1_AssetVault(AssetData.vault).withdrawERC20(_sender, MetaData);

        iSTBL_LT1_AssetYieldDistributor(AssetData.rewardDistributor)
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

    /** @notice Allows treasury to withdraw expired assets by burning the corresponding NFT
     * @dev Only callable by treasury after the lock duration has passed. Claims rewards if the NFT is disabled.
     * @param _tokenID ID of the NFT to burn and withdraw assets for
     * @custom:error Pi_Asset_InvalidAsset Thrown when the NFT's asset ID doesn't match this contract's asset ID
     * @custom:error Pi_InvalidTreasury Thrown when the caller is not the treasury
     * @custom:error Pi_Asset_WithdrawDurationNotReached Thrown when attempting to withdraw before the lock duration has passed
     * @custom:event withdrawAssetTreasury Emitted when assets are successfully withdrawn to treasury with treasury address, NFT ID, and metadata
     */
    function withdrawExpired(uint256 _tokenID) external isSetupDone {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);

        YLD_Metadata memory MetaData = iSTBL_YLD(registry.fetchYLDToken())
            .getNFTData(_tokenID);

        // Check if NFT is disabled
        if (MetaData.assetID != assetID)
            revert STBL_Asset_InvalidAsset(MetaData.assetID);

        // Check only treasury can call this function
        if (registry.fetchTreasury() != msg.sender)
            revert STBL_InvalidTreasury();

        //ensures that protocol can't withdraw after duration has passed
        if (
            (MetaData.depositTimestamp + MetaData.Fees.duration) >=
            block.timestamp
        ) revert STBL_Asset_WithdrawDurationNotReached(assetID, _tokenID);

        // If NFT is disabled then claim for yield is not done
        if (!MetaData.isDisabled) {
            iSTBL_LT1_AssetYieldDistributor(AssetData.rewardDistributor).claim(
                _tokenID
            );
        }

        // Vault withdraw
        iSTBL_LT1_AssetVault(AssetData.vault).withdrawERC20(
            registry.fetchTreasury(),
            MetaData
        );

        // Yield distribution disabled
        iSTBL_LT1_AssetYieldDistributor(AssetData.rewardDistributor)
            .disableStaking(
                _tokenID,
                MetaData.stableValueNet + MetaData.haircutAmount
            );

        emit withdrawAssetTreasury(
            registry.fetchTreasury(),
            _tokenID,
            MetaData
        );
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

        iSTBL_LT1_AssetYieldDistributor(AssetData.rewardDistributor)
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

        iSTBL_LT1_AssetYieldDistributor(AssetData.rewardDistributor)
            .disableStaking(
                _tokenID,
                MetaData.stableValueNet + MetaData.haircutAmount
            );
    }

    /**
     * @notice Generates metadata for a new asset deposit
     * @dev Creates a YLD_Metadata structure with deposit information, fee calculations, and USD valuations
     * @param assetValue The amount of assets being deposited (in asset's native decimals)
     * @return MetaData A fully populated YLD_Metadata structure containing:
     *   - Asset identification and deposit details
     *   - Fee structure snapshot at time of deposit
     *   - USD gross and net values after fee deductions
     *   - Haircut amount calculations
     * @custom:calculations
     * - Normalizes asset value to 18 decimals
     * - Fetches current oracle price for USD valuation
     * - Calculates all applicable fees (deposit, withdrawal, haircut, insurance)
     * - Computes net stable value after fee deductions
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

        // Snapshot of values
        MetaData.Fees.depositFee = AssetData.depositFees;
        MetaData.Fees.withdrawFee = AssetData.withdrawFees;
        MetaData.Fees.hairCut = AssetData.cut;
        MetaData.Fees.insuranceFee = AssetData.insuranceFees;
        MetaData.Fees.duration = AssetData.duration;
        MetaData.Fees.yieldDuration = AssetData.yieldDuration;

        // Determine USD Gross Value
        MetaData.stableValueGross = iSTBL_LT1_AssetOracle(AssetData.oracle)
            .fetchForwardPrice(MetaData.assetValue);

        //Fees Priced in Stable Value
        MetaData = MetaData.calculateDepositFees();

        MetaData.haircutAmountAssetValue = iSTBL_LT1_AssetOracle(
            AssetData.oracle
        ).fetchInversePrice(MetaData.haircutAmount);

        // Determine USD Net Value (USP Minted)
        MetaData.stableValueNet = (MetaData.stableValueGross -
            (MetaData.depositfeeAmount +
                MetaData.haircutAmount +
                MetaData.insurancefeeAmount));

        return MetaData;
    }

    /**
     * @notice Returns the address of the trusted forwarder for meta-transactions
     * @dev Used by ERC2771Context to validate meta-transaction relayers
     * @return forwarder The address of the current trusted forwarder from the registry
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
