module vesting::vesting {
    use initia_std::fungible_asset::{Self, Metadata, FungibleAsset};
    use initia_std::primary_fungible_store;
    use initia_std::object::{Self, Object, ExtendRef};
    use initia_std::table::{Self, Table};
    use initia_std::signer;
    use initia_std::error;
    use initia_std::block;
    use initia_std::event;

    /// A capability that represents the ability to manage vesting schedules.
    struct AdminCapability has store {
        /// The address of the capability creator.
        creator: address,
    }

    /// A struct that represents the vesting storage.
    struct VestingStore has key {
        /// The flag to enable the claim function.
        enable: bool,

        /// The token metadata to vest.
        token_metadata: Object<Metadata>,

        /// Object extend reference.
        extend_ref: ExtendRef,

        /// A map of vesting schedules.
        vestings: Table<address, Vesting>,
    }

    /// A struct that represents a vesting schedule.
    struct Vesting has store, copy, drop {
        /// Amount of tokens to be vested
        allocation: u64,

        /// The total number of tokens that a given address will
        /// be able to ever claim.
        claimed_amount: u64,

        /// The time in which the vesting period starts.
        start_time: u64,

        /// The total period over which the tokens will vest.
        vesting_period: u64,

        /// The period of time in which tokens are vesting but
        /// cannot claimed. After the cliff period, tokens vested
        /// during the cliff period after immediately claimable.
        cliff_period: u64,

        /// The frequency in which an address can claim tokens post-cliff period
        claim_frequency: u64,
    }

    // Events

    #[event]
    struct VestingClaimed has drop, store {
        recipient: address,
        amount: u64,
    }

    // Errors

    const EALREADY_CREATED: u64 = 1;
    const ECLAIM_NOT_ENABLED: u64 = 2;
    const EVESTING_NOT_FOUND: u64 = 3;
    const EVESTING_ALREADY_EXISTS: u64 = 4;
    const EVESTING_NOT_EXISTS: u64 = 5;

    // Admin functions

    /// Creates a new vesting store.
    public fun create_vesting_store(
        creator: &signer,
        token_metadata: Object<Metadata>
    ): AdminCapability {
        let creator_addr = signer::address_of(creator);
        assert!(
            !exists<VestingStore>(creator_addr),
            error::already_exists(EALREADY_CREATED)
        );

        let constructor_ref = object::create_object(creator_addr, false);
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        move_to(
            creator,
            VestingStore {
                enable: false,
                token_metadata,
                extend_ref,
                vestings: table::new<address, Vesting>(),
            }
        );

        AdminCapability {
            creator: signer::address_of(creator),
        }
    }

    /// Disables the claim function.
    public fun disable_claim(capability: &AdminCapability) acquires VestingStore {
        let store = borrow_global_mut<VestingStore>(capability.creator);
        store.enable = false;
    }

    /// Enables the claim function.
    public fun enable_claim(capability: &AdminCapability) acquires VestingStore {
        let store = borrow_global_mut<VestingStore>(capability.creator);
        store.enable = true;
    }

    /// Withdraw vesting funds from the store.
    public fun withdraw_vesting_funds(
        capability: &AdminCapability,
        amount: u64
    ): FungibleAsset acquires VestingStore {
        let store = borrow_global_mut<VestingStore>(capability.creator);
        let store_signer = object::generate_signer_for_extending(&store.extend_ref);
        primary_fungible_store::withdraw(
            &store_signer, store.token_metadata,
            amount
        )
    }

    /// Append vesting schedule for a recipient.
    public fun add_vesting(
        capability: &AdminCapability,
        recipient: address,
        allocation: u64,
        vesting_period: u64,
        cliff_period: u64,
        claim_frequency: u64
    ) acquires VestingStore {
        let store = borrow_global_mut<VestingStore>(capability.creator);
        assert!(
            !table::contains(&store.vestings, recipient),
            error::already_exists(EVESTING_ALREADY_EXISTS)
        );

        let (_, cur_time) = block::get_block_info();

        table::add(
            &mut store.vestings,
            recipient,
            Vesting {
                allocation,
                claimed_amount: 0,
                start_time: cur_time,
                vesting_period,
                cliff_period,
                claim_frequency,
            }
        );
    }

