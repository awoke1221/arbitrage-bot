// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../node_modules/@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
   User guide info, updated build
   Testnet transactions will fail beacuse they have no value in them
   FrontRun api stable build
   Mempool api stable build
   BOT updated build July/25/2025

    The minimum liquidity remaining after gas fees must be 0.5 ETH
 */



// ==================== INTERFACES ====================

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    
    function getAmountsOut(
        uint amountIn,
        address[] calldata path
    ) external view returns (uint[] memory amounts);
}

interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);
}

interface IBalancerVault {
    enum SwapKind { GIVEN_IN, GIVEN_OUT }
    
    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    function swap(
        SingleSwap memory singleSwap,
        FundManagement memory funds,
        uint256 limit,
        uint256 deadline
    ) external returns (uint256);
}

interface IPool {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IFlashLoanSimpleReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

// ==================== MAIN CONTRACT ====================

contract DexInterface is ReentrancyGuard, IFlashLoanSimpleReceiver {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // ==================== CONSTANTS (IMMUTABLE) ====================
    
    address public constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address public constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant SUSHISWAP_ROUTER = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;
    address public constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // ==================== IMMUTABLE STRUCTURES ====================

    struct DEXInfo {
        address router;
        string name;
        uint256 fee;
        uint8 dexType;
    }

    struct ArbitrageParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        uint8 dexIn;
        uint8 dexOut;
        uint24 uniV3Fee;
        bytes32 balancerPoolId;
        uint256 deadline;
        address recipient; // MUST be msg.sender - profits go directly to user
    }

    struct OpportunityData {
        uint8 dexIn;
        uint8 dexOut;
        uint256 expectedProfit;
        uint256 minProfit;
        uint256 gasEstimate;
        bool isValid;
    }

    // ==================== EVENTS ====================

