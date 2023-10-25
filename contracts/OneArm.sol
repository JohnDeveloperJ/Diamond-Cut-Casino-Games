// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "./Common.sol";

/**
 * @title Slots Game Contract
 * @notice This contract allows players to participate in a Slots game.
 * Players place bets, request random outcomes from Chainlink VRF, and receive payouts based on the slots result.
 */
contract Slots is Common {
    using SafeERC20 for IERC20;

    constructor(
        address _bankroll,
        address _vrf,
        address link_eth_feed,
        address _forwarder,
        uint16[] memory _multipliers,
        uint16[] memory _outcomeNum,
        uint16 _numOutcomes
    ) {
        Bankroll = IBankRoll(_bankroll);
        IChainLinkVRF = IVRFCoordinatorV2(_vrf);
        LINK_ETH_FEED = AggregatorV3Interface(link_eth_feed);
        ChainLinkVRF = _vrf;
        _trustedForwarder = _forwarder;
        _setSlotsMultipliers(_multipliers, _outcomeNum, _numOutcomes);
    }

    struct SlotsGame {
        uint256 wager;
        uint256 stopGain;
        uint256 stopLoss;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint32 numBets;
    }

    mapping(address => SlotsGame) slotsGames;
    mapping(uint256 => address) slotsIDs;

    mapping(uint16 => uint16) slotsMultipliers;
    uint16 numOutcomes;

    /**
     * @dev Event emitted at the start of a game when a player places a bet.
     */
    event Slots_Play_Event(
        address indexed playerAddress,
        uint256 wager,
        address tokenAddress,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss,
        uint256 VRFFee
    );

    /**
     * @dev Event emitted when a game's outcome is determined.
     */
    event Slots_Outcome_Event(
        address indexed playerAddress,
        uint256 wager,
        uint256 payout,
        address tokenAddress,
        uint16[] slotIDs,
        uint256[] multipliers,
        uint256[] payouts,
        uint32 numGames
    );

    /**
     * @dev Event emitted when a refund is issued to a player in case of VRF request failure.
     */
    event Slots_Refund_Event(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    error AwaitingVRF(uint256 requestID);
    error InvalidNumBets(uint256 maxNumBets);
    error NotAwaitingVRF();
    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error BlockNumberTooLow(uint256 have, uint256 want);
    error OnlyCoordinatorCanFulfill(address have, address want);

    /**
     * @notice Get the current game state of a player.
     * @param player Address of the player to get the game state.
     */
    function Slots_GetState(address player) external view returns (SlotsGame memory) {
        return slotsGames[player];
    }

    /**
     * @notice Get the current slots multipliers for each outcome.
     * @return multipliers Multipliers for all slots outcomes.
     */
    function Slots_GetMultipliers() external view returns (uint16[] memory multipliers) {
        multipliers = new uint16[](numOutcomes);
        for (uint16 i = 0; i < numOutcomes; i++) {
            multipliers[i] = slotsMultipliers[i];
        }
        return multipliers;
    }

    /**
     * @notice Start a Slots game by placing bets.
     * @param wager Amount wagered.
     * @param tokenAddress Address of the token used for betting. Use 0 address for the native coin.
     * @param numBets Number of bets to make and amount of random numbers to request.
     * @param stopGain Threshold value at which betting stops if a certain profit is reached.
     * @param stopLoss Threshold value at which betting stops if a certain loss is reached.
     */
    function Slots_Play(
        uint256 wager,
        address tokenAddress,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss
    ) external payable nonReentrant {
        address msgSender = _msgSender();

        if (slotsGames[msgSender].requestID != 0) {
            revert AwaitingVRF(slotsGames[msgSender].requestID);
        }
        if (!(numBets > 0 && numBets <= 100)) {
            revert InvalidNumBets(100);
        }

        _kellyWager(wager, tokenAddress);
        uint256 fee = _transferWager(tokenAddress, wager * numBets, 1100000, msgSender);
        uint256 id = _requestRandomWords(numBets);

        slotsGames[msgSender] = SlotsGame(
            wager,
            stopGain,
            stopLoss,
            id,
            tokenAddress,
            uint64(block.number),
            numBets
        );
        slotsIDs[id] = msgSender;

        emit Slots_Play_Event(
            msgSender,
            wager,
            tokenAddress,
            numBets,
            stopGain,
            stopLoss,
            fee
        );
    }

    /**
     * @notice Refund a player if the VRF request has failed.
     */
    function Slots_Refund() external nonReentrant {
        address msgSender = _msgSender();
        SlotsGame storage game = slotsGames[msgSender];
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

        delete slotsIDs[game.requestID];
        delete slotsGames[msgSender];

        if (tokenAddress == address(0)) {
            (bool success, ) = payable(msgSender).call{value: wager}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20(tokenAddress).safeTransfer(msgSender, wager);
        }
        emit Slots_Refund_Event(msgSender, wager, tokenAddress);
    }

    /**
     * @notice Callback function called by Chainlink VRF with random numbers.
     * @param requestId ID provided when the request was made.
     * @param randomWords Array of random numbers.
     */
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        if (msg.sender != ChainLinkVRF) {
            revert OnlyCoordinatorCanFulfill(msg.sender, ChainLinkVRF);
        }
        fulfillRandomWords(requestId, randomWords);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal {
        address playerAddress = slotsIDs[requestId];
        if (playerAddress == address(0)) revert();
        SlotsGame storage game = slotsGames[playerAddress];
        if (block.number > game.blockNumber + BLOCK_NUMBER_REFUND) revert();

        uint256 payout;
        int256 totalValue;
        uint32 i;
        uint16[] memory slotID = new uint16[](game.numBets);
        uint256[] memory multipliers = new uint256[](game.numBets);
        uint256[] memory payouts = new uint256[](game.numBets);

        address tokenAddress = game.tokenAddress;

        for (i = 0; i < game.numBets; i++) {
            if (totalValue >= int256(game.stopGain)) {
                break;
            }
            if (totalValue <= -int256(game.stopLoss)) {
                break;
            }

            slotID[i] = uint16(randomWords[i] % numOutcomes);
            multipliers[i] = slotsMultipliers[slotID[i]];

            if (multipliers[i] != 0) {
                totalValue +=
                    int256(game.wager * multipliers[i]) -
                    int256(game.wager);
                payout += game.wager * multipliers[i];
                payouts[i] = game.wager * multipliers[i];
            } else {
                totalValue -= int256(game.wager);
            }
        }

        payout += (game.numBets - i) * game.wager;

        emit Slots_Outcome_Event(
            playerAddress,
            game.wager,
            payout,
            tokenAddress,
            slotID,
            multipliers,
            payouts,
            i
        );
        _transferToBankroll(tokenAddress, game.wager * game.numBets);
        delete slotsIDs[requestId];
        delete slotsGames[playerAddress];
        if (payout != 0) {
            _transferPayout(playerAddress, payout, tokenAddress);
        }
    }

    /**
     * @notice Set the slots multipliers. This function can only be called at deploy time.
     * @param _multipliers Array of multipliers with each multiplier above 0.
     * @param _outcomeNum Array of slot outcomes corresponding to the multipliers.
     * @param _numOutcomes Total number of possible outcomes, e.g., if there are 7 possibilities for each slot and 3 slots, _numOutcomes = 7^3.
     */
    function _setSlotsMultipliers(
        uint16[] memory _multipliers,
        uint16[] memory _outcomeNum,
        uint16 _numOutcomes
    ) internal {
        for (uint16 i = 0; i < numOutcomes; i++) {
            delete slotsMultipliers[i];
        }

        numOutcomes = _numOutcomes;
        for (uint16 i = 0; i < _multipliers.length; i++) {
            slotsMultipliers[_outcomeNum[i]] = _multipliers[i];
        }
    }

    /**
     * @notice Calculate the maximum wager allowed based on the bankroll size.
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
        uint256 maxWager = (balance * 55770) / 100000000;
        if (wager > maxWager) {
            revert WagerAboveLimit(wager, maxWager);
        }
    }
}
