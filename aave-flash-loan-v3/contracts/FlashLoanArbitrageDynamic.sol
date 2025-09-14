// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

// Import Aave v3 flash loan base contract for handling flash loans
import {FlashLoanSimpleReceiverBase} from "@aave/core-v3/contracts/flashloan/base/FlashLoanSimpleReceiverBase.sol";
// Import interface for Aave pool addresses provider
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
// Import ERC20 interface for token interactions
import {IERC20} from "@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
// Import WETH interface (used for WBNB on BSC)
import {IWETH} from "@aave/core-v3/contracts/misc/interfaces/IWETH.sol";
// Import SafeERC20 for secure token transfers (handles fee-on-transfer)
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// Import ReentrancyGuard to prevent reentrancy attacks
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Interface for PancakeSwap V2 router to perform token swaps
interface IPancakeRouter {
    // Function to swap exact tokens for tokens along a path
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    // Function to get expected output amounts for a swap
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

// Interface for ERC20 with decimals (for validation)
interface IERC20WithDecimals is IERC20 {
    function decimals() external view returns (uint8);
}

// Main contract for dynamic arbitrage using Aave flash loans and PancakeSwap
contract FlashLoanArbitrageDynamic is FlashLoanSimpleReceiverBase, ReentrancyGuard {
    using SafeERC20 for IERC20;  // Use SafeERC20 for all token transfers

    // Owner of the contract (can withdraw funds and request loans)
    address payable owner;
    // Address of WBNB token (wrapped BNB for ERC20 compatibility)
    address public wbnbAddress;
    // Address of PancakeSwap V2 router for swaps
    address public pancakeRouterAddress;
    // Slippage tolerance (e.g., 5 for 5%, configurable)
    uint256 public slippageTolerance;  // In basis points (e.g., 500 = 5%)
    // Minimum profit threshold (in wei, to ensure profitability)
    uint256 public minProfit;

    // Instance of WBNB token for interactions
    IWETH private wbnb;
    // Instance of PancakeSwap router for swaps
    IPancakeRouter private pancakeRouter;

    // Events for transparency
    event FlashLoanExecuted(address indexed asset, uint256 amount, uint256 premium);
    event ArbitrageSuccess(address indexed targetToken, uint256 profit);
    event Withdrawal(address indexed token, uint256 amount);

    // Constructor to initialize the contract with necessary addresses
    constructor(
        address _addressProvider,  // Aave pool addresses provider
        address _wbnb,             // WBNB token address
        address _pancakeRouter,    // PancakeSwap router address
        uint256 _slippageTolerance, // Slippage tolerance in basis points
        uint256 _minProfit         // Minimum profit in wei
    ) FlashLoanSimpleReceiverBase(IPoolAddressesProvider(_addressProvider)) {
        owner = payable(msg.sender);  // Set deployer as owner
        wbnbAddress = _wbnb;
        pancakeRouterAddress = _pancakeRouter;
        slippageTolerance = _slippageTolerance;
        minProfit = _minProfit;
        wbnb = IWETH(_wbnb);  // Initialize WBNB instance
        pancakeRouter = IPancakeRouter(_pancakeRouter);  // Initialize router instance
    }

    // Function called by Aave after the flash loan is received
    // Performs arbitrage: borrow WBNB -> swap to target token -> swap back to WBNB -> repay
    function executeOperation(
        address asset,        // The borrowed asset (should be WBNB)
        uint256 amount,       // Amount borrowed
        uint256 premium,      // Fee charged by Aave
        address initiator,    // Address that initiated the loan
        bytes calldata params // Encoded parameters (target token, min output, deadline)
    ) external override nonReentrant returns (bool) {
        // Ensure only WBNB is borrowed for this arbitrage strategy
        require(asset == wbnbAddress, "Only WBNB flash loans supported");

        // Decode the parameters: target token to arbitrage, minimum output for buy swap, deadline
        (address targetToken, uint256 minOut, uint256 deadline) = abi.decode(params, (address, uint256, uint256));
        require(block.timestamp <= deadline, "Transaction deadline exceeded");

        // Validate targetToken: check if it's a standard ERC20 with decimals
        require(IERC20WithDecimals(targetToken).decimals() > 0, "Invalid target token");

        // Step 1: Swap borrowed WBNB to the target token on PancakeSwap
        // Create swap path: WBNB -> Target Token
        address[] memory pathToToken = new address[](2);
        pathToToken[0] = wbnbAddress;
        pathToToken[1] = targetToken;

        // Approve PancakeSwap to spend WBNB using SafeERC20
        IERC20(wbnbAddress).safeApprove(pancakeRouterAddress, amount);
        // Perform the swap
        pancakeRouter.swapExactTokensForTokens(
            amount,           // Input amount
            minOut,           // Minimum output
            pathToToken,      // Swap path
            address(this),    // Receive tokens here
            deadline          // Deadline
        );

        // Step 2: Swap the received target token back to WBNB
        // Get balance of target token after swap
        uint256 tokenBalance = IERC20(targetToken).balanceOf(address(this));
        // Create swap path: Target Token -> WBNB
        address[] memory pathToWbnb = new address[](2);
        pathToWbnb[0] = targetToken;
        pathToWbnb[1] = wbnbAddress;

        // Get expected output for sell swap
        uint256[] memory amountsOutSell = pancakeRouter.getAmountsOut(tokenBalance, pathToWbnb);
        // Set minimum output with configurable slippage tolerance
        uint256 minOutSell = amountsOutSell[1] * (10000 - slippageTolerance) / 10000;

        // Approve PancakeSwap to spend target token using SafeERC20
        IERC20(targetToken).safeApprove(pancakeRouterAddress, tokenBalance);
        // Perform the sell swap
        pancakeRouter.swapExactTokensForTokens(
            tokenBalance,     // Input amount
            minOutSell,       // Minimum output
            pathToWbnb,       // Swap path
            address(this),    // Receive WBNB here
            deadline          // Deadline
        );

        // Check if we have enough WBNB to repay the loan + premium and ensure profit
        uint256 finalWbnbBalance = IERC20(wbnbAddress).balanceOf(address(this));
        uint256 amountOwed = amount + premium;
        uint256 profit = finalWbnbBalance - amountOwed;
        require(finalWbnbBalance >= amountOwed + minProfit, "Insufficient profit or unable to repay loan");

        // Emit events
        emit FlashLoanExecuted(asset, amount, premium);
        emit ArbitrageSuccess(targetToken, profit);

        // Approve Aave pool to pull the owed amount using SafeERC20
        IERC20(asset).safeApprove(address(POOL), amountOwed);
        return true;  // Confirm successful execution
    }

    // Function to request a flash loan for arbitrage (owner-only)
    function requestFlashLoan(address _token, uint256 _amount, uint256 _minOut, uint256 _deadline) public onlyOwner {
        // Prevent arbitraging WBNB with itself
        require(_token != wbnbAddress, "Cannot arbitrage WBNB with itself");
        // Encode parameters for executeOperation
        bytes memory params = abi.encode(_token, _minOut, _deadline);
        // Request flash loan from Aave (borrowing WBNB)
        POOL.flashLoanSimple(address(this), wbnbAddress, _amount, params, 0);
    }

    // View function to check contract's balance of a token
    function getBalance(address _tokenAddress) external view returns (uint256) {
        return IERC20(_tokenAddress).balanceOf(address(this));
    }

    // Function to withdraw tokens from the contract (owner-only)
    function withdraw(address _tokenAddress) external onlyOwner {
        if (_tokenAddress == wbnbAddress) {
            // Unwrap WBNB to ETH and send to owner
            uint256 balance = wbnb.balanceOf(address(this));
            wbnb.withdraw(balance);
            payable(owner).transfer(balance);
            emit Withdrawal(_tokenAddress, balance);
        } else {
            // Withdraw ERC20 token
            IERC20 token = IERC20(_tokenAddress);
            uint256 balance = token.balanceOf(address(this));
            token.safeTransfer(owner, balance);
            emit Withdrawal(_tokenAddress, balance);
        }
    }

    // Function to manually repay a flash loan if needed (emergency)
    function repayLoan(address asset, uint256 amount, uint256 premium) external onlyOwner {
        uint256 amountOwed = amount + premium;
        require(IERC20(asset).balanceOf(address(this)) >= amountOwed, "Insufficient balance to repay");
        IERC20(asset).safeApprove(address(POOL), amountOwed);
        // Note: This is a simplified repay; in practice, use POOL.repay or similar
    }

    // Modifier to restrict functions to owner only
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this");
        _;
    }

    // Fallback function to receive ETH (if needed, though not used here)
    receive() external payable {}
}
