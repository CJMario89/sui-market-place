// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0


module MakeofferKiosk::makeofferKiosk {
    use sui::kiosk as kiosk;
    use std::option::{Self, Option};
    use sui::tx_context::{TxContext, sender};
    use sui::dynamic_object_field as dof;
    use sui::object::{Self, UID, ID};
    use sui::dynamic_field as df;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::event;


    const ENotOwner: u64 = 0;
    const EIncorrectAmount: u64 = 1;
    const ENotEnough: u64 = 2;
    const ENotEmpty: u64 = 3;
    const EOfferedExclusively: u64 = 4;
    const EUidAccessNotAllowed: u64 = 5;
    const EItemNotFound: u64 = 6;
    const ENotOffered: u64 = 7;

    struct MakeofferKiosk has key, store {
        id: UID,
        /// Balance of the Kiosk - all profits from sales go here.
        profits: Balance<SUI>,
        //makeoffer
        offer_pool: Balance<SUI>,
        /// Always point to `sender` of the transaction.
        /// Can be changed by calling `set_owner` with Cap.
        owner: address,
        /// Number of items stored in a Kiosk. Used to allow unpacking
        /// an empty Kiosk if it was wrapped or has a single owner.
        item_count: u32,
        /// [DEPRECATED] Please, don't use the `allow_extensions` and the matching
        /// `set_allow_extensions` function - it is a legacy feature that is being
        /// replaced by the `kiosk_extension` module and its Extensions API.
        ///
        /// Exposes `uid_mut` publicly when set to `true`, set to `false` by default.
        allow_extensions: bool
    }

    /// A Capability granting the bearer a right to `place` and `take` items
    struct KioskOwnerCap has key, store {
        id: UID,
        for: ID
    }

    // === Utilities ===

    // === Dynamic Field keys ===

    /// Dynamic field key for an item placed into the kiosk.
    struct Item has store, copy, drop { id: ID }
    /// Dynamic field key for an got into the kiosk.
    struct Got has store, copy, drop { id: ID }

    //makeoffer
    struct Offering has store, copy, drop { id: ID }

    //makeoffer
    struct OfferMade<phantom T: key + store> has copy, drop {
        kiosk: ID,
        id: ID,
        item_id: ID,
        amount: u64
    }

    //makeoffer
    struct OfferAccepted<phantom T: key + store> has copy, drop {
        kiosk: ID,
        id: ID,
        item_id: ID,
        amount: u64
    }

    //makeoffer
    struct OfferDemade<phantom T: key + store> has copy, drop {
        kiosk: ID,
        id: ID,
        item_id: ID,
        amount: u64
    }

    // === Kiosk packing and unpacking ===

    #[lint_allow(self_transfer, share_owned)]
    /// Creates a new Kiosk in a default configuration: sender receives the
    /// `KioskOwnerCap` and becomes the Owner, the `Kiosk` is shared.
    entry fun default(ctx: &mut TxContext) {
        let (kiosk, cap) = new(ctx);
        sui::transfer::transfer(cap, sender(ctx));
        sui::transfer::share_object(kiosk);
    }

    /// Creates a new `Kiosk` with a matching `KioskOwnerCap`.
    public fun new(ctx: &mut TxContext): (MakeofferKiosk, KioskOwnerCap) {
        let kiosk = MakeofferKiosk {
            id: object::new(ctx),
            profits: balance::zero(),
            offer_pool: balance::zero(),
            owner: sender(ctx),
            item_count: 0,
            allow_extensions: false
        };

        let cap = KioskOwnerCap {
            id: object::new(ctx),
            for: object::id(&kiosk)
        };

        (kiosk, cap)
    }

    /// Unpacks and destroys a Kiosk returning the profits (even if "0").
    /// Can only be performed by the bearer of the `KioskOwnerCap` in the
    /// case where there's no items inside and a `Kiosk` is not shared.
    public fun close_and_withdraw(
        self: MakeofferKiosk, cap: KioskOwnerCap, ctx: &mut TxContext
    ){
        let MakeofferKiosk { id, profits, offer_pool, owner: _, item_count, allow_extensions: _ } = self;
        let KioskOwnerCap { id: cap_id, for } = cap;

        assert!(object::uid_to_inner(&id) == for, ENotOwner);
        assert!(item_count == 0, ENotEmpty);

        object::delete(cap_id);
        object::delete(id);
        let offer_pool_amount = coin::from_balance(offer_pool, ctx);
        coin::put(&mut profits, offer_pool_amount);
        let total = coin::from_balance(profits, ctx);
        sui::transfer::public_transfer(total, sender(ctx))        
    }