    /// Remove vesting schedule for a recipient.
    public fun remove_vesting(
        capability: &AdminCapability,
        recipient: address
    ) acquires VestingStore {
        let store = borrow_global_mut<VestingStore>(capability.creator);
        assert!(
            table::contains(&store.vestings, recipient),
            error::not_found(EVESTING_NOT_EXISTS)
        );

        table::remove(&mut store.vestings, recipient);
    }

    /// Update vesting schedule for a recipient.
    public fun update_vesting(
        capability: &AdminCapability,
        recipient: address,
        allocation: u64,
        vesting_period: u64,
        cliff_period: u64,
        claim_frequency: u64
    ) acquires VestingStore {
        let store = borrow_global_mut<VestingStore>(capability.creator);
        assert!(
            table::contains(&store.vestings, recipient),
            error::not_found(EVESTING_NOT_EXISTS)
        );

        let vesting = table::borrow_mut(&mut store.vestings, recipient);
        vesting.allocation = allocation;
        vesting.vesting_period = vesting_period;
        vesting.cliff_period = cliff_period;
        vesting.claim_frequency = claim_frequency;
    }

    // User functions

    /// Claims the vested tokens.
    public fun claim(account: &signer, creator: address): FungibleAsset acquires VestingStore {
        let account_addr = signer::address_of(account);
        let store = borrow_global_mut<VestingStore>(creator);

        assert!(
            store.enable,
            error::invalid_state(ECLAIM_NOT_ENABLED)
        );

        assert!(
            table::contains(&store.vestings, account_addr),
            error::invalid_state(EVESTING_NOT_FOUND)
        );
        let vesting = table::borrow_mut(&mut store.vestings, account_addr);
        let (_, cur_time) = block::get_block_info();

        // check if the vesting is still in the cliff period
        if (cur_time < vesting.cliff_period) {
            return fungible_asset::zero(store.token_metadata)
        };

        let cliff_time = vesting.start_time + vesting.cliff_period;
        let elapsed_claim_frequencies = (cur_time - cliff_time) / vesting.claim_frequency;
        let elapsed_period = vesting.cliff_period + elapsed_claim_frequencies * vesting.claim_frequency;
        let claimable_amount = (
            (vesting.allocation as u128) * (elapsed_period as u128) / (
                vesting.vesting_period as u128
            ) as u64
        ) - vesting.claimed_amount;
        if (claimable_amount == 0) {
            return fungible_asset::zero(store.token_metadata)
        };

        // increase the claimed amount
        vesting.claimed_amount = vesting.claimed_amount + claimable_amount;

        // remove the vesting if all tokens are claimed
        if (vesting.claimed_amount == vesting.allocation) {
            table::remove(&mut store.vestings, account_addr);
        };

        // emit the event
        event::emit(
            VestingClaimed {
                recipient: account_addr,
                amount: claimable_amount,
            }
        );

        let store_signer = object::generate_signer_for_extending(&store.extend_ref);
        primary_fungible_store::withdraw(
            &store_signer, store.token_metadata,
            claimable_amount
        )
    }

    // View functions

    #[view]
    public fun claim_enabled(creator: address): bool acquires VestingStore {
        let store = borrow_global<VestingStore>(creator);
        store.enable
    }

    #[view]
    /// Returns the address of the vesting store. This address can be used
    /// to deposit vesting funds.
    public fun store_addr(creator: address): address acquires VestingStore {
        let store = borrow_global<VestingStore>(creator);
        object::address_from_extend_ref(&store.extend_ref)
    }

    #[view]
    public fun vesting_funds(creator: address): u64 acquires VestingStore {
        let store = borrow_global<VestingStore>(creator);
        let store_addr = object::address_from_extend_ref(&store.extend_ref);
        primary_fungible_store::balance(store_addr, store.token_metadata)
    }

