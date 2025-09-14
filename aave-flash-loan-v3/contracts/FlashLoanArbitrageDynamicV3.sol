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

// Interface for PancakeSwap V3 router to perform token swaps
interface IPancakeRouterV3 {
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

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

// Main contract for dynamic arbitrage using Aave flash loans and PancakeSwap V3
contract FlashLoanArbitrageDynamicV3 is FlashLoanSimpleReceiverBase {
    // Owner of the contract (can withdraw funds and request loans)
    address payable owner;
    // Address of WBNB token (wrapped BNB for ERC20 compatibility)
    address public wbnbAddress;
    // Address of PancakeSwap V3 router for swaps
    address public pancakeRouterV3Address;

    // Instance of WBNB token for interactions
    IWETH private wbnb;
    // Instance of PancakeSwap V3 router for swaps
    IPancakeRouterV3 private pancakeRouterV3;

    // Constructor to initialize the contract with necessary addresses
    constructor(
        address _addressProvider,     // Aave pool addresses provider
        address _wbnb,                // WBNB token address
        address _pancakeRouterV3      // PancakeSwap V3 router address
    ) FlashLoanSimpleReceiverBase(IPoolAddressesProvider(_addressProvider)) {
        owner = payable(msg.sender);  // Set deployer as owner
        wbnbAddress = _wbnb;
        pancakeRouterV3Address = _pancakeRouterV3;
        wbnb = IWETH(_wbnb);  // Initialize WBNB instance
        pancakeRouterV3 = IPancakeRouterV3(_pancakeRouterV3);  // Initialize V3 router instance
    }

    // Function called by Aave after the flash loan is received
    // Performs arbitrage: borrow WBNB -> swap to target token -> swap back to WBNB -> repay
    function executeOperation(
        address asset,        // The borrowed asset (should be WBNB)
        uint256 amount,       // Amount borrowed
        uint256 premium,      // Fee charged by Aave
        address initiator,    // Address that initiated the loan
        bytes calldata params // Encoded parameters (target token, fee, min output)
    ) external override returns (bool) {
        // Ensure only WBNB is borrowed for this arbitrage strategy
        require(asset == wbnbAddress, "Only WBNB flash loans supported");

        // Decode the parameters: target token, fee tier, and minimum output for buy swap
        (address targetToken, uint24 fee, uint256 minOut) = abi.decode(params, (address, uint24, uint256));

        // Step 1: Swap borrowed WBNB to the target token on PancakeSwap V3
        // Approve PancakeSwap V3 to spend WBNB
        IERC20(wbnbAddress).approve(pancakeRouterV3Address, amount);
        // Perform the swap using exactInputSingle
        uint256 amountOutBuy = pancakeRouterV3.exactInputSingle(
            IPancakeRouterV3.ExactInputSingleParams({
                tokenIn: wbnbAddress,
                tokenOut: targetToken,
                fee: fee,
                recipient: address(this),
                deadline: block.timestamp + 300,  // 5 minutes
                amountIn: amount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0  // No price limit
            })
        );

        // Step 2: Swap the received target token back to WBNB
        // Get balance of target token after swap
        uint256 tokenBalance = IERC20(targetToken).balanceOf(address(this));
        // Approve PancakeSwap V3 to spend target token
        IERC20(targetToken).approve(pancakeRouterV3Address, tokenBalance);
        // Set minimum output with 5% slippage tolerance
        uint256 minOutSell = (amountOutBuy * 95) / 100;  // Approximate based on buy output
        // Perform the sell swap
        pancakeRouterV3.exactInputSingle(
            IPancakeRouterV3.ExactInputSingleParams({
                tokenIn: targetToken,
                tokenOut: wbnbAddress,
                fee: fee,
                recipient: address(this),
                deadline: block.timestamp + 300,
                amountIn: tokenBalance,
                amountOutMinimum: minOutSell,
                sqrtPriceLimitX96: 0
            })
        );

        // Check if we have enough WBNB to repay the loan + premium
        uint256 finalWbnbBalance = IERC20(wbnbAddress).balanceOf(address(this));
        uint256 amountOwed = amount + premium;
        require(finalWbnbBalance >= amountOwed, "Insufficient WBNB to repay loan");

        // Approve Aave pool to pull the owed amount
        IERC20(asset).approve(address(POOL), amountOwed);
        return true;  // Confirm successful execution
    }

    // Function to request a flash loan for arbitrage (owner-only)
    function requestFlashLoan(address _token, uint256 _amount, uint24 _fee, uint256 _minOut) public onlyOwner {
        // Prevent arbitraging WBNB with itself
        require(_token != wbnbAddress, "Cannot arbitrage WBNB with itself");
        // Encode parameters for executeOperation
        bytes memory params = abi.encode(_token, _fee, _minOut);
        // Request flash loan from Aave (borrowing WBNB)
        POOL.flashLoanSimple(address(this), wbnbAddress, _amount, params, 0);
    }

    // View function to check contract's balance of a token
    function getBalance(address _tokenAddress) external view returns (uint256) {
        return IERC20(_tokenAddress).balanceOf(address(this));
    }

    // Function to withdraw tokens from the contract (owner-only)
    function withdraw(address _tokenAddress) external onlyOwner {
        IERC20 token = IERC20(_tokenAddress);
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }

    // Modifier to restrict functions to owner only
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this");
        _;
    }

    // Fallback function to receive ETH (if needed, though not used here)
    receive() external payable {}
}
