// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface, IERC20Minimal, IERC4626Minimal} from "./interfaces/External.sol";

/// @title  PriceRouter
/// @notice Token → USD valuation core shared by the Sail oracle adapters.
///         Fail-closed by convention: every error path returns (0, 0), which downstream
///         Sail templates treat as stale and deny (updatedAt == 0 ⇒ denied).
///
///         Numeraire: USD, 8-decimal mantissa ("USD8") — the Chainlink USD convention.
///         `usdPrice(token)` returns the value of ONE WHOLE token in USD8 plus the
///         honest `updatedAt` of the freshest data that produced it.
///
///         Sources per token (owner-registered):
///           FEED    — a Chainlink USD aggregator for the token.
///           ERC4626 — the token is a vault share; valued as convertToAssets over the
///                     vault's underlying, which MUST itself be registered as FEED or
///                     ALIAS-to-FEED (single level of nesting, enforced at read time).
///           ALIAS   — the token is a 1:1 rebasing claim on another token (Aave aToken,
///                     Compound v3 balance), valued at the target token's price.
///
///         L2 sequencer gating: if a sequencer-uptime feed is configured, every read is
///         gated on "sequencer up AND grace period elapsed"; otherwise reads proceed
///         (mainnet deployments pass address(0)).
contract PriceRouter {
    enum Kind {
        NONE,
        FEED,
        ERC4626,
        ALIAS
    }

    struct Source {
        Kind kind;
        address target; // FEED: aggregator · ERC4626: unused (token is the vault) · ALIAS: the aliased token
    }

    /// @notice Chainlink L2 sequencer-uptime feed (answer 0 = up). address(0) disables gating.
    AggregatorV3Interface public immutable sequencerFeed;
    /// @notice Seconds the sequencer must have been back up before prices are served again.
    uint256 public immutable sequencerGracePeriod;

    address public owner;
    mapping(address => Source) public sources;

    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event SourceSet(address indexed token, Kind kind, address target);

    error NotOwner();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address sequencerFeed_, uint256 sequencerGracePeriod_) {
        owner = msg.sender;
        sequencerFeed = AggregatorV3Interface(sequencerFeed_);
        sequencerGracePeriod = sequencerGracePeriod_;
        emit OwnerTransferred(address(0), msg.sender);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Register a Chainlink USD feed for `token`.
    function setFeed(address token, address aggregator) external onlyOwner {
        if (token == address(0) || aggregator == address(0)) revert ZeroAddress();
        sources[token] = Source(Kind.FEED, aggregator);
        emit SourceSet(token, Kind.FEED, aggregator);
    }

    /// @notice Register `vaultShareToken` as an ERC-4626 share priced via its underlying.
    function setVault(address vaultShareToken) external onlyOwner {
        if (vaultShareToken == address(0)) revert ZeroAddress();
        sources[vaultShareToken] = Source(Kind.ERC4626, address(0));
        emit SourceSet(vaultShareToken, Kind.ERC4626, address(0));
    }

    /// @notice Register `token` as a 1:1 rebasing claim on `target` (e.g. aUSDC → USDC).
    function setAlias(address token, address target) external onlyOwner {
        if (token == address(0) || target == address(0)) revert ZeroAddress();
        sources[token] = Source(Kind.ALIAS, target);
        emit SourceSet(token, Kind.ALIAS, target);
    }

    function clearSource(address token) external onlyOwner {
        delete sources[token];
        emit SourceSet(token, Kind.NONE, address(0));
    }

    // ── Valuation ─────────────────────────────────────────────────────────────

    /// @notice USD8 price of one whole `token`, with the honest freshness timestamp.
    /// @return price8    Value of 1.0 token in USD, 8-decimal mantissa. 0 on any failure.
    /// @return updatedAt Oldest feed timestamp involved. 0 on any failure (fail-closed).
    function usdPrice(address token) public view returns (uint256 price8, uint256 updatedAt) {
        if (!_sequencerUp()) return (0, 0);
        return _usdPrice(token, 0);
    }

    function _usdPrice(address token, uint256 depth) internal view returns (uint256, uint256) {
        Source memory s = sources[token];

        if (s.kind == Kind.FEED) {
            return _readFeed(s.target);
        }

        if (s.kind == Kind.ALIAS) {
            // One level only: the alias target must resolve without further aliasing depth abuse.
            if (depth >= 2) return (0, 0);
            return _usdPrice(s.target, depth + 1);
        }

        if (s.kind == Kind.ERC4626) {
            if (depth >= 1) return (0, 0); // no vault-of-vault: underlying must be FEED/ALIAS
            IERC4626Minimal vault = IERC4626Minimal(token);
            address underlying;
            uint256 assetsPerShare;
            uint8 shareDec;
            uint8 underlyingDec;
            // External calls guarded: a reverting vault must fail closed, not brick the read.
            try vault.asset() returns (address a) {
                underlying = a;
            } catch {
                return (0, 0);
            }
            try vault.decimals() returns (uint8 d) {
                shareDec = d;
            } catch {
                return (0, 0);
            }
            try vault.convertToAssets(10 ** shareDec) returns (uint256 a) {
                assetsPerShare = a;
            } catch {
                return (0, 0);
            }
            try IERC20Minimal(underlying).decimals() returns (uint8 d) {
                underlyingDec = d;
            } catch {
                return (0, 0);
            }
            (uint256 uPrice8, uint256 uUpdated) = _usdPrice(underlying, depth + 1);
            if (uPrice8 == 0) return (0, 0);
            // 1 whole share = assetsPerShare / 10^underlyingDec whole underlying.
            uint256 p = Math.mulDiv(uPrice8, assetsPerShare, 10 ** underlyingDec);
            return (p, uUpdated);
        }

        return (0, 0);
    }

    function _readFeed(address aggregator) internal view returns (uint256, uint256) {
        AggregatorV3Interface feed = AggregatorV3Interface(aggregator);
        int256 answer;
        uint256 updatedAt;
        uint8 feedDec;
        try feed.latestRoundData() returns (uint80, int256 a, uint256, uint256 u, uint80) {
            answer = a;
            updatedAt = u;
        } catch {
            return (0, 0);
        }
        try feed.decimals() returns (uint8 d) {
            feedDec = d;
        } catch {
            return (0, 0);
        }
        if (answer <= 0 || updatedAt == 0) return (0, 0);
        // Normalize any feed precision to USD8. (USD feeds are 8-dec in practice; this
        // keeps the invariant explicit rather than assumed.)
        uint256 p = uint256(answer);
        if (feedDec > 8) p = p / (10 ** (feedDec - 8));
        else if (feedDec < 8) p = p * (10 ** (8 - feedDec));
        if (p == 0) return (0, 0);
        return (p, updatedAt);
    }

    /// @dev Chainlink L2 sequencer feeds answer 0 when the sequencer is up; a restart
    ///      begins a grace period (startedAt) during which prices stay gated.
    function _sequencerUp() internal view returns (bool) {
        if (address(sequencerFeed) == address(0)) return true;
        try sequencerFeed.latestRoundData() returns (uint80, int256 answer, uint256 startedAt, uint256, uint80) {
            if (answer != 0) return false;
            if (block.timestamp - startedAt <= sequencerGracePeriod) return false;
            return true;
        } catch {
            return false;
        }
    }
}

/// @dev Local minimal mulDiv (full-precision multiply-divide, floor). Mirrors OZ/solmate
///      semantics for the subset we need; avoids an external dependency.
library Math {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        // 512-bit multiply then division — standard Remco Bloemen implementation.
        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }
        if (prod1 == 0) {
            return prod0 / denominator;
        }
        require(denominator > prod1, "mulDiv overflow");
        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, denominator)
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }
        uint256 twos = denominator & (~denominator + 1);
        assembly {
            denominator := div(denominator, twos)
            prod0 := div(prod0, twos)
            twos := add(div(sub(0, twos), twos), 1)
        }
        prod0 |= prod1 * twos;
        uint256 inverse = (3 * denominator) ^ 2;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;
        result = prod0 * inverse;
    }
}
