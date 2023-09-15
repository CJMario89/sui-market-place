##### Sui Marketplace

# Make offer

The concept of MakeofferKiosk is derived from **Sui::Kiosk** . Kiosk developed by Mysten currently only provide the function with listing and purchasing without make offer and accept offer. This package exchange the position of item and coin spot to change the functionality of list and purchase function,
There are some risks to make offer by this unofficial package. ex: If a collection have a lock rule, the items of the collection can not be trade on MakeofferKiosk, cause items are locked by Sui::Kiosk (Cause items can only be listed on official Kiosk if they are locked which defined by Sui).

## Different from original **kiosk**

### Balance 'offer_pool' in MakeofferKiosk object

To collect the offers coins of the owner of the kiosk.

### place_and_offer function

The function make offer to an item by putting the offered coins to their owned kiosk and new a dynamic field 'Offer' to record the target objectID of the item. Then, waiting for someone has the item to fill the offer.

### acceptoffer function

If someone has the objectID of an item that matches one in offers, can accept the offer by putting the item into the kiosk and create a dynamic field 'Got' (that records the items owner got by making offer) and receives coins from 'offer_pool' and free the dynamic field 'Offer'.

### deoffer function

Retrieve the offer back from 'offer_pool' by specifying the objectID of an item and free the dynamic field 'Offer'.

### take function

Free the dynamic field 'Got' and return the item which got by making offer
