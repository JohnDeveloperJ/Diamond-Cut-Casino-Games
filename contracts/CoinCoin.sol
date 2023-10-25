// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "./Common.sol";

/// @title Coin Flip Game Contract
/// @notice This contract allows users to play a Coin Flip game.
/// Users can place bets, request random outcomes from Chainlink VRF, and receive rewards.

contract CoinCoin is Common {
    using SafeERC20 for IERC20;

    IERC20 public token; // The native token used in the game.
    mapping(address => uint256) public playerEarnedTokens; // Track earned tokens for each player.
    mapping(address => address) public playerReferrers; // Mapping to store player referrers.

    // Define a leaderboard to track player earnings
    address[] public leaderboard;
    mapping(address => uint256) public playerEarnings;

    event TokensEarned(address indexed player, uint256 amount);
    event ReferralReward(address indexed referrer, address indexed referee, uint256 reward);

    /// @notice Contract constructor to initialize essential parameters.
    /// @param _bankroll Address of the bankroll contract.
    /// @param _vrf Address of the Chainlink VRF Coordinator.
    /// @param link_eth_feed Address of the Chainlink ETH/USD price feed.
    /// @param _forwarder Address of the trusted forwarder contract.
    /// @param _token Address of the native token used in the game.
    constructor(
        address _bankroll,
        address _vrf,
        address link_eth_feed,
        address _forwarder,
        address _token
    ) {
        Bankroll = IBankRoll(_bankroll);
        IChainLinkVRF = IVRFCoordinatorV2(_vrf);
        LINK_ETH_FEED = AggregatorV3Interface(link_eth_feed);
        ChainLinkVRF = _vrf;
        _trustedForwarder = _forwarder;
        token = IERC20(_token);
    }

    /// @notice Struct to store information about a Coin Flip game.
    struct CoinFlipGame {
        uint256 wager;
        uint256 stopGain;
        uint256 stopLoss;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint32 numBets;
        bool isHeads;
    }

    /// @notice Mapping to store active Coin Flip games for each player.
    mapping(address => CoinFlipGame) coinFlipGames;

    /// @notice Mapping to associate random number requests with player addresses.
    mapping(uint256 => address) coinIDs;

    /// @notice Event emitted when a player initiates a Coin Flip game.
    event CoinFlip_Play_Event(
        address indexed playerAddress,
        uint256 wager,
        address tokenAddress,
        bool isHeads,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss,
        uint256 VRFFee
    );

    /// @notice Event emitted when a Coin Flip game's outcome is determined.
    event CoinFlip_Outcome_Event(
        address indexed playerAddress,
        uint256 wager,
        uint256 payout,
        address tokenAddress,
        uint8[] coinOutcomes,
        uint256[] payouts,
        uint32 numGames
    );

    /// @notice Event emitted when a player is refunded due to VRF request failure.
    event CoinFlip_Refund_Event(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    /// @notice Custom errors for contract functionality.
    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error AwaitingVRF(uint256 requestID);
    error InvalidNumBets(uint256 maxNumBets);
    error NotAwaitingVRF();
    error BlockNumberTooLow(uint256 have, uint256 want);
    error OnlyCoordinatorCanFulfill(address have, address want);

    /// @notice Get the state of a player's current Coin Flip game.
    /// @param player Address of the player to get the game state.
    function CoinFlip_GetState(address player) external view returns (CoinFlipGame memory) {
        return coinFlipGames[player];
    }

    /// @notice Start a Coin Flip game by placing bets.
    /// @param wager Amount wagered.
    /// @param tokenAddress Address of the token used for betting, 0 address is considered the native coin.
    /// @param isHeads Flag indicating if the player bets on heads (true) or tails (false).
    /// @param numBets Number of bets to make and the amount of random numbers to request.
    /// @param stopGain Threshold value at which betting stops if a certain profit is obtained.
    /// @param stopLoss Threshold value at which betting stops if a certain loss is obtained.
    function CoinFlip_Play(
        uint256 wager,
        address tokenAddress,
        bool isHeads,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss
    ) external payable nonReentrant {
        address msgSender = _msgSender();
        if (coinFlipGames[msgSender].requestID != 0) {
            revert AwaitingVRF(coinFlipGames[msgSender].requestID);
        }
        if (!(numBets > 0 && numBets <= 100)) {
            revert InvalidNumBets(100);
        }

        _kellyWager(wager, tokenAddress);
        uint256 fee = _transferWager(tokenAddress, wager * numBets, 1000000, msgSender);

        uint256 id = _requestRandomWords(numBets);

        coinFlipGames[msgSender] = CoinFlipGame(
            wager,
            stopGain,
            stopLoss,
            id,
            tokenAddress,
            uint64(block.number),
            numBets,
            isHeads
        );
        coinIDs[id] = msgSender;

        emit CoinFlip_Play_Event(
            msgSender,
            wager,
            tokenAddress,
            isHeads,
            numBets,
            stopGain,
            stopLoss,
            fee
        );
    }

    /// @notice Refund the player if the VRF request has failed.
    function CoinFlip_Refund() external nonReentrant {
        address msgSender = _msgSender();
        CoinFlipGame storage game = coinFlipGames[msgSender];
        if (game.requestID == 0) {
            revert NotAwaitingVRF();
        }
        if (game.blockNumber + BLOCK_NUMBER_REFUND + 10 > block.number) {
            revert BlockNumberTooLow(
                block.number,
                game.blockNumber + BLOCK_NUMBER_REFUND + 10
            );
        }

        uint256 wager = game.wager * game.numBets;
        address tokenAddress = game.tokenAddress;

        delete coinIDs[game.requestID];
        delete coinFlipGames[msgSender];

        if (tokenAddress == address(0)) {
            (bool success, ) = payable(msgSender).call{value: wager}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            token.safeTransfer(msgSender, wager);
        }
        emit CoinFlip_Refund_Event(msgSender, wager, tokenAddress);
    }

    /// @notice Callback function called by Chainlink VRF with random numbers.
    /// @param requestId ID provided when the request was made.
    /// @param randomWords Array of random numbers.
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        if (msg.sender != ChainLinkVRF) {
            revert OnlyCoordinatorCanFulfill(msg.sender, ChainLinkVRF);
        }
        fulfillRandomWords(requestId, randomWords);
    }

    /// @notice Function to calculate the outcome and payouts of Coin Flip games based on random numbers.
    /// @param requestId ID provided when the random number request was made.
    /// @param randomWords Array of random numbers received from Chainlink VRF.
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal {
        address playerAddress = coinIDs[requestId];
        if (playerAddress == address(0)) revert();
        CoinFlipGame storage game = coinFlipGames[playerAddress];
        if (block.number > game.blockNumber + BLOCK_NUMBER_REFUND) revert();
        int256 totalValue;
        uint256 payout;
        uint32 i;
        uint8[] memory coinFlip = new uint8[](game.numBets);
        uint256[] memory payouts = new uint256[](game.numBets);

        address tokenAddress = game.tokenAddress;

        for (i = 0; i < game.numBets; i++) {
            if (totalValue >= int256(game.stopGain)) {
                break;
            }
            if (totalValue <= -int256(game.stopLoss)) {
                break;
            }

            coinFlip[i] = uint8(randomWords[i] % 2);

            if (coinFlip[i] == 1 && game.isHeads == true) {
                totalValue += int256((game.wager * 9800) / 10000);
                payout += (game.wager * 19800) / 10000;
                payouts[i] = (game.wager * 19800) / 10000;
                continue;
            }
            if (coinFlip[i] == 0 && game.isHeads == false) {
                totalValue += int256((game.wager * 9800) / 10000);
                payout += (game.wager * 19800) / 10000;
                payouts[i] = (game.wager * 19800) / 10000;
                continue;
            }

            totalValue -= int256(game.wager);
        }

        payout += (game.numBets - i) * game.wager;

        emit CoinFlip_Outcome_Event(
            playerAddress,
            game.wager,
            payout,
            tokenAddress,
            coinFlip,
            payouts,
            i
        );
        _transferToBankroll(tokenAddress, game.wager * game.numBets);
        delete coinIDs[requestId];
        delete coinFlipGames[playerAddress];
        if (payout != 0) {
            _transferPayout(playerAddress, payout, tokenAddress);
        }
    }

    /// @notice Calculate the maximum wager allowed based on the bankroll size.
    /// @param wager Amount wagered.
    /// @param tokenAddress Address of the token used for betting, 0 address is considered the native coin.
    function _kellyWager(uint256 wager, address tokenAddress) internal view {
        uint256 balance;
        if (tokenAddress == address(0)) {
            balance = address(Bankroll).balance;
        } else {
            balance = IERC20(tokenAddress).balanceOf(address(Bankroll));
        }
        uint256 maxWager = (balance * 1122448) / 100000000;
        if (wager > maxWager) {
            revert WagerAboveLimit(wager, maxWager);
        }
    }
}
