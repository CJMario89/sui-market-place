// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Kiosk is a primitive for building safe, decentralized and trustless trading
/// experiences. It allows storing and trading any types of assets as long as
/// the creator of these assets implements a `TransferPolicy` for them.
///
/// ### Principles and philosophy:
///
/// - Kiosk provides guarantees of "true ownership"; - just like single owner
/// objects, assets stored in the Kiosk can only be managed by the Kiosk owner.
/// Only the owner can `place`, `take`, `list`, perform any other actions on
/// assets in the Kiosk.
///
/// - Kiosk aims to be generic - allowing for a small set of default behaviors
/// and not imposing any restrictions on how the assets can be traded. The only
/// default scenario is a `list` + `purchase` flow; any other trading logic can
/// be implemented on top using the `list_with_purchase_cap` (and a matching
/// `purchase_with_cap`) flow.
///
/// - For every transaction happening with a third party a `TransferRequest` is
/// created - this way creators are fully in control of the trading experience.
///
/// ### Asset states in the Kiosk:
///
/// - `placed` -  An asset is `place`d into the Kiosk and can be `take`n out by
/// the Kiosk owner; it's freely tradable and modifiable via the `borrow_mut`
/// and `borrow_val` functions.
///
/// - `locked` - Similar to `placed` except that `take` is disabled and the only
/// way to move the asset out of the Kiosk is to `list` it or
/// `list_with_purchase_cap` therefore performing a trade (issuing a
/// `TransferRequest`). The check on the `lock` function makes sure that the
/// `TransferPolicy` exists to not lock the item in a `Kiosk` forever.
///
/// - `listed` - A `place`d or a `lock`ed item can be `list`ed for a fixed price
/// allowing anyone to `purchase` it from the Kiosk. While listed, an item can
/// not be taken or modified. However, an immutable borrow via `borrow` call is
/// still available. The `delist` function returns the asset to the previous
/// state.
///
/// - `listed_exclusively` - An item is listed via the `list_with_purchase_cap`
/// function (and a `PurchaseCap` is created). While listed this way, an item
/// can not be `delist`-ed unless a `PurchaseCap` is returned. All actions
/// available at this item state require a `PurchaseCap`:
///
/// 1. `purchase_with_cap` - to purchase the item for a price equal or higher
/// than the `min_price` set in the `PurchaseCap`.
/// 2. `return_purchase_cap` - to return the `PurchaseCap` and return the asset
/// into the previous state.
///
/// When an item is listed exclusively it cannot be modified nor taken and
/// losing a `PurchaseCap` would lock the item in the Kiosk forever. Therefore,
/// it is recommended to only use `PurchaseCap` functionality in trusted
/// applications and not use it for direct trading (eg sending to another
/// account).
///
/// ### Using multiple Transfer Policies for different "tracks":
///
/// Every `purchase` or `purchase_with_purchase_cap` creates a `TransferRequest`
/// hot potato which must be resolved in a matching `TransferPolicy` for the
/// transaction to pass. While the default scenario implies that there should be
/// a single `TransferPolicy<T>` for `T`; it is possible to have multiple, each
/// one having its own set of rules.
///
/// ### Examples:
///
/// - I create one `TransferPolicy` with "Royalty Rule" for everyone
/// - I create a special `TransferPolicy` for bearers of a "Club Membership"
/// object so they don't have to pay anything
/// - I create and wrap a `TransferPolicy` so that players of my game can
/// transfer items between `Kiosk`s in game without any charge (and maybe not
/// even paying the price with a 0 SUI PurchaseCap)
///
/// ```
/// Kiosk -> (Item, TransferRequest)
/// ... TransferRequest ------> Common Transfer Policy
/// ... TransferRequest ------> In-game Wrapped Transfer Policy
/// ... TransferRequest ------> Club Membership Transfer Policy
/// ```
///
/// See `transfer_policy` module for more details on how they function.
module MakeofferKiosk::kiosk {
    use std::option::{Self, Option};
    use sui::tx_context::{TxContext, sender};
    use sui::dynamic_object_field as dof;
    use sui::object::{Self, UID, ID};
    use sui::dynamic_field as df;
    use sui::transfer_policy::{
        Self,
        TransferPolicy,
        TransferRequest
    };
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::event;

