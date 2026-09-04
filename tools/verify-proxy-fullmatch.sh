#!/usr/bin/env bash
# Attempt a FULL-match verification of an already-verified ERC1967Proxy.
#
# Blockscout matches a standard OpenZeppelin proxy from its own bytecode
# database, which yields a PARTIAL match: the runtime code matches but the
# metadata hash comes from someone else's compilation, not ours. This asks the
# explorer to re-verify against our exact build so the match becomes full.
#
# Read-only with respect to the chain: verification submits source, never a
# transaction. Safe to re-run; an "already verified" reply is not an error.
#
#   tools/verify-proxy-fullmatch.sh <proxyAddress> <implAddress> <initialOwner>
set -uo pipefail

PROXY=${1:?proxy address required}
IMPL=${2:?implementation address required}
OWNER=${3:?initial owner (the address baked into initialize) required}
SRC="lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy"
VERIFIER_URL=${BLOCKSCOUT_URL:-https://rootstock.blockscout.com/api}

INIT=$(cast calldata "initialize(address)" "$OWNER")
ARGS=$(cast abi-encode "constructor(address,bytes)" "$IMPL" "$INIT")

echo "proxy:  $PROXY"
echo "impl:   $IMPL"
echo "owner:  $OWNER"
echo "args:   ${ARGS:0:42}..."
echo

forge verify-contract "$PROXY" "$SRC" \
  --chain 30 \
  --verifier blockscout \
  --verifier-url "$VERIFIER_URL" \
  --constructor-args "$ARGS" \
  --watch
