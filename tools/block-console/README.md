# Block Console

Reads the delay queue from chain, lets an operator pick the exact requests to act
on, and prints the transaction for the Admin multisig to sign. It never signs and
never broadcasts: both block levers are `onlyAdminOrOwner`, and this page holds no
key.

## Run it

    python3 -m http.server -d tools/block-console 8080

then open <http://localhost:8080>. Serve it rather than opening the file directly —
a `file://` page sends a null origin and the RPC will refuse it.

Enter an RPC endpoint and the `ExitDelayQueue` proxy address, then load.

## What it does

- **Lists requests from chain.** With no address filter it walks every recorded id;
  with one or more addresses it uses the queue's own per-party index, so filtering
  stays exact rather than guessing from a scan.
- **Selection replaces typing.** Request ids are ticked from the list, never entered
  by hand. Only `Queued` rows can be selected, because the on-chain batch is atomic
  and one terminal id would revert the whole call.
- **Shows who gets blocked** before you generate: the originator and owner always,
  and each request's receiver only when you ask for it.
- **Generates the calldata** for `freezeFromRequest` / `blacklistFromRequest`, with
  the destination and value to submit alongside it.
- **Carries the submission instructions** in its own tab, so the operator does not
  have to hold a second document open during an incident.

Reason hashes are optional and taken as a `bytes32`. Generate one with
`cast keccak "<your reason>"` — the page deliberately ships no hashing code of its
own rather than a hand-rolled keccak.

## Where this fits

The operator surface for non-technical use is the **Perimeter page on the admin
panel** (`Sovryn-Admin-Panel`, route `/perimeter`): it is a deployed URL, connects
a wallet, and submits to the multisig directly, so nothing has to be served or
copied by hand.

This page is the local fallback for when the panel is unavailable or the operator
wants to point at a different RPC or a queue that is not the registered one. It
generates the same calldata; it just hands it over instead of submitting it.

## Relationship to `script/07_BlockExits.s.sol`

The Foundry script remains the no-browser path and covers the levers this page does
not: the global pause, the clears (`unfreeze` / `unblacklist`), the controller kill
switch, and the post-hoc `verify` mode. The two produce the same calldata for the
levers they share.