    // Gets access to:
    // - `place_internal`
    // - `lock_internal`
    // - `uid_mut_internal`

    /// Trying to withdraw profits and sender is not owner.
    const ENotOwner: u64 = 0;
    /// Coin paid does not match the offer price.
    const EIncorrectAmount: u64 = 1;
    /// Trying to withdraw higher amount than stored.
    const ENotEnough: u64 = 2;
    /// Trying to close a Kiosk and it has items in it.
    const ENotEmpty: u64 = 3;
    /// Attempt to take an item that has a `PurchaseCap` issued.
    const EListedExclusively: u64 = 4;
    /// `PurchaseCap` does not match the `Kiosk`.
    const EWrongKiosk: u64 = 5;
    /// Tryng to exclusively list an already listed item.
    const EAlreadyListed: u64 = 6;
    /// Trying to call `uid_mut` when `allow_extensions` set to false.
    const EUidAccessNotAllowed: u64 = 7;
    /// Attempt to `take` an item that is locked.
    const EItemLocked: u64 = 8;
    /// Taking or mutably borrowing an item that is listed.
    const EItemIsListed: u64 = 9;
    /// Item does not match `Borrow` in `return_val`.
    const EItemMismatch: u64 = 10;
    /// An is not found while trying to borrow.
    const EItemNotFound: u64 = 11;
    /// Delisting an item that is not listed.
    const ENotListed: u64 = 12;

    /// An object which allows selling collectibles within "kiosk" ecosystem.
    /// By default gives the functionality to list an item openly - for anyone
    /// to purchase providing the guarantees for creators that every transfer
    /// needs to be approved via the `TransferPolicy`.
    struct Kiosk has key, store {
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
    /// from the `Kiosk` as well as to `list` them and `list_with_purchase_cap`.
    struct KioskOwnerCap has key, store {
        id: UID,
        for: ID
    }

    /// A capability which locks an item and gives a permission to
    /// purchase it from a `Kiosk` for any price no less than `min_price`.
    ///
    /// Allows exclusive listing: only bearer of the `PurchaseCap` can
    /// purchase the asset. However, the capablity should be used
    /// carefully as losing it would lock the asset in the `Kiosk`.
    ///
    /// The main application for the `PurchaseCap` is building extensions
    /// on top of the `Kiosk`.
    struct PurchaseCap<phantom T: key + store> has key, store {
        id: UID,
        /// ID of the `Kiosk` the cap belongs to.
        kiosk_id: ID,
        /// ID of the listed item.
        item_id: ID,
        /// Minimum price for which the item can be purchased.
        min_price: u64
    }

    // === Utilities ===

    /// Hot potato to ensure an item was returned after being taken using
    /// the `borrow_val` call.
    struct Borrow { kiosk_id: ID, item_id: ID }

    // === Dynamic Field keys ===

    /// Dynamic field key for an offer placed into the kiosk.
    struct Offer has store, copy, drop { id: ID }
    /// Dynamic field key for an item placed into the kiosk.
    struct Item has store, copy, drop { id: ID }
    /// Dynamic field key for an got into the kiosk.
    struct Got has store, copy, drop { id: ID }

    /// Dynamic field key for an active offer to purchase the T. If an
    /// item is listed without a `PurchaseCap`, exclusive is set to `false`.
    struct Listing has store, copy, drop { id: ID, is_exclusive: bool }
    //makeoffer
    struct Offering has store, copy, drop { id: ID, is_exclusive: bool }

    /// Dynamic field key which marks that an item is locked in the `Kiosk` and
    /// can't be `take`n. The item then can only be listed / sold via the PurchaseCap.
    /// Lock is released on `purchase`.
    struct Lock has store, copy, drop { id: ID }

