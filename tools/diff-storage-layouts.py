#!/usr/bin/env python3
"""
Storage-layout upgrade-compatibility check for the ColFee proxies.

Usage:
    diff-storage-layouts.py <saved-deployment-artifact.json> <candidate-build-artifact.json>

Both inputs must have a top-level `storageLayout` key with `.storage` (an
array of entries) and `.types` (a lookup table from internal type name to
type definition with `numberOfBytes`, `members`, `key`, `value`, etc.).

What this enforces -- the FULL upgrade-compatibility contract:

  Rule 1: VARIABLE PRESERVATION.
    Every non-__gap variable in the saved layout must exist in the
    candidate with the same (label, slot, offset, type), where "type"
    means the FULLY EXPANDED canonical type definition (internal
    struct/enum IDs stripped, but member lists / array lengths /
    mapping key+value / enum variant order are all part of the
    canonical form). This catches:
      - struct member reorder
      - struct member type widening (uint16 -> uint32)
      - enum variant reorder or insertion
      - mapping key/value type changes
      - array length changes

  Rule 2: __gap ACCOUNTING WITH SLOT SPANS.
    Each saved __gap entry (start, length L) defines an OZ namespace
    boundary at slot (start + L). The candidate must have either:
      (a) A __gap entry ending at the same boundary with length
          L_cand <= L (gaps can only shrink, never grow).
      (b) No __gap entry at that boundary -- the gap was fully
          consumed.
    The reclaimed slots [start, start + (L - L_cand)) must be filled
    by new (non-__gap) variables that collectively consume EXACTLY
    that many slots. Slot consumption is computed via
    types[entry.type].numberOfBytes / 32 (ceiling), so multi-slot
    entries (fixed arrays, multi-word structs) are counted correctly.

  Rule 3: NO OUT-OF-NAMESPACE SPILLAGE.
    Every new (non-__gap) entry's FULL slot range [slot, slot + span)
    must fit inside SOME saved __gap range. A multi-slot entry that
    starts inside a gap but spills past its boundary corrupts the
    next OZ namespace.

Exit codes:
    0  layout is upgrade-safe.
    1  upgrade is unsafe (specific violation explained on stderr).
    2  input error (missing/malformed storageLayout).
"""

from __future__ import annotations

import json
import re
import sys
from typing import Any


_STRUCT_ID_RE = re.compile(r"t_struct\(([^)]+)\)\d+_storage")
_ENUM_ID_RE = re.compile(r"t_enum\(([^)]+)\)\d+")


def normalize_type_name(name: str) -> str:
    """
    Strip Solidity's compilation-internal struct/enum IDs. The trailing
    number in `t_struct(RatePolicy)45131_storage` is a per-compilation
    ID, NOT part of the struct's semantic identity. Array lengths
    (`t_array(t_uint256)50_storage`) are NOT stripped -- they are
    semantically meaningful.
    """
    name = _STRUCT_ID_RE.sub(r"t_struct(\1)_storage", name)
    name = _ENUM_ID_RE.sub(r"t_enum(\1)", name)
    return name


def _walk(obj: Any, fn) -> Any:
    """Apply `fn` to every string in a nested dict/list."""
    if isinstance(obj, str):
        return fn(obj)
    if isinstance(obj, dict):
        return {k: _walk(v, fn) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_walk(x, fn) for x in obj]
    return obj


def normalize_types_map(types: dict) -> dict:
    """Rewrite keys and recursively rewrite all string values."""
    out: dict[str, Any] = {}
    for raw_key, raw_def in types.items():
        out[normalize_type_name(raw_key)] = _walk(raw_def, normalize_type_name)
    return out


def slot_span(type_name: str, types_map: dict) -> int:
    """
    Number of storage slots a type occupies. Computed from the type's
    `numberOfBytes` field divided by 32, rounded up.
    """
    type_def = types_map.get(type_name)
    if type_def is None:
        # Primitive type with no entry in the types map -- defaults to 1 slot.
        return 1
    nbytes_str = type_def.get("numberOfBytes", "32")
    try:
        nbytes = int(nbytes_str)
    except (TypeError, ValueError):
        raise SystemExit(
            f"error: malformed numberOfBytes={nbytes_str!r} for type {type_name!r}"
        )
    return (nbytes + 31) // 32


def parse_gap_length(type_name: str) -> int | None:
    """Extract N from `t_array(t_uint256)N_storage`."""
    m = re.match(r"t_array\(t_uint256\)(\d+)_storage", type_name)
    return int(m.group(1)) if m else None