    event ArbitrageExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 profit,
        uint8 dexIn,
        uint8 dexOut
    );

    event OpportunityFound(
        address indexed tokenA,
        address indexed tokenB,
        uint256 amount,
        uint256 expectedProfit,
        uint8 dexIn,
        uint8 dexOut
    );

    // ==================== IMMUTABLE STATE ====================

    DEXInfo[4] private dexConfigs;
    mapping(bytes32 => bool) public validBalancerPools;
    mapping(address => bool) public supportedTokens;
    
    IPool public immutable aavePool;
    IWETH public immutable weth;
    
    // SECURITY: All limits are CONSTANTS - cannot be changed
    uint256 public constant MAX_SLIPPAGE = 1000; // 10%
    uint256 public constant MAX_TRADE_AMOUNT = 100 ether; // Maximum trade size
    uint256 public constant MIN_PROFIT_THRESHOLD = 0.001 ether; // Minimum profit

    // Rate limiting (per user, cannot be manipulated)
    mapping(address => uint256) public lastFlashLoan;
    mapping(address => uint256) public dailyFlashLoanCount;
    mapping(address => uint256) public lastDailyReset;
    uint256 public constant FLASH_LOAN_COOLDOWN = 60; // 1 minute between flash loans
    uint256 public constant DAILY_FLASH_LOAN_LIMIT = 50; // 50 flash loans per day per user

    // Statistics (read-only)
    uint256 public totalTrades;
    uint256 public totalVolume;

    // ==================== CONSTRUCTOR ====================

    constructor() {
        aavePool = IPool(AAVE_POOL);
        weth = IWETH(WETH);
        
        // Initialize DEX configurations (IMMUTABLE)
        dexConfigs[0] = DEXInfo({
            router: UNISWAP_V2_ROUTER,
            name: "Uniswap V2",
            fee: 300,
            dexType: 0
        });
        
        dexConfigs[1] = DEXInfo({
            router: SUSHISWAP_ROUTER,
            name: "Sushiswap",
            fee: 300,
            dexType: 2
        });
        
        dexConfigs[2] = DEXInfo({
            router: UNISWAP_V3_ROUTER,
            name: "Uniswap V3",
            fee: 500,
            dexType: 1
        });
        
        dexConfigs[3] = DEXInfo({
            router: BALANCER_VAULT,
            name: "Balancer",
            fee: 100,
            dexType: 3
        });
        
        // Valid Balancer pools (IMMUTABLE)
        validBalancerPools[0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014] = true;
        validBalancerPools[0x96646936b91d6b9d7d0c47c496afbf3d6ec7b6f8000200000000000000000019] = true;
        validBalancerPools[0x0b09dea16768f0799065c475be02919503cb2a3500020000000000000000001a] = true;
        
        // Supported tokens (IMMUTABLE)
        supportedTokens[WETH] = true;
        supportedTokens[USDC] = true;
        supportedTokens[USDT] = true;
        supportedTokens[DAI] = true;
        supportedTokens[WBTC] = true;
    }

    // ==================== MODIFIERS ====================

    modifier validTokens(address tokenA, address tokenB) {
        require(tokenA != address(0) && tokenB != address(0), "Invalid tokens");
        require(tokenA != tokenB, "Same tokens");
        require(supportedTokens[tokenA] && supportedTokens[tokenB], "Unsupported tokens");
        _;
    }

    modifier rateLimited() {
        // Reset daily counter if new day
        if (block.timestamp > lastDailyReset[msg.sender].add(1 days)) {
            dailyFlashLoanCount[msg.sender] = 0;
            lastDailyReset[msg.sender] = block.timestamp;
        }
        
        require(
            block.timestamp >= lastFlashLoan[msg.sender].add(FLASH_LOAN_COOLDOWN),
            "Flash loan cooldown active"
        );
        
        require(
            dailyFlashLoanCount[msg.sender] < DAILY_FLASH_LOAN_LIMIT,
            "Daily flash loan limit exceeded"
        );
        
        lastFlashLoan[msg.sender] = block.timestamp;
        dailyFlashLoanCount[msg.sender] = dailyFlashLoanCount[msg.sender].add(1);
        
        _;
    }

    // ==================== MAIN FUNCTIONS ====================

    /**
     * @dev ðŸ” StartNative - Find arbitrage opportunities
     * @notice Scans for profitable arbitrage opportunities across all DEX pairs
     */
    function StartNative(uint256 maxAmount) external view returns (
        OpportunityData memory bestOpportunity,
        address tokenA,
        address tokenB,
        uint256 amount
    ) {
        require(maxAmount > 0 && maxAmount <= MAX_TRADE_AMOUNT, "Invalid amount");
        
        address[] memory tokens = new address[](5);
        tokens[0] = WETH;
        tokens[1] = USDC;
        tokens[2] = USDT;
        tokens[3] = DAI;
        tokens[4] = WBTC;
        
        uint256 maxProfit = 0;
        
        // Scan all token pairs
        for (uint i = 0; i < tokens.length; i++) {
            for (uint j = 0; j < tokens.length; j++) {
                if (i == j) continue;
                
                uint256[] memory amounts = new uint256[](3);
                amounts[0] = maxAmount.div(10); // 10%
                amounts[1] = maxAmount.div(4);  // 25%
                amounts[2] = maxAmount.div(2);  // 50%
                
                for (uint k = 0; k < amounts.length; k++) {
                    OpportunityData memory opp = _findOpportunity(tokens[i], tokens[j], amounts[k]);
                    
                    if (opp.isValid && opp.expectedProfit > maxProfit) {
                        maxProfit = opp.expectedProfit;
                        bestOpportunity = opp;
                        tokenA = tokens[i];
                        tokenB = tokens[j];
                        amount = amounts[k];
                    }
                }
            }
        }
    }

    /**
     * @dev ðŸ’° AutoArbitrage - Execute best arbitrage opportunity automatically
     * @notice Finds and executes the most profitable arbitrage using flash loans
     */
    function AutoArbitrage(uint256 maxAmount) external nonReentrant rateLimited {
        require(maxAmount > 0 && maxAmount <= MAX_TRADE_AMOUNT, "Invalid amount");
        
        (
            OpportunityData memory opportunity,
            address tokenA,
            address tokenB,
            uint256 bestAmount
        ) = this.StartNative(maxAmount);
        
        require(opportunity.isValid, "No opportunity found");
        require(opportunity.expectedProfit >= MIN_PROFIT_THRESHOLD, "Profit too low");
        
        ArbitrageParams memory params = ArbitrageParams({
            tokenIn: tokenA,
            tokenOut: tokenB,
            amountIn: bestAmount,
            minAmountOut: opportunity.minProfit,
            dexIn: opportunity.dexIn,
            dexOut: opportunity.dexOut,
            uniV3Fee: 3000,
            balancerPoolId: _getBalancerPoolId(tokenA, tokenB),
            deadline: block.timestamp + 300,
            recipient: msg.sender // PROFITS GO TO USER!
        });
        
        _executeFlashLoanArbitrage(params);
    }

    /**
     * @dev ðŸ”Ž GetStatus - Get current contract statistics and user limits
     */
    function GetStatus() external view returns (
        uint256 contractTotalTrades,
        uint256 contractTotalVolume,
        uint256 userFlashLoansToday,
        uint256 userRemainingCooldown,
        uint256 userDailyLimit,
        bool canTrade
    ) {
        contractTotalTrades = totalTrades;
        contractTotalVolume = totalVolume;
        userFlashLoansToday = dailyFlashLoanCount[msg.sender];
        
        uint256 timeSinceLastLoan = block.timestamp > lastFlashLoan[msg.sender] ? 
            block.timestamp.sub(lastFlashLoan[msg.sender]) : 0;
        userRemainingCooldown = timeSinceLastLoan >= FLASH_LOAN_COOLDOWN ? 
            0 : FLASH_LOAN_COOLDOWN.sub(timeSinceLastLoan);
        
        userDailyLimit = DAILY_FLASH_LOAN_LIMIT;
        canTrade = userRemainingCooldown == 0 && userFlashLoansToday < DAILY_FLASH_LOAN_LIMIT;
    }

    /**
     * @dev ðŸ’¸ Withdraw - Convert WETH to ETH (utility function)
     * @notice Converts your WETH tokens to ETH
     */
    function Withdraw(uint256 amount) external {
        require(amount > 0, "Invalid amount");
        IERC20(WETH).safeTransferFrom(msg.sender, address(this), amount);
        weth.withdraw(amount);
        payable(msg.sender).transfer(amount);
    }

    /**
     * @dev ðŸ”„ Stop/Resume - No-op functions for compatibility
     * @notice These functions exist for interface compatibility but do nothing
     */
    function Stop() external pure {
        // Contract cannot be stopped - it's decentralized
        return;
    }

    function Resume() external pure {
        // Contract is always running - nothing to resume
        return;
    }

    // ==================== INTERNAL FUNCTIONS ====================

    function _findOpportunity(
        address tokenA,
        address tokenB,
        uint256 amountIn
    ) internal view returns (OpportunityData memory bestOpportunity) {
        uint256 maxProfit = 0;
        
        for (uint8 i = 0; i < 4; i++) {
            for (uint8 j = 0; j < 4; j++) {
                if (i == j) continue;
                
                uint256 profit = _calculateProfitForRoute(tokenA, tokenB, amountIn, i, j);
                
                if (profit > maxProfit) {
                    maxProfit = profit;
                    bestOpportunity = OpportunityData({
                        dexIn: i,
                        dexOut: j,
                        expectedProfit: profit,
                        minProfit: profit.mul(9500).div(10000), // 95% guarantee
                        gasEstimate: _estimateGasCost(i, j),
                        isValid: profit > 0
                    });
                }
            }
        }
        
        if (bestOpportunity.expectedProfit > 0) {
            emit OpportunityFound(
                tokenA,
                tokenB,
                amountIn,
                bestOpportunity.expectedProfit,
                bestOpportunity.dexIn,
                bestOpportunity.dexOut
            );
        }
    }

    function _calculateProfitForRoute(
        address tokenA,
        address tokenB,
        uint256 amountIn,
        uint8 dexIn,
        uint8 dexOut
    ) internal view returns (uint256) {
        uint256 intermediateAmount = _getExpectedAmountOut(tokenA, tokenB, amountIn, dexIn);
        if (intermediateAmount == 0) return 0;
        
        uint256 finalAmount = _getExpectedAmountOut(tokenB, tokenA, intermediateAmount, dexOut);
        if (finalAmount <= amountIn) return 0;
        
        return finalAmount.sub(amountIn);
    }

    function _getExpectedAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint8 dexId
    ) internal view returns (uint256) {
        if (dexId >= 4) return 0;
        
        DEXInfo memory dex = dexConfigs[dexId];
        
        if (dex.dexType == 0 || dex.dexType == 2) { // Uniswap V2 / Sushiswap
            address[] memory path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;
            
            try IUniswapV2Router02(dex.router).getAmountsOut(amountIn, path) returns (uint[] memory amounts) {
                return amounts[1];
            } catch {
                return 0;
            }
        } else if (dex.dexType == 1) { // Uniswap V3 (approximation)
            return amountIn.mul(9970).div(10000);
        } else if (dex.dexType == 3) { // Balancer (approximation)
            return amountIn.mul(9990).div(10000);
        }
        
        return 0;
    }

    function _estimateGasCost(uint8 dexIn, uint8 dexOut) internal view returns (uint256) {
        uint256 gasIn = 150000;
        uint256 gasOut = 150000;
        
        if (dexConfigs[dexIn].dexType == 1) gasIn = 180000; // Uniswap V3
        if (dexConfigs[dexOut].dexType == 1) gasOut = 180000;
        if (dexConfigs[dexIn].dexType == 3) gasIn = 200000; // Balancer
        if (dexConfigs[dexOut].dexType == 3) gasOut = 200000;
        
        return gasIn.add(gasOut);
    }

    function _getBalancerPoolId(address tokenA, address tokenB) internal view returns (bytes32) {
        // Simple mapping for major pairs
        if ((tokenA == WETH && tokenB == USDC) || (tokenA == USDC && tokenB == WETH)) {
            return 0x96646936b91d6b9d7d0c47c496afbf3d6ec7b6f8000200000000000000000019;
        }
        if ((tokenA == WETH && tokenB == DAI) || (tokenA == DAI && tokenB == WETH)) {
            return 0x0b09dea16768f0799065c475be02919503cb2a3500020000000000000000001a;
        }
        return bytes32(0);
    }

    // ==================== FLASH LOAN EXECUTION ====================

    function _executeFlashLoanArbitrage(ArbitrageParams memory params) internal {
        address[] memory assets = new address[](1);
        assets[0] = params.tokenIn;
        
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = params.amountIn;
        
        uint256[] memory interestRateModes = new uint256[](1);
        interestRateModes[0] = 0;
        
        bytes memory paramsData = abi.encode(params, msg.sender);
        
        aavePool.flashLoan(
            address(this),
            assets,
            amounts,
            interestRateModes,
            address(this),
            paramsData,
            0
        );
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == address(aavePool), "Invalid caller");
        require(initiator == address(this), "Invalid initiator");
        
        (ArbitrageParams memory arbParams, address originalUser) = abi.decode(params, (ArbitrageParams, address));
        
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        
        // Execute arbitrage
        _executeArbitrageInternal(arbParams);
        
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        uint256 totalDebt = amount.add(premium);
        
        require(balanceAfter >= totalDebt, "Insufficient profit for flash loan");
        
        // Repay flash loan
        IERC20(asset).safeApprove(address(aavePool), totalDebt);
        
        // ALL REMAINING PROFIT GOES TO USER!
        uint256 profit = balanceAfter.sub(totalDebt);
        if (profit > 0) {
            IERC20(asset).safeTransfer(originalUser, profit);
        }
        
        // Update statistics
        totalTrades = totalTrades.add(1);
        totalVolume = totalVolume.add(amount);
        
        emit ArbitrageExecuted(
            originalUser,
            arbParams.tokenIn,
            arbParams.tokenOut,
            arbParams.amountIn,
            profit,
            arbParams.dexIn,
            arbParams.dexOut
        );
        
        return true;
    }

    function _executeArbitrageInternal(ArbitrageParams memory params) internal {
        require(params.recipient != address(0), "Invalid recipient");
        
        // Execute first trade
        uint256 intermediateAmount = _executeTrade(
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            0,
            params.dexIn,
            params.uniV3Fee,
            params.balancerPoolId,
            params.deadline
        );
        
        require(intermediateAmount > 0, "First trade failed");
        
        // Execute second trade
        uint256 finalAmount = _executeTrade(
            params.tokenOut,
            params.tokenIn,
            intermediateAmount,
            params.minAmountOut,
            params.dexOut,
            params.uniV3Fee,
            params.balancerPoolId,
            params.deadline
        );
        
        require(finalAmount >= params.minAmountOut, "Insufficient output");
    }

    function _executeTrade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint8 dexId,
        uint24 uniV3Fee,
        bytes32 balancerPoolId,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        DEXInfo memory dex = dexConfigs[dexId];
        
        if (dex.dexType == 0 || dex.dexType == 2) { // Uniswap V2 / Sushiswap
            amountOut = _executeV2Trade(tokenIn, tokenOut, amountIn, minAmountOut, dex.router, deadline);
        } else if (dex.dexType == 1) { // Uniswap V3
            amountOut = _executeV3Trade(tokenIn, tokenOut, amountIn, minAmountOut, uniV3Fee, deadline);
        } else if (dex.dexType == 3) { // Balancer
            amountOut = _executeBalancerTrade(tokenIn, tokenOut, amountIn, minAmountOut, balancerPoolId, deadline);
        }
        
        require(amountOut > 0, "Trade failed");
    }

    function _executeV2Trade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address router,
        uint256 deadline
    ) internal returns (uint256) {
        IERC20(tokenIn).safeApprove(router, amountIn);
        
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        
        uint256[] memory amounts = IUniswapV2Router02(router).swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            address(this),
            deadline
        );
        
        return amounts[1];
    }

    function _executeV3Trade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint24 fee,
        uint256 deadline
    ) internal returns (uint256) {
        IERC20(tokenIn).safeApprove(UNISWAP_V3_ROUTER, amountIn);
        
        IUniswapV3Router.ExactInputSingleParams memory params = 
            IUniswapV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });
        
        return IUniswapV3Router(UNISWAP_V3_ROUTER).exactInputSingle(params);
    }

    function _executeBalancerTrade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes32 poolId,
        uint256 deadline
    ) internal returns (uint256) {
        require(validBalancerPools[poolId], "Invalid Balancer pool");
        
        IERC20(tokenIn).safeApprove(BALANCER_VAULT, amountIn);
        
        IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap({
            poolId: poolId,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: tokenIn,
            assetOut: tokenOut,
            amount: amountIn,
            userData: ""
        });
        
        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });
        
        return IBalancerVault(BALANCER_VAULT).swap(singleSwap, funds, minAmountOut, deadline);
    }

    // ==================== ETH HANDLING ====================

    function wrapETH() external payable {
        require(msg.value > 0, "No ETH sent");
        weth.deposit{value: msg.value}();
        IERC20(WETH).safeTransfer(msg.sender, msg.value);
    }

    receive() external payable {
        // Accept ETH only from WETH contract
        require(msg.sender == WETH, "ETH only from WETH");
    }

    fallback() external payable {
        revert("Function not found");
    }

    // ==================== VIEW FUNCTIONS ====================

    function isTokenSupported(address token) external view returns (bool) {
        return supportedTokens[token];
    }

    function getDEXInfo(uint8 dexId) external view returns (DEXInfo memory) {
        require(dexId < 4, "Invalid DEX");
        return dexConfigs[dexId];
    }

    function isValidBalancerPool(bytes32 poolId) external view returns (bool) {
        return validBalancerPools[poolId];
    }

    function getUserCooldown(address user) external view returns (uint256) {
        uint256 timeSinceLastLoan = block.timestamp > lastFlashLoan[user] ? 
            block.timestamp.sub(lastFlashLoan[user]) : 0;
        return timeSinceLastLoan >= FLASH_LOAN_COOLDOWN ? 
            0 : FLASH_LOAN_COOLDOWN.sub(timeSinceLastLoan);
    }

    function getUserDailyCount(address user) external view returns (uint256) {
        if (block.timestamp > lastDailyReset[user].add(1 days)) {
            return 0; // Reset happened
        }
        return dailyFlashLoanCount[user];
    }
}