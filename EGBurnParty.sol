// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/KeeperCompatible.sol";

/**
 *  _______  ______      ______  _     _  ______ __   _       _____  _______  ______ _______ __   __
 *  |______ |  ____      |_____] |     | |_____/ | \  |      |_____] |_____| |_____/    |      \_/  
 *  |______ |_____|      |_____] |_____| |    \_ |  \_|      |       |     | |    \_    |       |   
 *                                                                                                  
 */

contract EGBurnParty is Ownable, KeeperCompatibleInterface {

    using Counters for Counters.Counter;

    struct BurnToken {
        uint256 index;
        address token;
        address burnAddress;
        uint256 minStakeAmount;
        uint256 maxStakeAmount;
        bool enabled;
    }

    struct BurnParty {
        uint256 partyId;
        string partyAPI;
        address creator;
        address token;
        uint256 burnDate;
        uint256 period;
        uint256 currentQuantity;
        uint256 requiredQuantity;
        uint256 maxStakeAmount;
        uint256 stakeCounter;
        bool started;
        bool cancelled;
        bool ended;
    }

    struct StakingPeriod{
        uint256 index;
        uint256 period;
        uint256 partyCount;
        uint256 currentPartyIndex;
        bool enabled;
    }

    struct StakeInfo{
        uint256 amount;
        bool unstaked;
    }

    // gas fee to pay LINK to ChainLink for automation of burning
    uint256 public gasFeeAmount;
    
    // `burnTokenCounter` detail: number of burn token
    Counters.Counter public burnTokenCounter;

    // `burnTokens` detail: tokenAddress => token information
    mapping (address => BurnToken) public burnTokens;

    // `burnTokenIndices` detail: token index => token address
    mapping (uint256 => address) public burnTokenIndices;

    
    // `partyCounter` detail: number of parties
    Counters.Counter public partyCounter;
    
    // `burnParties` detail: id => BurnParty
    mapping (uint256 => BurnParty) public burnParties;

    // `Stakes List` detail: Client_Address => Party_Id => Token_Amount
    mapping (address => mapping (uint256 => StakeInfo)) public stakesList;
    
    
    // `periodCounter` detail: number of staking periods
    Counters.Counter public periodCounter;
    
    // `stakingPeriods` detail: period day => staking period
    mapping(uint256 => StakingPeriod) public stakingPeriods;

    // `periodIndexToDay` detail: period index => period day
    mapping(uint256 => uint256) public periodIndices;

    // period => index => party ID
    mapping(uint256 => mapping(uint256 => uint256)) public periodBurnParties;

    event SetMinStakeAmount(address indexed tokenAddress, uint256 minStakeAmount);
    event SetMaxStakeAmount(address indexed tokenAddress, uint256 maxStakeAmount);
    event AddBurnToken(address indexed tokenAddress, address indexed burnAddress, uint256 minStakeAmount, uint256 maxStakeAmount);
    event SetBurnTokenStatus(address indexed tokenAddress, bool status);
    
    event CreateBurnParty(
        uint256 partyId,
        string partyAPI,
        address indexed creator,
        address indexed token, 
        uint256 startDate,
        uint256 period,
        uint256 indexed requiredQuantity, 
        uint256 stakeAmount,
        uint256 realStakeAmount,
        uint256 gasFeeAmount
    );
    event EndBurnParty(uint256 partyId, address indexed caller, address indexed burnToken, uint256 indexed amount, uint256 realAmount, address burnAddress);
    event CancelBurnParty(uint256 partyId, address indexed caller, address indexed burnToken, uint256 indexed amount);
    event AdminCancelBurnParty(uint256 partyId, address indexed caller, address indexed burnToken, uint256 indexed amount);
    event StakeBurnParty(uint256 indexed partyId, address indexed staker, uint256 indexed amount, uint256 realAmount, uint256 gasFeeAmount);
    event UnstakeFromBurnParty(uint256 indexed partyId, address indexed staker, uint256 indexed amount, uint256 realAmount);

    event RemovePeriod(uint256 period);
    event AddPeriod(uint256 period);
    event SetPeriodStatus(uint256 period, bool status);
    
    event SetGasFeeAmount(uint256 feeAmount);
    event WithdrawGasFee(address indexed feeAddress, uint256 amount);

    constructor() {

    }

    /**
    * @param  feeAmount this is amount of fee tokens
    *
    **/
    function setGasFeeAmount(uint256 feeAmount) external onlyOwner {
        require(feeAmount > 0, "EGBurnParty: Fee amount should be positive number");

        gasFeeAmount = feeAmount;

        emit SetGasFeeAmount(feeAmount);
    }

    /**
    * @param  feeAddress address to receive fee
    *
    **/
    function withdrawGasFee(address payable feeAddress) external onlyOwner {
        uint256 balance = address(this).balance;
        require(feeAddress != address(0), "EGBurnParty: The zero address should not be the fee address");
        require(balance > 0, "EGBurnParty: No balance to withdraw");

        (bool success, ) = feeAddress.call{value: balance}("");
        require(success, "EGBurnParty: Withdraw failed");

        emit WithdrawGasFee(feeAddress, balance);
    }
    function existPeriod(uint256 period) public view returns (bool){
        require(period > 0, "EGBurnParty: Period should be a positive number");
        return period == periodIndices[stakingPeriods[period].index];
    }

    /**
    * @param period date 
    *
    **/
    function addPeriod(uint256 period) external onlyOwner {
        require(period > 0, "EGBurnParty: Period should be a positive number");
        require(existPeriod(period) == false, "EGBurnParty: Period has been already added.");
        
        StakingPeriod memory _stakingPeriod = StakingPeriod({
            index: periodCounter.current(),
            period: period,
            partyCount: 0,
            currentPartyIndex: 0,
            enabled: true
        });
        stakingPeriods[period] = _stakingPeriod;
        periodIndices[periodCounter.current()] = period;

        periodCounter.increment();

        emit AddPeriod(period);
    }

    /**
    * @param period date
    *
    **/
    function removePeriod(uint256 period) external onlyOwner {
        require(period > 0, "EGBurnParty: Period should be a positive number");
        require(existPeriod(period) == true, "EGBurnParty: Period is not added.");
        require(stakingPeriods[period].partyCount == stakingPeriods[period].currentPartyIndex, "EGBurnParty: You cannot remove a period that has parties created against it");
        
        uint256 _lastIndex = periodCounter.current() - 1;
        uint256 _currentIndex = stakingPeriods[period].index;

        if(_currentIndex != _lastIndex){
            uint256 _lastPeriod = periodIndices[_lastIndex];
            periodIndices[_currentIndex] = _lastPeriod;
            stakingPeriods[_lastPeriod].index = _currentIndex;
            stakingPeriods[_lastPeriod].period = _lastPeriod;
        }

        delete stakingPeriods[period];
        delete periodIndices[_lastIndex];

        periodCounter.decrement();

        emit RemovePeriod(period);
    }

    /**
    * @param period date
    *
    **/
    function setPeriodStatus(uint256 period, bool status) external onlyOwner {
        require(period > 0, "EGBurnParty: Period should be a positive number");
        require(existPeriod(period) == true, "EGBurnParty: Period is not added.");

        stakingPeriods[period].enabled = status;

        emit SetPeriodStatus(period, status);
    }

    /**
    * method called from offchain - chainlink
    * call performUnkeep with partyId if returns true
    **/
    function checkUpkeep(bytes calldata /*checkData*/) external override view returns (bool, bytes memory) {
        for(uint256 i = 0; i < periodCounter.current(); i ++){
            uint256  _period = periodIndices[i];
            StakingPeriod storage _stakingPeriod = stakingPeriods[_period];
            if(_stakingPeriod.currentPartyIndex < _stakingPeriod.partyCount){
                uint256 _partyId = periodBurnParties[_period][_stakingPeriod.currentPartyIndex];
                if (
                    burnParties[_partyId].started == true && 
                    burnParties[_partyId].ended == false && 
                    block.timestamp >= burnParties[_partyId].burnDate
                )
                {
                    return (true, abi.encode(_partyId));
                }    
            }
        }
        return (false, abi.encode(""));
    }
    
    /**
    * method called from offchain - chainlink
    * call performUnkeep with partyId if returns true
    **/
    function performUpkeep(bytes calldata performData) external override {
        (uint256 partyId) = abi.decode(performData, (uint256));
        BurnParty storage party = burnParties[partyId];
        require(party.started == true, "EGBurnParty: Party has not started.");
        require(party.ended == false, "EGBurnParty: Party has already ended.");
        require(block.timestamp >= party.burnDate, "EGBurnParty: You can cancel a burn party only after burn date.");
        
        if(party.currentQuantity >= party.requiredQuantity)
            endBurnParty(partyId);
        else
            cancelBurnParty(partyId);
    }


    function existBurnToken(address tokenAddress) public view returns (bool){
        require(tokenAddress != address(0), "EGBurnParty: The zero address should not be added as a burn token");

        return tokenAddress == burnTokenIndices[burnTokens[tokenAddress].index];
    }

    /**
    * @param tokenAddress       burn token address
    * @param burnAddress        burning address
    * @param minStakeAmount     init stake amount
    * @param maxStakeAmount     max stake amount
    * @dev  add burn token
    *       fire `AddBurnToken` event
    */
    function addBurnToken(address tokenAddress, address burnAddress, uint256 minStakeAmount, uint256 maxStakeAmount) external onlyOwner {
        require(tokenAddress != address(0), "EGBurnParty: The zero address should not be added as a burn token");
        require(burnAddress != address(0), "EGBurnParty: The zero address should not be added as a burn address");
        require(minStakeAmount > 0, "EGBurnParty: Stake amount should be a positive number.");
        if(maxStakeAmount > 0){ // if zero maxStakeAmount means no limit of transactions
            require(maxStakeAmount >= minStakeAmount, "EGBurnParty: Max stake amount should be zero or bigger than the minimum stake amount.");
        }
        require(existBurnToken(tokenAddress) == false, "EGBurnParty: Token has been already added.");
        
        BurnToken memory burnToken = BurnToken({
            index: burnTokenCounter.current(),
            token: tokenAddress,
            burnAddress: burnAddress,
            minStakeAmount: minStakeAmount,
            maxStakeAmount: maxStakeAmount,
            enabled: true
        });
        burnTokens[tokenAddress] = burnToken;
        burnTokenIndices[burnTokenCounter.current()] = tokenAddress;

        burnTokenCounter.increment();

        emit AddBurnToken(tokenAddress, burnAddress, minStakeAmount, maxStakeAmount);
    }

    /**
    * @param tokenAddress       burn token address
    * @param minStakeAmount    initial stake amount
    * @dev  set the initial stake amount
    *       fire `SetMinStakeAmount` event
    */
    function setMinStakeAmount(address tokenAddress, uint256 minStakeAmount) external onlyOwner {
        require(tokenAddress != address(0), "EGBurnParty: The zero address should not be added as a burn token");
        require(minStakeAmount > 0, "EGBurnParty: Initial stake amount should be a positive number.");
        if(burnTokens[tokenAddress].maxStakeAmount > 0){ // if zero maxStakeAmount means no limit of transactions
            require(minStakeAmount <= burnTokens[tokenAddress].maxStakeAmount, "EGBurnParty: Stake amount should be smaller than the max stake amount.");
        }
        require(existBurnToken(tokenAddress) == true, "EGBurnParty: The token is not added as a burn token.");

        burnTokens[tokenAddress].minStakeAmount = minStakeAmount;

        emit SetMinStakeAmount(tokenAddress, minStakeAmount);
    }

    /**
    * @param tokenAddress       burn token address
    * @param maxStakeAmount     max stake amount
    * @dev  set the max stake amount
    *       fire `SetMaxStakeAmount` event
    */
    function setMaxStakeAmount(address tokenAddress, uint256 maxStakeAmount) external onlyOwner {
        require(tokenAddress != address(0), "EGBurnParty: The zero address should not be added as a burn token");
        if(maxStakeAmount > 0){ // if zero maxStakeAmount means no limit of transactions
            require(maxStakeAmount >= burnTokens[tokenAddress].minStakeAmount, "EGBurnParty: Max stake amount should be zero or bigger than the minimum stake amount.");
        }
        require(existBurnToken(tokenAddress) == true, "EGBurnParty: The token is not added as a burn token.");

        burnTokens[tokenAddress].maxStakeAmount = maxStakeAmount;

        emit SetMaxStakeAmount(tokenAddress, maxStakeAmount);
    }

    /**
    * @param tokenAddress       burn token address
    * @param status    burn token status
    * @dev  enable or disable this burn token
    *       fire `SetMinStakeAmount` event
    */
    function setBurnTokenStatus(address tokenAddress, bool status) external onlyOwner {
        require(tokenAddress != address(0), "EGBurnParty: The zero address should not be added as a burn token");
        require(existBurnToken(tokenAddress) == true, "EGBurnParty: The token is not added as a burn token.");

        burnTokens[tokenAddress].enabled = status;

        emit SetBurnTokenStatus(tokenAddress, status);
    }

    /**
    * @param token burn token
    * @param requiredQuantity minium amount for burnning
    *
    * @dev  create burn party object
    *       insert object into `burnParties`
    *       fire `CreateBurnParty` event
    */
    function createBurnParty(
        string calldata partyAPI,
        address token,
        uint256 period,
        uint256 requiredQuantity,
        uint256 stakeAmount
    )
        external payable
    {
        BurnToken storage _burnToken = burnTokens[token];
         require( bytes(partyAPI).length > 0, 
            "EGBurnParty: Empty string should not be added as a partyAPI");
        require( token != address(0), 
            "EGBurnParty: The zero address should not be a party token");
        require(existBurnToken(token) == true, 
            "EGBurnParty: The token is not added as a burn token.");
        require(_burnToken.enabled == true, 
            "EGBurnParty: The token is not enabled");
        require(period > 0, 
            "EGBurnParty: The period should be a positive number");
        require(existPeriod(period) == true, 
            "EGBurnParty: The period is not added.");
        require(stakingPeriods[period].enabled == true, 
            "EGBurnParty: The period is not enabled.");
        require(requiredQuantity > 0, 
            "EGBurnParty: Required quantity should be a positive number.");
        require(stakeAmount >= _burnToken.minStakeAmount,
            "EGBurnParty: Stake amount should be greater than the min stake amount.");
        if(_burnToken.maxStakeAmount > 0){ // if zero maxStakeAmount means no limit of transactions
            require(requiredQuantity <= _burnToken.maxStakeAmount, 
            "EGBurnParty: Required quantity should be smaller than the max stake amount.");
            require(stakeAmount <= _burnToken.maxStakeAmount,
            "EGBurnParty: Stake amount should be smaller than the max stake amount.");
        }
        require(msg.value >= gasFeeAmount,
            "EGBurnParty: Insufficent value for gas fee");
        require(IERC20(token).balanceOf(msg.sender) >= stakeAmount,
            "EGBurnParty: There is not the enough tokens in your wallet to create burn party.");

        uint256 _beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).transferFrom(msg.sender, address(this), stakeAmount);
        uint256 _stakeAmount = IERC20(token).balanceOf(address(this)) - _beforeBalance;

        BurnParty memory party = BurnParty({
            partyId: partyCounter.current(),
            partyAPI: partyAPI,
            creator: msg.sender,
            token: token,
            burnDate: block.timestamp + period * 60,
            period: period,
            currentQuantity: _stakeAmount,
            requiredQuantity: requiredQuantity,
            maxStakeAmount: _burnToken.maxStakeAmount,
            stakeCounter: 1,
            started: true,
            cancelled: false,
            ended: false
        });

        burnParties[partyCounter.current()] = party;
        StakeInfo memory _stakeInfo = StakeInfo({
            amount: _stakeAmount,
            unstaked: false
        });
        stakesList[msg.sender][partyCounter.current()] = _stakeInfo;
        periodBurnParties[period][stakingPeriods[period].partyCount] = partyCounter.current();
        stakingPeriods[period].partyCount ++;
        partyCounter.increment();

        emit CreateBurnParty(
            partyCounter.current() - 1, 
            partyAPI,
            msg.sender,
            token,
            block.timestamp,
            period,
            requiredQuantity, 
            stakeAmount,
            _stakeAmount,
            msg.value
        );
    }

    /**
    * @param partyId burn party id
    * @dev end burn party by id
    *      fire `EndBurnParty` event
    */
    function endBurnParty(uint256 partyId) public {
        BurnParty storage _party = burnParties[partyId];
        require(_party.started == true, "EGBurnParty: Party is not started.");
        require(_party.ended == false, "EGBurnParty: Party has already ended.");
        require(block.timestamp >= _party.burnDate, 
                "EGBurnParty: You can end burn party after burn date.");
        require(IERC20(_party.token).balanceOf(address(this)) >= _party.currentQuantity, 
                "EGBurnParty: Current balance of token is not enough to end the burn party.");
        require(_party.currentQuantity >= _party.requiredQuantity, 
            "EGBurnParty: Tokens currently staked are less than the quantity required for the burn");
        uint256 _currentPartyIndex = stakingPeriods[_party.period].currentPartyIndex;
        require(partyId == periodBurnParties[_party.period][_currentPartyIndex],  
            "EGBurnParty: You need to end the earliest party first");

        _party.ended = true;
        stakingPeriods[_party.period].currentPartyIndex ++;

        uint256 _beforeBalance = IERC20(_party.token).balanceOf(burnTokens[_party.token].burnAddress);
        IERC20(_party.token)
            .transfer(burnTokens[_party.token].burnAddress, _party.currentQuantity);
        uint256 _burnAmount = IERC20(_party.token).balanceOf(burnTokens[_party.token].burnAddress) - _beforeBalance;

        emit EndBurnParty(partyId, msg.sender, _party.token, _party.currentQuantity, _burnAmount, burnTokens[_party.token].burnAddress);
    }

    /**
    * @param partyId burn party id
    * @dev cancel burn party by id
    *      fire `CancelBurnParty` event
    */
    function cancelBurnParty(uint256 partyId) public {
        BurnParty storage _party = burnParties[partyId];
        require(_party.started == true, "EGBurnParty: Party is not started.");
        require(_party.ended == false, "EGBurnParty: Party has already ended.");
        require(block.timestamp >= _party.burnDate, "EGBurnParty: You can cancel a burn party only after burn date.");
        require(_party.currentQuantity < _party.requiredQuantity, 
                "EGBurnParty: You cannot cancel a burn party which has collected the required amount of tokens.");
        uint256 _currentPartyIndex = stakingPeriods[_party.period].currentPartyIndex;
        require(partyId == periodBurnParties[_party.period][_currentPartyIndex], 
            "EGBurnParty: You need to cancel the earliest party first");

        _party.ended = true;
        _party.cancelled = true;

        stakingPeriods[_party.period].currentPartyIndex ++;

        emit CancelBurnParty(partyId, msg.sender, _party.token, _party.currentQuantity);
    }

    /**
    * @param partyId burn party id
    * @dev cancel burn party by id
    *      fire `AdminCancelBurnParty` event
    */
    function adminCancelBurnParty(uint256 partyId) public onlyOwner {
        BurnParty storage _party = burnParties[partyId];
        require(_party.started == true, "EGBurnParty: Party is not started.");
        require(_party.ended == false, "EGBurnParty: Party has already ended.");
        require(block.timestamp >= _party.burnDate, "EGBurnParty: You can cancel a burn party only after burn date.");
        uint256 _currentPartyIndex = stakingPeriods[_party.period].currentPartyIndex;
        require(partyId == periodBurnParties[_party.period][_currentPartyIndex], 
            "EGBurnParty: You need to cancel the earliest party first.");

        _party.ended = true;
        _party.cancelled = true;

        stakingPeriods[_party.period].currentPartyIndex ++;

        emit AdminCancelBurnParty(partyId, msg.sender, _party.token, _party.currentQuantity);
    }

    /**
    * @param partyId burn party id
    * @param tokenAmount stake token amount
    * @dev  fire `StakeBurnParty` event
    */
    function stakeBurnParty(uint256 partyId, uint256 tokenAmount) external payable {
        BurnParty storage _party = burnParties[partyId];
        require(tokenAmount > 0, "EGBurnParty: Amount required to burn should be a positive number.");
        if(_party.maxStakeAmount > 0){ // if zero maxStakeAmount means no limit of transactions
            require(tokenAmount + _party.currentQuantity <= _party.maxStakeAmount, "EGBurnParty: Amount required to burn should be smaller than the available stake amount.");
        }
        require(_party.started == true, "EGBurnParty: Burn Party has not started.");
        require(_party.ended == false, "EGBurnParty: Burn Party has ended.");
        require(msg.value >= gasFeeAmount,
            "EGBurnParty: Not insufficent value for gas fee");
        require(IERC20(_party.token).balanceOf(msg.sender) >= tokenAmount, "EGBurnParty: Your token balance is insufficient for this burn party stake.");

        if(stakesList[msg.sender][partyId].amount == 0){
            _party.stakeCounter ++;
        }

        uint256 _beforeBalance = IERC20(_party.token).balanceOf(address(this));
        IERC20(_party.token).transferFrom(msg.sender, address(this), tokenAmount);
        uint256 _tokenAmount = IERC20(_party.token).balanceOf(address(this)) - _beforeBalance;

        _party.currentQuantity += _tokenAmount;
        stakesList[msg.sender][partyId].amount += _tokenAmount;


        emit StakeBurnParty(partyId, msg.sender, tokenAmount, _tokenAmount, msg.value);
    }

    /**
    * @param partyId burn party id
    * @dev fire `UnstakeFromBurnParty` event
    */
    function unstakeFromBurnParty(uint256 partyId) external {
        BurnParty storage _party = burnParties[partyId];
        StakeInfo storage _stakeInfo = stakesList[msg.sender][partyId];
        require(_stakeInfo.amount > 0, "EGBurnParty: You have not participated in this burn party.");
        require(!_stakeInfo.unstaked, "EGBurnParty: You have already unstaked from this burn party.");
        require( _party.cancelled == true, 
                 "EGBurnParty: You can unstake when the burn party is cancelled or after burn date.");
        require(IERC20(_party.token).balanceOf(address(this)) >= _stakeInfo.amount, 
                "EGBurnParty: Out of balance.");
        
        uint256 _beforeBalance = IERC20(_party.token).balanceOf(msg.sender);
        IERC20(_party.token).transfer(msg.sender, _stakeInfo.amount);
        uint256 _amount = IERC20(_party.token).balanceOf(msg.sender) - _beforeBalance;

        _party.currentQuantity -= _stakeInfo.amount;
        _party.stakeCounter--;
        
        stakesList[msg.sender][partyId].unstaked = true;
        

        emit UnstakeFromBurnParty(partyId, msg.sender, _stakeInfo.amount, _amount);
    }
}
