// SPDX-License-Identifier:MIT

pragma solidity ^0.8.0;


contract ChequeBank {
	struct ChequeInfo {
		uint amount;
		bytes32 chequeId;
		uint32 validFrom;
		uint32 validThru;
		address payee;
		address payer;
    }

	struct SignOverInfo {
		uint8 counter;
		bytes32 chequeId;
		address oldPayee;
		address newPayee;
    }

	struct Cheque {
        ChequeInfo chequeInfo;
		bytes sig;
    }

	struct SignOver {
        SignOverInfo signOverInfo;
		bytes sig;
    }

	event newDeposit(address indexed payer, uint amount);
	event newWithdraw(address indexed payer, uint amount);
	event newWithdrawTo(address indexed payer, address indexed recipient, uint amount);

	event newCheque(address indexed payer, address indexed payee, uint amount, bytes32 chequeId);
	event newRedeem(address indexed payer, address indexed payee, uint amount, bytes32 chequeId);

	// save the payer's deposit amount for redeem in format {payer_address : amount}
	mapping(address=>uint) public availables;

    // use issue the cheque off-chain, we don't save not signed cheque

    // save the signed checques in format { chequeId: Cheque}
	mapping(bytes32=>Cheque) public cheques;

    // use this to do some clean up for expire cheque, a bounty
    bytes32[] public chequeList;

	// save the sign over cheque in format { chequeId:SignOverInfo}
	mapping(bytes32=>SignOverInfo) public signOvers;

	address public immutable id;

	constructor(){
		id = address(this);
	}


    function addCheque(bytes32  chequeId) private {
        uint last = chequeList.length - 1;
        for (uint i = 0; i < last; i++){
            if (chequeList[i] == chequeId){
                return;
            }
        }
        chequeList.push(chequeId);
    }

    function _removeCheque(uint id) private {
        bytes32  chequeId;
        uint last = chequeList.length - 1;
        for (uint i = id; i < last; i++){
            chequeId = chequeList[i];
            chequeList[i] = chequeList[i+1];
        }
        chequeList.pop();

        _removeStaleCheque(chequeId);
    }

    function _removeStaleCheque(bytes32  chequeId)private{
        delete cheques[chequeId];
		delete signOvers[chequeId];
    }

    function pureCheque() external {
        uint[] memory expires = new uint[](100);
        uint last = chequeList.length - 1;
        uint current = 0;
        for (uint i = 0; i <= last; i++){
            (,bool expire,) = _validate(chequeList[i]);
            // if cheque is not exists, remove
            expire =  expire || cheques[chequeList[i]].chequeInfo.payer == address(0);
            if (current >= 100) {
                break;
            }
            if (expire){
                expires[current] = i;
                current++;
            }
        }

        for (uint i = 0; i < current; i++){
            _removeCheque(expires[i]);        
        }
    }

	function deposit() payable external {
		address payer = msg.sender;

		// overflow check omity
		availables[payer] += msg.value;
    
		emit newDeposit(payer,msg.value);
	}

	function withdraw(uint amount) external {
		address payer = msg.sender;
		uint balance = availables[payer];
		require(balance >= amount, "insuficient balance for withdraw");
		availables[payer] -= amount;
        address payable payee = payable(msg.sender);
		bool success = payee.send(amount);
		require(success,"withdraw falied");
		emit newWithdraw(payee,amount);

        // clean payer  and cheque operation leave to bounty
	}

	function withdrawTo(uint amount, address payable recipient) external {
		uint balance = availables[msg.sender];
		require(balance >= amount,"insuficient amount");

		// should not under flow with the previous validate
		availables[msg.sender] -= amount;
		
        address payable to = payable(recipient);

		bool success = to.send(amount);
		require(success, "withdraw failed");
		emit newWithdrawTo(msg.sender,recipient,amount);	

        // clean payer and cheque operation leave to bounty
	}

	function redeem(Cheque memory chequeData) external {
		// 1.not need to validate cheque sign, we only save signed cheques
		ChequeInfo memory cheque = chequeData.chequeInfo;
		
		// 2. validate expire and get payee
		(bool valid, , address payee) = _validate(cheque.chequeId);
        require(valid, "invalid cheque");
        
		// only payee can redeem it's cheque
		require(payee == msg.sender,"only final payee can redeem it's cheque");

		// 3.reduce balance on payer account
		uint amount = cheque.amount;
		uint available = availables[cheque.payer];
		require(available >= amount,"insufficient balance on issuer, can not redeem, contact cheque issuer to deposit more");
		availables[cheque.payer] -= cheque.amount;

		// 4.transfer to payee
        address payable to = payable(payee);
		bool success = to.send(cheque.amount);
		require(success,"transfer failed");
		emit newRedeem(payee,cheque.payer,amount,cheque.chequeId);

        // 4.remove redeemed cheque to prevent double spend
        _removeStaleCheque(cheque.chequeId);
	}


	function isFromValid(uint from,uint current)private pure returns(bool){
		return from <= current;	
	}

	function isToValid(uint to,uint current) private pure returns(bool) {
		if(to == 0) {
			return true;	
		}
		return to >= current;
	}


	/*
		good=true,clean = true, can redeem and clean after redeem
		good = false, clean = true, which means expire, can not redeem and should clean
		good = false, clean = false, which means should wait, can not redeem and should not clean
	*/
	function _validate(bytes32  chequeId) private  view returns(bool good, bool clean, address payable payee){
		// 1.lookup in the cheque map
		ChequeInfo storage cheque = cheques[chequeId].chequeInfo;
        
		// if no such cheque exists, invalid cheque
		if(cheque.payer == address(0)){
			return (good,clean,payee);
		}
		// get the initial payee
		payee = payable(cheque.payee);

		// 2.validate liveness from and to
		uint current = block.number;
		bool begin = isFromValid(cheque.validFrom,current);
		bool expire = isToValid(cheque.validThru,current);
		if (expire) {
			clean = true;
			return (good,clean,payee);
		}
		if(begin) {
			good = true;
			clean = true;
		}

		// 3.lookup in the signover map
		SignOverInfo storage signOver = signOvers[chequeId]; 		
		
		// if sign over exist, the final payee should be the new owner in sign over
		if (signOver.newPayee != address(0)){
			payee = payable(signOver.newPayee);
		}

		return (good,clean,payee);
	}

 function _signVerify(bytes32 hash, bytes memory sig) public pure  returns (address ) {
    bytes32 r;
    bytes32 s;
    uint8 v;

    if (sig.length != 65) {
      return address(0);
    }

    assembly {
      r := mload(add(sig, 32))
      s := mload(add(sig, 64))
      v := and(mload(add(sig, 65)), 255)
    }

    if (v < 27) {
      v += 27;
    }

    if (v != 27 && v != 28) {
      return address(0);
    }

    return ecrecover(hash, v, r, s);
  }

	

	function revoke(bytes32 chequeId) external {
        _removeStaleCheque(chequeId);

        // we don't know the index of this cheque in chequeList, not clean here
	}


    function chequeHash(ChequeInfo calldata _info) private view  returns(bytes32 ) {
         bytes memory input = abi.encodePacked(_info.chequeId, _info.payer, _info.payee, _info.amount, id, _info.validFrom, _info.validThru);

        return keccak256(bytes(input));
    }

	function signatureCheque(ChequeInfo calldata _info,bytes memory sig)external {
        Cheque storage cheque= cheques[_info.chequeId];
        require(cheque.chequeInfo.payer == address(0),"can not sign a signed cheque");
       
       
       // verify signer
       bytes32 hash = chequeHash(_info);
       address signer = _signVerify(hash,sig);
       require(signer == msg.sender,"invalid signature");

        cheque.chequeInfo = _info;
        cheque.sig = sig;
        cheques[_info.chequeId] = cheque;

        emit newCheque(_info.payer,_info.payee,_info.amount,_info.chequeId);
	}

	function notifySignOver(
        SignOver memory signOverData
    ) external {

    }

	function isChequeValid(
		address payee,
        bytes32  chequeId
    ) view public returns (bool) {
        (bool good,,address payable to) = _validate(chequeId);
        return good && to == payee;
    }
}

