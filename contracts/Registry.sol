pragma solidity ^0.4.11;

import "./historical/StandardToken.sol";
import "./PLCRVoting.sol";
import "./Parameterizer.sol";

contract Registry {

    // ------
    // EVENTS
    // ------

    event _Application(string domain, uint deposit);
    event _Challenge(string domain, uint deposit, uint pollID);
    event _Deposit(string domain, uint added, uint newTotal);
    event _Withdrawal(string domain, uint withdrew, uint newTotal);
    event _NewDomainWhitelisted(string domain);
    event _ApplicationRemoved(string domain);
    event _ListingRemoved(string domain);
    event _ChallengeFailed(uint challengeID);
    event _ChallengeSucceeded(uint challengeID);
    event _RewardClaimed(address voter, uint challengeID, uint reward);

    struct Listing {
        uint applicationExpiry; // expiration date of apply stage
        bool whitelisted;       // indicates registry status
        address owner;          // owner of Listing
        uint unstakedDeposit;   // number of unlocked tokens with potential risk if challenged
        uint challengeID;       // identifier of canonical challenge
    }

    struct Challenge {
        uint rewardPool;        // (remaining) pool of tokens distributed amongst winning voters
        address challenger;     // owner of Challenge
        bool resolved;          // indication of if challenge is resolved
        uint stake;             // number of tokens at risk for either party during challenge
        uint totalTokens;       // (remaining) amount of tokens used for voting by the winning side
    }

    // maps challengeIDs to associated challenge data
    mapping(uint => Challenge) public challengeMap;
    // maps domainHashes to associated listing data
    mapping(bytes32 => Listing) public listingMap;
    // maps challengeIDs and address to token claim data
    mapping(uint => mapping(address => bool)) public tokenClaims;

    // Global Variables
    StandardToken public token;
    PLCRVoting public voting;
    Parameterizer public parameterizer;

    // ------------
    // CONSTRUCTOR:
    // ------------

    function Registry(
        address _tokenAddr,
        address _paramsAddr
    ) {
        token = StandardToken(_tokenAddr);
        parameterizer = Parameterizer(_paramsAddr);
        voting = new PLCRVoting(_tokenAddr);
    }

    // --------------------
    // PUBLISHER INTERFACE:
    // --------------------

    //Allow a user to start an application
    //take tokens from user and set apply stage end time
    function apply(string _domain, uint _amount) external {
        bytes32 domainHash = sha3(_domain);
        require(!isWhitelisted(domainHash));
        require(!appExists(domainHash));
        require(_amount >= parameterizer.get("minDeposit"));

        //set owner
        Listing storage listing = listingMap[domainHash];
        listing.owner = msg.sender; 

        //transfer tokens
        require(token.transferFrom(listing.owner, this, _amount)); 

        //set apply stage end time
        listing.applicationExpiry = block.timestamp + parameterizer.get("applyStageLen"); 
        listing.unstakedDeposit = _amount;

        _Application(_domain, _amount);
    }

    //Allow the owner of a domain in the listing to increase their deposit
    function deposit(string domain, uint amount) external {
        Listing storage listing = listingMap[sha3(domain)];

        require(listing.owner == msg.sender);
        require(token.transferFrom(msg.sender, this, amount));

        listing.unstakedDeposit += amount;

        _Deposit(domain, amount, listing.unstakedDeposit);
    }

    //Allow the owner of a domain in the listing to withdraw
    //tokens not locked in a challenge (unstaked).
    //The publisher's domain remains whitelisted
    function withdraw(string domain, uint amount) external {
        Listing storage listing = listingMap[sha3(domain)];

        require(listing.owner == msg.sender);
        require(amount <= listing.unstakedDeposit);
        require(listing.unstakedDeposit - amount >= parameterizer.get("minDeposit"));

        require(token.transfer(msg.sender, amount));

        listing.unstakedDeposit -= amount;

        _Withdrawal(domain, amount, listing.unstakedDeposit);
    }

    //Allow the owner of a domain to remove the domain from the whitelist
    //Return all tokens to the owner
    function exit(string _domain) external {
        bytes32 domainHash = sha3(_domain);
        Listing storage listing = listingMap[domainHash];

        require(msg.sender == listing.owner);
        require(isWhitelisted(domainHash));
        // cannot exit during ongoing challenge
        require(listing.challengeID == 0 || challengeMap[listing.challengeID].resolved);

        //remove domain & return tokens
        resetListing(domainHash);
    }

    // -----------------------
    // TOKEN HOLDER INTERFACE:
    // -----------------------

    //start a poll for a domain in the apply stage or already on the whitelist
    //tokens are taken from the challenger and the publisher's tokens are locked
    function challenge(string domain) external returns (uint challengeID) {
        bytes32 domainHash = sha3(domain);
        Listing storage listing = listingMap[domainHash];
        //to be challenged, domain must be in apply stage or already on the whitelist
        require(appExists(domainHash) || listing.whitelisted); 
        // prevent multiple challenges
        require(listing.challengeID == 0 || challengeMap[listing.challengeID].resolved);
        uint deposit = parameterizer.get("minDeposit");
        if (listing.unstakedDeposit < deposit) {
            // not enough tokens, publisher auto-delisted
            resetListing(domainHash);
            return 0;
        }
        //take tokens from challenger
        require(token.transferFrom(msg.sender, this, deposit));
        //start poll
        uint pollID = voting.startPoll(
            parameterizer.get("voteQuorum"),
            parameterizer.get("commitPeriodLen"),
            parameterizer.get("revealPeriodLen")
        );

        challengeMap[pollID] = Challenge({
            challenger: msg.sender,
            rewardPool: ((100 - parameterizer.get("dispensationPct")) * deposit) / 100, 
            stake: deposit,
            resolved: false,
            totalTokens: 0
        });

        listingMap[domainHash].challengeID = pollID;       // update listing to store most recent challenge
        listingMap[domainHash].unstakedDeposit -= deposit; // lock tokens for listing during challenge

        _Challenge(domain, deposit, pollID);
        return pollID;
    }

    /**
    @notice updates a domain's status from application to listing, or resolves a challenge if one exists
    @param _domain The domain whose status is being updated
    */
    function updateStatus(string _domain) public {
        bytes32 domainHash = sha3(_domain);
        if (canBeWhitelisted(domainHash)) {
          whitelistApplication(domainHash);
          _NewDomainWhitelisted(_domain);
        } else if (challengeCanBeResolved(domainHash)) {
          resolveChallenge(_domain, domainHash);
        } else {
          revert();
        }
    }

    // ----------------
    // TOKEN FUNCTIONS:
    // ----------------

    // called by voter to claim reward for each completed vote
    // someone must call updateStatus() before this can be called
    function claimReward(uint _challengeID, uint _salt) public {
        // ensure voter has not already claimed tokens and challenge results have been processed
        require(tokenClaims[_challengeID][msg.sender] == false);
        require(challengeMap[_challengeID].resolved = true);

        uint voterTokens = voting.getNumPassingTokens(msg.sender, _challengeID, _salt);
        uint reward = calculateVoterReward(msg.sender, _challengeID, _salt);

        // subtract voter's information to preserve the participation ratios of other voters
        // compared to the remaining pool of rewards
        challengeMap[_challengeID].totalTokens -= voterTokens;
        challengeMap[_challengeID].rewardPool -= reward;

        require(token.transfer(msg.sender, reward));
        
        // ensures a voter cannot claim tokens again

        tokenClaims[_challengeID][msg.sender] = true;

        _RewardClaimed(msg.sender, _challengeID, reward);
    }

    /**
    @dev Calculate the provided voter's token reward for the given poll
    @param _voter Address of the voter whose reward balance is to be returned
    @param _challengeID pollID of the challenge a reward balance is being queried for
    @param _salt the salt for the voter's commit hash in the given poll
    @return a uint indicating the voter's reward in nano-adToken
    */
    function calculateVoterReward(address _voter, uint _challengeID, uint _salt)
    public constant returns (uint) {
        uint totalTokens = challengeMap[_challengeID].totalTokens;
        uint rewardPool = challengeMap[_challengeID].rewardPool;
        uint voterTokens = voting.getNumPassingTokens(_voter, _challengeID, _salt);
        return (voterTokens * rewardPool) / totalTokens;
    }
    
    // --------
    // GETTERS:
    // --------

    /**
    @dev determines whether a domain is an application which can be whitelisted
    @param _domainHash the domain whose status should be examined
    */
    function canBeWhitelisted(bytes32 _domainHash) constant public returns (bool) {
      uint challengeID = listingMap[_domainHash].challengeID;

      // TODO: change name of appExists to appWasMade.
      if (appExists(_domainHash) && isExpired(listingMap[_domainHash].applicationExpiry) &&
          !isWhitelisted(_domainHash) &&
          (challengeID == 0 || challengeMap[challengeID].resolved == true))
      { return true; }

      return false;
    }

    //return true if domain is whitelisted
    function isWhitelisted(bytes32 _domainHash) constant public returns (bool whitelisted) {
        return listingMap[_domainHash].whitelisted;
    } 

    //return true if apply(domain) was called for this domain
    function appExists(bytes32 _domainHash) constant public returns (bool exists) {
        return listingMap[_domainHash].applicationExpiry > 0;
    }

    // return true if the listing has an unresolved challenge
    function challengeExists(bytes32 _domainHash) constant public returns (bool) {
        uint challengeID = listingMap[_domainHash].challengeID;

        return (listingMap[_domainHash].challengeID > 0 && !challengeMap[challengeID].resolved);
    }

    /**
    @notice determines whether voting has concluded in a challenge for a given domain. Throws if no challenge exists.
    @param _domainHash a domain with an unresolved challenge
    */
    function challengeCanBeResolved(bytes32 _domainHash) constant public returns (bool) {
        uint challengeID = listingMap[_domainHash].challengeID;

        require(challengeExists(_domainHash));

        return voting.pollEnded(challengeID);
    }

    //return true if termDate has passed
    function isExpired(uint termDate) constant public returns (bool expired) {
        return termDate < block.timestamp;
    }

    //delete listing from whitelist and return tokens to owner
    function resetListing(bytes32 _domainHash) internal {
        Listing storage listing = listingMap[_domainHash];
        //transfer any remaining balance back to the owner
        if (listing.unstakedDeposit > 0)
            require(token.transfer(listing.owner, listing.unstakedDeposit));
        delete listingMap[_domainHash];
    }

    // ----------------
    // PRIVATE FUNCTIONS:
    // ----------------

    /**
    @dev determines the winner in a challenge, rewards them tokens, and either whitelists or de-whitelists the domain
    @param _domain a domain with an unresolved challenge
    */
    function resolveChallenge(string _domain, bytes32 _domainHash) private {
        uint challengeID = listingMap[_domainHash].challengeID;

        // winner gets back their full staked deposit, and dispensationPct*loser's stake
        uint reward = (2 * challengeMap[challengeID].stake) - challengeMap[challengeID].rewardPool;
        bool wasWhitelisted = isWhitelisted(_domainHash);

        if (voting.isPassed(challengeID)) { // The challenge failed
            whitelistApplication(_domainHash);
            listingMap[_domainHash].unstakedDeposit += reward; // give stake back to applicant

            _ChallengeFailed(challengeID);
            if (!wasWhitelisted) { _NewDomainWhitelisted(_domain); }
        } 
        else { // The challenge succeeded
            resetListing(_domainHash);
            require(token.transfer(challengeMap[challengeID].challenger, reward));

            _ChallengeSucceeded(challengeID);
            if (wasWhitelisted) { _ListingRemoved(_domain); }
            else { _ApplicationRemoved(_domain); }
        }

        // set flag on challenge being processed
        challengeMap[challengeID].resolved = true;

        // store the total tokens used for voting by the winning side for reward purposes
        challengeMap[challengeID].totalTokens =
          voting.getTotalNumberOfTokensForWinningOption(challengeID);
    }

    /**
    @dev Called by updateStatus if the applicationExpiry date passed without a challenge being made
    @param _domainHash the domainHash to whitelist
    */
    function whitelistApplication(bytes32 _domainHash) private {
        listingMap[_domainHash].whitelisted = true;
    }
}
