#!/usr/bin/env python3
"""GF(256) Shamir shares used by the key ceremony and recovery scripts."""

import argparse
from pathlib import Path
import re
import secrets


def gf256_mul(a, b):
    # AES irreducible polynomial x^8 + x^4 + x^3 + x + 1.
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return p


def gf256_inv(a):
    if a == 0:
        raise ValueError("Cannot invert 0")
    result = a
    for _ in range(6):
        result = gf256_mul(result, result)
        result = gf256_mul(result, a)
    # The loop yields a^127; square once more to obtain a^254.
    return gf256_mul(result, result)


def make_shares(secret_bytes, t, n):
    """Split each byte independently using a random polynomial of degree t-1."""
    if not secret_bytes or not 2 <= t <= n <= 255:
        raise ValueError("A non-empty secret and 2 <= threshold <= shares <= 255 are required")
    all_shares = [bytearray() for _ in range(n)]
    for byte_val in secret_bytes:
        coeffs = [byte_val] + [secrets.randbelow(256) for _ in range(t - 1)]
        for i in range(n):
            x = i + 1
            y = 0
            for power, c in enumerate(coeffs):
                x_pow = 1
                for _ in range(power):
                    x_pow = gf256_mul(x_pow, x)
                y ^= gf256_mul(c, x_pow)
            all_shares[i].append(y)
    return all_shares


def lagrange_interpolate(shares_for_byte, t):
    """Reconstruct the secret byte using Lagrange interpolation at x=0."""
    secret = 0
    xs = [s[0] for s in shares_for_byte]
    ys = [s[1] for s in shares_for_byte]
    for i in range(t):
        num = ys[i]
        for j in range(t):
            if i == j:
                continue
            num = gf256_mul(num, xs[j])
            num = gf256_mul(num, gf256_inv(xs[i] ^ xs[j]))
        secret ^= num
    return secret


def parse_shares(shares, threshold):
    parsed = []
    for share in shares:
        if not re.fullmatch(r"[0-9]{1,3}-(?:[0-9a-fA-F]{2})+", share):
            raise ValueError("Malformed share")
        index, data = share.split('-', 1)
        parsed.append((int(index), bytes.fromhex(data)))
    if (not 2 <= threshold <= 255 or len(parsed) < threshold
            or any(not 1 <= x <= 255 for x, _ in parsed)
            or len({x for x, _ in parsed}) != len(parsed)
            or len({len(data) for _, data in parsed}) != 1):
        raise ValueError("Invalid indices, duplicate indices, or unequal share lengths")
    return parsed


def combine(shares, threshold):
    parsed = parse_shares(shares, threshold)
    return bytes(
        lagrange_interpolate([(x, data[pos]) for x, data in parsed[:threshold]], threshold)
        for pos in range(len(parsed[0][1]))
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    split = commands.add_parser("split")
    split.add_argument("secret_hex")
    split.add_argument("threshold", type=int)
    split.add_argument("shares", type=int)
    recover = commands.add_parser("combine")
    recover.add_argument("threshold", type=int)
    recover.add_argument("shares", nargs="+")
    recover.add_argument("--files", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "split":
            for i, share in enumerate(make_shares(bytes.fromhex(args.secret_hex), args.threshold, args.shares), 1):
                print(f"{i}-{share.hex()}")
        else:
            shares = [Path(path).read_bytes().decode().rstrip("\n") for path in args.shares] if args.files else args.shares
            print(combine(shares, args.threshold).hex())
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))


if __name__ == "__main__":
    main()