    // === Events ===

    /// Emitted when an item was listed by the safe owner. Can be used
    /// to track available offers anywhere on the network; the event is
    /// type-indexed which allows for searching for offers of a specific `T`
    struct ItemListed<phantom T: key + store> has copy, drop {
        kiosk: ID,
        id: ID,
        price: u64
    }
    //makeoffer
    struct OfferMaked<phantom T: key + store> has copy, drop {
        kiosk: ID,
        id: ID,
        item_id: ID
    }

    /// Emitted when an item was purchased from the `Kiosk`. Can be used
    /// to track finalized sales across the network. The event is emitted
    /// in both cases: when an item is purchased via the `PurchaseCap` or
    /// when it's purchased directly (via `list` + `purchase`).
    ///
    /// The `price` is also emitted and might differ from the `price` set
    /// in the `ItemListed` event. This is because the `PurchaseCap` only
    /// sets a minimum price for the item, and the actual price is defined
    /// by the trading module / extension.
    struct ItemPurchased<phantom T: key + store> has copy, drop {
        kiosk: ID,
        id: ID,
        price: u64
    }
    //makeoffer
    struct OfferAccepted<phantom T: key + store> has copy, drop {
        kiosk: ID,
        id: ID,
        amount: u64
    }

    /// Emitted when an item was delisted by the safe owner. Can be used
    /// to close tracked offers.
    struct ItemDelisted<phantom T: key + store> has copy, drop {
        kiosk: ID,
        id: ID
    }
    //makeoffer
    struct OfferDemade<phantom T: key + store> has copy, drop {
        kiosk: ID,
        id: ID
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
    public fun new(ctx: &mut TxContext): (Kiosk, KioskOwnerCap) {
        let kiosk = Kiosk {
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
    // public fun close_and_withdraw(
    //     self: Kiosk, cap: KioskOwnerCap, ctx: &mut TxContext
    // ): Coin<SUI> {
    //     let Kiosk { id, profits, offer_pool, owner: _, item_count, allow_extensions: _ } = self;
    //     let KioskOwnerCap { id: cap_id, for } = cap;

    //     assert!(object::uid_to_inner(&id) == for, ENotOwner);
    //     assert!(item_count == 0, ENotEmpty);

    //     object::delete(cap_id);
    //     object::delete(id);
    //     coin::from_balance(profits, ctx)
    // }

    /// Change the `owner` field to the transaction sender.
    /// The change is purely cosmetical and does not affect any of the
    /// basic kiosk functions unless some logic for this is implemented
    /// in a third party module.
    public fun set_owner(
        self: &mut Kiosk, cap: &KioskOwnerCap, ctx: &TxContext
    ) {
        assert!(has_access(self, cap), ENotOwner);
        self.owner = sender(ctx);
    }

    /// Update the `owner` field with a custom address. Can be used for
    /// implementing a custom logic that relies on the `Kiosk` owner.
    public fun set_owner_custom(
        self: &mut Kiosk, cap: &KioskOwnerCap, owner: address
    ) {
        assert!(has_access(self, cap), ENotOwner);
        self.owner = owner
    }

    // === Place, Lock and Take from the Kiosk ===

    /// Place any object into a Kiosk.
    /// Performs an authorization check to make sure only owner can do that.
    // public fun place(
    //     self: &mut Kiosk, cap: &KioskOwnerCap, offer: Coin<SUI>
    // ) {
    //     assert!(has_access(self, cap), ENotOwner);
    //     place_internal(self, offer)
    // }

    /// Place an item to the `Kiosk` and issue a `Lock` for it. Once placed this
    /// way, an item can only be listed either with a `list` function or with a
    /// `list_with_purchase_cap`.
    ///
    /// Requires policy for `T` to make sure that there's an issued `TransferPolicy`
    /// and the item can be sold, otherwise the asset might be locked forever.
    public fun lock<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, _policy: &TransferPolicy<T>, item: Coin<SUI>
    ) {
        assert!(has_access(self, cap), ENotOwner);
        lock_internal(self, item)
    }

    /// Take any object from the Kiosk.
    /// Performs an authorization check to make sure only owner can do that.
    public fun take<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, id: ID, ctx: &mut TxContext
    ){
        assert!(has_access(self, cap), ENotOwner);
        // assert!(has_got(self, id), EItemNotFound);

        // self.item_count = self.item_count - 1;
        let item = dof::remove<Got, T>(&mut self.id, Got { id });
        sui::transfer::public_transfer(item, sender(ctx))
    }

