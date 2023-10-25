// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "./Common.sol";

/**
 * @title Rock Paper Scissors Game Contract
 * @notice This contract allows players to participate in a Rock, Paper, Scissors game.
 * Players select an action (Rock, Paper, or Scissors) and play against randomly generated actions.
 */
contract RockPaperScissors is Common {
    using SafeERC20 for IERC20;

    /**
     * @dev Constructor to initialize contract parameters.
     * @param _bankroll Address of the bankroll contract.
     * @param _vrf Address of the Chainlink VRF Coordinator.
     * @param link_eth_feed Address of the Chainlink ETH/USD price feed.
     * @param _forwarder Address of the trusted forwarder contract.
     */
    constructor(
        address _bankroll,
        address _vrf,
        address link_eth_feed,
        address _forwarder
    ) {
        Bankroll = IBankRoll(_bankroll);
        IChainLinkVRF = IVRFCoordinatorV2(_vrf);
        LINK_ETH_FEED = AggregatorV3Interface(link_eth_feed);
        ChainLinkVRF = _vrf;
        _trustedForwarder = _forwarder;
    }

    /**
     * @dev Struct to store information about a Rock Paper Scissors game.
     */
    struct RockPaperScissorsGame {
        uint256 wager;
        uint256 stopGain;
        uint256 stopLoss;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint32 numBets;
        uint8 action;
    }

    /**
     * @dev Mapping to associate player addresses with their game state.
     */
    mapping(address => RockPaperScissorsGame) rockPaperScissorsGames;

    /**
     * @dev Mapping to associate random number requests with player addresses.
     */
    mapping(uint256 => address) rockPaperScissorsIDs;

    /**
     * @dev Event emitted at the start of a game when a player places a bet.
     */
    event RockPaperScissors_Play_Event(
        address indexed playerAddress,
        uint256 wager,
        address tokenAddress,
        uint8 action,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss,
        uint256 VRFFee
    );

    /**
     * @dev Event emitted when a game's outcome is determined.
     */
    event RockPaperScissors_Outcome_Event(
        address indexed playerAddress,
        uint256 wager,
        uint256 payout,
        address tokenAddress,
        uint8[] outcomes,
        uint8[] randomActions,
        uint256[] payouts,
        uint32 numGames
    );

    /**
     * @dev Event emitted when a refund is issued to a player in case of VRF request failure.
     */
    event RockPaperScissors_Refund_Event(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    /**
     * @dev Custom errors for contract functionality.
     */
    error AwaitingVRF(uint256 requestID);
    error InvalidAction();
    error InvalidNumBets(uint256 maxNumBets);
    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error NotAwaitingVRF();
    error BlockNumberTooLow(uint256 have, uint256 want);
    error OnlyCoordinatorCanFulfill(address have, address want);

    /**
     * @notice Get the current game state of a player.
     * @param player Address of the player to get the game state.
     */
    function RockPaperScissors_GetState(address player) external view returns (RockPaperScissorsGame memory) {
        return rockPaperScissorsGames[player];
    }

    /**
     * @notice Start a Rock Paper Scissors game by placing bets.
     * @param wager Amount wagered.
     * @param tokenAddress Address of the token used for betting. Use 0 address for the native coin.
     * @param action Action selected by the player (0 for Rock, 1 for Paper, 2 for Scissors).
     * @param numBets Number of bets to make and amount of random numbers to request.
     * @param stopGain Threshold value at which betting stops if a certain profit is reached.
     * @param stopLoss Threshold value at which betting stops if a certain loss is reached.
     */
    function RockPaperScissors_Play(
        uint256 wager,
        address tokenAddress,
        uint8 action,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss
    ) external payable nonReentrant {
        address msgSender = _msgSender();
        if (action >= 3) {
            revert InvalidAction();
        }
        if (rockPaperScissorsGames[msgSender].requestID != 0) {
            revert AwaitingVRF(rockPaperScissorsGames[msgSender].requestID);
        }
        if (!(numBets > 0 && numBets <= 100)) {
            revert InvalidNumBets(100);
        }

        _kellyWager(wager, tokenAddress);
        uint256 fee = _transferWager(tokenAddress, wager * numBets, 1100000, msgSender);
        uint256 id = _requestRandomWords(numBets);

        rockPaperScissorsGames[msgSender] = RockPaperScissorsGame(
            wager,
            stopGain,
            stopLoss,
            id,
            tokenAddress,
            uint64(block.number),
            numBets,
            action
        );
        rockPaperScissorsIDs[id] = msgSender;

        emit RockPaperScissors_Play_Event(
            msgSender,
            wager,
            tokenAddress,
            action,
            numBets,
            stopGain,
            stopLoss,
            fee
        );
    }

    /**
     * @notice Refund a player if the VRF request has failed.
     */
    function RockPaperScissors_Refund() external nonReentrant {
        address msgSender = _msgSender();
        RockPaperScissorsGame storage game = rockPaperScissorsGames[msgSender];
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

        delete rockPaperScissorsIDs[game.requestID];
        delete rockPaperScissorsGames[msgSender];

        if (tokenAddress == address(0)) {
            (bool success, ) = payable(msgSender).call{value: wager}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20(tokenAddress).safeTransfer(msgSender, wager);
        }
        emit RockPaperScissors_Refund_Event(msgSender, wager, tokenAddress);
    }

    /**
     * @notice Function called by Chainlink VRF with random numbers.
     * @param requestId ID provided when the request was made.
     * @param randomWords Array of random numbers.
     */
    function rawFulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) external {
        if (msg.sender != ChainLinkVRF) {
            revert OnlyCoordinatorCanFulfill(msg.sender, ChainLinkVRF);
        }
        fulfillRandomWords(requestId, randomWords);
    }

    /**
     * @notice Function to calculate individual and total payouts and determine game outcomes.
     * @param requestId ID of the VRF request.
     * @param randomWords Array of random numbers.
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal {
        address playerAddress = rockPaperScissorsIDs[requestId];
        if (playerAddress == address(0)) {
            revert();
        }
        RockPaperScissorsGame storage game = rockPaperScissorsGames[playerAddress];
        if (block.number > game.blockNumber + BLOCK_NUMBER_REFUND) {
            revert();
        }

        uint8[] memory randomActions = new uint8[](game.numBets);
        uint8[] memory outcomes = new uint8[](game.numBets);
        uint256[] memory payouts = new uint256[](game.numBets);
        int256 totalValue;
        uint256 payout;
        uint32 i;

        address tokenAddress = game.tokenAddress;

        for (i = 0; i < game.numBets; i++) {
            if (totalValue >= int256(game.stopGain)) {
                break;
            }
            if (totalValue <= -int256(game.stopLoss)) {
                break;
            }

            randomActions[i] = uint8(randomWords[i] % 3);
            outcomes[i] = _determineRPSResult(game.action, randomActions[i]);

            if (outcomes[i] == 2) {
                payout += (game.wager * 99) / 100;
                totalValue -= int256((game.wager) / 100);
                payouts[i] = (game.wager * 99) / 100;
                continue;
            }

            if (outcomes[i] == 1) {
                payout += (game.wager * 198) / 100;
                totalValue += int256((game.wager * 98) / 100);
                payouts[i] = (game.wager * 198) / 100;
                continue;
            }

            totalValue -= int256(game.wager);
        }

        payout += (game.numBets - i) * game.wager;

        emit RockPaperScissors_Outcome_Event(
            playerAddress,
            game.wager,
            payout,
            game.tokenAddress,
            outcomes,
            randomActions,
            payouts,
            i
        );
        _transferToBankroll(tokenAddress, game.wager * game.numBets);
        delete rockPaperScissorsIDs[requestId];
        delete rockPaperScissorsGames[playerAddress];
        if (payout != 0) {
            _transferPayout(playerAddress, payout, tokenAddress);
        }
    }

    /**
     * @notice Determines the result of a Rock, Paper, Scissors game.
     * @param playerPick Action selected by the player (0 for Rock, 1 for Paper, 2 for Scissors).
     * @param rngPick Randomly generated action (0 for Rock, 1 for Paper, 2 for Scissors).
     * @return Result of the game (0 for loss, 1 for win, 2 for draw).
     */
    function _determineRPSResult(uint8 playerPick, uint8 rngPick) internal pure returns (uint8) {
        if (playerPick == rngPick) {
            return 2; // Draw
        }
        if (playerPick == 0) {
            if (rngPick == 1) {
                return 0; // Loss
            } else {
                return 1; // Win
            }
        }

        if (playerPick == 1) {
            if (rngPick == 2) {
                return 0; // Loss
            } else {
                return 1; // Win
            }
        }

        if (playerPick == 2) {
            if (rngPick == 0) {
                return 0; // Loss
            } else {
                return 1; // Win
            }
        }
    }

    /**
     * @notice Calculates the maximum wager allowed based on the bankroll size.
     * @param wager Amount wagered.
     * @param tokenAddress Address of the token used for betting. Use 0 address for the native coin.
     */
    function _kellyWager(uint256 wager, address tokenAddress) internal view {
        uint256 balance;
        if (tokenAddress == address(0)) {
            balance = address(Bankroll).balance;
        } else {
            balance = IERC20(tokenAddress).balanceOf(address(Bankroll));
        }
        uint256 maxWager = (balance * 1683629) / 100000000;
        if (wager > maxWager) {
            revert WagerAboveLimit(wager, maxWager);
        }
    }
}
