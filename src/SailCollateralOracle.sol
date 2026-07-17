// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IOracle} from "./interfaces/IOracle.sol";
import {IERC20Minimal} from "./interfaces/External.sol";
import {PriceRouter, Math} from "./PriceRouter.sol";

/// @title  SailCollateralOracle
/// @notice IOracle adapter for Sail's COLLATERAL role: getPrice(account, address(0))
///         returns the account's aggregate portfolio value in the USD numeraire
///         (decimals = 8), summed over an operator-registered position list.
///
///         Position tokens are valued through the shared PriceRouter, so aTokens
///         (ALIAS), ERC-4626 vault shares, and plain feed-priced ERC-20s all work.
///
///         Numeraire: USD8 — the SAME numeraire as SailOracle's borrow role, which is
///         a hard requirement of BorrowPermission's LTV check.
///
///         Trust model: the OPERATOR owns this contract and registers each account's
///         position list (Sail's oracle choice is explicitly operator-supplied). The
///         Permission Signer allowlists this adapter when configuring the mandate.
///
///         Gas: Sail evaluates permissions under a 150k-gas staticcall budget that the
///         oracle read must SHARE with the template's own logic. Positions are capped
///         at MAX_POSITIONS and each costs roughly 15–30k gas depending on source kind
///         (see test/Gas.t.sol measurements) — keep lists short; 3–4 is the sane max.
///
///         Fail-closed: an empty list, any unpriceable position, or a gated sequencer
///         returns (0, 0, 0), which BorrowPermission treats as stale and denies.
contract SailCollateralOracle is IOracle {
    uint8 public constant VALUE_DECIMALS = 8;
    uint256 public constant MAX_POSITIONS = 6;

    PriceRouter public immutable router;
    address public owner;
    mapping(address => address[]) internal _positions;

    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event PositionsSet(address indexed account, address[] tokens);

    error NotOwner();
    error ZeroAddress();
    error TooManyPositions();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address router_) {
        router = PriceRouter(router_);
        owner = msg.sender;
        emit OwnerTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Replace `account`'s collateral position list.
    function setPositions(address account, address[] calldata tokens) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (tokens.length > MAX_POSITIONS) revert TooManyPositions();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) revert ZeroAddress();
        }
        _positions[account] = tokens;
        emit PositionsSet(account, tokens);
    }

    function positions(address account) external view returns (address[] memory) {
        return _positions[account];
    }

    /// @inheritdoc IOracle
    /// @dev base = the ACCOUNT (not a token); quote must be address(0) (the numeraire).
    function getPrice(address base, address quote)
        external
        view
        returns (uint256 price, uint8 decimals, uint256 updatedAt)
    {
        if (quote != address(0) || base == address(0)) return (0, 0, 0);

        address[] memory tokens = _positions[base];
        uint256 n = tokens.length;
        if (n == 0) return (0, 0, 0);

        uint256 totalUsd8;
        uint256 oldest = type(uint256).max;

        for (uint256 i = 0; i < n; i++) {
            address token = tokens[i];

            uint256 bal;
            try IERC20Minimal(token).balanceOf(base) returns (uint256 b) {
                bal = b;
            } catch {
                return (0, 0, 0);
            }

            (uint256 price8, uint256 up) = router.usdPrice(token);
            if (price8 == 0) return (0, 0, 0); // one bad leg poisons the total — deny

            if (bal != 0) {
                uint8 dec;
                try IERC20Minimal(token).decimals() returns (uint8 d) {
                    dec = d;
                } catch {
                    return (0, 0, 0);
                }
                if (dec > 30) return (0, 0, 0);
                totalUsd8 += Math.mulDiv(bal, price8, 10 ** dec);
            }
            if (up < oldest) oldest = up;
        }

        if (oldest == type(uint256).max || oldest == 0) return (0, 0, 0);
        return (totalUsd8, VALUE_DECIMALS, oldest);
    }
}