    /// Change the `owner` field to the transaction sender.
    /// The change is purely cosmetical and does not affect any of the
    /// basic kiosk functions unless some logic for this is implemented
    /// in a third party module.
    public fun set_owner(
        self: &mut MakeofferKiosk, cap: &KioskOwnerCap, ctx: &TxContext
    ) {
        assert!(has_access(self, cap), ENotOwner);
        self.owner = sender(ctx);
    }

    /// Update the `owner` field with a custom address. Can be used for
    /// implementing a custom logic that relies on the `Kiosk` owner.
    public fun set_owner_custom(
        self: &mut MakeofferKiosk, cap: &KioskOwnerCap, owner: address
    ) {
        assert!(has_access(self, cap), ENotOwner);
        self.owner = owner
    }

    

    /// Take any object from the Kiosk.
    /// Performs an authorization check to make sure only owner can do that.
    public fun take<T: key + store>(
        self: &mut MakeofferKiosk, cap: &KioskOwnerCap, id: ID, ctx: &mut TxContext
    ){
        assert!(has_access(self, cap), ENotOwner);
        assert!(has_got(self, id), EItemNotFound);

        self.item_count = self.item_count - 1;
        let item = dof::remove<Got, T>(&mut self.id, Got { id });
        sui::transfer::public_transfer(item, sender(ctx))
    }


    
    /// Calls `place` and `offer` together - simplifies the flow.
    //makeoffer
    //item => offer
    //price => item_id
    public fun place_and_offer<T: key + store>(
        self: &mut MakeofferKiosk, cap: &KioskOwnerCap, item_id: ID, offer: Coin<SUI>
    ) {
        let id = object::id(&offer);
        assert!(has_access(self, cap), ENotOwner);
        self.item_count = self.item_count + 1;
        let amount = coin::value(&offer);
        coin::put(&mut self.offer_pool, offer);
        df::add(&mut self.id, Offering { id: item_id }, amount);
        event::emit(OfferMade<T> { kiosk: object::id(self), id, item_id, amount })
    }

    // makeoffer
    public fun deoffer<T: key + store>(
        self: &mut MakeofferKiosk, cap: &KioskOwnerCap, item_id: ID, ctx: &mut TxContext
    ) {
        assert!(has_access(self, cap), ENotOwner);
        assert!(has_offer(self, item_id), EItemNotFound);
        assert!(is_offered(self, item_id), ENotOffered);

        self.item_count = self.item_count + 1;
        let amount = df::remove<Offering, u64>(&mut self.id, Offering { id:item_id });
        let offer = coin::take(&mut self.offer_pool, amount, ctx);
        sui::transfer::public_transfer(offer, sender(ctx));
        
        event::emit(OfferDemade<T> { kiosk: object::id(self), id:item_id, item_id, amount })
    }

    /// if they have a method implemented that allows a trade, it is possible to
    /// request their approval (by calling some function) so that the trade can be
    /// finalized.
    //makeoffer
    //purchase => acceptoffer
    //payment => item
    public fun acceptoffer<T: key + store>(
        self: &mut MakeofferKiosk, id: ID, item: T, ctx: &mut TxContext
    ) {
        let item_id = object::id(&item);
        self.item_count = self.item_count - 1;
        assert!(item_id == object::id(&item), EIncorrectAmount);
        let amount = df::remove<Offering, u64>(&mut self.id, Offering { id: item_id });

        event::emit(OfferAccepted<T> { kiosk: object::id(self), id, item_id, amount });
        dof::add(&mut self.id, Got { id: item_id }, item);
        let offer = coin::take(&mut self.offer_pool, amount, ctx);
        sui::transfer::public_transfer(offer, sender(ctx))

    }

   
    /// Withdraw profits from the Kiosk.
    public fun withdraw(
        self: &mut MakeofferKiosk, cap: &KioskOwnerCap, amount: Option<u64>, ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(has_access(self, cap), ENotOwner);

        let amount = if (option::is_some(&amount)) {
            let amt = option::destroy_some(amount);
            assert!(amt <= balance::value(&self.profits), ENotEnough);
            amt
        } else {
            balance::value(&self.profits)
        };

        coin::take(&mut self.profits, amount, ctx)
    }


