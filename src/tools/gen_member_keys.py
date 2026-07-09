from nacl import signing, encoding
import base64, pathlib, argparse, hashlib, json, datetime

def b64url_no_pad(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")

parser = argparse.ArgumentParser(description="Generate member PoP keys + registration payload (sub + cnf.jkt)")
parser.add_argument("--who", type=str, required=True, help="Member identity (sub)")
parser.add_argument("--org", type=str, required=True, help="Organization identifier (org_id)")
args = parser.parse_args()

who = args.who
org = args.org

# Generate Ed25519 keypair
sk = signing.SigningKey.generate()
vk = sk.verify_key

priv_hex = sk.encode(encoder=encoding.HexEncoder).decode()
pub_raw  = vk.encode()  # 32 bytes Ed25519 public key
pub_b64  = b64url_no_pad(pub_raw)

# jkt := base64url(sha256(pubkey_bytes))
jkt = b64url_no_pad(hashlib.sha256(pub_raw).digest())

pathlib.Path("holder_keys").mkdir(exist_ok=True)
pathlib.Path(f"holder_keys/{who}.privhex").write_text(priv_hex)
pathlib.Path(f"holder_keys/{who}.pubb64").write_text(pub_b64)
pathlib.Path(f"holder_keys/{who}.jkt").write_text(jkt)

reg = {
    "org_id": org,
    "member_id": who,
    "sub": who,            # for PoC: sub := member_id
    "pub_b64": pub_b64,
    "jkt": jkt,
    "created_at": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
}

pathlib.Path(f"holder_keys/{who}.register.json").write_text(json.dumps(reg, indent=2))

print(f"generated PRIVHEX: {priv_hex} for {who}")
print(f"generated PUBB64 : {pub_b64} for {who}")
print(f"generated JKT    : {jkt}")
print(f"wrote registration payload: holder_keys/{who}.register.json")
 