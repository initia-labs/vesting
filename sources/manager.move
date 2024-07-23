/// The manager module is responsible for managing the vesting contract. It allows the creation of
/// new vesting store, the addition and removal of vesting schedules, and the withdrawal of
/// vested tokens.
/// 
/// It is recommended to use the `vesting::manager` module with `0x1::multisig::MultisigWallet`.
module vesting::manager {
    use initia_std::signer;
    use initia_std::fungible_asset::Metadata;
    use initia_std::primary_fungible_store;
    use initia_std::object::Object;

    use vesting::vesting::{Self, AdminCapability};

    struct ManagerStore has key {
        // The admin capability for the vesting contract.
        admin_capability: AdminCapability,
    }

    // Entry functions

    public entry fun create_manager(
        creator: &signer,
        token_metadata: Object<Metadata>
    ) {
        let admin_capability = vesting::create_vesting_store(creator, token_metadata);

        move_to(creator, ManagerStore {admin_capability});
    }

    public entry fun enable_claim(admin: &signer) acquires ManagerStore {
        let store = borrow_global_mut<ManagerStore>(signer::address_of(admin));
        vesting::enable_claim(&store.admin_capability);
    }

    public entry fun disable_claim(admin: &signer) acquires ManagerStore {
        let store = borrow_global_mut<ManagerStore>(signer::address_of(admin));
        vesting::disable_claim(&store.admin_capability);
    }

    public entry fun withdraw_vesting_funds(
        admin: &signer,
        recipient: address,
        amount: u64
    ) acquires ManagerStore {
        let store = borrow_global_mut<ManagerStore>(signer::address_of(admin));
        let tokens = vesting::withdraw_vesting_funds(&store.admin_capability, amount);
        primary_fungible_store::deposit(recipient, tokens);
    }

    public entry fun add_vesting(
        admin: &signer,
        recipient: address,
        allocation: u64,
        vesting_period: u64,
        cliff_period: u64,
        claim_frequency: u64,
    ) acquires ManagerStore {
        let store = borrow_global_mut<ManagerStore>(signer::address_of(admin));
        vesting::add_vesting(
            &store.admin_capability,
            recipient,
            allocation,
            vesting_period,
            cliff_period,
            claim_frequency
        );
    }

    public entry fun remove_vesting(admin: &signer, recipient: address) acquires ManagerStore {
        let store = borrow_global_mut<ManagerStore>(signer::address_of(admin));
        vesting::remove_vesting(&store.admin_capability, recipient);
    }

    public entry fun update_vesting(
        admin: &signer,
        recipient: address,
        allocation: u64,
        vesting_period: u64,
        cliff_period: u64,
        claim_frequency: u64,
    ) acquires ManagerStore {
        let store = borrow_global_mut<ManagerStore>(signer::address_of(admin));
        vesting::update_vesting(
            &store.admin_capability,
            recipient,
            allocation,
            vesting_period,
            cliff_period,
            claim_frequency
        );
    }
}