def expand_type(type_name: str, types_map: dict, seen: set | None = None) -> dict:
    """
    Fully expanded type signature: recursively follows nested type
    references via the `.types` map so that struct/enum members, mapping
    key+value, and array base types are all rendered structurally. The
    result deep-equals iff two types are upgrade-compatible.

    We deliberately DROP the human-readable `.label` field from each
    type definition because it embeds the contract scope (e.g.
    "struct ExitFeeController.RatePolicy" -- the prefix changes if the
    contract is renamed or moved between source files but doesn't
    affect the ABI / storage encoding). We also drop `astId` for the
    same reason (compilation-internal).

    Returns a dict tree of just the bits that matter on-wire: encoding,
    numberOfBytes, member ORDER + names + slot/offset + recursive types,
    enum variant ORDER + names, mapping key+value, array base+length.
    """
    if seen is None:
        seen = set()
    if type_name in seen:
        # Cycle. Solidity storage types shouldn't be self-referential
        # but be defensive: return a marker rather than recursing forever.
        return {"_cycle": type_name}
    seen = seen | {type_name}

    type_def = types_map.get(type_name)
    if type_def is None:
        # Primitive with no entry in the types map (uint, bool, address, ...).
        return {"primitive": type_name}

    out: dict[str, Any] = {
        "encoding": type_def.get("encoding"),
        "numberOfBytes": type_def.get("numberOfBytes"),
    }
    # `members` appears for both structs (with slot/offset/type per member)
    # and enums (just label per member, no slot/offset). Preserve member
    # ORDER -- that's what Solidity ABI-encodes by.
    if "members" in type_def and type_def["members"] is not None:
        members = type_def["members"]
        if members and isinstance(members[0], dict):
            out["members"] = [
                {
                    "label": m.get("label"),
                    "slot": m.get("slot"),
                    "offset": m.get("offset"),
                    "type_expansion": expand_type(m["type"], types_map, seen)
                    if "type" in m
                    else None,
                }
                for m in members
            ]
        else:
            # Enum variants (some Solidity outputs render members as a
            # flat string list).
            out["members"] = list(members)
    if "key" in type_def:
        out["key_expansion"] = expand_type(type_def["key"], types_map, seen)
    if "value" in type_def:
        out["value_expansion"] = expand_type(type_def["value"], types_map, seen)
    if "base" in type_def:
        out["base_expansion"] = expand_type(type_def["base"], types_map, seen)
    return out


def canonical_entry(entry: dict, types_map: dict) -> dict:
    """
    The canonical fingerprint for a storage entry: label + slot + offset +
    fully expanded type signature (no contract-scope noise, no internal
    compiler IDs).
    """
    type_name = normalize_type_name(entry["type"])
    return {
        "label": entry["label"],
        "slot": entry["slot"],
        "offset": entry["offset"],
        "type": type_name,
        "type_expansion": expand_type(type_name, types_map),
    }


