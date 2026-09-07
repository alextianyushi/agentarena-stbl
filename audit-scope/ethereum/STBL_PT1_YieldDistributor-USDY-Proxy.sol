// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../../interfaces/ISTBL_Register.sol";
import "../../interfaces/ISTBL_Core.sol";
import "../../interfaces/ISTBL_YLD.sol";

import "../../lib/STBL_AssetDefinitionLib.sol";
import "../../lib/STBL_Structs.sol";
import "../../lib/STBL_Errors.sol";

import "./interfaces/ISTBL_PT1_AssetVault.sol";
import "./interfaces/ISTBL_PT1_AssetIssuer.sol";
import "./interfaces/ISTBL_PT1_AssetYieldDistributor.sol";

import "./lib/STBL_PT1_Asset_Errors.sol";

/**
 * @title USDY Yield Distributor
 * @author STBL Protocol Team
 * @notice Manages reward distribution for USDY assets in the STBL Protocol
 * @dev This contract handles the distribution of yield rewards to USDY token holders.
 *      It implements a reward index system for efficient reward calculation and distribution.
 *      The contract integrates with the STBL registry system and supports meta-transactions.
 */
contract STBL_PT1_YieldDistributor is
    Initializable,
    iSTBL_PT1_AssetYieldDistributor,
    ERC2771ContextUpgradeable,
    UUPSUpgradeable
{
    using STBL_AssetDefinitionLib for AssetDefinition;
    using SafeERC20 for IERC20;

    /** @notice Role identifier for contract upgrade authorization */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /** @notice Current implementation version number for tracking upgrades */
    uint256 private _version;

    /** @notice Registry contract interface reference */
    iSTBL_Register public registry;

    /** @notice Unique identifier for the USDY asset */
    uint256 public assetID;

    /** @notice Timestamp of the previous reward distribution */
    uint256 public previousDistribution;

    /** @notice Mapping of token IDs to their staking information */
    mapping(uint256 => stakingStruct) public stakingData;

    /** @notice Total supply of staked tokens */
    uint256 public totalSupply;

    /** @notice Multiplier used for precision in reward calculations (18 decimals) */
    uint256 private constant MULTIPLIER = 1e18;

    /** @notice Global reward index for reward calculation */
    uint256 private rewardIndex;

    /**
     * @dev Storage gap reserved for future state variables in upgradeable contracts
     * @notice This gap ensures storage layout compatibility when adding new state variables in future versions
     */
    uint256[64] private __gap;

    /**
     * @notice Ensures caller is the authorized issuer contract
     * @dev Reverts if the caller is not the issuer for this asset
     */
    modifier isIssuer() {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);
        if (!AssetData.isIssuer(msg.sender))
            revert STBL_Asset_InvalidIssuer(assetID);
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
        previousDistribution = block.timestamp;
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
     * @notice Distributes yield rewards to all stakers
     * @param reward Amount of reward tokens to distribute
     * @dev Updates the global reward index and transfers tokens from vault to this contract.
     *      Only callable by the authorized vault contract after yield duration has passed.
     * @custom:error STBL_AssetAlreadyDisabled Thrown if the asset is disabled
     * @custom:error STBL_Asset_YieldDurationNotReached Thrown if the yield duration hasn't been reached
     * @custom:error STBL_Asset_InvalidVault Thrown if the caller is not the authorized vault
     * @custom:event RewardDistributed Emitted when rewards are successfully distributed
     */
    function distributeReward(uint256 reward) external {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);
        if (!AssetData.isActive()) revert STBL_AssetDisabled(assetID);
        if (previousDistribution + AssetData.yieldDuration >= block.timestamp)
            revert STBL_Asset_YieldDurationNotReached(
                assetID,
                previousDistribution
            );
        if (!AssetData.isVault(msg.sender))
            revert STBL_Asset_InvalidVault(assetID);
        IERC20(AssetData.token).safeTransferFrom(
            msg.sender,
            address(this),
            reward
        );
        rewardIndex += (reward * MULTIPLIER) / totalSupply;
        previousDistribution = block.timestamp;
        emit RewardDistributed(reward);
    }

    /**
     * @notice Calculates pending rewards for a specific token ID
     * @param id Token ID to calculate rewards for
     * @return Amount of pending rewards earned since last update
     * @dev Internal function that uses the reward index difference to calculate pending rewards
     */
    function _calculateRewards(uint256 id) private view returns (uint256) {
        uint256 shares = stakingData[id].balance;
        return
            (shares * (rewardIndex - stakingData[id].rewardIndex)) / MULTIPLIER;
    }

    /**
     * @notice Returns the total rewards earned for a specific token ID
     * @param id Token ID to query
     * @return Total rewards earned (both claimed and pending)
     * @dev Combines already earned rewards with pending rewards
     */
    function calculateRewardsEarned(
        uint256 id
    ) external view returns (uint256) {
        return stakingData[id].earned + _calculateRewards(id);
    }

    /**
     * @notice Updates the reward state for a specific token ID
     * @param id Token ID to update
     * @dev Internal function that calculates and stores pending rewards, updates reward index
     */
    function _updateRewards(uint256 id) private {
        stakingData[id].earned += _calculateRewards(id);
        stakingData[id].rewardIndex = rewardIndex;
    }

    /**
     * @notice Enables staking for a token ID
     * @param id Token ID to enable staking for
     * @param value Amount of tokens to stake
     * @dev Updates rewards before changing balance, increases total supply.
     *      Only callable by the authorized issuer contract.
     * @custom:event StakingEnabled Emitted when staking is enabled for a token ID
     */
    function enableStaking(uint256 id, uint256 value) external isIssuer {
        _updateRewards(id);
        stakingData[id].balance += value;
        totalSupply += value;
        emit StakingEnabled(id, value);
    }

    /**
     * @notice Disables staking for a token ID
     * @param id Token ID to disable staking for
     * @param value Amount of tokens to unstake
     * @dev Updates rewards before changing balance, decreases total supply.
     *      Only callable by the authorized issuer contract.
     * @custom:event StakingDisabled Emitted when staking is disabled for a token ID
     */
    function disableStaking(uint256 id, uint256 value) external isIssuer {
        _updateRewards(id);
        stakingData[id].balance -= value;
        totalSupply -= value;
        emit StakingDisabled(id, value);
    }

    /**
     * @notice Claims accumulated rewards for a specific token ID
     * @param id Token ID to claim rewards for
     * @return Amount of rewards claimed and transferred
     * @dev Transfers all accumulated rewards to the token owner, resets earned balance.
     *      Validates that both the asset and the specific token are not disabled.
     * @custom:error STBL_AssetAlreadyDisabled Thrown if the asset is disabled
     * @custom:error STBL_YLDDisabled Thrown if the specific token is disabled
     * @custom:event RewardClaimed Emitted when rewards are claimed for a token ID
     */
    function claim(uint256 id) external returns (uint256) {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);
        if (!AssetData.isActive()) revert STBL_AssetDisabled(assetID);

        iSTBL_YLD YToken = iSTBL_YLD(registry.fetchYLDToken());

        YLD_Metadata memory MetaData = iSTBL_YLD(registry.fetchYLDToken())
            .getNFTData(id);

        if (MetaData.isDisabled) revert STBL_YLDDisabled(id);

        _updateRewards(id);

        uint256 reward = stakingData[id].earned;
        if (reward > 0) {
            stakingData[id].earned = 0;
            IERC20(AssetData.token).safeTransfer(YToken.ownerOf(id), reward);
            emit RewardClaimed(id, reward);
        }
        return reward;
    }

    /**
     * @notice Returns the address of the trusted forwarder for meta-transactions
     * @return The address of the current trusted forwarder from the registry
     * @dev Used by ERC2771Context to validate meta-transaction relayers.
     *      Delegates to the registry for centralized forwarder management.
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
