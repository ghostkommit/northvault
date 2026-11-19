#!/usr/bin/env python3
"""Bootstrap and readiness probes for disposable, cookie-authenticated Regtest."""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys

NODE = Path("/data/bitcoin")
MINER = "northvault-integration-miner"


def require_fixture():
    if (NODE / "northvault-test-only").read_text() != "disposable regtest\n":
        raise RuntimeError("Refusing an unmarked node directory")


def rpc(*args):
    result = subprocess.run(
        ["bitcoin-cli", f"-datadir={NODE}", "-regtest",
         "-rpcconnect=127.0.0.1", "-rpcport=18443", "-rpcclienttimeout=5", *args],
        check=True, capture_output=True, text=True, timeout=8,
    ).stdout.strip()
    try:
        return json.loads(result)
    except json.JSONDecodeError:
        return result


def rpc_health():
    require_fixture()
    info = rpc("getblockchaininfo")
    if info["chain"] != "regtest":
        raise RuntimeError("Refusing a non-Regtest node")
    return info


def bootstrap():
    info = rpc_health()
    if MINER not in rpc("listwallets"):
        existing = [wallet["name"] for wallet in rpc("listwalletdir")["wallets"]]
        rpc("loadwallet" if MINER in existing else "createwallet", MINER)
    # A retained chain whose tip is over a day old leaves Core in initial block
    # download, and electrs waits for that to end. One fresh block ends it.
    missing = max(101 - info["blocks"], 1 if info.get("initialblockdownload") else 0)
    if missing:
        address = rpc(f"-rpcwallet={MINER}", "getnewaddress")
        rpc("generatetoaddress", str(missing), address)
    print("Disposable Regtest miner ready", flush=True)


def electrum_health():
    info = rpc_health()
    if info["blocks"] < 101 or MINER not in rpc("listwallets"):
        raise RuntimeError("Regtest miner is not ready")
    with socket.create_connection(("127.0.0.1", 50001), timeout=3) as connection:
        connection.sendall(b'{"id":1,"method":"blockchain.headers.subscribe","params":[]}\n')
        with connection.makefile("rb") as stream:
            response = json.loads(stream.readline(65536))
    if response.get("error") or response.get("id") != 1:
        raise RuntimeError("Electrum readiness RPC failed")
    if response["result"]["height"] < info["blocks"]:
        raise RuntimeError("Electrum has not indexed the current chain tip")


def node():
    require_fixture()
    os.execvp("bitcoind", [
        "bitcoind", f"-datadir={NODE}", "-regtest", "-server=1", "-daemon=0",
        "-connect=0", "-discover=0", "-dnsseed=0", "-listen=1", "-listenonion=0",
        "-bind=127.0.0.1:18444", "-port=18444",
        "-rpcbind=127.0.0.1", "-rpcallowip=127.0.0.1", "-rpcport=18443",
        "-fallbackfee=0.00002000", "-txindex=1", "-printtoconsole=1",
    ])


if __name__ == "__main__":
    try:
        actions = {"node": node, "bootstrap": bootstrap,
                   "rpc-health": rpc_health, "electrum-health": electrum_health}
        actions[sys.argv[1]]()
    except (KeyError, IndexError, OSError, ValueError, RuntimeError,
            subprocess.SubprocessError):
        # Do not dump RPC responses, cookies, or fixture wallet data to logs.
        print("Regtest operation failed; check service readiness and configuration", file=sys.stderr)
        sys.exit(1)