def _load_layout(path: str) -> tuple[list, dict]:
    """Return (storage_list, normalized_types_map). Raises SystemExit on input errors."""
    try:
        with open(path) as f:
            artifact = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        raise SystemExit(f"error: failed to read {path}: {e}")
    layout = artifact.get("storageLayout")
    if not isinstance(layout, dict):
        raise SystemExit(f"error: {path} has no 'storageLayout' object")
    storage = layout.get("storage")
    if not isinstance(storage, list):
        raise SystemExit(f"error: {path}.storageLayout.storage is not an array")
    types = layout.get("types") or {}
    if not isinstance(types, dict):
        raise SystemExit(f"error: {path}.storageLayout.types is not an object")
    return storage, normalize_types_map(types)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: diff-storage-layouts.py <saved-deployment-artifact.json> "
            "<candidate-build-artifact.json>",
            file=sys.stderr,
        )
        return 2

    saved_storage, saved_types = _load_layout(argv[1])
    cand_storage, cand_types = _load_layout(argv[2])

    saved_labels = {e["label"] for e in saved_storage if e["label"] != "__gap"}

    # ─── Rule 1: VARIABLE PRESERVATION (with full type-def equivalence) ─────
    cand_by_label = {e["label"]: e for e in cand_storage if e["label"] != "__gap"}
    for s_entry in saved_storage:
        if s_entry["label"] == "__gap":
            continue
        c_entry = cand_by_label.get(s_entry["label"])
        if c_entry is None:
            print(
                f"error: variable removed from candidate layout: {s_entry['label']!r}",
                file=sys.stderr,
            )
            return 1
        s_fp = canonical_entry(s_entry, saved_types)
        c_fp = canonical_entry(c_entry, cand_types)
        if s_fp != c_fp:
            print(
                f"error: variable {s_entry['label']!r} shifted or changed shape "
                "(label, slot, offset, type, or struct/enum members differ).",
                file=sys.stderr,
            )
            print("  saved:     " + json.dumps(s_fp, sort_keys=True), file=sys.stderr)
            print("  candidate: " + json.dumps(c_fp, sort_keys=True), file=sys.stderr)
            return 1

    # ─── Rule 2: __gap ACCOUNTING (slot-spans, not entry counts) ────────────
    saved_gaps = [e for e in saved_storage if e["label"] == "__gap"]
    cand_gaps = [e for e in cand_storage if e["label"] == "__gap"]

    for sg in saved_gaps:
        sg_start = int(sg["slot"])
        sg_len = parse_gap_length(sg["type"])
        if sg_len is None:
            print(
                f"error: could not parse saved __gap length from type "
                f"{sg['type']!r} at slot {sg['slot']}",
                file=sys.stderr,
            )
            return 1
        namespace_end = sg_start + sg_len  # exclusive

        # Find candidate gap ending at the same namespace boundary.
        matching_cg = None
        for cg in cand_gaps:
            cg_start = int(cg["slot"])
            cg_len = parse_gap_length(cg["type"])
            if cg_len is None:
                continue
            if cg_start + cg_len == namespace_end:
                matching_cg = (cg_start, cg_len, cg["type"])
                break

        if matching_cg is None:
            cg_start, cg_len = namespace_end, 0  # fully consumed
            cg_type_label = "(absent)"
        else:
            cg_start, cg_len, cg_type_label = matching_cg
            if cg_len > sg_len:
                print(
                    f"error: __gap GREW at namespace_end={namespace_end} "
                    f"(saved length {sg_len} -> candidate length {cg_len}). "
                    "A gap cannot grow; that means a variable was removed.",
                    file=sys.stderr,
                )
                return 1

        reclaimed_start = sg_start
        reclaimed_end = cg_start  # exclusive
        reclaimed_slots = reclaimed_end - reclaimed_start  # == sg_len - cg_len

        if reclaimed_slots == 0:
            print(f"    ok: namespace_end={namespace_end} __gap unchanged (length {sg_len})")
            continue

        # Count the UNION of slot ranges occupied by new non-gap entries
        # whose start sits inside the reclaimed range. Solidity packs
        # multiple <= 32-byte entries into a single slot (e.g. two uint128s
        # at the same slot, different offsets) -- summing per-entry spans
        # would overcount in that case. Multi-slot entries that start
        # inside but spill past the namespace boundary are caught by
        # Rule 3 below; this loop only counts WITHIN the reclaimed range.
        new_here = [
            e
            for e in cand_storage
            if e["label"] != "__gap"
            and e["label"] not in saved_labels
            and reclaimed_start <= int(e["slot"]) < reclaimed_end
        ]
        occupied_slots: set[int] = set()
        for e in new_here:
            s = int(e["slot"])
            span = slot_span(normalize_type_name(e["type"]), cand_types)
            for slot_idx in range(s, s + span):
                # Only count slots WITHIN the reclaimed range. A multi-slot
                # entry spilling past `reclaimed_end` is allowed to bleed
                # outside HERE -- Rule 3 will independently verify it sits
                # entirely inside SOME saved __gap range (which may be a
                # different one than this iteration's gap).
                if reclaimed_start <= slot_idx < reclaimed_end:
                    occupied_slots.add(slot_idx)
        consumed_total = len(occupied_slots)

        if consumed_total != reclaimed_slots:
            print(
                f"error: __gap accounting at namespace_end={namespace_end} is off.",
                file=sys.stderr,
            )
            print(
                f"  saved gap:        slot {sg_start}, length {sg_len}",
                file=sys.stderr,
            )
            print(
                f"  candidate gap:    {cg_type_label} at slot {cg_start}, length {cg_len}",
                file=sys.stderr,
            )
            print(
                f"  reclaimed range:  [{reclaimed_start}, {reclaimed_end}) = {reclaimed_slots} slot(s)",
                file=sys.stderr,
            )
            print(
                f"  new vars consume: {consumed_total} slot(s)",
                file=sys.stderr,
            )
            for e in new_here:
                span = slot_span(normalize_type_name(e["type"]), cand_types)
                print(
                    f"    - {e['label']} at slot {e['slot']} type {e['type']} (span={span})",
                    file=sys.stderr,
                )
            return 1

        print(
            f"    ok: namespace_end={namespace_end} "
            f"saved_gap={sg_len} candidate_gap={cg_len} reclaimed={reclaimed_slots}"
        )

    # ─── Rule 3: NO OUT-OF-NAMESPACE SPILLAGE ───────────────────────────────
    saved_gap_ranges = []
    for sg in saved_gaps:
        sg_start = int(sg["slot"])
        sg_len = parse_gap_length(sg["type"])
        if sg_len is None:
            continue
        saved_gap_ranges.append((sg_start, sg_start + sg_len))  # [lo, hi) exclusive

    out_of_range = []
    for ce in cand_storage:
        if ce["label"] == "__gap" or ce["label"] in saved_labels:
            continue
        e_start = int(ce["slot"])
        e_span = slot_span(normalize_type_name(ce["type"]), cand_types)
        e_end = e_start + e_span
        if not any(lo <= e_start and e_end <= hi for (lo, hi) in saved_gap_ranges):
            out_of_range.append((ce, e_start, e_span))

    if out_of_range:
        print(
            f"error: {len(out_of_range)} new variable(s) sit at slot(s) outside any "
            "saved __gap range (or spill past a saved namespace boundary):",
            file=sys.stderr,
        )
        for ce, e_start, e_span in out_of_range:
            print(
                f"    - {ce['label']} at slot {e_start} (span {e_span}, type {ce['type']})",
                file=sys.stderr,
            )
        print(
            "    A safe upgrade may only add storage inside slots reclaimed from a "
            "saved __gap, without spilling past the gap's namespace boundary.",
            file=sys.stderr,
        )
        return 1

    print("Storage layout: upgrade-safe.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
