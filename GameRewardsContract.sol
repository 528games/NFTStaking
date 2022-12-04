// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

import "hardhat/console.sol";

contract ERC721Staking is ReentrancyGuard, AccessControl, Initializable {
    using SafeERC20 for IERC20;

    struct TokenReward {
        address token;
        uint256 rateOfReward;
        uint256 unclaimedReward;
    }

    // Interfaces for ERC20 and ERC721
    IERC20 public rewardsToken;
    IERC721 public nftCollection;

    // Internals
    TokenReward[] contractRewards;

    uint256 totalStaked;

    // constants
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Constructor function to set the rewards token and the NFT collection addresses
    constructor() {
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    struct StakedToken {
        address staker;
        uint256 tokenId;
    }

    // Staker info
    struct Staker {
        // Amount of tokens staked by the staker
        uint256 amountStaked;
        // Staked token ids
        StakedToken[] stakedTokens;
        // Last time of the rewards were calculated for this user
        uint256 timeOfLastUpdate;
        TokenReward[] rewards;
    }

    // Rewards per hour per token deposited in wei.
    uint256 private rewardsPerHour = 100000;

    // Mapping of User Address to Staker info
    mapping(address => Staker) public stakers;

    // Mapping of Token Id to staker. Made for the SC to remember
    // who to send back the ERC721 Token to.
    mapping(uint256 => address) public stakerAddress;

    /// Update contract configuration
    /// @dev Callable by admin roles only
    function updateConfig(TokenReward[] calldata _rewards)
        external
        onlyRole(ADMIN_ROLE)
    {
        delete contractRewards;
        for (uint256 i = 0; i < _rewards.length; i++) {
            contractRewards.push(_rewards[i]);
        }
    }

    function initialize(
        TokenReward[] memory _rewards,
        address _owner,
        address _nftCollection
    ) public onlyRole(ADMIN_ROLE) initializer {
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, _owner);
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);

        nftCollection = IERC721(address(_nftCollection));

        delete contractRewards;
        for (uint256 i = 0; i < _rewards.length; i++) {
            contractRewards.push(_rewards[i]);
        }
    }

    // If address already has ERC721 Token/s staked, calculate the rewards.
    // Increment the amountStaked and map msg.sender to the Token Id of the staked
    // Token to later send back on withdrawal. Finally give timeOfLastUpdate the
    // value of now.
    function stake(uint256 _tokenId) external nonReentrant {
        // If wallet has tokens staked, calculate the rewards before adding the new token
        if (stakers[msg.sender].amountStaked > 0) {
            // Update the rewards for this user, as the amount of rewards decreases with less tokens.
            TokenReward[] memory _rewards = calculateRewards(msg.sender);

            for (uint256 i = 0; i < _rewards.length; i++) {
                //find index of token in staker rewards array
                uint256 idx = 0;
                for (
                    uint256 j = 0;
                    j < stakers[msg.sender].rewards.length;
                    j++
                ) {
                    if (
                        stakers[msg.sender].rewards[j].token ==
                        _rewards[j].token
                    ) {
                        idx = j;
                        break;
                    }
                }

                stakers[msg.sender].rewards[idx].unclaimedReward += _rewards[i]
                    .unclaimedReward;
            }
        }

        // Wallet must own the token they are trying to stake
        require(
            nftCollection.ownerOf(_tokenId) == msg.sender,
            "You don't own this token!"
        );

        // Transfer the token from the wallet to the Smart contract
        nftCollection.transferFrom(msg.sender, address(this), _tokenId);

        // Create StakedToken
        StakedToken memory stakedToken = StakedToken(msg.sender, _tokenId);

        // Add the token to the stakedTokens array
        stakers[msg.sender].stakedTokens.push(stakedToken);

        // Add staking rewards or replace rate if present
        for (uint256 i = 0; i < contractRewards.length; i++) {
            // check if reward is already present
            uint256 idx = 0;
            bool _containsReward;
            for (uint256 j = 0; j < stakers[msg.sender].rewards.length; j++) {
                if (
                    stakers[msg.sender].rewards[j].token ==
                    contractRewards[i].token
                ) {
                    idx = j;
                    _containsReward = true;
                    break;
                } else {
                    _containsReward = false;
                }
            }
            if (_containsReward) {
                stakers[msg.sender].rewards[idx].rateOfReward = contractRewards[
                    i
                ].rateOfReward;
            } else {
                stakers[msg.sender].rewards.push(contractRewards[i]);
            }
        }

        // Increment the amount staked for this wallet
        stakers[msg.sender].amountStaked++;

        // Update the mapping of the tokenId to the staker's address
        stakerAddress[_tokenId] = msg.sender;

        // Update the timeOfLastUpdate for the staker
        stakers[msg.sender].timeOfLastUpdate = block.timestamp;

        totalStaked++;
    }

    // Check if user has any ERC721 Tokens Staked and if they tried to withdraw,
    // calculate the rewards and store them in the unclaimedRewards
    // decrement the amountStaked of the user and transfer the ERC721 token back to them
    function withdraw(uint256 _tokenId) external nonReentrant {
        // Make sure the user has at least one token staked before withdrawing
        require(
            stakers[msg.sender].amountStaked > 0,
            "You have no tokens staked"
        );

        // Wallet must own the token they are trying to withdraw
        require(
            stakerAddress[_tokenId] == msg.sender,
            "You don't own this token!"
        );

        // Update the rewards for this user, as the amount of rewards decreases with less tokens.
        TokenReward[] memory _rewards = availableRewards(msg.sender);

        delete stakers[msg.sender].rewards;
        for (uint256 i = 0; i < _rewards.length; i++) {
            stakers[msg.sender].rewards.push(_rewards[i]);
        }

        // Find the index of this token id in the stakedTokens array
        uint256 index = 0;
        for (uint256 i = 0; i < stakers[msg.sender].stakedTokens.length; i++) {
            if (
                stakers[msg.sender].stakedTokens[i].tokenId == _tokenId &&
                stakers[msg.sender].stakedTokens[i].staker != address(0)
            ) {
                index = i;
                break;
            }
        }

        // Set this token's .staker to be address 0 to mark it as no longer staked
        stakers[msg.sender].stakedTokens[index].staker = address(0);

        // Decrement the amount staked for this wallet
        stakers[msg.sender].amountStaked--;

        // Update the mapping of the tokenId to the be address(0) to indicate that the token is no longer staked
        stakerAddress[_tokenId] = address(0);

        // Transfer the token back to the withdrawer
        nftCollection.transferFrom(address(this), msg.sender, _tokenId);

        // Update the timeOfLastUpdate for the withdrawer
        stakers[msg.sender].timeOfLastUpdate = block.timestamp;

        totalStaked--;
    }

    // Calculate rewards for the msg.sender, check if there are any rewards
    // claim, set unclaimedRewards to 0 and transfer the ERC20 Reward token
    // to the user.
    function claimRewards() external {
        TokenReward[] memory _rewards = availableRewards(msg.sender);

        uint256 _totalRewards;
        for (uint256 i = 0; i < _rewards.length; i++) {
            _totalRewards += _rewards[i].unclaimedReward;
        }

        require(_totalRewards > 0, "You have no rewards to claim");

        for (uint256 i = 0; i < _rewards.length; i++) {
            stakers[msg.sender].timeOfLastUpdate = block.timestamp;

            uint256 index = 0;
            for (uint256 j = 0; j < stakers[msg.sender].rewards.length; j++) {
                if (stakers[msg.sender].rewards[j].token == _rewards[i].token) {
                    index = j;
                    break;
                }
            }

            stakers[msg.sender].rewards[index].unclaimedReward = 0;

            IERC20 _rewardsToken = IERC20(_rewards[i].token);
            _rewardsToken.safeTransfer(msg.sender, _rewards[i].unclaimedReward);
        }
    }

    //////////
    // View //
    //////////

    function availableRewards(address _staker)
        public
        view
        returns (TokenReward[] memory)
    {
        TokenReward[] memory _rewards = new TokenReward[](
            stakers[_staker].rewards.length
        );

        TokenReward[] memory _calculatedRewards = calculateRewards(_staker);

        for (uint256 i = 0; i < stakers[_staker].rewards.length; i++) {
            bool _rewardExists;
            uint256 index;
            for (uint256 j = 0; j < _calculatedRewards.length; j++) {
                if (
                    stakers[_staker].rewards[i].token ==
                    _calculatedRewards[j].token
                ) {
                    index = j;
                    _rewardExists = true;
                    break;
                } else {
                    _rewardExists = false;
                }
            }

            if (_rewardExists) {
                uint256 _reward = _calculatedRewards[index].unclaimedReward +
                    stakers[_staker].rewards[i].unclaimedReward;

                TokenReward memory _tokenReward = TokenReward(
                    stakers[_staker].rewards[i].token,
                    stakers[_staker].rewards[i].rateOfReward,
                    _reward
                );

                _rewards[i] = _tokenReward;
            }
        }

        return _rewards;
    }

    function getStakedTokens(address _user)
        public
        view
        returns (StakedToken[] memory)
    {
        // Check if we know this user
        if (stakers[_user].amountStaked > 0) {
            // Return all the tokens in the stakedToken Array for this user that are not -1
            StakedToken[] memory _stakedTokens = new StakedToken[](
                stakers[_user].amountStaked
            );
            uint256 _index = 0;

            for (uint256 j = 0; j < stakers[_user].stakedTokens.length; j++) {
                if (stakers[_user].stakedTokens[j].staker != (address(0))) {
                    _stakedTokens[_index] = stakers[_user].stakedTokens[j];
                    _index++;
                }
            }

            return _stakedTokens;
        }
        // Otherwise, return empty array
        else {
            return new StakedToken[](0);
        }
    }

    /////////////
    // Internal//
    /////////////

    // Calculate rewards for param _staker by calculating the time passed
    // since last update in hours and mulitplying it to ERC721 Tokens Staked
    // and rewardsPerHour.
    function calculateRewardsOld(address _staker)
        internal
        view
        returns (uint256 _rewards)
    {
        return (((
            ((block.timestamp - stakers[_staker].timeOfLastUpdate) *
                stakers[_staker].amountStaked)
        ) * rewardsPerHour) / 3600);
    }

    uint256 rateOfReward = 2;

    function calculateRewards(address _staker)
        internal
        view
        returns (TokenReward[] memory)
    {
        TokenReward[] memory _reward = new TokenReward[](
            stakers[_staker].rewards.length
        );

        for (uint256 i = 0; i < stakers[_staker].rewards.length; i++) {
            IERC20 _rewardTokenContract = IERC20(
                stakers[_staker].rewards[i].token
            );
            uint256 _rewardTokenTreasuryBalance = _rewardTokenContract
                .balanceOf(address(this));
            uint256 _treasuryRewardsPerYear = _rewardTokenTreasuryBalance /
                stakers[_staker].rewards[i].rateOfReward;

            uint256 _calculatedReward = ((((
                ((block.timestamp - stakers[_staker].timeOfLastUpdate) *
                    stakers[_staker].amountStaked)
            ) * _treasuryRewardsPerYear) / totalStaked) / 3153600);

            TokenReward memory _tokenReward = TokenReward(
                stakers[_staker].rewards[i].token,
                stakers[_staker].rewards[i].rateOfReward,
                _calculatedReward
            );
            _reward[i] = _tokenReward;
        }
        return _reward;
    }
}
