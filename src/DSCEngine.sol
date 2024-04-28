// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions
pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/Test.sol";
import {OracleLib, AggregatorV3Interface} from "../../src/libraries/OracleLib.sol";

/*
 * @title DSCEngine
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////
    //Error  	 ///
    ////////////////
    error DSCEngine_MustBeMoreThanZero();
    error DSCEngine_TokenAddressAndPriceFeedAddressLengthMismatch();
    error DSCEngine_NotAllowedToken();
    error DSCEngine_CollateralTransferFailed();
    error DSCEngine_LowHealthFactor(uint256 healthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine_TransferFailed();
    error DSCEngine_HealthFactorOk();

    ////////////////
    //Type  	 ///
    ////////////////
    using OracleLib for AggregatorV3Interface;

    ////////////////////////
    //State Variables  	 ///
    ////////////////////////

    uint256 public constant ADDITONAL_FEED_PRECISION = 1e10;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public constant LIQUIDATION_PRECISION = 100;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidator

    mapping(address tokent => address priceFeed) private s_priceFeeds; //token to price feed mapping
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; //user to token to amount mapping
    mapping(address user => uint256 amount) private s_DSCMinted; //user to amount of DSC minted mapping
    address[] private s_collateralTokens; //array of collateral tokens
    DecentralizedStableCoin private immutable i_dsc; //DSC token

    ////////////////
    //Events     ///
    ////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    ////////////////
    //Modifiers  ///
    ////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine_MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowerdToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine_NotAllowedToken();
        }
        _;
    }

    ////////////////
    //Function   ///
    ////////////////
    constructor(address[] memory tokenAddress, address[] memory priceFeedAddress, address dscAddress) {
        if (tokenAddress.length != priceFeedAddress.length) {
            revert DSCEngine_TokenAddressAndPriceFeedAddressLengthMismatch();
        }
        //usd price feed
        //for example Eth/USD , Btc/USD , etc
        for (uint256 i = 0; i < tokenAddress.length; i++) {
            s_priceFeeds[tokenAddress[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddress[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////
    //External Function   ///
    /////////////////////////
    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC to mint
     * @notice This function is a helper function to deposit collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     *
     * @param tokenCollateralAddress  The address of the token to deposit as collateral
     * @param amountCollateral  The amount of collateral to deposit
     * @notice This function allows a user to deposit collateral into the system
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowerdToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine_CollateralTransferFailed();
        }
    }

    /**
     *
     * @param tokenCollateralAddress  The address of the token to redeem as collateral
     * @param amountCollateral The amount of collateral to redeem
     * @param amountToBurn The amount of DSC to burn
     * @notice This function is a helper function to redeem collateral and burn DSC in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountToBurn)
        external
    {
        burnDsc(amountToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    //in order to redeem Collateral
    //1.health factor must be > 1
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param amountDscToMint The amount of DSC to mint
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        //check is collateral value > DSC value
        _revertIfHealthFactorIsBroken(msg.sender);
        //mint DSC
        bool mintSuccess = i_dsc.mint(msg.sender, amountDscToMint);
        if (!mintSuccess) {
            revert DSCEngine_MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * this is the key of the stablecoin system, if the health factor is less than 1, the user can be liquidated
     * ie. 50$ worth of DSC minted, 100$ worth of weth collateral deposited, and when the weth price droped and the collateral worth droped to 75$, the health factor will below 1,
     * and the user can be liquidated.the liquidator can get 75$ worth of weth by burning 50$ worth of DSC,in other words, the liquidator can get 25$ worth of weth as a bonus
     *
     * @param collateral  The address of the collateral token
     * @param user  The address of the user to liquidate
     * @param debtToCover The amount of DSC you want to burn to cover the debt and inprove the health factor
     * @notice a known bug is that when the collateral price is too low, lower than the worth of the DSC minted,
     * we cant incentive the liquidator to liquidate the user, because the liquidator will get less collateral than the DSC minted
     * for example, 100$ worth of DSC minted, 50$ worth of weth deposited, and the weth price droped to 25$, the health factor will be below 1, but the liquidator will get 50$ worth of weth by burning 100$ worth of DSC
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //check the health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorOk();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine_LowHealthFactor(endingUserHealthFactor);
        }
        _revertIfHealthFactorIsBroken(user);
    }

    //////////////////////////////////////
    //Private & Internal view Function ///
    //////////////////////////////////////
    /*
     * @dev low level function to burn DSC, dont call it unless checking health factor is broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool burnSuccess = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!burnSuccess) {
            revert DSCEngine_TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        console.log("redeemCollateral amountCollateral:", amountCollateral);
        console.log(
            "redeemCollateral s_collateralDeposited[from][tokenCollateralAddress]:",
            s_collateralDeposited[from][tokenCollateralAddress]
        );
        console.log("redeemCollateral tokenCollateralAddress:", tokenCollateralAddress);
        console.log("redeemCollateral from:", from);
        console.log("redeemCollateral to:", to);
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        console.log("amountCollateral :", amountCollateral);
        console.log("msg.sender :", msg.sender);
        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    function _getAccountInfomation(address user)
        private
        view
        returns (uint256 totalDscMinterd, uint256 collaterlValueInUsd)
    {
        totalDscMinterd = s_DSCMinted[user];
        collaterlValueInUsd = getAccountCollateralValueInUsd(user);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }
    /**
     * return how close the user is to being liquidated
     * If the health factor is less than 1, the user can be liquidated
     * @param user The address of the user
     */

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinterd, uint256 collaterlValueInUsd) = _getAccountInfomation(user);
        //calculate health factor
        return _calculateHealthFactor(totalDscMinterd, collaterlValueInUsd);
        // return (collaterlValueInUsd / totalDscMinterd);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_LowHealthFactor(userHealthFactor);
        }
    }

    //////////////////////////////////////
    //Public & External view Function ///
    //////////////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountInfomation(address user)
        external
        view
        returns (uint256 totalDscMinterd, uint256 collaterlValueInUsd)
    {
        (totalDscMinterd, collaterlValueInUsd) = _getAccountInfomation(user);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITONAL_FEED_PRECISION);
    }

    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //loop through the collateral token, get the amount they have deposited, and map it to the price feed to get the value in USD
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        //if 1ETH = 1000$
        //the return value will be 1000 * 1e8
        return (uint256(price) * ADDITONAL_FEED_PRECISION * amount) / PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}