    // === Trading functionality: List and Purchase ===

    /// List the item by setting a price and making it available for purchase.
    /// Performs an authorization check to make sure only owner can sell.
    //makeoffer
    //price => item_id
    //turn off public? just leave place_and_list?
    public fun offer<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, id: ID, item_id: ID
    ) {
        assert!(has_access(self, cap), ENotOwner);
        assert!(has_offer(self, item_id), EItemNotFound);
        // assert!(!is_offered_exclusively(self, id), EListedExclusively);

        df::add(&mut self.id, Offering { id: item_id, is_exclusive: false }, item_id);
        event::emit(OfferMaked<T> { kiosk: object::id(self), id, item_id })
    }

    /// Calls `place` and `list` together - simplifies the flow.
    //makeoffer
    //item => offer
    //price => item_id
    public fun place_and_offer<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, item_id: ID, offer: Coin<SUI>
    ) {
        let id = object::id(&offer);
        assert!(has_access(self, cap), ENotOwner);
        // place_internal(self, offer)
        // place(self, cap, offer);
        self.item_count = self.item_count + 1;
        let amount = coin::value(&offer);
        coin::put(&mut self.offer_pool, offer);
        df::add(&mut self.id, Offer { id: item_id }, amount);
        offer<T>(self, cap, id, item_id)
    }

