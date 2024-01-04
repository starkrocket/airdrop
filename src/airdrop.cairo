use starknet::{ContractAddress, Felt252TryIntoContractAddress};

#[starknet::interface]
trait IERC20<TContractState> {
    fn name(self: @TContractState) -> felt252;
    fn symbol(self: @TContractState) -> felt252;
    fn decimals(self: @TContractState) -> u8;
    fn totalSupply(self: @TContractState) -> u256;
    fn balanceOf(self: @TContractState, account: ContractAddress) -> u256;
    fn allowance(self: @TContractState, owner: ContractAddress, spender: ContractAddress) -> u256;
    fn transfer(ref self: TContractState, recipient: ContractAddress, amount: u256);
    fn transferFrom(ref self: TContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256);
    fn approve(ref self: TContractState, spender: ContractAddress, amount: u256);
    fn increaseAllowance(ref self: TContractState, spender: ContractAddress, added_value: u256);
    fn decreaseAllowance(ref self: TContractState, spender: ContractAddress, subtracted_value: u256);
}


#[starknet::interface]
trait IClaimContract<TContractState> {
    fn claim(ref self: TContractState, points: felt252, proof: Array<felt252>, referrer: ContractAddress);
    fn setRoot(ref self: TContractState, root: felt252);
    fn setToken(ref self: TContractState, token: ContractAddress);
    fn setBatchSize(ref self: TContractState, batch_size: u128);
    fn setDropPercent(ref self: TContractState, drop_percent: u128);
    fn setClaimStatus(ref self: TContractState, status: bool);
    fn claimed(self: @TContractState, account: ContractAddress) -> u256;
    fn claims(self: @TContractState) -> u128;
    fn tokensClaimed(self: @TContractState) -> u256;
    fn token(self: @TContractState) -> ContractAddress;
    fn referrer(self: @TContractState, referrer: ContractAddress) -> (u128, u256);
    fn claimOpen(self: @TContractState) -> bool;
    fn verifyProof(self: @TContractState, address: felt252, amount: felt252, proof: Array<felt252>) -> bool;
}

#[starknet::contract]
mod ClaimContract {
    use super::{IERC20Dispatcher, IERC20DispatcherTrait};
    use super::{IClaimContract, ContractAddress, Felt252TryIntoContractAddress};
    use starknet::{get_caller_address, get_contract_address};
    use core::pedersen::pedersen;

    #[storage]
    struct Storage {
        owner:ContractAddress,
        token: ContractAddress,
        claims: u128,
        tokens_claimed: u256,
        claimed: LegacyMap::<ContractAddress, u256>,
        referrers: LegacyMap::<ContractAddress, (u128, u256)>,
        merkle_root_storage: felt252,
        batch_size: u128,
        drop_percent: u128,
        claim_open: bool
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Claimed : Claimed
    }

