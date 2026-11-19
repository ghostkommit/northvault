#!/usr/bin/env python3
"""Run real Regtest tests using installed binaries, never a user's node or wallet.

Requires bitcoind, bitcoin-cli and electrs on PATH, or explicit executable paths
in BITCOIND, BITCOIN_CLI and ELECTRS. No binary downloads or Docker required.
"""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def executable(variable, name):
    path = shutil.which(os.environ.get(variable, name))
    if path is None:
        raise RuntimeError(f"Missing {name}; install it or set {variable} to its executable path")
    return path


def available_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def wait_ready(processes, check, description):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if any(p.poll() is not None for p in processes):
            raise RuntimeError(f"Fixture process exited before {description}")
        try:
            if check():
                return
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for {description}")


def main():
    bitcoind = executable("BITCOIND", "bitcoind")
    cli = executable("BITCOIN_CLI", "bitcoin-cli")
    electrs = executable("ELECTRS", "electrs")
    with tempfile.TemporaryDirectory(prefix="northvault-regtest-") as temporary:
        root = Path(temporary)
        node = root / "node"
        node.mkdir()
        (node / "northvault-test-only").write_text("disposable regtest\n")
        ports = set()
        while len(ports) < 4:
            ports.add(available_port())
        rpc_port, p2p_port, electrum_port, monitoring_port = ports
        processes = []
        logs = []

        def launch(args, name):
            log = (root / f"{name}.log").open("wb")
            logs.append(log)
            process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            processes.append(process)
            return process

        def rpc(*args):
            output = subprocess.check_output([
                cli, f"-datadir={node}", "-regtest", "-rpcconnect=127.0.0.1",
                f"-rpcport={rpc_port}", "-rpcclienttimeout=5", *args,
            ], stderr=subprocess.DEVNULL, timeout=10)
            try:
                return json.loads(output)
            except ValueError:
                return output.decode().strip()

        def electrum_ready():
            with socket.create_connection(("127.0.0.1", electrum_port), timeout=1) as connection:
                connection.sendall(b'{"id":1,"method":"blockchain.headers.subscribe","params":[]}\n')
                response = connection.makefile("rb").readline(65536)
                return json.loads(response).get("result", {}).get("height", 0) >= 101

        try:
            launch([
                bitcoind, f"-datadir={node}", "-regtest", "-server=1", "-daemon=0",
                "-connect=0", "-discover=0", "-dnsseed=0", "-listenonion=0",
                f"-bind=127.0.0.1:{p2p_port}", f"-port={p2p_port}",
                "-rpcbind=127.0.0.1", "-rpcallowip=127.0.0.1", f"-rpcport={rpc_port}",
                "-fallbackfee=0.00002000", "-txindex=1",
            ], "bitcoind")
            wait_ready(processes, lambda: rpc("getblockchaininfo")["chain"] == "regtest", "Regtest RPC")
            rpc("createwallet", "northvault-integration-miner")
            miner = rpc("-rpcwallet=northvault-integration-miner", "getnewaddress")
            rpc("generatetoaddress", "101", miner)
            launch([
                electrs, "--network", "regtest", "--daemon-dir", str(node),
                "--db-dir", str(root / "electrs"),
                "--daemon-rpc-addr", f"127.0.0.1:{rpc_port}",
                "--daemon-p2p-addr", f"127.0.0.1:{p2p_port}",
                "--electrum-rpc-addr", f"127.0.0.1:{electrum_port}",
                "--monitoring-addr", f"127.0.0.1:{monitoring_port}",
            ], "electrs")
            wait_ready(processes, electrum_ready, "Electrum indexing")
            environment = dict(os.environ,
                NORTHVAULT_TEST_BITCOIN_CLI=cli,
                NORTHVAULT_TEST_NODE_DIR=str(node),
                NORTHVAULT_TEST_RPC_PORT=str(rpc_port),
                NORTHVAULT_TEST_ELECTRUM_PORT=str(electrum_port),
            )
            subprocess.run([
                "cargo", "test", "--locked", "--offline", "--test", "regtest_node",
                "--", "--ignored", "--test-threads=1",
            ], cwd=ROOT / "core", env=environment, check=True, timeout=600)
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            for log in logs:
                log.close()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f"Regtest checks failed: {error}", file=sys.stderr)
        sys.exit(1)