    /// Remove an existing listing from the `Kiosk` and keep the item in the
    /// user Kiosk. Can only be performed by the owner of the `Kiosk`.
    // makeoffer
    public fun deoffer<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, item_id: ID
    ) {
        assert!(has_access(self, cap), ENotOwner);
        assert!(has_offer(self, item_id), EItemNotFound);
        assert!(!is_offered_exclusively(self, item_id), EListedExclusively);
        assert!(is_offered(self, item_id), ENotListed);

        df::remove<Offering, u64>(&mut self.id, Offering { id:item_id, is_exclusive: false });
        event::emit(OfferDemade<T> { kiosk: object::id(self), id:item_id })
    }

    /// Make a trade: pay the owner of the item and request a Transfer to the `target`
    /// kiosk (to prevent item being taken by the approving party).
    ///
    /// Received `TransferRequest` needs to be handled by the publisher of the T,
    /// if they have a method implemented that allows a trade, it is possible to
    /// request their approval (by calling some function) so that the trade can be
    /// finalized.
    //makeoffer
    //purchase => acceptoffer
    //payment => item
    public fun acceptoffer<T: key + store>(
        self: &mut Kiosk, id: ID, item: T, ctx: &mut TxContext
    ) {
        let item_id = object::id(&item);
        df::remove<Offering, ID>(&mut self.id, Offering { id:item_id, is_exclusive: false });
        self.item_count = self.item_count - 1;
        assert!(item_id == object::id(&item), EIncorrectAmount);
        df::remove_if_exists<Lock, bool>(&mut self.id, Lock { id: id });
        let amount = df::remove<Offer, u64>(&mut self.id, Offer { id: item_id });

        event::emit(OfferAccepted<T> { kiosk: object::id(self), id, amount });
        dof::add(&mut self.id, Got { id: item_id }, item);
        let offer = coin::take(&mut self.offer_pool, amount, ctx);
        sui::transfer::public_transfer(offer, sender(ctx))

        // (inner, transfer_policy::new_request(id, price, object::id(self)))
    }

    // public fun check<T: key + store>(
    //     self: &mut Kiosk, id: ID, item: T, ctx: &mut TxContext
    // ) {
    //     let item_id = object::id(&item);
    //     // df::remove<Offering, ID>(&mut self.id, Offering { id:item_id, is_exclusive: false });
    //     // self.item_count = self.item_count - 1;
    //     // assert!(item_id == object::id(&item), EIncorrectAmount);
    //     // df::remove_if_exists<Lock, bool>(&mut self.id, Lock { id: item_id });
    //     let amount = df::remove<Offer, u64>(&mut self.id, Offer { id: item_id });
        


    //     event::emit(OfferAccepted<T> { kiosk: object::id(self), id:item_id, amount });
    //     dof::add(&mut self.id, Got { id: item_id }, item);
    //     //this line!!
    //     let money = coin::take(&mut self.offer_pool, amount, ctx);
    //     sui::transfer::public_transfer(money, sender(ctx));
    //     //Error: Transaction failed with the following error. Dry run failed, could not automatically determine a budget: UnusedValueWithoutDrop { result_idx: 0, secondary_idx: 0 }
    //     // (inner, transfer_policy::new_request(id, price, object::id(self)))
    // }

    // === Trading Functionality: Exclusive listing with `PurchaseCap` ===

    /// Creates a `PurchaseCap` which gives the right to purchase an item
    /// for any price equal or higher than the `min_price`.
    public fun list_with_purchase_cap<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, id: ID, min_price: u64, ctx: &mut TxContext
    ): PurchaseCap<T> {
        assert!(has_access(self, cap), ENotOwner);
        assert!(has_item_with_type<T>(self, id), EItemNotFound);
        assert!(!is_listed(self, id), EAlreadyListed);

        df::add(&mut self.id, Listing { id, is_exclusive: true }, min_price);

        PurchaseCap<T> {
            min_price,
            item_id: id,
            id: object::new(ctx),
            kiosk_id: object::id(self),
        }
    }

    /// Unpack the `PurchaseCap` and call `purchase`. Sets the payment amount
    /// as the price for the listing making sure it's no less than `min_amount`.
    public fun purchase_with_cap<T: key + store>(
        self: &mut Kiosk, purchase_cap: PurchaseCap<T>, payment: Coin<SUI>
    ): (T, TransferRequest<T>) {
        let PurchaseCap { id, item_id, kiosk_id, min_price } = purchase_cap;
        object::delete(id);

        let id = item_id;
        let paid = coin::value(&payment);
        assert!(paid >= min_price, EIncorrectAmount);
        assert!(object::id(self) == kiosk_id, EWrongKiosk);

        df::remove<Listing, u64>(&mut self.id, Listing { id, is_exclusive: true });

        coin::put(&mut self.profits, payment);
        self.item_count = self.item_count - 1;
        df::remove_if_exists<Lock, bool>(&mut self.id, Lock { id });
        let item = dof::remove<Item, T>(&mut self.id, Item { id });

        (item, transfer_policy::new_request(id, paid, object::id(self)))
    }

    /// Return the `PurchaseCap` without making a purchase; remove an active offer and
    /// allow the item for taking. Can only be returned to its `Kiosk`, aborts otherwise.
    public fun return_purchase_cap<T: key + store>(
        self: &mut Kiosk, purchase_cap: PurchaseCap<T>
    ) {
        let PurchaseCap { id, item_id, kiosk_id, min_price: _ } = purchase_cap;

        assert!(object::id(self) == kiosk_id, EWrongKiosk);
        df::remove<Listing, u64>(&mut self.id, Listing { id: item_id, is_exclusive: true });
        object::delete(id)
    }

    /// Withdraw profits from the Kiosk.
    public fun withdraw(
        self: &mut Kiosk, cap: &KioskOwnerCap, amount: Option<u64>, ctx: &mut TxContext
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

    // === Internal Core ===

    /// Internal: "lock" an item disabling the `take` action.
    public(friend) fun lock_internal(self: &mut Kiosk, item: Coin<SUI>) {
        df::add(&mut self.id, Lock { id: object::id(&item) }, true);
        place_internal(self, item)
    }

    /// Internal: "place" an item to the Kiosk and increment the item count.
    //makeoffer
    //item => offer
    public(friend) fun place_internal(self: &mut Kiosk, offer: Coin<SUI>) {
        self.item_count = self.item_count + 1;
        let id = object::id(&offer);
        let amount = coin::value(&offer);
        coin::put(&mut self.offer_pool, offer);
        df::add(&mut self.id, Offer { id: id }, amount)
    }

    /// Internal: get a mutable access to the UID.
    public(friend) fun uid_mut_internal(self: &mut Kiosk): &mut UID {
        &mut self.id
    }

    // === Kiosk fields access ===

    /// Check whether the `item` is present in the `Kiosk`.
    public fun has_item(self: &Kiosk, id: ID): bool {
        dof::exists_(&self.id, Item { id })
    }

    /// Check whether the `item` is present in the `Kiosk` and has type T.
    public fun has_item_with_type<T: key + store>(self: &Kiosk, id: ID): bool {
        dof::exists_with_type<Item, T>(&self.id, Item { id })
    }

    //makeoffer
    public fun has_offer(self: &Kiosk, id: ID): bool {
        df::exists_(&self.id, Offer { id })
    }

    //makeoffer
    public fun has_got(self: &Kiosk, id: ID): bool {
        df::exists_(&self.id, Got { id })
    }

    /// Check whether an item with the `id` is locked in the `Kiosk`. Meaning
    /// that the only two actions that can be performed on it are `list` and
    /// `list_with_purchase_cap`, it cannot be `take`n out of the `Kiosk`.
    public fun is_locked(self: &Kiosk, id: ID): bool {
        df::exists_(&self.id, Lock { id })
    }

    /// Check whether an `item` is listed (exclusively or non exclusively).
    public fun is_listed(self: &Kiosk, id: ID): bool {
        df::exists_(&self.id, Listing { id, is_exclusive: false })
        || is_listed_exclusively(self, id)
    }

    /// Check whether an `item` is listed (exclusively or non exclusively).
    //makeoffer
    public fun is_offered(self: &Kiosk, id: ID): bool {
        df::exists_(&self.id, Offering { id, is_exclusive: false })
        || is_offered_exclusively(self, id)
    }
    public fun is_offered_exclusively(self: &Kiosk, id: ID): bool {
        df::exists_(&self.id, Offering { id, is_exclusive: true })
    }


    /// Check whether there's a `PurchaseCap` issued for an item.
    public fun is_listed_exclusively(self: &Kiosk, id: ID): bool {
        df::exists_(&self.id, Listing { id, is_exclusive: true })
    }

    /// Check whether the `KioskOwnerCap` matches the `Kiosk`.
    public fun has_access(self: &mut Kiosk, cap: &KioskOwnerCap): bool {
        object::id(self) == cap.for
    }

    /// Access the `UID` using the `KioskOwnerCap`.
    public fun uid_mut_as_owner(
        self: &mut Kiosk, cap: &KioskOwnerCap
    ): &mut UID {
        assert!(has_access(self, cap), ENotOwner);
        &mut self.id
    }

    /// [DEPRECATED]
    /// Allow or disallow `uid` and `uid_mut` access via the `allow_extensions`
    /// setting.
    public fun set_allow_extensions(
        self: &mut Kiosk, cap: &KioskOwnerCap, allow_extensions: bool
    ) {
        assert!(has_access(self, cap), ENotOwner);
        self.allow_extensions = allow_extensions;
    }

    /// Get the immutable `UID` for dynamic field access.
    /// Always enabled.
    ///
    /// Given the &UID can be used for reading keys and authorization,
    /// its access
    public fun uid(self: &Kiosk): &UID {
        &self.id
    }

    /// Get the mutable `UID` for dynamic field access and extensions.
    /// Aborts if `allow_extensions` set to `false`.
    public fun uid_mut(self: &mut Kiosk): &mut UID {
        assert!(self.allow_extensions, EUidAccessNotAllowed);
        &mut self.id
    }

    /// Get the owner of the Kiosk.
    public fun owner(self: &Kiosk): address {
        self.owner
    }

    /// Get the number of items stored in a Kiosk.
    public fun item_count(self: &Kiosk): u32 {
        self.item_count
    }

    /// Get the amount of profits collected by selling items.
    public fun profits_amount(self: &Kiosk): u64 {
        balance::value(&self.profits)
    }

    /// Get mutable access to `profits` - owner only action.
    public fun profits_mut(self: &mut Kiosk, cap: &KioskOwnerCap): &mut Balance<SUI> {
        assert!(has_access(self, cap), ENotOwner);
        &mut self.profits
    }

    // === Item borrowing ===

    /// Immutably borrow an item from the `Kiosk`. Any item can be `borrow`ed
    /// at any time.
    public fun borrow<T: key + store>(
        self: &Kiosk, cap: &KioskOwnerCap, id: ID
    ): &T {
        assert!(object::id(self) == cap.for, ENotOwner);
        assert!(has_item(self, id), EItemNotFound);

        dof::borrow(&self.id, Item { id })
    }

    /// Mutably borrow an item from the `Kiosk`.
    /// Item can be `borrow_mut`ed only if it's not `is_listed`.
    public fun borrow_mut<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, id: ID
    ): &mut T {
        assert!(has_access(self, cap), ENotOwner);
        assert!(has_item(self, id), EItemNotFound);
        assert!(!is_listed(self, id), EItemIsListed);

        dof::borrow_mut(&mut self.id, Item { id })
    }

    /// Take the item from the `Kiosk` with a guarantee that it will be returned.
    /// Item can be `borrow_val`-ed only if it's not `is_listed`.
    public fun borrow_val<T: key + store>(
        self: &mut Kiosk, cap: &KioskOwnerCap, id: ID
    ): (T, Borrow) {
        assert!(has_access(self, cap), ENotOwner);
        assert!(has_item(self, id), EItemNotFound);
        assert!(!is_listed(self, id), EItemIsListed);

        (
            dof::remove(&mut self.id, Item { id }),
            Borrow { kiosk_id: object::id(self), item_id: id }
        )
    }

    /// Return the borrowed item to the `Kiosk`. This method cannot be avoided
    /// if `borrow_val` is used.
    public fun return_val<T: key + store>(
        self: &mut Kiosk, item: T, borrow: Borrow
    ) {
        let Borrow { kiosk_id, item_id } = borrow;

        assert!(object::id(self) == kiosk_id, EWrongKiosk);
        assert!(object::id(&item) == item_id, EItemMismatch);

        dof::add(&mut self.id, Item { id: item_id }, item);
    }

    // === KioskOwnerCap fields access ===

    /// Get the `for` field of the `KioskOwnerCap`.
    public fun kiosk_owner_cap_for(cap: &KioskOwnerCap): ID {
        cap.for
    }

    // === PurchaseCap fields access ===

    /// Get the `kiosk_id` from the `PurchaseCap`.
    public fun purchase_cap_kiosk<T: key + store>(self: &PurchaseCap<T>): ID {
        self.kiosk_id
    }

    /// Get the `Item_id` from the `PurchaseCap`.
    public fun purchase_cap_item<T: key + store>(self: &PurchaseCap<T>): ID {
        self.item_id
    }

    /// Get the `min_price` from the `PurchaseCap`.
    public fun purchase_cap_min_price<T: key + store>(self: &PurchaseCap<T>): u64 {
        self.min_price
    }
}