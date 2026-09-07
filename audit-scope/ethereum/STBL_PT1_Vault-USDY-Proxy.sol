// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@stbl-protocol/stbl-contracts-evm-core/contracts/interfaces/ISTBL_Register.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/interfaces/ISTBL_Core.sol";

import "./interfaces/ISTBL_PT1_AssetIssuer.sol";
import "./interfaces/ISTBL_PT1_AssetVault.sol";
import "./interfaces/ISTBL_PT1_AssetYieldDistributor.sol";
import "./interfaces/ISTBL_PT1_AssetOracle.sol";

import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_AssetDefinitionLib.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_Structs.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_Errors.sol";
import "@stbl-protocol/stbl-contracts-evm-core/contracts/lib/STBL_DecimalConverter.sol";

import "./lib/STBL_OracleLib.sol";
import "./lib/STBL_PT1_Asset_Errors.sol";

/**
 * @title STBL Protocol Type 1 Asset Vault
 * @notice Manages secure storage, deposits, withdrawals, and yield distribution for protocol assets
 * @dev Upgradeable vault contract implementing ERC2771 meta-transaction support with comprehensive fee tracking
 * @dev Handles asset custody operations including deposits, withdrawals, yield calculations, and fee management
 * @author STBL Protocol Team
 * @custom:version 1.0.0
 * @custom:security-contact security@stblprotocol.com
 */