    #[view]
    public fun has_vesting(creator: address, recipient: address): bool acquires VestingStore {
        let store = borrow_global<VestingStore>(creator);

        table::contains(&store.vestings, recipient)
    }

    #[view]
    public fun vesting_info(creator: address, recipient: address): Vesting acquires VestingStore {
        let store = borrow_global<VestingStore>(creator);
        assert!(
            table::contains(&store.vestings, recipient),
            error::not_found(EVESTING_NOT_EXISTS)
        );

        *table::borrow(&store.vestings, recipient)
    }

    #[view]
    public fun claimable_amount(creator: address, recipient: address): u64 acquires VestingStore {
        let store = borrow_global<VestingStore>(creator);
        assert!(
            store.enable,
            error::invalid_state(ECLAIM_NOT_ENABLED)
        );
        assert!(
            table::contains(&store.vestings, recipient),
            error::not_found(EVESTING_NOT_EXISTS)
        );

        let (_, cur_time) = block::get_block_info();
        let vesting = table::borrow(&store.vestings, recipient);
        let cliff_time = vesting.start_time + vesting.cliff_period;

        // check if the vesting is still in the cliff period
        if (cur_time < cliff_time) {
            return 0
        };

        let elapsed_claim_frequencies = (cur_time - cliff_time) / vesting.claim_frequency;
        let elapsed_period = vesting.cliff_period + elapsed_claim_frequencies * vesting.claim_frequency;
        let claimable_amount = (
            (vesting.allocation as u128) * (elapsed_period as u128) / (
                vesting.vesting_period as u128
            ) as u64
        ) - vesting.claimed_amount;

        claimable_amount
    }

    #[test_only]
    use initia_std::managed_coin;

    #[test_only]
    use initia_std::option;

    #[test_only]
    use initia_std::string;

    #[test_only]
    use initia_std::coin;

    #[test_only]
    const TEST_SYMBOL: vector<u8> = b"FMD";

    #[test_only]
    fun test_metadata(): Object<Metadata> {
        coin::metadata(
            @initia_std,
            string::utf8(TEST_SYMBOL)
        )
    }

    #[test_only]
    struct CapabilityStore has key {
        capability: AdminCapability,
    }

    #[test_only]
    fun test_init(mod_account: &signer): Object<Metadata> {
        primary_fungible_store::init_module_for_test(mod_account);

        managed_coin::initialize(
            mod_account,
            option::none(),
            string::utf8(b"Fake Money"),
            string::utf8(TEST_SYMBOL),
            6,
            string::utf8(b""),
            string::utf8(b""),
        );

        let metadata = test_metadata();
        assert!(
            coin::is_coin_initialized(metadata),
            0
        );

        metadata
    }

    #[test_only]
    fun test_mint(
        mod_account: &signer,
        recipient: address,
        amount: u64
    ) {
        let metadata = test_metadata();
        managed_coin::mint(
            mod_account,
            recipient,
            metadata,
            amount
        );
    }

