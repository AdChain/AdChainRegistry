# UPDATE: DO NOT USE THIS REPO
## We will be using this forked off generalized version of the adChain Registry repo:

[https://github.com/skmgoldin/tcr](https://github.com/skmgoldin/tcr)

#### Our adChain Registry dApp will expect the apply function to supply the `domain` in the `_data` param in the apply function. The dApp will also make sure `_listingHash` matches the `domain` supplied in the `_data` paramfor the apply function.
```
function apply(bytes32 _listingHash, uint _amount, string _data) external
```
#### For hashing the `_listingHash`, we are using the `soliditySHA3` function from:

[https://github.com/ethereumjs/ethereumjs-abi](https://github.com/ethereumjs/ethereumjs-abi)

```
const abi = require('ethereumjs-abi')
0x${abi.soliditySHA3(['bytes32'], [domain.toLowerCase().trim()]).toString('hex')}
```

# AdChainRegistry

[ ![Codeship Status for AdChain/AdChainRegistry](https://app.codeship.com/projects/3bdda690-6405-0135-6105-4ab105608534/status?branch=master)](https://app.codeship.com/projects/240253)

A token-curated registry listing the domains of high-quality web publishers with authentic human audiences.

## Commands

Compile contracts using truffle

    $ npm run compile

Run tests

    $ npm run test

Run tests and log TestRPC stats

    $ npm run test gas


## Application Process

1.  A publisher calls ```apply()``` to create an application and puts down a deposit of AdToken.  The apply stage for the application begins. During the apply stage, the application is waiting to be added to the whitelist, but can be challenged or left unchallenged.

    The application is challenged:

    1.  A challenger calls ```challenge()``` and puts down a deposit that matches the publisher's.

    2.  A vote starts (see Voter and Reward Process).

    3.  After the results are in, the anyone calls ```updateStatus()```.  
        
        If the applicant won, the domain is moved to the whitelist and they recieve a portion of the challenger's deposit as a reward.  Their own deposit is saved by the registry.

        If the challenger won, their deposit is returned and they recieve a portion of the applicant's deposit as a reward.

    The application goes unchallenged:

    1.  At the end of the apply stage, ```updateStatus()``` may be called, which adds their name to the whitelist.
        The applicant's deposit is saved and can be withdrawn when their whitelist period expires.

2.  To check if a publisher is in the registry, anyone can call ```isWhitelisted()``` at any time.



## Rechallenges

1.  Once a domain is whitelisted, it can be re challenged at any time. To challenge a domain already on the whitelist, a challenger calls ```challenge()``` and puts down a deposit of adToken to match the current minDeposit parameter.

2. If a whitelisted domain is challenged and does not have enough tokens deposited into the contract (ie a whitelist's current deposit is less than the minDeposit parameter), then the domain is automatically removed from the whitelist.



## Publisher Interface

1.  Deposit() - if the minDeposit amount is reparametrized to a higher value, then owners of whitelisted domains can increase their deposit in order to avoid being automatically removed from the whitelist in the event that their domain is challenged.

2.  Withdraw() - if the minDeposit amount is reparametrized to a lower value, then the owners of a whitelisted domain can withdraw unlocked tokens. Tokens locked in a challenge may not be withdrawn.

3.  Exit() - the owner of a listing can call this function in order to voluntarily remove their domain from the whitelist. Domains may not be removed from the whitelist if there is an ongoing challenge on that domain.



## Voter and Reward Process

1.  The vote itself is created and managed by the PLCR voting contract.

2.  Voters who voted on the losing side gain no reward, but voters who voted on the winning side can call ```claimReward()```
    to claim a portion of the loser's (either the applicant's or the challenger's) deposit proportional to the amount of
    AdToken they contributed to the vote.

3.  No tokens are ever lost or burned because the reward pool of tokens is repartitioned every time ```claimReward()``` is called. 



## Reparameterization Process

1.  To propose a new value for a parameter, a user calls ```changeParameter()``` and puts down a deposit of AdToken with the
    parameter and the new value they want to introduce. A vote to make or disregard the proposed change is started immediately. 
    The deposit will be returned to the user upon completion of the poll.

2. After voters have committed and revealed their votes within the vote contract, anyone calls ```processProposal()``` to evaluate the results of the vote. Deposited tokens are returned to the user who proposed the parameter change. If the results show that the proposed change is approved, the parameter value in the params mapping is changed. 

3.  To check the value of parameters, a user calls ```get()``` with the string keyword of the parameter.
