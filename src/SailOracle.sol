// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IOracle} from "./interfaces/IOracle.sol";
import {IERC20Minimal} from "./interfaces/External.sol";
import {PriceRouter, Math} from "./PriceRouter.sol";

/// @title  SailOracle
/// @notice IOracle adapter for Sail Protocol's SwapPermission and BorrowPermission,
///         backed by a PriceRouter (Chainlink USD feeds + ERC-4626 + alias resolution).
///
///         Roles served (see Sail's docs/oracle-adapters.md):
///           Swap oracle    — getPrice(tokenIn, tokenOut): price of 1 tokenIn UNIT in
///                            tokenOut UNITS, both native units, fixed 18-dec mantissa.
///           Borrow oracle  — getPrice(asset, address(0)): per-UNIT value of `asset`
///                            in the USD numeraire; decimals = 8 + asset.decimals().
///
///         Shared numeraire: USD8 — matches SailCollateralOracle (decimals = 8), which
///         satisfies the borrow+collateral shared-numeraire requirement because the
///         templates fold each role's own `decimals` into their math.
///
///         Fail-closed: every failure path returns (0, 0, 0); Sail templates treat
///         updatedAt == 0 as stale and deny. This adapter never fabricates freshness —
///         `updatedAt` is always the OLDEST feed timestamp involved in the answer.
contract SailOracle is IOracle {
    /// @dev Mantissa precision for the swap role.
    uint8 public constant SWAP_DECIMALS = 18;

    PriceRouter public immutable router;

    constructor(address router_) {
        router = PriceRouter(router_);
    }

    /// @inheritdoc IOracle
    function getPrice(address base, address quote)
        external
        view
        returns (uint256 price, uint8 decimals, uint256 updatedAt)
    {
        if (base == address(0)) return (0, 0, 0);

        (uint256 basePrice8, uint256 baseUpdated) = router.usdPrice(base);
        if (basePrice8 == 0) return (0, 0, 0);

        uint8 baseDec = _tokenDecimals(base);
        if (baseDec > 30) return (0, 0, 0); // nonsensical metadata — refuse to price

        // ── Borrow role: quote = address(0) ⇒ per-unit value in the USD numeraire ──
        if (quote == address(0)) {
            // 1 base UNIT = basePrice8 / 10^(8 + baseDec) USD.
            return (basePrice8, 8 + baseDec, baseUpdated);
        }

        // ── Swap role: price of 1 base UNIT in quote UNITS, 18-dec mantissa ──
        (uint256 quotePrice8, uint256 quoteUpdated) = router.usdPrice(quote);
        if (quotePrice8 == 0) return (0, 0, 0);

        uint8 quoteDec = _tokenDecimals(quote);
        if (quoteDec > 30) return (0, 0, 0);

        // 1 whole base = basePrice8/quotePrice8 whole quote
        // 1 base unit  = (basePrice8/quotePrice8) · 10^(quoteDec-baseDec) quote units
        // mantissa (18-dec): two full-precision steps, no intermediate truncation to zero
        uint256 t = Math.mulDiv(basePrice8, 10 ** uint256(SWAP_DECIMALS), quotePrice8);
        price = Math.mulDiv(t, 10 ** quoteDec, 10 ** baseDec);
        if (price == 0) return (0, 0, 0);

        updatedAt = baseUpdated < quoteUpdated ? baseUpdated : quoteUpdated;
        return (price, SWAP_DECIMALS, updatedAt);
    }

    function _tokenDecimals(address token) internal view returns (uint8) {
        try IERC20Minimal(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return type(uint8).max; // triggers the >30 refusal above
        }
    }
}
