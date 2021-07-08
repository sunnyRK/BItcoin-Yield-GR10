// SPDX-License-Identifier: MIT

pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/math/MathUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../deps/@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";

import "../interfaces/badger/IController.sol";
import "../interfaces/aave/ILendingPool.sol";

import "./interfaces/AaveLendingPoolV2.sol";
import "./interfaces/AaveLendingPoolProviderV2.sol";
import "./interfaces/IWETHGateway.sol";
import "./interfaces/ISwapRouter.sol";
import "./interfaces/IQuoter.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/aave/FlashLoanReceiverBase.sol";

import {
    BaseStrategy
} from "../deps/BaseStrategy.sol";

import './chainlink/AggregatorInterface.sol';

contract MyStrategy is BaseStrategy {
    using SafeERC20Upgradeable for IERC20;
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;

    // address public want // Inherited from BaseStrategy, the token the strategy wants, swaps into and tries to grow
    address public lpComponent; // Token we provide liquidity with
    address public reward; // Token we farm and swap to want / lpComponent
    address public constant LENDING_POOL = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    address public borrowPercentage = 70;
    address public borrowedAmount;

    address public lendingPoolAddress = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9; // mainnet
    // address public lendingPoolAddress = 0x8dFf5E27EA6b7AC08EbFdf9eB090F32ee9a30fcf; // polygon

    address public constant ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564; // Mainnet
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // Mainnet
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // Mainnet
    address public constant aaveToken = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9; // Mainnet
    
    AaveLendingPoolProviderV2 public provider;
    bool public initialized;
    address public underlying;
    address public aWBTC;
    uint256 public val;

    constructor(address _WBTC, address _aWBTC, ILendingPoolAddressesProvider _addressesProvider) public FlashLoanReceiverBase(_addressesProvider) {
        
        underlying = _WBTC;
        aWBTC = _aWBTC;

        provider = AaveLendingPoolProviderV2(address(_addressesProvider));
        
        IERC20(underlying).safeApprove(provider.getLendingPool(), type(uint256).max);
        IERC20(WETH).safeApprove(provider.getLendingPool(), type(uint256).max);

        IERC20(underlying).safeApprove(ROUTER, type(uint256).max);
        IERC20(WETH).safeApprove(ROUTER, type(uint256).max);    
    }

    function initialize(
        address _governance,
        address _strategist,
        address _controller,
        address _keeper,
        address _guardian,
        address[3] memory _wantConfig,
        uint256[3] memory _feeConfig
    ) public initializer {
        __BaseStrategy_init(_governance, _strategist, _controller, _keeper, _guardian);

        /// @dev Add config here
        want = _wantConfig[0];
        lpComponent = _wantConfig[1];
        reward = _wantConfig[2];

        performanceFeeGovernance = _feeConfig[0];
        performanceFeeStrategist = _feeConfig[1];
        withdrawalFee = _feeConfig[2];

        /// @dev do one off approvals here
        // IERC20Upgradeable(want).safeApprove(gauge, type(uint256).max);
    }

    /// ===== View Functions =====

    // @dev Specify the name of the strategy
    function getName() external override pure returns (string memory) {
        return "wBTC AAVE Farm Strat";
    }

    // @dev Specify the version of the Strategy, for upgrades
    function version() external pure returns (string memory) {
        return "1.0";
    }

    /// @dev Balance of want currently held in strategy positions
    function balanceOfPool() public override view returns (uint256) {
        // aTokens
        return IERC20Upgradeable(lpComponent).balanceOf(address(this));

    }
    
    /// @dev Returns true if this strategy requires tending
    function isTendable() public override view returns (bool) {
        return true;
    }

    // @dev These are the tokens that cannot be moved except by the vault
    function getProtectedTokens() public override view returns (address[] memory) {
        address[] memory protectedTokens = new address[](3);
        protectedTokens[0] = want;
        protectedTokens[1] = lpComponent;
        protectedTokens[2] = reward;
        return protectedTokens;
    }

    /// ===== Permissioned Actions: Governance =====
    /// @notice Delete if you don't need!
    function setKeepReward(uint256 _setKeepReward) external {
        _onlyGovernance();
    }

    /// ===== Internal Core Implementations =====

    /// @dev security check to avoid moving tokens that would cause a rugpull, edit based on strat
    function _onlyNotProtectedTokens(address _asset) internal override {
        address[] memory protectedTokens = getProtectedTokens();

        for(uint256 x = 0; x < protectedTokens.length; x++){
            require(address(protectedTokens[x]) != _asset, "Asset is protected");
        }
    }

    /// @dev invest the amount of want
    /// @notice When this function is called, the controller has already sent want to this
    /// @notice Just get the current balance and then invest accordingly
    function _deposit(uint256 _amount) internal override {
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        depositAmount();
        getAAVEUserDetails();
        _rebalance();
    }

    function _rebalance() internal {
        uint256 borrowedAmount = borrowAmount();
        while (borrowedAmount > 0) {
            uniswapperV3(0, WETH, underlying, borrowedAmount, 0);
            depositAmount();
            borrowedAmount = borrowAmount();
        }
    }

    function depositAmount() internal {
        AaveLendingPoolV2 lendingPool = AaveLendingPoolV2(provider.getLendingPool());
        lendingPool.deposit(underlying, IERC20(underlying).balanceOf(address(this)), address(this), 0); // 29 -> referral
    }

    function borrowAmount() internal returns(uint256) {
        (,,uint256 borrowedAmount,,,) = AaveLendingPoolV2(provider.getLendingPool()).getUserAccountData(address(this));
        if(borrowedAmount <= 3e18) {
            borrowedAmount = 0;
        } else {
            AaveLendingPoolV2(provider.getLendingPool()).borrow(WETH, borrowedAmount, 2, 0, address(this));
        }
        return borrowedAmount;
    }

    function uniswapperV3(uint256 swapFlag, address _token0, address _token1, uint256 borrowedAmount, uint256 _amountout) internal {
        if(swapFlag == 0) {
            ISwapRouter.ExactInputSingleParams memory fromWethToWbtcParams =
            ISwapRouter.ExactInputSingleParams(
                _token0,
                _token1,
                10000,
                address(this),
                block.timestamp,
                borrowedAmount,
                0,
                0
            );
            ISwapRouter(ROUTER).exactInputSingle(fromWethToWbtcParams);
            uint256 wbtcTokensUniswapper = IERC20(_token1).balanceOf(address(this));
            console.log('WbtcTokens--: ', wbtcTokensUniswapper);
            val = wbtcTokensUniswapper;
        } else {
            ISwapRouter.ExactOutputSingleParams memory params =
            ISwapRouter.ExactOutputSingleParams(
                _token0,
                _token1,
                10000,
                address(this),
                block.timestamp,
                _amountout,
                IERC20(WBTC).balanceOf(address(this)),
                0
            );
            ISwapRouter(ROUTER).exactOutputSingle(params);
        }
    }

    function repay(uint totalDebtETH) internal {
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2).safeApprove(provider.getLendingPool(), 0);
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2).safeApprove(provider.getLendingPool(), type(uint256).max);
        AaveLendingPoolV2(provider.getLendingPool()).repay(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, totalDebtETH, 2, address(this));
    }

    function withdrawWBTC(uint256 a) internal {
        AaveLendingPoolV2(provider.getLendingPool()).withdraw(underlying, a, address(this));
    }

    function getLatestPrice(address _oracle) public view returns (int) {
        (
            uint80 roundID, 
            int price,
            uint startedAt,
            uint timeStamp,
            uint80 answeredInRound
        ) = AggregatorV3Interface(_oracle).latestRoundData();
            return price;
    }

    /// @dev utility function to withdraw everything for migration
    // Withdraw All with AAVE flashloan
    function _withdrawAll() internal override {
        (,uint256 totalDebtETH,,,,) = getAAVEUserDetails();
        _withdrawSome(totalDebtETH);
    }

    

    /// @dev withdraw the specified amount of want, liquidate from lpComponent to want, paying off any necessary debt for the conversion
        // Withdraw with AAVE flashloan
    function _withdrawSome(uint256 _amount) internal override returns (uint256) {

        if (_amount > balanceOfPool()) {
            _amount = balanceOfPool();
        }

        address receiver = address(this);

        address[] memory assets = new address[](1);
        assets[0] = asset;

        uint[] memory amounts = new uint[](1);
        amounts[0] = totalDebtETH;

        // 0 = no debt, 1 = stable, 2 = variable
        // 0 = pay all loaned
        uint[] memory modes = new uint[](1);
        modes[0] = 0;

        address onBehalfOf = address(this);

        bytes memory params = ""; // extra data to pass abi.encode(...)
        uint16 referralCode = 0;

        LENDING_POOL.flashLoan(
            receiver,
            assets,
            amounts,
            modes,
            onBehalfOf,
            params,
            referralCode
        );
        return _amount;
    }

    function executeOperation(
        address[] calldata assets,
        uint[] calldata amounts,
        uint[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        repay(amounts[0]);
        (uint256 a,,,,,) = getAAVEUserDetails();
        uint256 aWBTCBal = IERC20(aWBTC).balanceOf(address(this));
        withdrawWBTC(aWBTCBal);
        uint amountOwing = amounts[0] + premiums[0];
        uniswapperV3(1, WBTC, WETH, 0, amountOwing);
        IERC20(assets[0]).approve(address(LENDING_POOL), amountOwing);
        // And repay Aave here automatically
        return true;
    }


    function getAAVEUserDetails() public view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        (uint256 a,uint256 b, uint256 c,uint256 d,uint256 e,uint256 f) = 
                    AaveLendingPoolV2(provider.getLendingPool()).getUserAccountData(address(this));
        return (a, b, c, d, e, f);
    }

    /// @dev Harvest from strategy mechanics, realizing increase in underlying position
    function harvest() external whenNotPaused returns (uint256 harvested) {
        _onlyAuthorizedActors();

        uint256 _before = IERC20Upgradeable(want).balanceOf(address(this));

        // Write your code here 

        uint256 earned = IERC20Upgradeable(want).balanceOf(address(this)).sub(_before);

        /// @notice Keep this in so you get paid!
        (uint256 governancePerformanceFee, uint256 strategistPerformanceFee) = _processPerformanceFees(earned);

        /// @dev Harvest event that every strategy MUST have, see BaseStrategy
        emit Harvest(earned, block.number);

        return earned;
    }

    // Alternative Harvest with Price received from harvester, used to avoid exessive front-running
    function harvest(uint256 price) external whenNotPaused returns (uint256 harvested) {

    }

    /// @dev Rebalance, Compound or Pay off debt here
    function tend() external whenNotPaused {
        _onlyAuthorizedActors();
    }


    /// ===== Internal Helper Functions =====
    
    /// @dev used to manage the governance and strategist fee, make sure to use it to get paid!
    function _processPerformanceFees(uint256 _amount) internal returns (uint256 governancePerformanceFee, uint256 strategistPerformanceFee) {
        governancePerformanceFee = _processFee(want, _amount, performanceFeeGovernance, IController(controller).rewards());

        strategistPerformanceFee = _processFee(want, _amount, performanceFeeStrategist, strategist);
    }

    /// Extra Function
    function setBorrowPercentage(uint256 _percentage) public {
        _onlyGovernance();
        borrowPercentage = _percentage;
    }
}
