"""Regression for audit 2c9d5fa2: run with python3 test/test_art_launch_manifest.py after forge build."""

import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ArtLaunchManifestTest(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((ROOT / "launch.json").read_text())

    def test_only_art_contracts_in_dependency_order(self):
        self.assertEqual(set(self.manifest), {"kind", "contracts", "notes"})
        self.assertEqual(self.manifest["kind"], "evm_contracts")
        self.assertEqual(
            self.manifest["contracts"],
            [
                {"contract": "WorkerArt1", "constructorArgs": []},
                {"contract": "WorkerArt2", "constructorArgs": []},
                {
                    "contract": "WorkerFrensRenderer",
                    "constructorArgs": ["$contract:WorkerArt1", "$contract:WorkerArt2"],
                },
            ],
        )

    def test_arguments_match_compiled_nonpayable_constructors(self):
        earlier = set()
        for entry in self.manifest["contracts"]:
            name = entry["contract"]
            with self.subTest(contract=name):
                artifacts = list((ROOT / "out").glob(f"*.sol/{name}.json"))
                self.assertEqual(len(artifacts), 1, "run forge build first")
                abi = json.loads(artifacts[0].read_text())["abi"]
                constructors = [item for item in abi if item["type"] == "constructor"]
                self.assertEqual(len(constructors), 1)
                constructor = constructors[0]
                self.assertEqual(constructor["stateMutability"], "nonpayable")
                args = entry["constructorArgs"]
                self.assertEqual(len(args), len(constructor["inputs"]))
                for arg, param in zip(args, constructor["inputs"]):
                    self.assertEqual(param["type"], "address")
                    self.assertTrue(arg.startswith("$contract:"))
                    self.assertIn(arg.removeprefix("$contract:"), earlier)
            earlier.add(name)


if __name__ == "__main__":
    unittest.main()