    /// Internal: "place" an item to the Kiosk and increment the item count.
    //makeoffer
    //item => offer
    public(friend) fun place_internal(self: &mut MakeofferKiosk, offer: Coin<SUI>) {
        self.item_count = self.item_count + 1;
        let id = object::id(&offer);
        let amount = coin::value(&offer);
        coin::put(&mut self.offer_pool, offer);
        df::add(&mut self.id, Offering { id: id }, amount)
    }

    /// Internal: get a mutable access to the UID.
    public(friend) fun uid_mut_internal(self: &mut MakeofferKiosk): &mut UID {
        &mut self.id
    }

    // === Kiosk fields access ===

    /// Check whether the `item` is present in the `Kiosk`.
    public fun has_item(self: &MakeofferKiosk, id: ID): bool {
        dof::exists_(&self.id, Item { id })
    }

    /// Check whether the `item` is present in the `Kiosk` and has type T.
    public fun has_item_with_type<T: key + store>(self: &MakeofferKiosk, id: ID): bool {
        dof::exists_with_type<Item, T>(&self.id, Item { id })
    }

    //makeoffer
    public fun has_offer(self: &MakeofferKiosk, id: ID): bool {
        df::exists_(&self.id, Offering { id })
    }

    //makeoffer
    public fun has_got(self: &MakeofferKiosk, id: ID): bool {
        df::exists_(&self.id, Got { id })
    }

    //makeoffer
    public fun is_offered(self: &MakeofferKiosk, id: ID): bool {
        df::exists_(&self.id, Offering { id })
    }


    /// Check whether the `KioskOwnerCap` matches the `Kiosk`.
    public fun has_access(self: &mut MakeofferKiosk, cap: &KioskOwnerCap): bool {
        object::id(self) == cap.for
    }

    /// Access the `UID` using the `KioskOwnerCap`.
    public fun uid_mut_as_owner(
        self: &mut MakeofferKiosk, cap: &KioskOwnerCap
    ): &mut UID {
        assert!(has_access(self, cap), ENotOwner);
        &mut self.id
    }

    /// [DEPRECATED]
    /// Allow or disallow `uid` and `uid_mut` access via the `allow_extensions`
    /// setting.
    public fun set_allow_extensions(
        self: &mut MakeofferKiosk, cap: &KioskOwnerCap, allow_extensions: bool
    ) {
        assert!(has_access(self, cap), ENotOwner);
        self.allow_extensions = allow_extensions;
    }

    /// Get the immutable `UID` for dynamic field access.
    /// Always enabled.
    ///
    /// Given the &UID can be used for reading keys and authorization,
    /// its access
    public fun uid(self: &MakeofferKiosk): &UID {
        &self.id
    }

    /// Get the mutable `UID` for dynamic field access and extensions.
    /// Aborts if `allow_extensions` set to `false`.
    public fun uid_mut(self: &mut MakeofferKiosk): &mut UID {
        assert!(self.allow_extensions, EUidAccessNotAllowed);
        &mut self.id
    }

    /// Get the owner of the MakeofferKiosk.
    public fun owner(self: &MakeofferKiosk): address {
        self.owner
    }

    /// Get the number of items stored in a MakeofferKiosk.
    public fun item_count(self: &MakeofferKiosk): u32 {
        self.item_count
    }

    /// Get the amount of profits collected by selling items.
    public fun profits_amount(self: &MakeofferKiosk): u64 {
        balance::value(&self.profits)
    }

    /// Get mutable access to `profits` - owner only action.
    public fun profits_mut(self: &mut MakeofferKiosk, cap: &KioskOwnerCap): &mut Balance<SUI> {
        assert!(has_access(self, cap), ENotOwner);
        &mut self.profits
    }

    //Orignal Kiosk

    public fun place_and_list<T: key + store>(
        self: &mut kiosk::Kiosk, cap: &kiosk::KioskOwnerCap, item: T, price: u64
    ) {
        kiosk::place_and_list(self, cap, item, price)
    }


}