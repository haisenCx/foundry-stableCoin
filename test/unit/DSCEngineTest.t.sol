// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DepolyDSC} from "../../script/DepolyDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MockFailedTransferFrom} from "test/mocks/MockFaildTransferFrom.sol";
import {MockFailedTransfer} from "test/mocks/MockFaildTransfer.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DepolyDSC depolyer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 amountCollateral = 10 ether;
    uint256 redeemAmount = 6 ether;
    address public USER = makeAddr("user");
    address public liquidator = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_BALANCE = 100 ether;
    uint256 public constant amountToMint = 100 ether;
    uint256 public constant amountToBurn = 5 ether;
    uint256 public constant collateralToCover = 20 ether;

    function setUp() public {
        depolyer = new DepolyDSC();
        (dsc, dscEngine, helperConfig) = depolyer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_BALANCE);
    }

    /////////////////
    // Test Cases //
    /////////////////

    function testDscEngineAddress() public {
        assertEq(dsc.owner(), address(dscEngine));
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine_TokenAddressAndPriceFeedAddressLengthMismatch.selector);
        new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    }

    /////////////////////////////
    // price Tests             //
    /////////////////////////////

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedAmount = 0.05 ether;
        uint256 acturalAmount = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(acturalAmount, expectedAmount);
    }

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 acturalUsd = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(acturalUsd, expectedUsd);
    }

    /////////////////////////////
    // depositCollateral Tests //
    /////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.mint(USER, amountCollateral);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), amountCollateral);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine_CollateralTransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL); // approve
        vm.expectRevert(DSCEngine.DSCEngine_MustBeMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        console.log("user depositCollateral:", AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccounrInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collaterValueInUsd) = dscEngine.getAccountInfomation(USER);
        console.log("totalDscMinted", totalDscMinted);
        console.log("collaterValueInUsd", collaterValueInUsd);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dscEngine.getTokenAmountFromUsd(weth, collaterValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }
    /////////////////////////////
    ///  mintDsc Tests        ///
    /////////////////////////////

    function testMintDscRevertIfamountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_MustBeMoreThanZero.selector);
        dscEngine.mintDsc(0);
        vm.stopPrank();
    }

    function testMintDscSuccess() public depositedCollateral {
        vm.startPrank(USER);
        dscEngine.mintDsc(AMOUNT_COLLATERAL);
        vm.stopPrank();
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInfomation(USER);
        uint256 heathFactor = dscEngine.calculateHealthFactor(totalDscMinted, collateralValueInUsd);
        console.log("totalDscMinterd", totalDscMinted);
        console.log("collateralValueInUsd", collateralValueInUsd);
        console.log("heathFactor", heathFactor);
        assertEq(totalDscMinted, AMOUNT_COLLATERAL);
    }

    function testRevertMintDscIfHealthFactorIsLow() public depositedCollateral {
        vm.startPrank(USER);
        (, uint256 collateralValueInUsd) = dscEngine.getAccountInfomation(USER);
        uint256 userHealthFactor =
            dscEngine.calculateHealthFactor(AMOUNT_COLLATERAL + 90000000 ether, collateralValueInUsd);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine_LowHealthFactor.selector, userHealthFactor));
        dscEngine.mintDsc(AMOUNT_COLLATERAL + 90000000 ether);
        vm.stopPrank();
    }

    ////////////////////////////
    ///  burnDsc Tests        ///
    /////////////////////////////
    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    function testBurnRevertIfAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_MustBeMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function testCanBurn() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.burnDsc(amountToBurn);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amountToMint - amountToBurn);
    }

    function testBurnRevertIfAmountExceedsTotalDscMinted() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amountToMint);
        vm.expectRevert();
        dscEngine.burnDsc(amountToMint + 1);
        vm.stopPrank();
    }
    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dscEngine.getHealthFactor(USER);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == 0.9 ether);
    }
    /////////////////////////////
    ///  liquidate Tests      ///
    /////////////////////////////

    function testLiquidateWhenHealthFactorOk() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine_HealthFactorOk.selector);
        dscEngine.liquidate(address(dsc), USER, amountToMint);
        vm.stopPrank();
    }

    function testLiquidateSuccess() public {
        //arrange
        //deposit collateral and mint dsc for user
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        //deposit collateral and mint dsc for liquidator
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        ERC20Mock(weth).mint(liquidator, collateralToCover);
        dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        vm.stopPrank();

        //price of weth crashed
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        //action
        vm.startPrank(liquidator);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInfomation(USER);
        uint256 heathFactor = dscEngine.calculateHealthFactor(totalDscMinted, collateralValueInUsd);
        console.log("totalDscMinterd", totalDscMinted);
        console.log("collateralValueInUsd", collateralValueInUsd);
        console.log("heathFactor", heathFactor);
        dscEngine.liquidate(weth, USER, amountToMint);
        vm.stopPrank();

        //assert
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dscEngine.getTokenAmountFromUsd(weth, amountToMint)
            + (dscEngine.getTokenAmountFromUsd(weth, amountToMint) / dscEngine.getLiquidationBonus());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    /////////////////////////////////////////
    ///  depositCollateralAndMintDsc      ///
    /////////////////////////////////////////
    function testDepositCollateralAndMintDscSuccess() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInfomation(USER);
        uint256 heathFactor = dscEngine.calculateHealthFactor(totalDscMinted, collateralValueInUsd);
        console.log("totalDscMinterd", totalDscMinted);
        console.log("collateralValueInUsd", collateralValueInUsd);
        console.log("heathFactor", heathFactor);
        assertEq(totalDscMinted, amountToMint);
    }

    ////////////////////////////////////
    ///  redeemCollateralForDsc      ///
    ////////////////////////////////////
    function testRedeemCollateralForDscSuccess() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInfomation(USER);
        uint256 heathFactor = dscEngine.calculateHealthFactor(totalDscMinted, collateralValueInUsd);
        console.log("totalDscMinterd", totalDscMinted);
        console.log("collateralValueInUsd", collateralValueInUsd);
        console.log("heathFactor", heathFactor);
        assertEq(totalDscMinted, 0);
    }

    /////////////////////////////
    // redeemCollateral Tests  //
    /////////////////////////////
    function testRedeemCollateralSuccess() public depositedCollateral {
        //Arrange - setup
        vm.startPrank(USER);

        uint256 startCollateralBalance = dscEngine.getAccountCollateralValueInUsd(USER);
        console.log("startCollateralBalance", startCollateralBalance);
        dscEngine.redeemCollateral(weth, redeemAmount);
        console.log("redeemCollateral end");
        uint256 remainCollateralBalance = dscEngine.getAccountCollateralValueInUsd(USER);
        //10weth - 5weth = 5weth
        uint256 expectedBalance = dscEngine.getUsdValue(weth, (AMOUNT_COLLATERAL - redeemAmount));
        vm.stopPrank();

        console.log("expectedBalance", expectedBalance);
        console.log("remainCollateralBalance", remainCollateralBalance);
        assertEq(remainCollateralBalance, expectedBalance);
    }

    function testRedeemCollateralRevertsIfAmountIsZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_MustBeMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRedeemCollateralRevertsferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.mint(USER, amountCollateral);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), amountCollateral);
        mockDsce.depositCollateral(address(mockDsc), amountCollateral);
        uint256 startCollateralBalance = dscEngine.getAccountCollateralValueInUsd(USER);
        console.log("startCollateralBalance", startCollateralBalance);

        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine_TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), redeemAmount);
        vm.stopPrank();
    }
}