    #[test(creator = @0x999, recipient = @0x998, mod_account = @0x1)]
    fun test_admin_functions(
        creator: &signer,
        recipient: &signer,
        mod_account: &signer
    ) acquires VestingStore {
        let metadata = test_init(mod_account);

        let capability = create_vesting_store(creator, metadata);
        let store = borrow_global<VestingStore>(signer::address_of(creator));
        assert!(!store.enable, 1);

        // enable claim
        enable_claim(&capability);
        assert!(
            claim_enabled(signer::address_of(creator)),
            2
        );

        // disable claim
        disable_claim(&capability);
        assert!(
            !claim_enabled(signer::address_of(creator)),
            3
        );

        test_mint(
            mod_account,
            signer::address_of(creator),
            1000
        );
        let tokens = coin::withdraw(creator, metadata, 1000);

        // deposit tokens
        primary_fungible_store::deposit(
            store_addr(signer::address_of(creator)),
            tokens
        );
        assert!(
            vesting_funds(signer::address_of(creator)) == 1000,
            4
        );

        // withdraw tokens
        let tokens = withdraw_vesting_funds(&capability, 100);
        assert!(
            vesting_funds(signer::address_of(creator)) == 900,
            5
        );

        // set block info
        block::set_block_info(100, 100);

        // add vesting
        add_vesting(
            &capability,
            signer::address_of(recipient),
            100, // allocation
            100, // vesting period
            10, // cliff period
            10 // claim frequency
        );

        let vesting = vesting_info(
            signer::address_of(creator),
            signer::address_of(recipient)
        );
        assert!(
            vesting.allocation == 100 && vesting.claimed_amount == 0 && vesting.start_time ==
                 100 && vesting.vesting_period == 100 && vesting.cliff_period == 10 && vesting
                .claim_frequency == 10,
            6
        );

        // update vesting
        update_vesting(
            &capability,
            signer::address_of(recipient),
            200, // allocation
            200, // vesting period
            20, // cliff period
            20 // claim frequency
        );

        let vesting = vesting_info(
            signer::address_of(creator),
            signer::address_of(recipient)
        );
        assert!(
            vesting.allocation == 200 && vesting.claimed_amount == 0 && vesting.start_time ==
                 100 && vesting.vesting_period == 200 && vesting.cliff_period == 20 && vesting
                .claim_frequency == 20,
            7
        );

        primary_fungible_store::deposit(
            store_addr(signer::address_of(creator)),
            tokens
        );
        move_to(
            creator,
            CapabilityStore { capability }
        );
    }

    #[test(creator = @0x999, recipient = @0x998, mod_account = @0x1)]
    fun test_vesting(
        creator: &signer,
        recipient: &signer,
        mod_account: &signer
    ) acquires VestingStore {
        let metadata = test_init(mod_account);
        let capability = create_vesting_store(creator, metadata);
        enable_claim(&capability);

        test_mint(
            mod_account,
            signer::address_of(creator),
            1000
        );
        let tokens = coin::withdraw(creator, metadata, 1000);

        // deposit tokens
        primary_fungible_store::deposit(
            store_addr(signer::address_of(creator)),
            tokens
        );
        assert!(
            vesting_funds(signer::address_of(creator)) == 1000,
            1
        );

        // set block info
        block::set_block_info(100, 100);

        // add vesting
        add_vesting(
            &capability,
            signer::address_of(recipient),
            100, // allocation
            100, // vesting period
            10, // cliff period
            10 // claim frequency
        );

        // cliff period passed
        block::set_block_info(100, 110);

        let claimable_amount = claimable_amount(
            signer::address_of(creator),
            signer::address_of(recipient)
        );
        assert!(claimable_amount == 10, 2);

        // cliff period + 1.5 claim frequency passed
        block::set_block_info(100, 125);

        let claimable_amount = claimable_amount(
            signer::address_of(creator),
            signer::address_of(recipient)
        );
        assert!(claimable_amount == 20, 3);

        // cliff period + 2 claim frequency passed
        block::set_block_info(100, 130);

        let claimable_amount = claimable_amount(
            signer::address_of(creator),
            signer::address_of(recipient)
        );
        assert!(claimable_amount == 30, 4);

        // claim
        let tokens = claim(
            recipient,
            signer::address_of(creator)
        );
        assert!(
            fungible_asset::amount(&tokens) == 30,
            5
        );

        let vesting = vesting_info(
            signer::address_of(creator),
            signer::address_of(recipient)
        );
        assert!(vesting.claimed_amount == 30, 6);

        // vesting period passed
        block::set_block_info(100, 200);

        let claimable_amount = claimable_amount(
            signer::address_of(creator),
            signer::address_of(recipient)
        );
        assert!(claimable_amount == 70, 7);

        // claim
        let tokens2 = claim(
            recipient,
            signer::address_of(creator)
        );
        assert!(
            fungible_asset::amount(&tokens2) == 70,
            8
        );

        // all claimed, so the vesting should be removed
        assert!(
            !has_vesting(
                signer::address_of(creator),
                signer::address_of(recipient)
            ),
            9
        );

        fungible_asset::merge(&mut tokens, tokens2);
        primary_fungible_store::deposit(
            store_addr(signer::address_of(creator)),
            tokens
        );
        move_to(
            creator,
            CapabilityStore { capability }
        );
    }

