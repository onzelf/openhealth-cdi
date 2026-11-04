"""Self-check for admission.py (issue #7). Run: python test_admission.py

Covers the Test1F cases at the unit level: admitted A and B pass; no key,
wrong key, replayed challenge, a non-admitted organisation and a second valid
Hospital A connection are refused; a client that cannot answer is refused.
"""

import base64
from types import SimpleNamespace

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from admission import admission_keys, admit, challenge_message

ENVELOPE, RUN, ROUND = "env-1", "local-pathmnist-ab-003", 3


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def public(key: Ed25519PrivateKey) -> str:
    return b64url(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))


def honest(key, org):
    """Answers like the patched client.py."""
    def answer(config):
        message = challenge_message(
            config["envelope_id"], config["run_id"], config["round"],
            config["admission_nonce"], org,
        )
        return {"org_id": org, "admission_signature": b64url(key.sign(message))}
    return answer


class Proxy:
    def __init__(self, cid, answer):
        self.cid, self.answer = cid, answer

    def get_properties(self, ins, timeout, group_id):
        return SimpleNamespace(properties=self.answer(ins.config))


def broken(_config):
    raise TimeoutError("no answer")


key_a, key_b, key_c, rogue = (Ed25519PrivateKey.generate() for _ in range(4))
keys = {"org://HospitalA": public(key_a), "org://HospitalB": public(key_b)}

# A signature for an earlier challenge, replayed now.
old = challenge_message(ENVELOPE, RUN, ROUND - 1, "old-nonce", "org://HospitalA")
replayed = {"org_id": "org://HospitalA", "admission_signature": b64url(key_a.sign(old))}

clients = [
    Proxy("a", honest(key_a, "org://HospitalA")),
    Proxy("b", honest(key_b, "org://HospitalB")),
    Proxy("no-key", lambda c: {"org_id": "org://HospitalA"}),
    Proxy("wrong-key", honest(rogue, "org://HospitalA")),
    Proxy("replay", lambda c: replayed),
    Proxy("not-admitted", honest(key_c, "org://HospitalC")),
    Proxy("second-a", honest(key_a, "org://HospitalA")),
    Proxy("silent", broken),
]
admitted, orgs, rejected = admit(
    [(p, "fit-ins") for p in clients], keys, ENVELOPE, RUN, ROUND
)

assert [p.cid for p, _ in admitted] == ["a", "b"], admitted
assert orgs == {"a": "org://HospitalA", "b": "org://HospitalB"}, orgs
reasons = dict(rejected)
assert reasons["no-key"] == "invalid_proof:org://HospitalA", reasons
assert reasons["wrong-key"] == "invalid_proof:org://HospitalA", reasons
assert reasons["replay"] == "invalid_proof:org://HospitalA", reasons
assert reasons["not-admitted"] == "invalid_proof:org://HospitalC", reasons
assert reasons["second-a"] == "duplicate_org:org://HospitalA", reasons
assert reasons["silent"] == "no_proof:TimeoutError", reasons

# A valid signature for another envelope does not count here.
admitted, _, _ = admit(
    [(Proxy("a", honest(key_a, "org://HospitalA")), "fit-ins")],
    keys, "another-envelope", RUN, ROUND,
)
assert admitted and admitted[0][0].cid == "a"
moved = {"org_id": "org://HospitalA", "admission_signature": b64url(
    key_a.sign(challenge_message("another-envelope", RUN, ROUND, "n", "org://HospitalA")))}
admitted, _, rejected = admit([(Proxy("x", lambda c: moved), "fit-ins")], keys, ENVELOPE, RUN, ROUND)
assert not admitted and rejected == [("x", "invalid_proof:org://HospitalA")]

# The server's own fresh nonce, signed for another envelope, run or round: refused.
def signs_for(key, org_id, envelope=None, run=None, server_round=None):
    def answer(config):
        message = challenge_message(
            envelope or config["envelope_id"],
            run or config["run_id"],
            config["round"] if server_round is None else server_round,
            config["admission_nonce"],
            org_id,
        )
        return {"org_id": org_id, "admission_signature": b64url(key.sign(message))}
    return answer


for label, answer in [
    ("other-envelope", signs_for(key_a, "org://HospitalA", envelope="another-envelope")),
    ("other-run", signs_for(key_a, "org://HospitalA", run="local-pathmnist-ab-999")),
    ("other-round", signs_for(key_a, "org://HospitalA", server_round=ROUND + 1)),
]:
    admitted, _, rejected = admit([(Proxy(label, answer), "fit-ins")], keys, ENVELOPE, RUN, ROUND)
    assert not admitted and rejected == [(label, "invalid_proof:org://HospitalA")], (label, rejected)
admitted, _, _ = admit([(Proxy("a", signs_for(key_a, "org://HospitalA")), "fit-ins")], keys, ENVELOPE, RUN, ROUND)
assert [p.cid for p, _ in admitted] == ["a"], admitted

# Only envelope participants count, and a guest key never replaces a participant's key.
binding = {
    "participants": ["org://HospitalA"],
    "participant_keys": {"org://HospitalA": "key-a", "org://HospitalB": "key-b"},
    "guest_keys": {"org://HospitalA": "guest-key", "org://HospitalC": "key-c"},
}
assert admission_keys(binding, guest_admitted=False) == {"org://HospitalA": "key-a"}
assert admission_keys(binding, guest_admitted=True) == {"org://HospitalA": "key-a", "org://HospitalC": "key-c"}

# No keys bound (e.g. no envelope): nobody is admitted.
admitted, _, _ = admit([(p, "fit-ins") for p in clients[:2]], {}, ENVELOPE, RUN, ROUND)
assert admitted == []

print("admission self-check: all cases pass")
