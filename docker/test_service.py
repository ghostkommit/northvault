"""Exercise bootstrap/recovery and readiness with synthetic external boundaries."""

import contextlib
import io
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

import service


# A subprocess RPC boundary persists state between calls, like a restarted node.
FAKE_CLI = r'''
import json
from pathlib import Path
import sys
node = Path(next(arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("-datadir=")))
state_file = node / "state.json"
state = json.loads(state_file.read_text())
args = [arg for arg in sys.argv[1:] if not arg.startswith("-")]
method = args[0]
if method == "getblockchaininfo":
    result = {"chain": state["chain"], "blocks": state["blocks"], "initialblockdownload": state.get("stale", False)}
elif method == "listwallets":
    result = state["loaded"]
elif method == "listwalletdir":
    result = {"wallets": [{"name": name} for name in state["wallets"]]}
elif method == "createwallet":
    assert args[1] not in state["wallets"]
    state["wallets"].append(args[1])
    state["loaded"].append(args[1])
    result = {}
elif method == "loadwallet":
    assert args[1] in state["wallets"]
    state["loaded"].append(args[1])
    result = {}
elif method == "getnewaddress":
    result = "synthetic-rpc-boundary-address"
elif method == "generatetoaddress":
    state["blocks"] += int(args[1])
    state["stale"] = False
    result = []
else:
    sys.exit(1)
state["calls"].append(method)
state_file.write_text(json.dumps(state))
print(json.dumps(result))
'''


class ServiceWorkflows(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="northvault-compose-check-")
        self.addCleanup(temporary.cleanup)
        self.node = Path(temporary.name)
        (self.node / "northvault-test-only").write_text("disposable regtest\n")
        self.state_file = self.node / "state.json"
        self.write_state({"chain": "regtest", "blocks": 0, "wallets": [],
                          "loaded": [], "calls": []})
        cli = self.node / "bitcoin-cli"
        cli.write_text(f"#!{sys.executable}\n" + FAKE_CLI)
        cli.chmod(0o700)
        node_patch = patch.object(service, "NODE", self.node)
        path_patch = patch.dict(os.environ, {"PATH": f"{self.node}{os.pathsep}{os.environ['PATH']}"})
        node_patch.start()
        path_patch.start()
        self.addCleanup(node_patch.stop)
        self.addCleanup(path_patch.stop)

    def read_state(self):
        return json.loads(self.state_file.read_text())

    def write_state(self, state):
        self.state_file.write_text(json.dumps(state))

    def bootstrap(self):
        with contextlib.redirect_stdout(io.StringIO()):
            service.bootstrap()

    def test_bootstrap_repeat_and_restart_preserve_chain_and_wallet(self):
        self.bootstrap()
        self.bootstrap()
        state = self.read_state()
        self.assertEqual(state["blocks"], 101)
        self.assertEqual(state["wallets"], [service.MINER])
        self.assertEqual(state["calls"].count("createwallet"), 1)
        self.assertEqual(state["calls"].count("generatetoaddress"), 1)
        # Existing chain, but the node did not automatically load its wallet.
        state.update(loaded=[], blocks=110)
        self.write_state(state)
        self.bootstrap()
        self.assertEqual(self.read_state()["loaded"], [service.MINER])
        self.assertEqual(self.read_state()["blocks"], 110)
        # A chain retained for over a day needs one fresh block before electrs syncs.
        state = self.read_state()
        state["stale"] = True
        self.write_state(state)
        self.bootstrap()
        self.bootstrap()
        self.assertEqual(self.read_state()["blocks"], 111)

    def test_refuse_unmarked_or_wrong_network_without_mutation(self):
        (self.node / "northvault-test-only").write_text("not a fixture\n")
        with self.assertRaises(RuntimeError):
            self.bootstrap()
        self.assertEqual(self.read_state()["calls"], [])
        (self.node / "northvault-test-only").write_text("disposable regtest\n")
        state = self.read_state()
        state["chain"] = "main"
        self.write_state(state)
        with self.assertRaises(RuntimeError):
            self.bootstrap()
        self.assertEqual(self.read_state()["calls"], ["getblockchaininfo"])
        self.assertEqual(self.read_state()["wallets"], [])

    def check_electrum(self, response):
        # Actual TCP/JSON exchange; only redirect the endpoint to an ephemeral port.
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(5)
            requests = []

            def respond():
                with listener.accept()[0] as client:
                    client.settimeout(5)
                    with client.makefile("rb") as stream:
                        requests.append(json.loads(stream.readline()))
                    client.sendall(json.dumps(response).encode() + b"\n")

            thread = threading.Thread(target=respond)
            thread.start()
            connect = socket.create_connection
            try:
                with patch.object(service.socket, "create_connection",
                                  side_effect=lambda address, timeout: connect(listener.getsockname(), timeout)):
                    service.electrum_health()
            finally:
                thread.join(timeout=6)
                self.assertFalse(thread.is_alive())
                self.assertEqual(requests, [{"id": 1, "method": "blockchain.headers.subscribe", "params": []}])

    def test_readiness_waits_for_miner_and_index_and_rejects_rpc_errors(self):
        with self.assertRaises(RuntimeError):
            service.electrum_health()
        self.bootstrap()
        for response in [
            {"id": 1, "result": {"height": 100}},
            {"id": 1, "error": {"code": -1}},
            {"id": 2, "result": {"height": 101}},
        ]:
            with self.subTest(response=response), self.assertRaises(RuntimeError):
                self.check_electrum(response)
        self.check_electrum({"id": 1, "result": {"height": 101}})


if __name__ == "__main__":
    unittest.main()