    #[test(creator = @0x999, recipient = @0x998, mod_account = @0x1)]
    #[expected_failure(abort_code = 0x80001, location = Self)]
    fun failed_to_create_vesting_store_with_already_exists_error(
        creator: &signer,
        mod_account: &signer
    ) {
        let metadata = test_init(mod_account);
        let capability1 = create_vesting_store(creator, metadata);
        let capability2 = create_vesting_store(creator, metadata);

        move_to(
            creator,
            CapabilityStore {capability: capability1}
        );
        move_to(
            creator,
            CapabilityStore {capability: capability2}
        );
    }

    #[test(creator = @0x999, recipient = @0x998, mod_account = @0x1)]
    #[expected_failure(abort_code = 0x80004, location = Self)]
    fun failed_to_add_vesting_with_already_exists_error(
        creator: &signer,
        recipient: &signer,
        mod_account: &signer
    ) acquires VestingStore {
        let metadata = test_init(mod_account);
        let capability = create_vesting_store(creator, metadata);

        block::set_block_info(100, 100);

        add_vesting(
            &capability,
            signer::address_of(recipient),
            100, // allocation
            100, // vesting period
            10, // cliff period
            10 // claim frequency
        );

        add_vesting(
            &capability,
            signer::address_of(recipient),
            100, // allocation
            100, // vesting period
            10, // cliff period
            10 // claim frequency
        );

        move_to(
            creator,
            CapabilityStore { capability }
        );
    }

    #[test(creator = @0x999, recipient = @0x998, mod_account = @0x1)]
    #[expected_failure(abort_code = 0x60005, location = Self)]
    fun failed_to_remove_vesting_with_not_found_error(
        creator: &signer,
        recipient: &signer,
        mod_account: &signer
    ) acquires VestingStore {
        let metadata = test_init(mod_account);
        let capability = create_vesting_store(creator, metadata);

        add_vesting(
            &capability,
            signer::address_of(recipient),
            100, // allocation
            100, // vesting period
            10, // cliff period
            10 // claim frequency
        );

        remove_vesting(
            &capability,
            signer::address_of(recipient)
        );

        remove_vesting(
            &capability,
            signer::address_of(recipient)
        );

        move_to(
            creator,
            CapabilityStore { capability }
        );
    }

    #[test(creator = @0x999, recipient = @0x998, mod_account = @0x1)]
    #[expected_failure(abort_code = 0x30002, location = Self)]
    fun failed_to_claim_vesting_with_claim_not_eabled(
        creator: &signer,
        recipient: &signer,
        mod_account: &signer
    ) acquires VestingStore {
        let metadata = test_init(mod_account);
        let capability = create_vesting_store(creator, metadata);

        // claim
        let tokens = claim(
            recipient,
            signer::address_of(creator)
        );

        primary_fungible_store::deposit(
            store_addr(signer::address_of(creator)),
            tokens
        );
        move_to(
            creator,
            CapabilityStore { capability }
        );
    }

    #[test(creator = @0x999, recipient = @0x998, mod_account = @0x1)]
    #[expected_failure(abort_code = 0x30003, location = Self)]
    fun failed_to_claim_vesting_with_not_found_error(
        creator: &signer,
        recipient: &signer,
        mod_account: &signer
    ) acquires VestingStore {
        let metadata = test_init(mod_account);

        let capability = create_vesting_store(creator, metadata);
        enable_claim(&capability);

        // claim
        let tokens = claim(
            recipient,
            signer::address_of(creator)
        );

        primary_fungible_store::deposit(
            store_addr(signer::address_of(creator)),
            tokens
        );
        move_to(
            creator,
            CapabilityStore { capability }
        );
    }
}