contract STBL_PT1_Vault is
    Initializable,
    iSTBL_PT1_AssetVault,
    ERC2771ContextUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using STBL_AssetDefinitionLib for AssetDefinition;
    using STBL_OracleLib for iSTBL_PT1_AssetOracle;
    using DecimalConverter for uint256;

    /** @notice Role identifier for contract upgrade authorization */
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /** @notice Role identifier for Yield Distribution authorization */
    bytes32 public constant YIELD_DISTRIBUTION_ROLE =
        keccak256("YIELD_DISTRIBUTION_ROLE");

    /** @notice Current implementation version for upgrade tracking */
    uint256 private _version;

    /** @notice Protocol registry contract providing system configuration and access control */
    iSTBL_Register private registry;

    /** @notice Unique identifier for the asset type managed by this vault instance */
    uint256 private assetID;

    /** @notice Complete vault state including deposits, fees, yields, and tracking metrics */
    VaultStruct private VaultData;

    /** @dev Reserved storage slots for future contract upgrades (60 slots = 1920 bytes) */
    uint256[60] private __gap;

    /**
     * @notice Validates that the caller is an authorized issuer for the managed asset
     * @dev Queries registry for asset definition and verifies issuer permissions
     * @dev Reverts with STBL_Asset_InvalidIssuer if authorization fails
     */
    modifier isValidIssuer() {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);
        if (!AssetData.isIssuer(msg.sender))
            revert STBL_Asset_InvalidIssuer(assetID);
        _;
    }

    /**
     * @notice Initializes the contract implementation without setting up state
     * @dev Constructor for upgradeable contracts - actual initialization happens in initialize()
     * @dev Sets up ERC2771Context with zero address (forwarder set later via registry)
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() ERC2771ContextUpgradeable(address(0)) {}

    /**
     * @notice Initializes the vault with asset ID and registry configuration
     * @dev Sets up access control, UUPS upgradeability, and associates vault with specific asset
     * @dev Can only be called once during proxy deployment
     * @param _id Unique identifier of the asset this vault will manage
     * @param _registry Address of the protocol registry containing system configuration
     */
    function initialize(uint256 _id, address _registry) public initializer {
        __UUPSUpgradeable_init();

        registry = iSTBL_Register(_registry);
        assetID = _id;
    }

    /**
     * @notice Authorizes contract upgrades for addresses with UPGRADER_ROLE
     * @dev Validates upgrade permissions through registry and increments version counter
     * @dev Required by UUPS proxy pattern for upgrade authorization
     * @param newImplementation Address of the new implementation contract to upgrade to
     */
    function _authorizeUpgrade(address newImplementation) internal override {
        if (!registry.hasRole(UPGRADER_ROLE, _msgSender()))
            revert STBL_UnauthorizedCaller();
        _version = _version + 1;
        emit ContractUpgraded(newImplementation);
    }

    /**
     * @notice Returns the current contract implementation version
     * @dev Version increments with each successful upgrade for tracking purposes
     * @return Current version number of the contract implementation
     */
    function version() external view returns (uint256) {
        return _version;
    }

    /**
     * @notice Processes ERC20 token deposits into the vault with comprehensive fee tracking
     * @dev Transfers tokens from depositor, calculates fees using oracle pricing, and updates vault state
     * @dev Records gross/net deposits, USD values, and fee breakdowns with decimal conversion
     * @dev Only callable by authorized asset issuers
     * @param _from Address of the depositor providing the tokens
     * @param MetaData Comprehensive deposit information including amounts, fees, and haircuts
     * @custom:event depositEvent Emitted with complete deposit details including fee calculations
     */
    function depositERC20(
        address _from,
        YLD_Metadata memory MetaData
    ) external isValidIssuer {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);

        IERC20(AssetData.token).safeTransferFrom(
            _from,
            address(this),
            MetaData.assetValue.convertFrom18Decimals(
                DecimalConverter.getTokenDecimals(AssetData.token)
            )
        );

        uint256 depositFeesAssetValue = iSTBL_PT1_AssetOracle(AssetData.oracle)
            .fetchInversePrice(MetaData.depositfeeAmount);
        uint256 insuranceFeeAssetValue = iSTBL_PT1_AssetOracle(AssetData.oracle)
            .fetchInversePrice(MetaData.insurancefeeAmount);

        /** Store asset Values gross and net */
        VaultData.assetDepositGross += MetaData.assetValue;
        VaultData.assetDepositNet += (MetaData.assetValue -
            (depositFeesAssetValue + insuranceFeeAssetValue));

        /** Aggregate Stable Value distributed */
        VaultData.depositValueUSD +=
            MetaData.stableValueNet +
            MetaData.haircutAmount;

        /** Aggregate fees Values added */
        VaultData.depositFees += depositFeesAssetValue;
        VaultData.insuranceFees += insuranceFeeAssetValue;

        /** Aggregate haircut Values added */
        VaultData.cumilativeHairCutValue += MetaData.haircutAmount;

        emit depositEvent(
            AssetData.token,
            _from,
            MetaData.assetValue,
            MetaData.depositfeeAmount,
            MetaData.insurancefeeAmount,
            MetaData.haircutAmount,
            depositFeesAssetValue,
            insuranceFeeAssetValue
        );
    }

    /**
     * @notice Processes ERC20 token withdrawals from the vault with fee deduction and state updates
     * @dev Calculates withdrawal amounts using oracle pricing, applies fees, and transfers tokens
     * @dev Updates vault balances by reducing deposits, USD tracking, and haircut values
     * @dev Only callable by authorized asset issuers
     * @param _to Address that will receive the withdrawn tokens
     * @param MetaData Comprehensive withdrawal information including amounts, fees, and haircuts
     * @custom:event withdrawEvent Emitted with complete withdrawal details including fee calculations
     */
    function withdrawERC20(
        address _to,
        YLD_Metadata memory MetaData
    ) external isValidIssuer {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);

        if (
            iSTBL_PT1_AssetOracle(AssetData.oracle).fetchForwardPrice(
                VaultData.assetDepositNet
            ) < (VaultData.depositValueUSD)
        )
            revert STBL_Asset_InsufficientVaultValue(
                iSTBL_PT1_AssetOracle(AssetData.oracle).fetchForwardPrice(
                    VaultData.assetDepositNet
                ),
                VaultData.depositValueUSD
            );

        uint256 withdrawfeeAmount = calculateWithdrawFees(
            MetaData,
            AssetData.withdrawFees
        );

        /** Calculate Withdraw asset value */
        uint256 withdrawAssetValue = iSTBL_PT1_AssetOracle(AssetData.oracle)
            .fetchInversePrice(
                ((MetaData.stableValueNet + MetaData.haircutAmount) -
                    withdrawfeeAmount)
            );

        uint256 withdrawFeeAssetValue = iSTBL_PT1_AssetOracle(AssetData.oracle)
            .fetchInversePrice(withdrawfeeAmount);

        /** Transfer Asset outward post decimal conversion */
        IERC20(AssetData.token).safeTransfer(
            _to,
            withdrawAssetValue.convertFrom18Decimals(
                DecimalConverter.getTokenDecimals(AssetData.token)
            )
        );

        /** Deduct Withdraw fees */
        VaultData.withdrawFees += withdrawFeeAssetValue;

        /** Deduct USD Value Withdrawn */
        VaultData.depositValueUSD -=
            MetaData.stableValueNet +
            MetaData.haircutAmount;

        /** Deduct Hair Cut values */
        VaultData.cumilativeHairCutValue -= MetaData
            .haircutAmount; /** look at this in depth */

        /** */
        VaultData.assetDepositNet -= (withdrawAssetValue +
            withdrawFeeAssetValue);
        VaultData.assetDepositGross -= MetaData.assetValue;

        emit withdrawEvent(
            AssetData.token,
            _to,
            withdrawAssetValue,
            withdrawfeeAmount,
            withdrawFeeAssetValue,
            MetaData.haircutAmount
        );
    }

    /**
     * @notice Calculates potential yield based on asset price appreciation vs tracked USD value
     * @dev Internal function comparing current oracle-based USD value against historical deposit tracking
     * @dev Returns positive differential when current asset value exceeds tracked USD deposits
     * @return Price differential in USD (18 decimals) representing available yield, or 0 if no appreciation
     */
    function iCalculatePriceDifferentiation() internal view returns (uint256) {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);

        uint256 USDValueOfDepositValue = iSTBL_PT1_AssetOracle(AssetData.oracle)
            .fetchForwardPrice(VaultData.assetDepositNet);

        if (USDValueOfDepositValue > VaultData.depositValueUSD) {
            return USDValueOfDepositValue - VaultData.depositValueUSD;
        } else {
            return (0);
        }
    }

    /**
     * @notice Distributes accumulated yield from asset appreciation to protocol reward distributor
     * @dev Calculates yield differential, deducts protocol fees, and transfers tokens to distributor
     * @dev Only executes distribution when positive price differential exists
     * @dev Restricted to protocol treasury address for security
     * @custom:event YieldDistributed Emitted with yield distribution details including fees and amounts
     */
    function distributeYield() external {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);
        uint256 differentialUSD = iCalculatePriceDifferentiation();

        if (!registry.hasRole(YIELD_DISTRIBUTION_ROLE, _msgSender()))
            revert STBL_UnauthorizedCaller();

        if (differentialUSD > 0) {
            (uint256 yield, uint256 yieldFee) = AssetData.calculateYieldFee(
                differentialUSD
            );

            uint256 yieldFeeAssetValue = iSTBL_PT1_AssetOracle(AssetData.oracle)
                .fetchInversePrice(yieldFee);

            uint256 yieldAssetValue = iSTBL_PT1_AssetOracle(AssetData.oracle)
                .fetchInversePrice(yield);

            VaultData.yieldFees += yieldFeeAssetValue;

            IERC20(AssetData.token).approve(
                AssetData.rewardDistributor,
                yieldAssetValue.convertFrom18Decimals(
                    DecimalConverter.getTokenDecimals(AssetData.token)
                )
            );

            VaultData.assetDepositNet -= yieldAssetValue + yieldFeeAssetValue;

            iSTBL_PT1_AssetYieldDistributor(AssetData.rewardDistributor)
                .distributeReward(
                    yieldAssetValue.convertFrom18Decimals(
                        DecimalConverter.getTokenDecimals(AssetData.token)
                    )
                );

            emit YieldDistributed(
                AssetData.token,
                AssetData.rewardDistributor,
                yield,
                yieldFee,
                yieldAssetValue
            );
        }
    }

    /**
     * @notice External view function exposing price differential calculation for yield potential
     * @dev Public interface to check available yield without executing distribution
     * @dev Used by external contracts, interfaces, and monitoring systems
     * @return Price differential value in USD (18 decimals) representing distributable yield
     */
    function CalculatePriceDifferentiation() external view returns (uint256) {
        return iCalculatePriceDifferentiation();
    }

    /**
     * @notice Transfers all accumulated protocol fees to the designated treasury address
     * @dev Consolidates deposit, withdrawal, yield, and insurance fees for batch transfer
     * @dev Resets all fee counters to zero after successful transfer completion
     * @dev Validates treasury address existence before executing transfer
     * @custom:event FeesWithdrawn Emitted with detailed breakdown of all withdrawn fee categories
     */
    function withdrawFees() external {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);
        address treasury = registry.fetchTreasury();

        if (treasury == address(0)) revert STBL_InvalidTreasury();

        /** Calculate fees Value */
        uint256 Fees = VaultData.depositFees +
            VaultData.withdrawFees +
            VaultData.yieldFees +
            VaultData.insuranceFees;

        /** Transfer Fees Outside */
        IERC20(AssetData.token).safeTransfer(
            treasury,
            Fees.convertFrom18Decimals(
                DecimalConverter.getTokenDecimals(AssetData.token)
            )
        );
        emit FeesWithdrawn(
            treasury,
            VaultData.depositFees,
            VaultData.withdrawFees,
            VaultData.yieldFees,
            VaultData.insuranceFees,
            Fees
        );

        /** Reset Counters */
        VaultData.depositFees = 0;
        VaultData.withdrawFees = 0;
        VaultData.yieldFees = 0;
        VaultData.insuranceFees = 0;
    }

    /**
     * @notice Drains a specified amount of tokens from the vault to treasury during emergency situations
     * @dev Emergency function that transfers tokens directly to treasury when asset is disabled
     * @dev Can only be executed when the asset status is not ENABLED for security purposes
     * @dev Reduces the net asset deposit tracking by the withdrawn amount
     * @custom:event EmergencyFundsWithdraw Emitted with the amount of tokens withdrawn
     * @custom:security Only callable when asset is disabled and treasury address is valid
     */
    function emergencyWithdraw() external {
        AssetDefinition memory AssetData = registry.fetchAssetData(assetID);
        address treasury = registry.fetchTreasury();

        if (treasury == address(0)) revert STBL_InvalidTreasury();
        if (AssetData.status != AssetStatus.EMERGENCY_STOP)
            revert STBL_AssetActive();

        uint256 balance = IERC20(AssetData.token).balanceOf(address(this));

        IERC20(AssetData.token).safeTransfer(treasury, balance);
        emit EmergencyFundsWithdraw(balance);
    }

    /**
     * @notice Calculates withdrawal fees based on gross stable value and fee percentage
     * @dev Internal pure function that computes fees without modifying state
     * @dev Fee calculation: (stableValueGross * withdrawFee) / FEES_CONSTANT
     * @param MetaData Withdrawal metadata containing stable value information
     * @param withdrawFee Fee percentage to be applied (scaled by FEES_CONSTANT)
     * @return withdrawfeeAmount Calculated withdrawal fee amount in stable value units
     */
    function calculateWithdrawFees(
        YLD_Metadata memory MetaData,
        uint256 withdrawFee
    ) internal pure returns (uint256 withdrawfeeAmount) {
        withdrawfeeAmount =
            (MetaData.stableValueGross * withdrawFee) /
            FEES_CONSTANT;
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
     * @notice Retrieves the complete vault state data
     * @dev Returns all vault metrics including deposits, fees, yields, and tracking values
     * @return VaultStruct containing comprehensive vault state information
     */
    function fetchVaultData() external view returns (VaultStruct memory) {
        return VaultData;
    }

    /**
     * @notice Retrieves the trusted forwarder address for ERC2771 meta-transaction support
     * @dev Queries registry for current trusted forwarder configuration
     * @dev Used by ERC2771Context to validate and process meta-transactions
     * @return Address of the currently configured trusted forwarder contract
     */
    function trustedForwarder() public view virtual override returns (address) {
        return registry.trustedForwarder();
    }

    /**
     * @notice Resolves inheritance conflict for _msgSender() between ERC2771Context and Context
     * @dev Returns the actual transaction sender, accounting for meta-transaction forwarding
     * @dev Prioritizes ERC2771Context implementation for proper meta-transaction handling
     * @return Actual sender address of the current transaction
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
     * @notice Resolves inheritance conflict for _msgData() between ERC2771Context and Context
     * @dev Returns the actual transaction calldata, accounting for meta-transaction forwarding
     * @dev Prioritizes ERC2771Context implementation for proper meta-transaction handling
     * @return Complete calldata of the current transaction
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
     * @notice Resolves inheritance conflict for _contextSuffixLength() in ERC2771Context
     * @dev Returns the length of context suffix used in meta-transaction processing
     * @dev Prioritizes ERC2771Context implementation for proper meta-transaction handling
     * @return Length of the context suffix for meta-transaction support
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
