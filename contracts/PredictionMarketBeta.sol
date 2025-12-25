// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * Internal Beta Prediction Market
 *
 * Design goals:
 * - Minimal, workable on-chain primitive to support a Polymarket-like UI
 * - USDC used as the unit of account and collateral
 * - Simple constant-product AMM between YES and NO shares
 *
 * Core mechanics:
 * - Minting a complete set: deposit 1 USDC => receive 1 YES + 1 NO share (in 1e18 share units)
 * - Swapping: swap YES<->NO against an AMM pool
 * - Exit before resolution: burn equal YES+NO pairs => withdraw USDC 1:1
 * - After resolution: winning shares redeem 1 USDC per share, losing shares redeem 0
 *
 * IMPORTANT: This is an internal beta contract. It is not designed for production.
 */

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function decimals() external view returns (uint8);
}

library SafeTransfer {
    function safeTransfer(IERC20Like token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeWithSelector(token.transfer.selector, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAILED");
    }

    function safeTransferFrom(IERC20Like token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeWithSelector(token.transferFrom.selector, from, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }
}

contract OwnableLite {
    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "BAD_OWNER");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

contract PredictionMarketBeta is OwnableLite {
    using SafeTransfer for IERC20Like;

    enum Side {
        YES,
        NO
    }

    struct Market {
        string question;
        uint64 closeTime;
        uint64 resolveAfter;
        bool resolved;
        Side outcome;
        uint16 feeBps; // swap fee (e.g., 35 = 0.35%)
        uint256 collateralUSDC; // total USDC backing the market
        uint256 yesReserve; // AMM reserves in shares (1e18)
        uint256 noReserve; // AMM reserves in shares (1e18)
        address creator;
    }

    IERC20Like public immutable usdc;
    uint8 public immutable usdcDecimals;
    address public feeRecipient;

    uint256 public marketCount;
    mapping(uint256 => Market) public markets;

    // balances[marketId][user] => shares (1e18)
    mapping(uint256 => mapping(address => uint256)) public yesBalance;
    mapping(uint256 => mapping(address => uint256)) public noBalance;

    event MarketCreated(uint256 indexed marketId, string question, uint64 closeTime, uint64 resolveAfter, uint256 seedUSDC, uint16 feeBps);
    event MintedSet(address indexed user, uint256 indexed marketId, uint256 usdcAmount, uint256 shares);
    event Swapped(address indexed user, uint256 indexed marketId, Side fromSide, uint256 inShares, uint256 outShares, uint256 feeShares);
    event RedeemedPairs(address indexed user, uint256 indexed marketId, uint256 pairs, uint256 usdcOut);
    event MarketResolved(uint256 indexed marketId, Side outcome);
    event RedeemedWinner(address indexed user, uint256 indexed marketId, Side side, uint256 shares, uint256 usdcOut);

    error MarketClosed();
    error MarketNotResolved();
    error MarketAlreadyResolved();
    error InvalidParams();
    error InvalidTime();
    error Slippage();

    constructor(IERC20Like _usdc, address _feeRecipient) {
        usdc = _usdc;
        usdcDecimals = _usdc.decimals();
        feeRecipient = _feeRecipient;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "BAD_RECIPIENT");
        feeRecipient = newRecipient;
    }

    /// @notice Create a market and seed the AMM pool.
    /// @param seedUSDC Seed collateral (in USDC units) that will be converted to seed shares for both YES and NO reserves.
    function createMarket(
        string calldata question,
        uint64 closeTime,
        uint64 resolveAfter,
        uint256 seedUSDC,
        uint16 feeBps
    ) external returns (uint256 marketId) {
        if (closeTime <= block.timestamp || resolveAfter < closeTime) revert InvalidTime();
        if (seedUSDC == 0 || feeBps > 1000) revert InvalidParams();

        marketId = ++marketCount;
        Market storage m = markets[marketId];
        m.question = question;
        m.closeTime = closeTime;
        m.resolveAfter = resolveAfter;
        m.resolved = false;
        m.outcome = Side.YES;
        m.feeBps = feeBps;
        m.creator = msg.sender;

        // Pull seed collateral
        usdc.safeTransferFrom(msg.sender, address(this), seedUSDC);
        m.collateralUSDC = seedUSDC;

        // Convert seed collateral to seed shares in 1e18 units
        uint256 seedShares = _usdcToShares(seedUSDC);
        m.yesReserve = seedShares;
        m.noReserve = seedShares;

        emit MarketCreated(marketId, question, closeTime, resolveAfter, seedUSDC, feeBps);
    }

    /// @notice Mint a complete set: deposit USDC and receive equal YES and NO shares.
    function mintSet(uint256 marketId, uint256 usdcAmount) public {
        Market storage m = markets[marketId];
        if (block.timestamp >= m.closeTime) revert MarketClosed();
        if (m.resolved) revert MarketAlreadyResolved();
        if (usdcAmount == 0) revert InvalidParams();

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        m.collateralUSDC += usdcAmount;

        uint256 shares = _usdcToShares(usdcAmount);
        yesBalance[marketId][msg.sender] += shares;
        noBalance[marketId][msg.sender] += shares;

        emit MintedSet(msg.sender, marketId, usdcAmount, shares);
    }

    /// @notice Buy YES using USDC: mint a complete set and swap all freshly minted NO into YES.
    function buyYesWithUSDC(uint256 marketId, uint256 usdcAmount, uint256 minYesOut) external {
        uint256 beforeNo = noBalance[marketId][msg.sender];
        mintSet(marketId, usdcAmount);
        uint256 mintedNo = noBalance[marketId][msg.sender] - beforeNo;
        uint256 out = swap(marketId, Side.NO, mintedNo, minYesOut);
        out;
    }

    /// @notice Buy NO using USDC: mint a complete set and swap all freshly minted YES into NO.
    function buyNoWithUSDC(uint256 marketId, uint256 usdcAmount, uint256 minNoOut) external {
        uint256 beforeYes = yesBalance[marketId][msg.sender];
        mintSet(marketId, usdcAmount);
        uint256 mintedYes = yesBalance[marketId][msg.sender] - beforeYes;
        uint256 out = swap(marketId, Side.YES, mintedYes, minNoOut);
        out;
    }

    /// @notice Swap YES<->NO against the constant-product pool.
    function swap(uint256 marketId, Side fromSide, uint256 inShares, uint256 minOutShares) public returns (uint256 outShares) {
        Market storage m = markets[marketId];
        if (block.timestamp >= m.closeTime) revert MarketClosed();
        if (m.resolved) revert MarketAlreadyResolved();
        if (inShares == 0) revert InvalidParams();

        // pull from user balances
        if (fromSide == Side.YES) {
            require(yesBalance[marketId][msg.sender] >= inShares, "INSUFFICIENT_YES");
            yesBalance[marketId][msg.sender] -= inShares;
        } else {
            require(noBalance[marketId][msg.sender] >= inShares, "INSUFFICIENT_NO");
            noBalance[marketId][msg.sender] -= inShares;
        }

        // fee stays in pool
        uint256 feeShares = (inShares * m.feeBps) / 10_000;
        uint256 inWithFee = inShares - feeShares;

        uint256 reserveIn = (fromSide == Side.YES) ? m.yesReserve : m.noReserve;
        uint256 reserveOut = (fromSide == Side.YES) ? m.noReserve : m.yesReserve;

        outShares = (reserveOut * inWithFee) / (reserveIn + inWithFee);
        if (outShares < minOutShares) revert Slippage();

        if (fromSide == Side.YES) {
            m.yesReserve = reserveIn + inShares;
            m.noReserve = reserveOut - outShares;
            noBalance[marketId][msg.sender] += outShares;
        } else {
            m.noReserve = reserveIn + inShares;
            m.yesReserve = reserveOut - outShares;
            yesBalance[marketId][msg.sender] += outShares;
        }

        emit Swapped(msg.sender, marketId, fromSide, inShares, outShares, feeShares);
    }

    /// @notice Exit before resolution: burn equal YES+NO pairs and withdraw USDC 1:1.
    function redeemPairs(uint256 marketId, uint256 pairsShares) external {
        Market storage m = markets[marketId];
        if (block.timestamp >= m.closeTime) revert MarketClosed();
        if (m.resolved) revert MarketAlreadyResolved();
        if (pairsShares == 0) revert InvalidParams();

        require(yesBalance[marketId][msg.sender] >= pairsShares, "INSUFFICIENT_YES");
        require(noBalance[marketId][msg.sender] >= pairsShares, "INSUFFICIENT_NO");

        yesBalance[marketId][msg.sender] -= pairsShares;
        noBalance[marketId][msg.sender] -= pairsShares;

        uint256 usdcOut = _sharesToUSDC(pairsShares);
        require(m.collateralUSDC >= usdcOut, "INSUFFICIENT_COLLATERAL");
        m.collateralUSDC -= usdcOut;

        usdc.safeTransfer(msg.sender, usdcOut);
        emit RedeemedPairs(msg.sender, marketId, pairsShares, usdcOut);
    }

    /// @notice Resolve the market outcome (internal beta: owner only).
    function resolve(uint256 marketId, Side outcome) external onlyOwner {
        Market storage m = markets[marketId];
        if (m.resolved) revert MarketAlreadyResolved();
        if (block.timestamp < m.resolveAfter) revert InvalidTime();
        m.resolved = true;
        m.outcome = outcome;
        emit MarketResolved(marketId, outcome);
    }

    /// @notice Redeem winning shares after resolution.
    function redeemWinner(uint256 marketId, uint256 shares) external {
        Market storage m = markets[marketId];
        if (!m.resolved) revert MarketNotResolved();
        if (shares == 0) revert InvalidParams();

        if (m.outcome == Side.YES) {
            require(yesBalance[marketId][msg.sender] >= shares, "INSUFFICIENT_YES");
            yesBalance[marketId][msg.sender] -= shares;
        } else {
            require(noBalance[marketId][msg.sender] >= shares, "INSUFFICIENT_NO");
            noBalance[marketId][msg.sender] -= shares;
        }

        uint256 usdcOut = _sharesToUSDC(shares);
        require(m.collateralUSDC >= usdcOut, "INSUFFICIENT_COLLATERAL");
        m.collateralUSDC -= usdcOut;

        usdc.safeTransfer(msg.sender, usdcOut);
        emit RedeemedWinner(msg.sender, marketId, m.outcome, shares, usdcOut);
    }

    /// @notice View helper: implied probability from AMM reserves.
    function getPrices(uint256 marketId) external view returns (uint256 priceYes1e18, uint256 priceNo1e18) {
        Market storage m = markets[marketId];
        uint256 sum = m.yesReserve + m.noReserve;
        if (sum == 0) return (5e17, 5e17);
        priceYes1e18 = (m.noReserve * 1e18) / sum;
        priceNo1e18 = (m.yesReserve * 1e18) / sum;
    }

    function _usdcToShares(uint256 usdcAmount) internal view returns (uint256) {
        if (usdcDecimals == 18) return usdcAmount;
        if (usdcDecimals < 18) {
            uint256 factor = 10 ** (18 - usdcDecimals);
            return usdcAmount * factor;
        }
        uint256 div = 10 ** (usdcDecimals - 18);
        return usdcAmount / div;
    }

    function _sharesToUSDC(uint256 shares) internal view returns (uint256) {
        if (usdcDecimals == 18) return shares;
        if (usdcDecimals < 18) {
            uint256 factor = 10 ** (18 - usdcDecimals);
            return shares / factor;
        }
        uint256 mul = 10 ** (usdcDecimals - 18);
        return shares * mul;
    }
}

/// @dev Minimal mintable USDC-like token for local testing.
contract MockUSDC is OwnableLite {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOWANCE");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "BAD_TO");
        uint256 bal = balanceOf[from];
        require(bal >= amount, "BALANCE");
        balanceOf[from] = bal - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
