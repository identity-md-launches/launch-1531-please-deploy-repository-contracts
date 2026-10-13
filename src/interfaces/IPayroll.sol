// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Payroll: where HELP WANTED's fees arrive and how they leave
/// @notice No owner and no setters. Everything that arrives is split by fixed shares between
/// sIMD stakers (a slow stream), seat owners (pull claims) and the budget that buys the house
/// feeds. Later launches only ever call `pay` and `tip`; Payroll never needs to know them.
///
/// @dev The functions below are the frozen surface other launches compile against. The
/// implementation may add views and events, never change these signatures.
interface IPayroll {
    /// @notice Pulls `amount` IMD from the caller and books it as revenue.
    /// @param memo A free label for the ledger (an order id, `bytes32("grant")`, …). It changes
    /// nothing about how the money is split.
    function pay(uint256 amount, bytes32 memo) external;

    /// @notice Pulls `amount` IMD from the caller as a tip for the agents that did one job.
    /// @dev Split equally between `agentIds`; each share waits for `claimTip`. Only the first 16
    /// ids share the tip; ids after that are ignored. What the equal split leaves over joins the
    /// seat pool, and an empty list sends the whole amount there. Never reverts because of what
    /// the list contains.
    function tip(uint256[] calldata agentIds, uint256 amount) external;

    /// @notice Splits any IMD that arrived by plain transfer since the last call.
    function book() external returns (uint256 booked);

    /// @notice Moves the due part of the staker stream into sIMD. Anyone may call.
    function drip() external returns (uint256 sent);

    /// @notice Pays the current seat owner. A contract owner must initiate its claim, except Payroll itself.
    function claimSeat(uint256 tokenId) external returns (uint256 paid);

    function claimSeats(uint256[] calldata tokenIds) external returns (uint256 paid);

    /// @notice Pays the bound seat's owner. A contract owner must initiate its claim, except Payroll itself.
    function claimTip(uint256 agentId) external returns (uint256 paid);

    function seatClaimable(uint256 tokenId) external view returns (uint256);

    function tipOwed(uint256 agentId) external view returns (uint256);
}
