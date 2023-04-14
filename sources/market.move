module donkeyswap::market {
    //use aptos_framework::debug;

    use std::signer::address_of;

    //use std::debug;
    use std::vector;
    use std::option::{Self, Option};
    use aptos_framework::type_info::{Self, TypeInfo};
    use aptos_std::math64;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::table::{Self, Table};


    //////// SECTION: CONFIGURATION


    const PROTOCOL_FEE_BPS: u64 = 50; // 0.5%


    //////// SECTION: CONSTANTS AND DEFINITIONS


    const ERR_COINSTORE_NONEXISTENT: u64 = 101;
    const ERR_COINSTORE_ALREADY_EXISTS: u64 = 102;
    const ERR_COINSTORE_COIN_NOT_INITIALIZED: u64 = 103;
    const ERR_LIQUIDITY_INSUFFICIENT: u64 = 201;
    const ERR_QUOTE_INSUFFICIENT: u64 = 202;
    const ERR_ORDER_NOT_FOUND: u64 = 301;
    const ERR_ORDER_TYPE_UNKNOWN: u64 = 302;
    const ERR_ORDER_WRONG_COIN_TYPE: u64 = 303;
    const ERR_ORDER_DUPLICATE_COIN_TYPE: u64 = 304;
    const ERR_PERMISSION_DENIED: u64 = 401;
    const ERR_ALREADY_INITIALIZED: u64 = 402;


    struct CoinStore<phantom CoinType> has key {
        coins: Coin<CoinType>,
        protocol_fees: u64
    }

    struct OrderStore has key {
        current_id: u64,
        orders: vector<Order>,
        locked: Table<TypeInfo, u64>,
        liquidity: Table<TypeInfo, u64>,
        decimals: Table<TypeInfo, u8>
    }

    struct Order has drop, store, copy {
        type: TypeInfo,
        id: u64,
        user_address: address,
        base_type: TypeInfo,
        quote_type: TypeInfo,
        base: u64,
        min_quote: u64
    }


    struct USDC {}
    struct DONK {}
    struct LimitSwapOrder {}
    

    //////// SECTION: ENTRY FUNCTIONS


    public fun swap<BaseCoinType, QuoteCoinType>(
        user: &signer,
        base_size: u64
    ): (u64) acquires OrderStore, CoinStore {
        assert!(type_info::type_of<BaseCoinType>() != type_info::type_of<QuoteCoinType>(), ERR_ORDER_DUPLICATE_COIN_TYPE);
        let lp_size = add_liquidity<BaseCoinType>(user, base_size);
        return remove_liquidity<QuoteCoinType>(user, lp_size)
    }


    public fun add_liquidity<CoinType>(
        user: &signer,
        size: u64
    ): (u64) acquires OrderStore, CoinStore {
        assert_input_cointype<CoinType>();

        // withdraw coin
        let order_store = borrow_global_mut<OrderStore>(@donkeyswap);
        withdraw_funds<CoinType>(order_store, user, size);

        // give lp coin
        // no protocol fees for depositing liquidity
        let lp_coin_amount = calculate_lp_coin_amount_internal(order_store, size, type_info::type_of<CoinType>());
        deposit_funds<DONK>(order_store, address_of(user), lp_coin_amount);

        // since there is more liquidity in one side, retry fulfilling orders;
        // some may not have been fulfilled because of insufficient liquidity
        fulfill_orders<CoinType>();

        return lp_coin_amount
    }


    public fun remove_liquidity<CoinType>(
        user: &signer,
        lp_size: u64
    ): (u64) acquires OrderStore, CoinStore {
        assert_input_cointype<CoinType>();

        // withdraw lp coin
        let order_store = borrow_global_mut<OrderStore>(@donkeyswap);
        withdraw_funds<DONK>(order_store, user, lp_size);

        // calculate coin size to transfer
        let size = calculate_coin_from_lp_coin_amount_internal<CoinType>(order_store, lp_size);
        let fees = calculate_protocol_fees(size);
        let size_after_fees = size - fees;

        let order_store = borrow_global_mut<OrderStore>(@donkeyswap);
        record_protocol_fees_paid<CoinType>(order_store, fees);

        let error_code = execute_remove_liquidity<CoinType>(order_store, address_of(user), size_after_fees);
        assert!(error_code == 0, error_code);
        return size_after_fees
    }

    
    /// Don't swap until receiving at least min_quote
    public fun limit_swap<BaseCoinType, QuoteCoinType>(
        user: &signer,
        base: u64,
        min_quote: u64
    ): (u64) acquires OrderStore, CoinStore {
        assert_input_cointype<BaseCoinType>();
        assert_input_cointype<QuoteCoinType>();

        let order_store = borrow_global_mut<OrderStore>(@donkeyswap);

        // withdraw coin
        withdraw_funds<BaseCoinType>(order_store, user, base);
        lock_coin(order_store, base, type_info::type_of<BaseCoinType>());

        // register order
        let order = Order {
            type: type_info::type_of<LimitSwapOrder>(),
            id: { order_store.current_id = order_store.current_id + 1; order_store.current_id },
            user_address: address_of(user), // VULN: does not check if account is registered
            base_type: type_info::type_of<BaseCoinType>(),
            quote_type: type_info::type_of<QuoteCoinType>(),
            base: base,
            min_quote: min_quote
        };

        vector::push_back(&mut order_store.orders, order);
        return order.id
    }


    public fun cancel_order<BaseCoinType>(
        user: &signer,
        order_id: u64
    ) acquires OrderStore, CoinStore {
        let order_store = borrow_global_mut<OrderStore>(@donkeyswap);

        let order_option: Option<Order> = get_order_by_id(order_store, order_id);
        assert!(!option::is_none(&order_option), ERR_ORDER_NOT_FOUND);
        let order: Order = option::extract(&mut order_option);

        unlock_coin(order_store, order.base, type_info::type_of<BaseCoinType>());

        // VULN: does not check if order.base_type == type_info::type_of(BaseCoinType)
        // VULN: does not check if order.user_address == address_of(user)
        deposit_funds<BaseCoinType>(order_store, address_of(user), order.base);

        drop_order(order_store, &order);
    }


    public fun fulfill_orders<CoinType>(): vector<u64> acquires OrderStore, CoinStore {
        let order_store = borrow_global_mut<OrderStore>(@donkeyswap);

        let successful_order_ids = vector::empty<u64>();
        let coin_type = type_info::type_of<CoinType>();

        let orders: vector<Order> = vector::empty();

        let i = 0;
        let len = vector::length(&order_store.orders);
        
        while (i < len) {
            let order = vector::borrow<Order>(&order_store.orders, i);
            if (order.quote_type == coin_type) {
                vector::push_back(&mut orders, *order);
            };
            i = i + 1;
        };

        while (true) {
            let order_option = get_next_order(&mut orders);
            if (option::is_none(&order_option)) {
                break
            };
            let status = execute_order<CoinType>(order_store, &option::extract(&mut order_option));
            if (status == 0) {
                vector::push_back(&mut successful_order_ids, option::borrow(&mut order_option).id);
            };
        };
        
        return successful_order_ids
    }


    public fun fulfill_order<CoinType>(
        order_id: u64
    ): (u64) acquires OrderStore, CoinStore {
        let order_store = borrow_global_mut<OrderStore>(@donkeyswap);
        let order_option: Option<Order> = get_order_by_id(order_store, order_id);
        assert!(!option::is_none(&order_option), ERR_ORDER_NOT_FOUND);
        return execute_order<CoinType>(order_store, option::borrow(&order_option))
    }


    //////// SECTION: ADMIN-ONLY ENTRY FUNCTIONS


    public entry fun admin_setup(admin: &signer) acquires OrderStore {
        assert!(address_of(admin) == @donkeyswap, ERR_PERMISSION_DENIED);
        assert!(!exists<OrderStore>(address_of(admin)), ERR_ALREADY_INITIALIZED);

        move_to(admin, OrderStore {
            current_id: 0,
            orders: vector::empty<Order>(),
            locked: table::new<TypeInfo, u64>(),
            liquidity: table::new<TypeInfo, u64>(),
            decimals: table::new<TypeInfo, u8>()
        });

        admin_create_coinstore<DONK>(admin);
        admin_create_coinstore<USDC>(admin);
    }


    public entry fun admin_deposit_donk(admin: &signer, amount: u64) acquires OrderStore, CoinStore {
        assert!(address_of(admin) == @donkeyswap, ERR_PERMISSION_DENIED);

        assert!(coin::is_coin_initialized<DONK>(), ERR_COINSTORE_COIN_NOT_INITIALIZED);
        let order_store = borrow_global_mut<OrderStore>(@donkeyswap);
        let coin = coin::withdraw<DONK>(admin, amount);
        let dest_coin_store = borrow_global_mut<CoinStore<DONK>>(@donkeyswap);
        register_liquidity(order_store, amount, type_info::type_of<DONK>());
        coin::merge<DONK>(&mut dest_coin_store.coins, coin);
    }


    public entry fun admin_create_coinstore<CoinType>(
        admin: &signer
    ) acquires OrderStore {
        assert!(address_of(admin) == @donkeyswap, ERR_PERMISSION_DENIED);

        assert!(coin::is_coin_initialized<CoinType>(), ERR_COINSTORE_COIN_NOT_INITIALIZED);
        assert!(!exists<CoinStore<CoinType>>(@donkeyswap), ERR_COINSTORE_ALREADY_EXISTS);
        move_to(admin, CoinStore<CoinType> {
            coins: coin::zero<CoinType>(),
            protocol_fees: 0
        });

        let order_store = borrow_global_mut<OrderStore>(@donkeyswap);
        table::add(&mut order_store.locked, type_info::type_of<CoinType>(), 0);
        table::add(&mut order_store.liquidity, type_info::type_of<CoinType>(), 0);
        table::add(&mut order_store.decimals, type_info::type_of<CoinType>(), coin::decimals<CoinType>());
    }


    public entry fun admin_withdraw_protocol_fees<CoinType>(
        admin: &signer
    ) acquires OrderStore, CoinStore {
        assert!(address_of(admin) == @donkeyswap, ERR_PERMISSION_DENIED);

        assert!(exists<CoinStore<CoinType>>(@donkeyswap), ERR_COINSTORE_NONEXISTENT);
        let coin_store = borrow_global_mut<CoinStore<CoinType>>(@donkeyswap);

        let fees = coin_store.protocol_fees;
        let fee_coins = coin::extract(&mut coin_store.coins, fees);
        coin::deposit<CoinType>(address_of(admin), fee_coins);
        let order_store = borrow_global_mut<OrderStore>(@donkeyswap);
        unlock_coin(order_store, fees, type_info::type_of<CoinType>());
        coin_store.protocol_fees = 0;
    }


    //////// SECTION: INTERNAL FUNCTIONS


    fun get_next_order(orders: &mut vector<Order>): (Option<Order>) {
        let len: u64 = vector::length(orders);
        if (len == 0) {
            return option::none<Order>()
        };

        // just pop from it
        let order: Order = vector::remove<Order>(orders, 0);
        return option::some<Order>(order)
    }

    
    fun execute_remove_liquidity<CoinType>(
        order_store: &mut OrderStore,
        user_address: address,
        size: u64
    ): (u64) acquires CoinStore { // error code, if any (otherwise 0)
        // checks

        if (size > get_liquidity_size_internal(order_store, type_info::type_of<CoinType>())) {
            return ERR_LIQUIDITY_INSUFFICIENT
        };

        // effects

        deposit_funds<CoinType>(order_store, user_address, size);
        return 0
    }


    fun withdraw_funds<CoinType>(
        order_store: &mut OrderStore,
        user: &signer,
        amount: u64
    ) acquires CoinStore {
        assert!(exists<CoinStore<CoinType>>(@donkeyswap), ERR_COINSTORE_NONEXISTENT);
        let coin = coin::withdraw<CoinType>(user, amount);
        let dest_coin_store = borrow_global_mut<CoinStore<CoinType>>(@donkeyswap);
        register_liquidity(order_store, amount, type_info::type_of<CoinType>());
        coin::merge<CoinType>(&mut dest_coin_store.coins, coin);
    }


    fun deposit_funds<CoinType>(
        order_store: &mut OrderStore,
        user_address: address,
        amount: u64
    ) acquires CoinStore {
        let coin_store = borrow_global_mut<CoinStore<CoinType>>(@donkeyswap);
        let coin = coin::extract<CoinType>(&mut coin_store.coins, amount);
        unregister_liquidity(order_store, amount, type_info::type_of<CoinType>());
        coin::deposit(user_address, coin); // VULN: does not check if user address is registered
    }


    fun execute_order<CoinType>(
        order_store: &mut OrderStore,
        order: &Order
    ): (u64) acquires CoinStore {
        if (order.type == type_info::type_of<LimitSwapOrder>()) {
            return execute_limit_order<CoinType>(order_store, order)
        };

        abort(ERR_ORDER_TYPE_UNKNOWN)
    }


    fun execute_limit_order<QuoteCoinType>(
        order_store: &mut OrderStore,
        order: &Order
    ): (u64) acquires CoinStore {
        // checks

        if (order.quote_type != type_info::type_of<QuoteCoinType>()) {
            return ERR_ORDER_WRONG_COIN_TYPE
        };
        
        let lp_size = calculate_lp_coin_amount_internal(order_store, order.base, order.base_type);

        let size = calculate_coin_from_lp_coin_amount_internal<QuoteCoinType>(order_store, lp_size);
        let fees = calculate_protocol_fees(size);
        let size_after_fees = size - fees;

        if (size_after_fees < order.min_quote) {
            return ERR_QUOTE_INSUFFICIENT
        };

        // effects

        let error_code = execute_remove_liquidity<QuoteCoinType>(order_store, order.user_address, size_after_fees);
        if (error_code == 0) {
            // successfully executed
            record_protocol_fees_paid<QuoteCoinType>(order_store, fees);
            unlock_coin(order_store, order.base, order.base_type);
            drop_order(order_store, order);
        }; // otherwise, leave it to be executed later

        return error_code
    }


    fun drop_order(
        order_store: &mut OrderStore,
        order: &Order,
    ) {
        let i = 0;
        let len = vector::length(&order_store.orders);
        while (i < len) {
            let order2 = vector::borrow<Order>(&order_store.orders, i);
            if (order2.id == order.id) {
                vector::remove<Order>(&mut order_store.orders, i);
                break
            };
            i = i + 1;
        };
    }


    fun record_protocol_fees_paid<CoinType>(
        order_store: &mut OrderStore,
        fees: u64
    ) acquires CoinStore {
        let coin_store = borrow_global_mut<CoinStore<CoinType>>(@donkeyswap);
        coin_store.protocol_fees = coin_store.protocol_fees + fees;
        lock_coin(order_store, fees, type_info::type_of<CoinType>());
    }


    fun lock_coin(
        order_store: &mut OrderStore,
        size: u64,
        type: TypeInfo
    ) {
        let current_locked = get_locked_size_internal(order_store, type);
        let current_liquidity = get_liquidity_size_internal(order_store, type);
        assert!(size <= current_liquidity, ERR_LIQUIDITY_INSUFFICIENT);
        table::upsert<TypeInfo, u64>(&mut order_store.locked, type, current_locked + size);
        table::upsert<TypeInfo, u64>(&mut order_store.liquidity, type, current_liquidity - size);
    }


    fun unlock_coin(
        order_store: &mut OrderStore,
        size: u64,
        type: TypeInfo
    ) {
        let current_locked = get_locked_size_internal(order_store, type);
        let current_liquidity = get_liquidity_size_internal(order_store, type);
        table::upsert<TypeInfo, u64>(&mut order_store.locked, type, current_locked - size);
        table::upsert<TypeInfo, u64>(&mut order_store.liquidity, type, current_liquidity + size);
    }


    fun register_liquidity(
        order_store: &mut OrderStore,
        size: u64,
        type: TypeInfo
    ) {
        let current_liquidity = get_liquidity_size_internal(order_store, type);
        table::upsert<TypeInfo, u64>(&mut order_store.liquidity, type, current_liquidity + size);
    }


    fun unregister_liquidity(
        order_store: &mut OrderStore,
        size: u64,
        type: TypeInfo
    ) {
        let current_liquidity = get_liquidity_size_internal(order_store, type);
        table::upsert<TypeInfo, u64>(&mut order_store.liquidity, type, current_liquidity - size);
    }


    fun assert_input_cointype<CoinType>() {
        assert!(type_info::type_of<CoinType>() != type_info::type_of<DONK>(), ERR_ORDER_WRONG_COIN_TYPE);
    }


    //////// SECTION: READ-ONLY FUNCTIONS


    fun calculate_lp_coin_amount_internal(
        order_store: &OrderStore,
        size: u64,
        type: TypeInfo
    ): (u64) {
        return size * get_usd_value_internal(order_store, type)
    }


    #[query]
    public fun calculate_lp_coin_amount(
        size: u64,
        type: TypeInfo
    ): (u64) acquires OrderStore {
        let order_store = borrow_global<OrderStore>(@donkeyswap);
        return calculate_lp_coin_amount_internal(order_store, size, type)
    }


    fun calculate_coin_from_lp_coin_amount_internal<CoinType>(
        order_store: &OrderStore,
        lp_size: u64
    ): (u64) {
        let usd_value = get_usd_value_internal(order_store, type_info::type_of<CoinType>());
        return if (usd_value == 0) { 0 } else { lp_size / usd_value }
    }


    #[query]
    public fun calculate_coin_from_lp_coin_amount<CoinType>(
        lp_size: u64
    ): (u64) acquires OrderStore {
        let order_store = borrow_global<OrderStore>(@donkeyswap);
        return calculate_coin_from_lp_coin_amount_internal<CoinType>(order_store, lp_size)
    }


    fun get_usd_value_internal(
        order_store: &OrderStore,
        type: TypeInfo
    ): (u64) {
        let usdc_type = type_info::type_of<USDC>();
        let base_size = get_liquidity_size_internal(order_store, type);
        let quote_size = get_liquidity_size_internal(order_store, usdc_type);
        assert!(base_size != 0 && quote_size != 0, ERR_LIQUIDITY_INSUFFICIENT);

        return get_price_internal(order_store, type, usdc_type)
    }


    #[query]
    public fun get_usd_value(
        type: TypeInfo
    ): (u64) acquires OrderStore {
        let order_store = borrow_global<OrderStore>(@donkeyswap);
        return get_usd_value_internal(order_store, type)
    }

    
    #[query]
    public fun calculate_protocol_fees(
        size: u64
    ): (u64) {
        return size * PROTOCOL_FEE_BPS / 10000
    }


    fun get_order_by_id(
        order_store: &OrderStore,
        order_id: u64
    ): (Option<Order>) {
        let i = 0;
        let len = vector::length(&order_store.orders);
        while (i < len) {
            let order = vector::borrow<Order>(&order_store.orders, i);
            if (order.id == order_id) {
                return option::some(*order)
            };
            i = i + 1;
        };

        return option::none<Order>()
    }

    
    fun get_locked_size_internal(
        order_store: &OrderStore,
        type: TypeInfo
    ): (u64) {
        return *table::borrow<TypeInfo, u64>(&order_store.locked, type)
    }


    fun get_liquidity_size_internal(
        order_store: &OrderStore,
        type: TypeInfo
    ): (u64) {
        return *table::borrow<TypeInfo, u64>(&order_store.liquidity, type)
    }


    #[query]
    public fun get_locked_size(
        type: TypeInfo
    ): (u64) acquires OrderStore {
        let order_store = borrow_global<OrderStore>(@donkeyswap);
        return get_locked_size_internal(order_store, type)
    }


    #[query]
    public fun get_liquidity_size(
        type: TypeInfo
    ): (u64) acquires OrderStore {
        let order_store = borrow_global<OrderStore>(@donkeyswap);
        return get_liquidity_size_internal(order_store, type)
    }


    //////// SECTION: ORACLE CODE


    fun get_price_internal(
        order_store: &OrderStore,
        base_type: TypeInfo,
        quote_type: TypeInfo
    ): (u64) { // value is measured in quote decimals
        let base_size = get_liquidity_size_internal(order_store, base_type);
        let quote_size = get_liquidity_size_internal(order_store, quote_type);

        if (base_size == 0 || quote_size == 0) { return 0 };

        let base_decimals = *table::borrow(&order_store.decimals, base_type);
        //let quote_decimals = *table::borrow(&order_store.decimals, base_type);

        //debug::print<u64>(&base_size);
        //debug::print<u64>(&quote_size);
        //debug::print<u8>(&base_decimals);
        //debug::print<u8>(&quote_decimals);

        // x*y=k
        // (y/yd)/(x/xd)
        // (y/yd)*xd/x
        // y*xd/x/yd
        // but we want to measure in quote decimals (yd), so we leave that off
        return quote_size * math64::pow(10, (base_decimals as u64)) / base_size
    }


    #[query]
    public fun get_price(
        base_type: TypeInfo,
        quote_type: TypeInfo
    ): (u64) acquires OrderStore {
        let order_store = borrow_global<OrderStore>(@donkeyswap);
        return get_price_internal(order_store, base_type, quote_type)
    }
    

    #[query]
    public fun get_protocol_fees<CoinType>(): (u64) acquires CoinStore {
        assert!(exists<CoinStore<CoinType>>(@donkeyswap), ERR_COINSTORE_NONEXISTENT);
        let coin_store = borrow_global_mut<CoinStore<CoinType>>(@donkeyswap);
        return coin_store.protocol_fees
    }


    #[query]
    public fun get_protocol_fees_bps(): (u64) {
        return PROTOCOL_FEE_BPS
    }
    
}