    #[derive(Drop, starknet::Event)]
    struct Claimed  {
        address: ContractAddress,
        amount: u256
    }
    
    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, token: ContractAddress, merkly_root: felt252, batch_size: u128, drop_percent:u128) {
        self.owner.write(owner);
        self.merkle_root_storage.write(merkly_root);
        self.token.write(token);
        self.batch_size.write(batch_size);
        self.drop_percent.write(drop_percent);
    }

    fn calculate_points(points: u128, claims: u128, drop_percent: u128, batch_size: u128) -> u256 {
        let mut batch_id: u128 = (claims / batch_size );
        if batch_id > 9 {batch_id = 9;}
        let amount: u256 = (points * (100 - (batch_id * drop_percent)) / 100).into();
        amount
    }

    fn get_hash(value1: felt252, value2: felt252) -> felt252 {
        pedersen(value1, value2)
    }

    fn verify_proof(root: felt252, leaf: felt252, proof: Array<felt252>) -> bool {
        let hash: felt252 = hash_proof(leaf, proof);
        if hash == root {
            return true;
        } else {
            return false;
        }
    }

    fn hash_proof(leaf: felt252, proofEnter: Array<felt252>) -> felt252 {
        let mut proof = proofEnter;
        if (proof.len() == 0_u32) {
            return leaf;
        }
        let mut hash: felt252 = 0_felt252;
        if integer::u256_from_felt252(
            leaf
        ) < integer::u256_from_felt252(
            *proof[0_u32]
        ) {
            hash = get_hash(leaf, *proof[0_u32]);
        } else {
            hash = get_hash(*proof[0_u32], leaf);
        }
        proof.pop_front().unwrap();
        let result = hash_proof(hash, proof);
        result
    }
       

    #[abi(embed_v0)]
    impl ClaimContract of super::IClaimContract<ContractState> {
        fn claim(ref self: ContractState, points: felt252, proof: Array<felt252>, referrer: ContractAddress) {
            assert(self.claim_open.read(), 'Claim is closed');

            let caller: ContractAddress = get_caller_address();

            let is_already_claimed = self.claimed.read(caller);
            assert(is_already_claimed == 0, 'Already claimed');

            // Convert caller to felt252 and create hash
            let caller_as_felt252: felt252 = caller.into();
            let h0: felt252 = get_hash(0, caller_as_felt252);
            let h1: felt252 = get_hash(h0, points);
            let hashed_leaf: felt252 = get_hash(h1, 2);

            let is_valid_request: bool = verify_proof(self.merkle_root_storage.read(), hashed_leaf, proof);
            assert(is_valid_request, 'Proof not valid');

            let d:u256 = 1000000000000000000;
            let amount: u256 = calculate_points(points.try_into().unwrap(), self.claims.read(), self.drop_percent.read(), self.batch_size.read())*d;
            let referrer_amount: u256 = amount/10;

            self.claims.write(self.claims.read() + 1);
            self.claimed.write(caller, amount);
            let (refferal_count, token_amount): (u128, u256) = self.referrers.read(referrer);
            self.referrers.write(referrer, (refferal_count+1, token_amount+referrer_amount));
            self.tokens_claimed.write(self.tokens_claimed.read() + amount);

            IERC20Dispatcher { contract_address: self.token.read() }.transfer(caller, amount.into());
            IERC20Dispatcher { contract_address: self.token.read() }.transfer(referrer, referrer_amount);
            self.emit(Claimed { address: caller, amount: amount});
        }

        fn setRoot(ref self: ContractState, root: felt252) {
            let caller: ContractAddress = get_caller_address();
            assert(caller == self.owner.read(), 'Not owner');
            self.merkle_root_storage.write(root);
        }

        fn setToken(ref self: ContractState, token: ContractAddress) {
            let caller: ContractAddress = get_caller_address();
            assert(caller == self.owner.read(), 'Not owner');
            self.token.write(token);
        }
        
        fn setBatchSize(ref self: ContractState, batch_size: u128) {
            let caller: ContractAddress = get_caller_address();
            assert(caller == self.owner.read(), 'Not owner');
            self.batch_size.write(batch_size);
        }

        fn setDropPercent(ref self: ContractState, drop_percent: u128) {
            let caller: ContractAddress = get_caller_address();
            assert(caller == self.owner.read(), 'Not owner');
            self.drop_percent.write(drop_percent);
        }

        fn setClaimStatus(ref self: ContractState, status: bool) {
            let caller: ContractAddress = get_caller_address();
            assert(caller == self.owner.read(), 'Not owner');
            self.claim_open.write(status);
        }

        fn token(self: @ContractState) -> ContractAddress {
            self.token.read()
        }

        fn referrer(self: @ContractState, referrer: ContractAddress) -> (u128, u256) {
            self.referrers.read(referrer)
        }

        fn claimed(self: @ContractState, account: ContractAddress) -> u256 {
            self.claimed.read(account)
        }

        fn claims(self: @ContractState) -> u128 {
            self.claims.read()
        }

        fn tokensClaimed(self: @ContractState) -> u256 {
            self.tokens_claimed.read()
        }

        fn claimOpen(self: @ContractState) -> bool {
            self.claim_open.read()
        }

        fn verifyProof(self: @ContractState, address: felt252, amount: felt252, proof: Array<felt252>) -> bool {
            let h0: felt252 = get_hash(0, address);
            let h1: felt252 = get_hash(h0, amount);
            let hashed_leaf: felt252 = get_hash(h1, 2);
            let is_valid_request: bool = verify_proof(self.merkle_root_storage.read(), hashed_leaf, proof);
            is_valid_request
        }
    }
}
