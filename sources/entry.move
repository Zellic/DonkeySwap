module donkeyswap::user {
    use donkeyswap::market;

    public entry fun swap<BaseCoinType, QuoteCoinType>(
        user: &signer,
        base_size: u64
    ) {
        market::swap<BaseCoinType, QuoteCoinType>(user, base_size);
    }


    public entry fun add_liquidity<CoinType>(
        user: &signer,
        size: u64
    ) {
        market::add_liquidity<CoinType>(user, size);
    }


    public entry fun remove_liquidity<CoinType>(
        user: &signer,
        lp_size: u64
    ) {
        market::remove_liquidity<CoinType>(user, lp_size);
    }

    
    public entry fun limit_swap<BaseCoinType, QuoteCoinType>(
        user: &signer,
        base: u64,
        min_quote: u64
    ) {
        market::limit_swap<BaseCoinType, QuoteCoinType>(user, base, min_quote);
    }


    public entry fun cancel_order<BaseCoinType>(
        user: &signer,
        order_id: u64
    ) {
        market::cancel_order<BaseCoinType>(user, order_id);
    }


    public entry fun fulfill_orders<CoinType>() {
        market::fulfill_orders<CoinType>();
    }


    public entry fun fulfill_order<CoinType>(
        order_id: u64
    ) {
        market::fulfill_order<CoinType>(order_id);
    }

}
