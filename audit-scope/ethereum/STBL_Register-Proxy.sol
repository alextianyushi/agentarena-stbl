// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "../lib/STBL_Structs.sol";
import "../lib/STBL_Errors.sol";
import "../interfaces/ISTBL_Register.sol";

/**
 * @title STBL Protocol Register Contract
 * @notice Central registry for managing asset registration and configuration in the STBL Protocol
 * @dev Implements UUPS upgradeable proxy pattern with role-based access control for asset management
 *      Supports ERC2771 meta-transactions for gasless user interactions
 *      Manages asset definitions, fees, limits, and deposit tracking
 * @author STBL Protocol Team
 * @custom:security-contact security@stblprotocol.com
 */
contract STBL_Register is
    Initializable,
    iSTBL_Register,
    AccessControlUpgradeable,
    ERC2771ContextUpgradeable,
    UUPSUpgradeable
{
    /** @notice Role identifier for asset registration and configuration permissions */
    bytes32 public constant REGISTER_ROLE = keccak256("REGISTER_ROLE");

    /** @notice Role identifier for contract upgrade functionality */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /** @dev Version number of the contract implementation for upgrade tracking */
    uint256 private _version;

    /** @dev Counter for tracking the total number of registered assets */
    uint256 private assetCtr;

    /** @dev Address of the USST (USD Stable Token) contract */
    address private USST;

    /** @dev Address of the YLD (Yield Token) contract */
    address private YLD;

    /** @dev Address of the Core protocol contract */
    address private Core;

    /** @dev Address of the protocol treasury contract */
    address private treasury;

    /** @dev Mapping of asset ID to complete asset definition data */
    mapping(uint256 => AssetDefinition) private assetData;

    /** @dev Mapping to track total deposit amounts per asset
     *       Maps asset ID to the cumulative amount deposited for that asset
     */
    mapping(uint256 => uint256) private assetDeposits;

    /** @dev Address of the trusted forwarder for ERC2771 meta-transactions
     *       Used to enable gasless transactions through relayer services
     */
    address private trustedForwarderAddress;

    /** @dev Reserved storage space for future contract upgrades
     *       Ensures storage layout compatibility when adding new state variables
     */
    uint256[64] private __gap;

    /**
     * @dev Initializes the implementation contract and disables further initialization
     * @notice This constructor prevents direct initialization of the implementation contract
     *         Required for proper UUPS proxy pattern implementation
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() ERC2771ContextUpgradeable(address(0)) {
        _disableInitializers();
    }

    /**
     * @notice Initializes the STBL Register contract with protocol token addresses
     * @dev Sets up initial access control roles and configures protocol addresses
     *      Can only be called once during proxy deployment
     *      Grants DEFAULT_ADMIN_ROLE and UPGRADER_ROLE to the deployer
     * @param _YLD Address of the YLD token contract
     * @param _USST Address of the USST token contract
     */
    function initialize(address _YLD, address _USST) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(UPGRADER_ROLE, _msgSender());
        _setRoleAdmin(REGISTER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(UPGRADER_ROLE, DEFAULT_ADMIN_ROLE);

        YLD = _YLD;
        USST = _USST;
        assetCtr = 0;
        trustedForwarderAddress = address(0);
    }

    /**
     * @notice Authorizes contract upgrades and increments version counter
     * @dev Internal function required by UUPS proxy pattern
     *      Only callable by addresses with UPGRADER_ROLE
     *      Automatically increments version number for tracking
     * @param newImplementation Address of the new implementation contract (required by interface)
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {
        _version = _version + 1;
        emit ContractUpgraded(newImplementation);
    }

    /**
     * @notice Returns the current contract implementation version
     * @dev Useful for tracking upgrade history and ensuring compatibility
     * @return Current version number of the contract implementation
     */
    function version() external view returns (uint256) {
        return _version;
    }

    /**
     * @notice Sets the Core contract address
     * @dev Updates the address of the main protocol Core contract
     *      Only callable by addresses with DEFAULT_ADMIN_ROLE
     * @param _Core The new Core contract address
     * @custom:error STBL_InvalidAddress Thrown if the provided address is zero
     * @custom:event CoreUpdateEvent Emitted when Core address is successfully updated
     */
    function setCore(address _Core) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_Core == address(0)) revert STBL_InvalidAddress();
        Core = _Core;

        emit CoreUpdateEvent(_Core);
    }

    /**
     * @notice Sets the treasury contract address
     * @dev Updates the address of the protocol treasury contract
     *      Only callable by addresses with DEFAULT_ADMIN_ROLE
     * @param _treasury The new treasury contract address
     * @custom:error STBL_InvalidAddress Thrown if the provided address is zero
     * @custom:event TreasuryUpdateEvent Emitted when treasury address is successfully updated
     */
    function setTreasury(
        address _treasury
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_treasury == address(0)) revert STBL_InvalidAddress();
        treasury = _treasury;

        emit TreasuryUpdateEvent(_treasury);
    }

    /**
     * @notice Adds a new asset to the protocol registry
     * @dev Creates a new asset entry with basic metadata and assigns a unique ID
     *      Asset is initialized in disabled state and requires setup before use
     *      Only callable by addresses with REGISTER_ROLE
     * @param _name Human-readable name of the asset
     * @param _desc Detailed description of the asset
     * @param _type Contract type identifier for the asset
     * @param _aggType Boolean indicating if the asset uses aggregation
     * @return The unique ID assigned to the newly created asset
     * @custom:event AddAssetEvent Emitted when a new asset is successfully added
     */
    function addAsset(
        string memory _name,
        string memory _desc,
        uint8 _type,
        bool _aggType
    ) external onlyRole(REGISTER_ROLE) returns (uint256) {
        unchecked {
            assetCtr += 1;
        }
        if (bytes(_name).length == 0) revert STBL_InvalidAssetName();
        if (bytes(_desc).length == 0) revert STBL_InvalidAssetName();

        assetData[assetCtr].id = assetCtr;
        assetData[assetCtr].name = _name;
        assetData[assetCtr].description = _desc;
        assetData[assetCtr].contractType = _type;
        assetData[assetCtr].isAggreagated = _aggType;
        assetData[assetCtr].status = AssetStatus.INITIALIZED;

        emit AddAssetEvent(assetCtr, assetData[assetCtr]);
        return assetCtr;
    }

    /**
     * @notice Completes asset setup with all required contract addresses and parameters
     * @dev Configures a previously added asset with operational parameters
     *      Validates all fee percentages are within acceptable ranges (≤100%)
     *      Enables the asset upon successful setup
     *      Only callable by addresses with REGISTER_ROLE
     * @param _id The unique identifier of the asset to configure
     * @param _contractAddr The primary token contract address for the asset
     * @param _issuanceAddr Address responsible for token issuance operations
     * @param _distAddr Address of the reward distribution contract
     * @param _vaultAddr Address of the asset's vault contract for fund management
     * @param _oracle Address of the price oracle providing asset valuation
     * @param _cut Protocol cut percentage in basis points (max 10000 = 100%)
     * @param _limit Maximum deposit limit for the asset in native units
     * @param _depositFee Fee charged on deposits in basis points (max 10000 = 100%)
     * @param _withdrawFee Fee charged on withdrawals in basis points (max 10000 = 100%)
     * @param _yieldFee Fee applied to yield generation in basis points (max 10000 = 100%)
     * @param _insuranceFee Insurance fee in basis points (max 10000 = 100%)
     * @param _duration Main duration parameter for protocol operations in seconds
     * @param _yieldDuration Duration specifically for yield calculations in seconds
     * @param _additionalBytes Additional configuration data for asset-specific parameters
     * @custom:error STBL_SetupAlreadyDone Thrown if the asset has already been configured
     * @custom:error STBL_InvalidAssetSetup Thrown if the asset ID is invalid or zero
     * @custom:error STBL_InvalidFeePercentage Thrown if any fee exceeds 100% (10000 basis points)
     * @custom:error STBL_InvalidCutPercentage Thrown if cut percentage exceeds 100% (10000 basis points)
     * @custom:event SetupAssetEvent Emitted when the asset is successfully configured
     */
    function setupAsset(
        uint256 _id,
        address _contractAddr,
        address _issuanceAddr,
        address _distAddr,
        address _vaultAddr,
        address _oracle,
        uint256 _cut,
        uint256 _limit,
        uint256 _depositFee,
        uint256 _withdrawFee,
        uint256 _yieldFee,
        uint256 _insuranceFee,
        uint256 _duration,
        uint256 _yieldDuration,
        bytes memory _additionalBytes
    ) external onlyRole(REGISTER_ROLE) {
        if (assetData[_id].status != AssetStatus.INITIALIZED)
            revert STBL_SetupAlreadyDone();
        if (_id > assetCtr || _id == 0) revert STBL_InvalidAssetSetup();

        // Fees Values checks
        if (_depositFee > FEES_CONSTANT)
            revert STBL_InvalidFeePercentage(_depositFee);
        if (_withdrawFee > FEES_CONSTANT)
            revert STBL_InvalidFeePercentage(_withdrawFee);
        if (_yieldFee > FEES_CONSTANT)
            revert STBL_InvalidFeePercentage(_yieldFee);
        if (_insuranceFee > FEES_CONSTANT)
            revert STBL_InvalidFeePercentage(_insuranceFee);
        if (_cut > FEES_CONSTANT) revert STBL_InvalidCutPercentage(_cut);
        if ((_depositFee + _insuranceFee + _withdrawFee + _cut) > FEES_CONSTANT)
            revert STBL_InvalidFeePercentage(
                (_depositFee + _insuranceFee + _withdrawFee + _cut)
            );

        // Address 0 Checks
        if (_contractAddr == address(0)) revert STBL_InvalidAddress();
        if (_issuanceAddr == address(0)) revert STBL_InvalidAddress();
        if (_distAddr == address(0)) revert STBL_InvalidAddress();
        if (_vaultAddr == address(0)) revert STBL_InvalidAddress();
        if (_oracle == address(0)) revert STBL_InvalidAddress();

        // Duration checks
        if (_yieldDuration > _duration) revert STBL_InvalidDuration();

        assetData[_id].token = _contractAddr;
        assetData[_id].issuer = _issuanceAddr;
        assetData[_id].rewardDistributor = _distAddr;
        assetData[_id].oracle = _oracle;
        assetData[_id].vault = _vaultAddr;
        assetData[_id].status = AssetStatus.ENABLED;
        assetData[_id].cut = _cut;
        assetData[_id].limit = _limit;
        assetData[_id].depositFees = _depositFee;
        assetData[_id].withdrawFees = _withdrawFee;
        assetData[_id].yieldFees = _yieldFee;
        assetData[_id].insuranceFees = _insuranceFee;
        assetData[_id].duration = _duration;
        assetData[_id].yieldDuration = _yieldDuration;
        assetData[_id].additionalBuffer = _additionalBytes;
        emit SetupAssetEvent(_id, assetData[_id]);
    }

    /**
     * @notice Updates the protocol cut percentage for an asset
     * @dev Modifies the percentage cut taken by the protocol on asset transactions
     *      Only callable by addresses with REGISTER_ROLE
     * @param _id The ID of the asset to update
     * @param _cut The new cut percentage in basis points (max FEES_CONSTANT = 100%)
     * @custom:error STBL_InvalidCutPercentage Thrown if cut exceeds 100% (FEES_CONSTANT basis points)
     * @custom:event CutUpdateEvent Emitted when cut percentage is successfully updated
     */
    function setCut(
        uint256 _id,
        uint256 _cut
    ) external onlyRole(REGISTER_ROLE) {
        if (assetData[_id].status != AssetStatus.ENABLED)
            revert STBL_AssetNotActive();
        if (_cut > FEES_CONSTANT) revert STBL_InvalidCutPercentage(_cut);

        if (
            (assetData[_id].depositFees +
                assetData[_id].withdrawFees +
                assetData[_id].insuranceFees +
                _cut) > FEES_CONSTANT
        )
            revert STBL_InvalidFeePercentage(
                (assetData[_id].depositFees +
                    assetData[_id].withdrawFees +
                    assetData[_id].insuranceFees +
                    _cut)
            );

        assetData[_id].cut = _cut;
        emit CutUpdateEvent(_id, _cut);
    }

    /**
     * @notice Updates the deposit limit for an asset
     * @dev Modifies the maximum amount that can be deposited for the asset
     *      Only callable by addresses with REGISTER_ROLE
     * @param _id The ID of the asset to update
     * @param _limit The new deposit limit in the asset's native units
     * @custom:event LimitUpdateEvent Emitted when the limit is successfully updated
     */
    function setLimit(
        uint256 _id,
        uint256 _limit
    ) external onlyRole(REGISTER_ROLE) {
        if (assetData[_id].status != AssetStatus.ENABLED)
            revert STBL_AssetNotActive();
        assetData[_id].limit = _limit;
        emit LimitUpdateEvent(_id, _limit);
    }

    /**
     * @notice Updates all fee parameters for an asset
     * @dev Modifies deposit, withdrawal, yield, and insurance fees for the asset
     *      All fees are validated to ensure they don't exceed 100%
     *      Only callable by addresses with REGISTER_ROLE
     * @param _id The ID of the asset to update
     * @param _depositFee Fee charged on deposits in basis points (max 10000 = 100%)
     * @param _withdrawFee Fee charged on withdrawals in basis points (max 10000 = 100%)
     * @param _yieldFee Fee applied to yield generation in basis points (max 10000 = 100%)
     * @param _insuranceFee Insurance fee in basis points (max 10000 = 100%)
     * @custom:error STBL_InvalidFeePercentage Thrown if any fee exceeds 100% (10000 basis points)
     * @custom:event FeeUpdateEvent Emitted when fees are successfully updated
     */
    function setFees(
        uint256 _id,
        uint256 _depositFee,
        uint256 _withdrawFee,
        uint256 _yieldFee,
        uint256 _insuranceFee
    ) external onlyRole(REGISTER_ROLE) {
        /** Pre checks */
        if (assetData[_id].status != AssetStatus.ENABLED)
            revert STBL_AssetNotActive();
        if (_depositFee > FEES_CONSTANT)
            revert STBL_InvalidFeePercentage(_depositFee);
        if (_withdrawFee > FEES_CONSTANT)
            revert STBL_InvalidFeePercentage(_withdrawFee);
        if (_yieldFee > FEES_CONSTANT)
            revert STBL_InvalidFeePercentage(_yieldFee);
        if (_insuranceFee > FEES_CONSTANT)
            revert STBL_InvalidFeePercentage(_insuranceFee);
        if (
            (_depositFee + _insuranceFee + _withdrawFee + assetData[_id].cut) >
            FEES_CONSTANT
        )
            revert STBL_InvalidFeePercentage(
                (_depositFee +
                    _insuranceFee +
                    _withdrawFee +
                    assetData[_id].cut)
            );

        /** Sets value */
        assetData[_id].depositFees = _depositFee;
        assetData[_id].withdrawFees = _withdrawFee;
        assetData[_id].insuranceFees = _insuranceFee;
        assetData[_id].yieldFees = _yieldFee;
        emit FeeUpdateEvent(
            _id,
            _depositFee,
            _withdrawFee,
            _insuranceFee,
            _yieldFee
        );
    }

    /**
     * @notice Updates duration parameters for an asset
     * @dev Modifies timing parameters that control protocol operations and yield calculations
     *      Only callable by addresses with REGISTER_ROLE
     * @param _id The ID of the asset to update durations for
     * @param _duration Main duration parameter for protocol operations in seconds
     * @param _yieldDuration Duration parameter specifically for yield calculations in seconds
     * @custom:event durationUpdateEvent Emitted when durations are successfully updated
     */
    function setDurations(
        uint256 _id,
        uint256 _duration,
        uint256 _yieldDuration
    ) external onlyRole(REGISTER_ROLE) {
        if (assetData[_id].status != AssetStatus.ENABLED)
            revert STBL_AssetNotActive();

        if (_yieldDuration > _duration) revert STBL_InvalidDuration();

        assetData[_id].duration = _duration;
        assetData[_id].yieldDuration = _yieldDuration;

        emit durationUpdateEvent(_id, _duration, _yieldDuration);
    }

    /**
     * @notice Updates additional buffer data for an asset
     * @dev Allows storing custom configuration data specific to the asset
     *      Only callable by addresses with REGISTER_ROLE
     * @param _id The ID of the asset to update
     * @param _data Additional configuration data stored as arbitrary bytes
     * @custom:event AdditionalBufferUpdateEvent Emitted when buffer data is successfully updated
     */
    function setAdditionalBuffer(
        uint256 _id,
        bytes memory _data
    ) external onlyRole(REGISTER_ROLE) {
        if (assetData[_id].status != AssetStatus.ENABLED)
            revert STBL_AssetNotActive();
        assetData[_id].additionalBuffer = _data;
        emit AdditionalBufferUpdateEvent(_id, _data);
    }

    /**
     * @notice Updates the oracle address for an asset
     * @dev Modifies the price oracle contract address used for asset valuation
     *      Only callable by addresses with REGISTER_ROLE
     * @param _id The ID of the asset to update
     * @param _oracle The new oracle contract address (cannot be zero address)
     * @custom:error STBL_InvalidAddress Thrown if the provided address is zero
     * @custom:event OracleUpdateEvent Emitted when oracle address is successfully updated
     */
    function setOracle(
        uint256 _id,
        address _oracle
    ) external onlyRole(REGISTER_ROLE) {
        if (assetData[_id].status != AssetStatus.ENABLED)
            revert STBL_AssetNotActive();
        if (_oracle == address(0)) revert STBL_InvalidAddress();
        assetData[_id].oracle = _oracle;
        emit OracleUpdateEvent(_id, _oracle);
    }

    /**
     * @notice Disables an asset to prevent new interactions
     * @dev Sets the asset to disabled state, preventing deposits and withdrawals
     *      Only callable by addresses with REGISTER_ROLE
     * @param _id The ID of the asset to disable
     * @custom:error STBL_AssetDisabled Thrown if the asset is already disabled
     * @custom:event AssetStateUpdateEvent Emitted when asset state is successfully updated
     */
    function disableAsset(uint256 _id) external onlyRole(REGISTER_ROLE) {
        if (assetData[_id].status != AssetStatus.ENABLED)
            revert STBL_AssetNotActive();
        assetData[_id].status = AssetStatus.DISABLED;
        emit AssetStateUpdateEvent(_id, assetData[_id].status);
    }

    /**
     * @notice Enables an asset to allow interactions
     * @dev Sets the asset to enabled state, allowing deposits and withdrawals
     *      Only callable by addresses with REGISTER_ROLE
     * @param _id The ID of the asset to enable
     * @custom:error STBL_AssetEnabled Thrown if the asset is already enabled
     * @custom:event AssetStateUpdateEvent Emitted when asset state is successfully updated
     */
    function enableAsset(uint256 _id) external onlyRole(REGISTER_ROLE) {
        if (assetData[_id].status != AssetStatus.DISABLED)
            revert STBL_AssetNotActive();
        assetData[_id].status = AssetStatus.ENABLED;
        emit AssetStateUpdateEvent(_id, assetData[_id].status);
    }

    /**
     * @notice Initiates an emergency stop for an asset, preventing all operations
     * @dev Sets the asset to emergency stop state, which halts all interactions including deposits and withdrawals
     *      Can only be applied to assets that are currently enabled or disabled
     *      Only callable by addresses with REGISTER_ROLE
     * @param _id The ID of the asset to emergency stop
     * @custom:error STBL_AssetNotActive Thrown if the asset is not in enabled or disabled state
     * @custom:event AssetStateUpdateEvent Emitted when asset state is successfully updated to emergency stop
     */
    function emergenyStopAsset(uint256 _id) external onlyRole(REGISTER_ROLE) {
        if (
            assetData[_id].status != AssetStatus.ENABLED &&
            assetData[_id].status != AssetStatus.DISABLED
        ) revert STBL_AssetNotActive();
        assetData[_id].status = AssetStatus.EMERGENCY_STOP;
        emit AssetStateUpdateEvent(_id, assetData[_id].status);
    }

    /**
     * @notice Increments the total deposit tracking for a specific asset
     * @dev Updates the cumulative deposit amount for an asset
     *      Only callable by the Core contract to maintain deposit tracking integrity
     * @param _id The ID of the asset to increment deposits for
     * @param _amount The amount to add to the total deposits
     * @custom:error STBL_UnauthorizedCaller Thrown if caller is not the Core contract
     * @custom:event AssetDepositIncrementEvent Emitted when deposits are successfully incremented
     */
    function incrementAssetDeposits(uint256 _id, uint256 _amount) external {
        if (msg.sender != Core) revert STBL_UnauthorizedCaller();
        assetDeposits[_id] += _amount;
        emit AssetDepositIncrementEvent(_id, _amount);
    }

    /**
     * @notice Decrements the total deposit tracking for a specific asset
     * @dev Updates the cumulative deposit amount for an asset by reducing it
     *      Only callable by the Core contract to maintain deposit tracking integrity
     * @param _id The ID of the asset to decrement deposits for
     * @param _amount The amount to subtract from the total deposits
     * @custom:error STBL_UnauthorizedCaller Thrown if caller is not the Core contract
     * @custom:event AssetDepositDecrementEvent Emitted when deposits are successfully decremented
     */
    function decrementAssetDeposits(uint256 _id, uint256 _amount) external {
        if (msg.sender != Core) revert STBL_UnauthorizedCaller();
        assetDeposits[_id] -= _amount;
        emit AssetDepositDecrementEvent(_id, _amount);
    }

    /**
     * @notice Updates the trusted forwarder address for meta-transactions
     * @dev Modifies the ERC2771 trusted forwarder address for gasless transactions
     *      Only callable by addresses with DEFAULT_ADMIN_ROLE
     * @param _newForwarder The new trusted forwarder address to be used
     * @custom:event TrustedForwarderUpdated Emitted with previous and new forwarder addresses
     */
    function updateTrustedForwarder(
        address _newForwarder
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address previousForwarder = trustedForwarderAddress;
        trustedForwarderAddress = _newForwarder;
        emit TrustedForwarderUpdated(previousForwarder, _newForwarder);
    }

    /**
     * @notice Retrieves complete asset configuration data
     * @dev Returns the full AssetDefinition struct for the specified asset
     * @param _id The ID of the asset to fetch
     * @return Complete asset definition containing all configuration parameters
     */
    function fetchAssetData(
        uint256 _id
    ) external view returns (AssetDefinition memory) {
        return assetData[_id];
    }

    /**
     * @notice Retrieves a specific property of an asset using flag-based selection
     * @dev Provides gas-optimized access to individual asset properties
     *      Uses flag system to specify which property to return
     * @param _id The ID of the asset to fetch data from
     * @param _flag The property selector flag:
     *             0 = name (string)
     *             1 = description (string)
     *             2 = contractType (uint8)
     *             3 = isAggregated (bool)
     *             4 = status (uint8)
     *             5 = isSetup (bool)
     *             6 = cut (uint256)
     *             7 = limit (uint256)
     *             8 = token address (address)
     *             9 = issuer address (address)
     *             10 = rewardDistributor address (address)
     *             11 = oracle address (address)
     *             12 = vault address (address)
     *             13 = depositFee (uint256)
     *             14 = withdrawFee (uint256)
     *             15 = yieldFee (uint256)
     *             16 = insuranceFee (uint256)
     *             17 = additionalBuffer (bytes)
     * @return Raw bytes containing the requested property (use abi.decode to convert to specific type)
     * @custom:error STBL_InvalidFlagValue Thrown if the flag value is not recognized (> 17)
     */
    function fetchAssetElement(
        uint256 _id,
        uint8 _flag
    ) external view returns (bytes memory) {
        if (_flag > 16) revert STBL_InvalidFlagValue(_flag);

        if (_flag == 0) return bytes(assetData[_id].name);
        if (_flag == 1) return bytes(assetData[_id].description);
        if (_flag == 2) return abi.encode(assetData[_id].contractType);
        if (_flag == 3) return abi.encode(assetData[_id].isAggreagated);
        if (_flag == 4) return abi.encode(assetData[_id].status);
        if (_flag == 5) return abi.encode(assetData[_id].cut);
        if (_flag == 6) return abi.encode(assetData[_id].limit);
        if (_flag == 7) return abi.encode(assetData[_id].token);
        if (_flag == 8) return abi.encode(assetData[_id].issuer);
        if (_flag == 9) return abi.encode(assetData[_id].rewardDistributor);
        if (_flag == 10) return abi.encode(assetData[_id].oracle);
        if (_flag == 11) return abi.encode(assetData[_id].vault);
        if (_flag == 12) return abi.encode(assetData[_id].depositFees);
        if (_flag == 13) return abi.encode(assetData[_id].withdrawFees);
        if (_flag == 14) return abi.encode(assetData[_id].yieldFees);
        if (_flag == 15) return abi.encode(assetData[_id].insuranceFees);
        if (_flag == 16) return abi.encode(assetData[_id].additionalBuffer);
        revert STBL_InvalidFlagValue(_flag);
    }

    /**
     * @notice Gets the USST token contract address
     * @dev Returns the address of the USD Stable Token contract
     * @return The USST token contract address
     */
    function fetchUSSTToken() external view returns (address) {
        return USST;
    }

    /**
     * @notice Gets the YLD token contract address
     * @dev Returns the address of the Yield token contract
     * @return The YLD token contract address
     */
    function fetchYLDToken() external view returns (address) {
        return YLD;
    }

    /**
     * @notice Gets the Core protocol contract address
     * @dev Returns the address of the main protocol Core contract
     * @return The Core contract address
     */
    function fetchCore() external view returns (address) {
        return Core;
    }

    /**
     * @notice Gets the treasury contract address
     * @dev Returns the address of the protocol treasury contract
     * @return The treasury contract address
     */
    function fetchTreasury() external view returns (address) {
        return treasury;
    }

    /**
     * @notice Gets the current asset counter value
     * @dev Returns the total number of assets that have been registered
     * @return The current asset counter representing total registered assets
     */
    function fetchCounter() external view returns (uint256) {
        return assetCtr;
    }

    /**
     * @notice Gets the total deposits for a specific asset
     * @dev Returns the cumulative amount deposited for the specified asset
     * @param _assetID The ID of the asset to query deposits for
     * @return The total deposit amount for the specified asset
     */
    function fetchDeposits(uint256 _assetID) external view returns (uint256) {
        return assetDeposits[_assetID];
    }

    /**
     * @notice Checks if a proposed deposit would exceed the asset's limit
     * @dev Validates whether adding a deposit amount would breach the asset's deposit limit
     * @param _assetID The ID of the asset to check the deposit limit for
     * @param _amount The proposed deposit amount to validate
     * @return Boolean indicating if the deposit limit would be exceeded (true = limit exceeded)
     */
    function isDepositLimitReached(
        uint256 _assetID,
        uint256 _amount
    ) external view returns (bool) {
        return (assetDeposits[_assetID] + _amount > assetData[_assetID].limit);
    }

    /**
     * @notice Gets the current trusted forwarder address for meta-transactions
     * @dev Returns the ERC2771 trusted forwarder address used for gasless transactions
     *      Overrides the ERC2771ContextUpgradeable implementation
     * @return The address of the current trusted forwarder
     */
    function trustedForwarder()
        public
        view
        virtual
        override(iSTBL_Register, ERC2771ContextUpgradeable)
        returns (address)
    {
        return trustedForwarderAddress;
    }

    /**
     * @dev Resolves inheritance conflict between Context and ERC2771Context
     * @notice Returns the actual sender of the transaction, accounting for meta-transactions
     * @return The actual sender address, considering ERC2771 forwarding
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
     * @dev Resolves inheritance conflict between Context and ERC2771Context
     * @notice Returns the actual calldata of the transaction, accounting for meta-transactions
     * @return The actual transaction calldata, considering ERC2771 forwarding
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
     * @dev Resolves inheritance conflict for ERC2771Context
     * @notice Returns the length of the context suffix for meta-transaction support
     * @return The context suffix length for ERC2771 meta-transaction handling
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
