// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {ByteHasher} from "./helpers/ByteHasher.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";
import {console} from "forge-std/console.sol";

/*
REFERENCE IMPLEMENTATION


Energy is a humanity-based unit of account that all verified humans can spend onchain at the rate of X Energy per year. It uses WorldID to give every person in the world a recurring, expiring balance that represents their individual engagement. 

For example, a user could spend 100% of their Energy attempting to earn a specific token. Or, they could spend 100% of their Energy attempting to get more governance power in a specific project. In both cases, the receiving entitity knows that the user exhausted all of their limited Energy in the name of the entity, and can reward them accordingly.

This opens up a new design space for applications to offer users free access to transactions that have economic value—now or in the future—in a way that's not bound to 1 person; 1 action, but is subject to individual preferences.  

Impl details:
- Energy is credited continuously but must be spent by the end of each calendar year (vacation days model)
- All state required to spend Energy is included in accompanying WorldID proofs. Transaction execution can be performed anywhere / by anyone

TODO:
- add comments/formatting
- decide on period duration / energy per period
- decide on yearly id reset
- proxy / upgradeability
- events
- security / tests
- add year-end flexibility (low pri)

*/

interface IWorldIDRouter {
    function verifyProof(
        uint256 root,
        uint256 groupId,
        uint256 signalHash,
        uint256 nullifierHash,
        uint256 externalNullifierHash,
        uint256[8] calldata proof
    ) external;
}

contract Energy {
    using ByteHasher for bytes;

    error InsufficientEnergy();
    error InvalidNonce();

    event EnergySpent(uint256 nullifierHash, address spenderTag, address recipient, uint256 amount);

    IWorldIDRouter public immutable worldIDRouter;
    string public appId;
    uint256 internal immutable groupId = 1;

    struct EnergyBalance {
        uint256 amount;
        uint256 year;
    }

    mapping(uint256 => EnergyBalance) private nullifierToEnergyBalance;
    mapping(uint256 => uint256) private nullifierToLastClaim;
    mapping(uint256 => uint256) private nullifierToNonce;

    uint256 constant ENERGY_PER_PERIOD = 100;
    uint256 constant PERIOD_DURATION = 168 hours;

    constructor(address _worldIDRouterAddress, string memory _appId) {
        worldIDRouter = IWorldIDRouter(_worldIDRouterAddress);
        appId = _appId;
    }

    function verifyProof(uint256 root, uint256 nullifierHash, uint256[8] calldata proof, uint256 signalHash) private {
        uint256 externalNullifierHash =
            abi.encodePacked(abi.encodePacked(appId).hashToField(), "spend-energy").hashToField();

        worldIDRouter.verifyProof(root, groupId, signalHash, nullifierHash, externalNullifierHash, proof);
    }

    function hashToJsonSignal(string[] memory keys, string[] memory values) internal pure returns (uint256) {
        require(keys.length == values.length, "Keys and values must have the same length");

        string memory signalAsJson = "{";
        for (uint256 i = 0; i < keys.length; i++) {
            if (i > 0) {
                signalAsJson = string.concat(signalAsJson, ",");
            }
            signalAsJson = string.concat(signalAsJson, "'", keys[i], "':'", values[i], "'");
        }
        signalAsJson = string.concat(signalAsJson, "}");
        console.log("signalAsJson", signalAsJson);

        return abi.encodePacked(signalAsJson).hashToField();
    }

    function spendEnergy(
        uint256 root,
        uint256 nullifierHash,
        uint256[8] calldata proof,
        address spenderTag,
        address recipient,
        uint256 energyAmount,
        uint256 nonce
    ) external {
        if (nonce != nullifierToNonce[nullifierHash] + 1) revert InvalidNonce();

        string[] memory keys = new string[](4);
        string[] memory values = new string[](4);
        (keys[0], keys[1], keys[2], keys[3]) = ("nonce", "amount", "spenderTag", "recipient");
        (values[0], values[1], values[2], values[3]) = (
            Strings.toString(nonce),
            Strings.toString(energyAmount),
            Strings.toHexString(spenderTag),
            Strings.toHexString(recipient)
        );
        uint256 signalHash = hashToJsonSignal(keys, values);

        verifyProof(root, nullifierHash, proof, signalHash);

        nullifierToNonce[nullifierHash] = nonce;

        updateEnergyBalance(nullifierHash);
        _spendEnergy(nullifierHash, spenderTag, recipient, energyAmount);
    }

    function calculateCurrentEnergyBalance(uint256 nullifierHash, uint256 lastClaim)
        private
        view
        returns (uint256, uint256, uint256)
    {
        EnergyBalance memory balance = nullifierToEnergyBalance[nullifierHash];
        uint256 currentYear = (block.timestamp / 365 days) + 1970;

        if (lastClaim == 0) {
            // First time interaction, start with 2 periods of energy
            return (2 * ENERGY_PER_PERIOD, currentYear, 0);
        }

        if (balance.year < currentYear) {
            // Reset energy if it's a new year
            return (0, currentYear, 0);
        }

        uint256 periodsPassed = (block.timestamp - lastClaim) / PERIOD_DURATION;
        uint256 newAmount = balance.amount + (periodsPassed * ENERGY_PER_PERIOD);

        return (newAmount, currentYear, periodsPassed);
    }

    function updateEnergyBalance(uint256 nullifierHash) private {
        uint256 lastClaim = nullifierToLastClaim[nullifierHash];
        (uint256 newAmount, uint256 currentYear, uint256 periodsPassed) =
            calculateCurrentEnergyBalance(nullifierHash, lastClaim);

        nullifierToEnergyBalance[nullifierHash] = EnergyBalance({amount: newAmount, year: currentYear});

        if (periodsPassed > 0 || lastClaim == 0) {
            nullifierToLastClaim[nullifierHash] = block.timestamp;
        }
    }

    function balanceForNullifier(uint256 nullifierHash) external view returns (uint256) {
        uint256 lastClaim = nullifierToLastClaim[nullifierHash];
        (uint256 currentBalance,,) = calculateCurrentEnergyBalance(nullifierHash, lastClaim);
        return currentBalance;
    }

    function _spendEnergy(uint256 nullifierHash, address spenderTag, address recipient, uint256 amount) private {
        EnergyBalance storage balance = nullifierToEnergyBalance[nullifierHash];
        if (balance.amount < amount) revert InsufficientEnergy();
        balance.amount -= amount;
        emit EnergySpent(nullifierHash, spenderTag, recipient, amount);
    }

    function nonceForNullifier(uint256 nullifierHash) external view returns (uint256) {
        return nullifierToNonce[nullifierHash];
    }
}
