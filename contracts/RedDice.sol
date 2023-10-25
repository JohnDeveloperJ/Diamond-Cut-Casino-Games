// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "./Common.sol";

/**
 * @title Dice Game with Play-to-Earn Features
 * @dev A smart contract that allows players to participate in a dice game with Play-to-Earn functionality.
 */
contract Dice is Common {
    // Existing contract code...

    // Additional state variables for Play-to-Earn
    IERC20 public token; // The native token used in the game.
    mapping(address => uint256) public playerEarnedTokens;
    mapping(address => address) public playerReferrers;
    
    // Define a leaderboard to track player earnings
    address[] public leaderboard;
    mapping(address => uint256) public playerEarnings;

    event TokensEarned(address indexed player, uint256 amount);
    event ReferralReward(address indexed referrer, address indexed referee, uint256 reward);

    /**
     * @dev Constructor for the Dice contract.
     * @param _bankroll Address of the bankroll contract.
     * @param _vrf Address of the VRF (Verifiable Random Function) contract.
     * @param link_eth_feed Address of the LINK/ETH price feed contract.
     * @param _forwarder Address of the trusted forwarder contract.
     * @param _token Address of the ERC20 token used within the game.
     */
    constructor(
        address _bankroll,
        address _vrf,
        address link_eth_feed,
        address _forwarder,
        address _token
    ) {
        // ... (your existing constructor code)
        token = IERC20(_token);
    }

    /**
     * @dev Modified function to play the Dice game with Play-to-Earn features.
     * @param wager Wagered amount.
     * @param multiplier Multiplier for potential winnings.
     * @param tokenAddress Address of the token used for the wager.
     * @param isOver Boolean indicating whether the player bets over or under.
     * @param numBets Number of bets placed in a single transaction.
     * @param stopGain Threshold at which betting should stop if a profit is reached.
     * @param stopLoss Threshold at which betting should stop if a loss is reached.
     * @param payout Total payout for the player.
     */
    function Dice_Play(
        uint256 wager,
        uint32 multiplier,
        address tokenAddress,
        bool isOver,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss,
        uint256 payout
    ) external payable nonReentrant {
        // ... (your existing play logic)

        // Calculate and distribute rewards to the player
        uint256 rewards = calculateRewards(payout); // Pass the payout as an argument
        playerEarnedTokens[_msgSender()] += rewards;
        emit TokensEarned(_msgSender(), rewards);
        
        // Check for referrals
        address referrer = playerReferrers[_msgSender()];
        if (referrer != address(0)) {
            uint256 referralReward = rewards / 10; // 10% referral reward
            playerEarnedTokens[referrer] += referralReward;
            emit ReferralReward(referrer, _msgSender(), referralReward);
        }

        // Update the leaderboard
        updateLeaderboard(_msgSender(), rewards);
    }

    /**
     * @dev Function to claim earned tokens by the player.
     */
    function claimTokens() external {
        uint256 earnedTokens = playerEarnedTokens[_msgSender()];
        require(earnedTokens > 0, "No earned tokens to claim.");
        playerEarnedTokens[_msgSender()] = 0;
        token.transfer(_msgSender(), earnedTokens);
    }

    /**
     * @dev Function for players to refer others to the game.
     * @param referee Address of the player being referred.
     */
    function referPlayer(address referee) external {
        require(playerReferrers[referee] == address(0), "Player is already referred.");
        playerReferrers[referee] = _msgSender();
    }

    /**
     * @dev Internal function to calculate rewards for the player.
     * @param payout Total payout for the player.
     * @return The calculated rewards for the player.
     */
    function calculateRewards(uint256 payout) internal pure returns (uint256) {
        // Implement your reward calculation logic here
        // Use the provided payout argument to calculate rewards
        return payout * 10 / 100; // 10% of the payout as rewards
    }

    /**
     * @dev Internal function to update the leaderboard with player earnings.
     * @param player Address of the player.
     * @param earnings Earnings of the player.
     */
    function updateLeaderboard(address player, uint256 earnings) internal {
        // Implement leaderboard update logic
        leaderboard.push(player);
        playerEarnings[player] += earnings;
        // Sort the leaderboard based on earnings
        // You can use a sorting algorithm like QuickSort or HeapSort for this.
    }
}
