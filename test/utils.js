/* eslint-env mocha */
/* global artifacts */

const HttpProvider = require('ethjs-provider-http');
const EthRPC = require('ethjs-rpc');
const abi = require('ethereumjs-abi');
const fs = require('fs');

const ethRPC = new EthRPC(new HttpProvider('http://localhost:8545'));

const PLCRVoting = artifacts.require('PLCRVoting.sol');
const Sale = artifacts.require('historical/Sale.sol');
const Registry = artifacts.require('Registry.sol');
const Token = artifacts.require('historical/Token.sol');

const adchainConfig = JSON.parse(fs.readFileSync('./conf/config.json'));
const paramConfig = adchainConfig.RegistryDefaults;

const utils = {
  getVoting: async () => {
    const registry = await Registry.deployed();
    const votingAddr = await registry.voting.call();
    return PLCRVoting.at(votingAddr);
  },
  increaseTime: async seconds =>
    new Promise((resolve, reject) => ethRPC.sendAsync({
      method: 'evm_increaseTime',
      params: [seconds],
    }, (err) => {
      if (err) reject(err);
      resolve();
    }))
      .then(() => new Promise((resolve, reject) => ethRPC.sendAsync({
        method: 'evm_mine',
        params: [],
      }, (err) => {
        if (err) reject(err);
        resolve();
      }))),
  getVoteSaltHash: (vote, salt) => (
    `0x${abi.soliditySHA3(['uint', 'uint'], [vote, salt]).toString('hex')}`
  ),
  getDomainHash: domain => (
    `0x${abi.soliditySHA3(['string'], [domain]).toString('hex')}`
  ),
  buyTokens: async (address, etherAmount) => {
    const sale = await Sale.deployed();
    await sale.purchaseTokens({ from: address, value: etherAmount });
  },
  approvePLCR: async (address, adtAmount) => {
    const registry = await Registry.deployed();
    const plcrAddr = await registry.voting.call();
    const token = Token.at(await registry.token.call());
    await token.approve(plcrAddr, adtAmount, { from: address });
  },
  addToWhitelist: async (domain, deposit, actor) => {
    const registry = await Registry.deployed();
    await utils.as(actor, registry.apply, domain, deposit);
    await utils.increaseTime(paramConfig.applyStageLength + 1);
    await utils.as(actor, registry.updateStatus, domain);
  },
  as: (actor, fn, ...args) => {
    function detectSendObject(potentialSendObj) {
      function hasOwnProperty(obj, prop) {
        const proto = obj.constructor.prototype;
        return (prop in obj) &&
          (!(prop in proto) || proto[prop] !== obj[prop]);
      }
      if (typeof potentialSendObj !== 'object') { return undefined; }
      if (
        hasOwnProperty(potentialSendObj, 'from') ||
        hasOwnProperty(potentialSendObj, 'to') ||
        hasOwnProperty(potentialSendObj, 'gas') ||
        hasOwnProperty(potentialSendObj, 'gasPrice') ||
        hasOwnProperty(potentialSendObj, 'value')
      ) {
        throw new Error('It is unsafe to use "as" with custom send objects');
      }
      return undefined;
    }
    detectSendObject(args[args.length - 1]);
    const sendObject = { from: actor };
    return fn(...args, sendObject);
  },
  isEVMException: err => (
    err.toString().includes('invalid opcode')
  ),
  getCurrentDeposit: async (domain) => {
    const registry = await Registry.deployed();
    // hash the domain so we can identify in listingMap
    const hash = utils.getDomainHash(domain);
    // get the struct in the mapping
    const listing = await registry.listingMap.call(hash);
    // get the current deposit amount from the listing struct
    const currentDeposit = await listing[3];
    return currentDeposit.toString();
  },
  challengeAndGetPollID: async (domain, actor) => {
    const registry = await Registry.deployed();
    const receipt = await utils.as(actor, registry.challenge, domain);
    return receipt.logs[0].args.pollID;
  },
  commitVote: async (pollID, voteOption, tokensArg, salt, voter) => {
    const voting = await utils.getVoting();
    const hash = utils.getVoteSaltHash(voteOption, salt);
    await utils.as(voter, voting.requestVotingRights, tokensArg);

    const prevPollID = await voting.getInsertPointForNumTokens.call(voter, tokensArg);
    await utils.as(voter, voting.commitVote, pollID, hash, tokensArg, prevPollID);
  },
};

module.exports = utils;
