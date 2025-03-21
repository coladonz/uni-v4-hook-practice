// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import "v4-core/src/types/BeforeSwapDelta.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";

/// @title TanguHook
/// @author coladonz
/// @notice Hook for Uniswap V4
contract TanguHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using SafeERC20 for IERC20;

    Currency public immutable USDC = Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    Currency public immutable USDT = Currency.wrap(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    IAavePool public immutable aavePool;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    mapping(Currency => uint256) public devFeeAccrued;
    mapping(Currency => uint256) public totalFeeAccrued;

    mapping(Currency => IERC20) public aTokens;
    mapping(Currency => uint256) public totalATokenShares;

    mapping(Currency => mapping(address => UserInfo)) public userInfos;
    mapping(Currency => uint256) public rewardPerShare;
    mapping(Currency => uint256) public totalShares;

    error InvalidPoolTokens();
    event ClaimedFee(address indexed user, Currency currency, uint256 amount);
    event ClaimedDevFee(address indexed user, Currency currency, uint256 amount);

    constructor(IPoolManager _poolManager, IAavePool _pool) BaseHook(_poolManager) Ownable(msg.sender) {
        aavePool = _pool;

        IERC20(Currency.unwrap(USDC)).forceApprove(address(aavePool), type(uint256).max);
        IERC20(Currency.unwrap(USDT)).forceApprove(address(aavePool), type(uint256).max);
    }

    /// @notice Set the aToken for a given currency
    /// @param aToken The address of the aToken
    /// @param uToken The currency
    function setATokens(address aToken, Currency uToken) external onlyOwner {
        aTokens[uToken] = IERC20(aToken);
    }

    /// @notice Get the permissions for the hook
    /// @return The permissions for the hook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /// @notice Get the hook data for a given user
    /// @param user The address of the user
    /// @return The hook data for the user
    function getHookData(address user) public pure returns (bytes memory) {
        return abi.encode(user);
    }

    /// @notice Parse the hook data for a given user
    /// @param data The hook data
    /// @return user The address of the user
    function parseHookData(bytes calldata data) public pure returns (address user) {
        return abi.decode(data, (address));
    }

    /// @notice Get the pending rewards for a given user and currency
    /// @param user The address of the user
    /// @param currency The currency
    /// @return The pending rewards for the user and currency
    function pendingRewards(address user, Currency currency) public view returns (uint256) {
        UserInfo storage userInfo = userInfos[currency][user];
        uint256 reward = (userInfo.amount * rewardPerShare[currency]) / 1e18 - userInfo.rewardDebt;

        return reward;
    }

    /// @notice Get the pending rewards for a given user and currency in exact amount
    /// @param user The address of the user
    /// @param currency The currency
    /// @return The pending rewards for the user and currency in exact amount
    function pendingRewardExact(address user, Currency currency) external view returns (uint256) {
        uint share = pendingRewards(user, currency);
        uint256 reward = (share * _getATokenSharePrice(currency)) / 1e18;
        return reward;
    }

    /// @notice Claim the fee for a given user and currency
    /// @param currency The currency
    function claimFee(Currency currency) external {
        uint rewards = _claimFee(msg.sender, currency);
        _withdrawAave(rewards, msg.sender, currency);

        emit ClaimedFee(msg.sender, currency, rewards);
    }

    /// @notice Claim the dev fee for a given currency
    /// @param currency The currency
    function claimDevFee(Currency currency) external onlyOwner {
        uint rewards = devFeeAccrued[currency];
        devFeeAccrued[currency] = 0;
        _withdrawAave(rewards, owner(), currency);
        emit ClaimedDevFee(owner(), currency, rewards);
    }

    /// @notice Add rewards to the pool
    /// @param currency The currency
    /// @param amount The amount of rewards to add
    function _addRewards(Currency currency, uint256 amount) internal {
        rewardPerShare[currency] += (amount * 1e18) / totalShares[currency];
    }

    /// @notice Deposit funds into the pool
    /// @param user The address of the user
    /// @param amount The amount of funds to deposit
    /// @param currency The currency
    function _deposit(address user, uint amount, Currency currency) internal {
        UserInfo storage userInfo = userInfos[currency][user];
        userInfo.amount += amount;
        userInfo.rewardDebt += (amount * rewardPerShare[currency]) / 1e18;
        totalShares[currency] += amount;
    }

    /// @notice Claim the fee for a given user and currency
    /// @param user The address of the user
    /// @param currency The currency
    /// @return The amount of fee claimed
    function _claimFee(address user, Currency currency) internal returns (uint) {
        uint pendingReward = pendingRewards(user, currency);
        UserInfo storage userInfo = userInfos[currency][user];
        if (pendingReward > 0) {
            userInfo.rewardDebt = (userInfo.amount * rewardPerShare[currency]) / 1e18;
        }
        return pendingReward;
    }

    /// @notice Get the price of the aToken shares
    /// @param currency The currency
    /// @return The price of the aToken shares
    function _getATokenSharePrice(Currency currency) internal view returns (uint) {
        return (aTokens[currency].balanceOf(address(this)) * 1e18) / totalATokenShares[currency];
    }

    /// @notice Deposit funds into the aave pool
    /// @param share The amount of shares to deposit
    /// @param currency The currency
    function _depositAave(uint share, Currency currency) internal {
        totalATokenShares[currency] += share;
        aavePool.supply(Currency.unwrap(currency), share, address(this), 0);
    }

    /// @notice Withdraw funds from the aave pool
    /// @param share The amount of shares to withdraw
    /// @param to The address to withdraw to
    /// @param currency The currency
    /// @return The amount of funds withdrawn
    function _withdrawAave(uint share, address to, Currency currency) internal returns (uint) {
        uint amount = (share * _getATokenSharePrice(currency)) / 1e18;
        totalATokenShares[currency] -= share;
        return aavePool.withdraw(Currency.unwrap(currency), amount, to);
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    /// @notice Initialize the pool
    /// @param key The pool key
    /// @return The selector for the function
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (equals(key.currency0, USDC) && equals(key.currency1, USDT)) {
            return BaseHook.beforeInitialize.selector;
        }

        revert InvalidPoolTokens();
    }

    /// @notice Before swap hook
    /// @param swapParams The swap parameters
    /// @param hookData The hook data
    /// @return The selector for the function, the before swap delta, and the fee
    function _beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        address user = parseHookData(hookData);

        uint swapAmount = uint256(
            swapParams.amountSpecified > 0 ? swapParams.amountSpecified : -swapParams.amountSpecified
        );
        uint fee = swapAmount / 1000;
        Currency swapCurrency = swapParams.zeroForOne ? USDC : USDT;

        // Take Fee
        poolManager.take(swapCurrency, address(this), fee);
        _depositAave(fee, swapCurrency);

        // Update Fee, Deposit
        totalFeeAccrued[swapCurrency] += fee;
        devFeeAccrued[swapCurrency] += fee / 2;
        _deposit(user, swapAmount, swapCurrency);
        _addRewards(swapParams.zeroForOne ? USDC : USDT, fee - fee / 2);

        // Return Delta
        BeforeSwapDelta delta = toBeforeSwapDelta(int128(int256(fee)), 0);

        return (BaseHook.beforeSwap.selector, delta, 0);
    }
}
