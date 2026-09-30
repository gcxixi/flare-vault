#!/usr/bin/env python3
"""
FlareVault Companion Decryption Tool (Python)

Decodes and unpacks .flarevault encrypted archives using the RSA Private Key.
Zero-dependency fallback using system openssl CLI if cryptography package is not installed.
"""

import sys
import os
import struct
import json
import hmac
import hashlib
import tempfile
import subprocess
import tarfile
import argparse

FLARE_MAGIC = b'FLAR'
FLARE_VERSION = 1
FLARE_ALGO_RSA = 1
AES_KEY_SIZE = 32
HMAC_KEY_SIZE = 32
IV_SIZE = 16
TAG_SIZE = 32

def parse_header(f):
    magic = f.read(4)
    if magic != FLARE_MAGIC:
        raise ValueError(f"Invalid magic: {magic}. Not a FlareVault archive.")
    
    ver, algo = struct.unpack("BB", f.read(2))
    if ver != FLARE_VERSION or algo != FLARE_ALGO_RSA:
        raise ValueError(f"Unsupported version ({ver}) or algorithm ({algo}).")
    
    enc_key_len = struct.unpack(">H", f.read(2))[0]
    enc_key_data = f.read(enc_key_len)
    
    iv = f.read(IV_SIZE)
    expected_hmac = f.read(TAG_SIZE)
    
    meta_len = struct.unpack(">H", f.read(2))[0]
    meta_json = f.read(meta_len).decode("utf-8", errors="replace") if meta_len > 0 else "{}"
    
    ciphertext_offset = f.tell()
    
    return {
        "magic": magic,
        "version": ver,
        "algo": algo,
        "enc_key_len": enc_key_len,
        "enc_key_data": enc_key_data,
        "iv": iv,
        "expected_hmac": expected_hmac,
        "meta_json": json.loads(meta_json),
        "ciphertext_offset": ciphertext_offset
    }

def rsa_decrypt_session_key(enc_key_data, key_path, password=None):
    # Try cryptography library first if available
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding
        
        with open(key_path, "rb") as kf:
            priv_key = serialization.load_pem_private_key(
                kf.read(),
                password=password.encode("utf-8") if password else None
            )
        session_bundle = priv_key.decrypt(
            enc_key_data,
            padding.OAEP(
                mgf=padding.MGF1(algorithm=hashes.SHA256()),
                algorithm=hashes.SHA256(),
                label=None
            )
        )
        return session_bundle[:32], session_bundle[32:64]
    except ImportError:
        # Fallback to system openssl CLI
        pass
    
    # Using openssl CLI
    with tempfile.NamedTemporaryFile("wb", delete=False) as enc_tmp:
        enc_tmp.write(enc_key_data)
        enc_tmp_name = enc_tmp.name
    
    with tempfile.NamedTemporaryFile("wb", delete=False) as out_tmp:
        out_tmp_name = out_tmp.name
    
    unenc_key_name = key_path
    temp_unenc_key = None
    if password:
        temp_unenc_key = tempfile.NamedTemporaryFile("wb", delete=False)
        cmd_pwd = ["openssl", "rsa", "-in", key_path, "-passin", f"pass:{password}", "-out", temp_unenc_key.name]
        res = subprocess.run(cmd_pwd, capture_output=True)
        if res.returncode != 0:
            os.unlink(enc_tmp_name)
            os.unlink(out_tmp_name)
            raise RuntimeError(f"OpenSSL failed to unlock private key: {res.stderr.decode()}")
        unenc_key_name = temp_unenc_key.name

    try:
        cmd = [
            "openssl", "pkeyutl", "-decrypt",
            "-inkey", unenc_key_name,
            "-pkeyopt", "rsa_padding_mode:oaep",
            "-pkeyopt", "rsa_oaep_md:sha256",
            "-in", enc_tmp_name,
            "-out", out_tmp_name
        ]
        res = subprocess.run(cmd, capture_output=True)
        if res.returncode != 0:
            raise RuntimeError(f"OpenSSL RSA decryption failed: {res.stderr.decode()}")
        
        with open(out_tmp_name, "rb") as rf:
            session_bundle = rf.read()
        
        if len(session_bundle) < 64:
            raise ValueError("Decrypted session key bundle too short")
        
        return session_bundle[:32], session_bundle[32:64]
    finally:
        if os.path.exists(enc_tmp_name): os.unlink(enc_tmp_name)
        if os.path.exists(out_tmp_name): os.unlink(out_tmp_name)
        if temp_unenc_key and os.path.exists(temp_unenc_key.name): os.unlink(temp_unenc_key.name)

def verify_hmac(input_path, hdr, hmac_key):
    hm = hmac.new(hmac_key, digestmod=hashlib.sha256)
    with open(input_path, "rb") as f:
        # Pre-tag bytes
        pre_tag_len = 4 + 2 + 2 + hdr["enc_key_len"] + IV_SIZE
        f.seek(0)
        hm.update(f.read(pre_tag_len))
        
        # Skip tag
        f.seek(pre_tag_len + TAG_SIZE)
        
        # Post-tag bytes (metadata + ciphertext)
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            hm.update(chunk)
    
    computed = hm.digest()
    if not hmac.compare_digest(computed, hdr["expected_hmac"]):
        raise ValueError("HMAC verification failed! File is corrupted or tampered.")

def aes_decrypt(input_path, ciphertext_offset, output_path, aes_key, iv):
    # Try cryptography library first
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives import padding
        
        cipher = Cipher(algorithms.AES(aes_key), modes.CBC(iv))
        decryptor = cipher.decryptor()
        unpadder = padding.PKCS7(128).unpadder()
        
        with open(input_path, "rb") as inf, open(output_path, "wb") as outf:
            inf.seek(ciphertext_offset)
            while True:
                chunk = inf.read(1024 * 1024)
                if not chunk:
                    break
                decrypted_chunk = decryptor.update(chunk)
                outf.write(unpadder.update(decrypted_chunk))
            
            final_bytes = decryptor.finalize()
            outf.write(unpadder.update(final_bytes) + unpadder.finalize())
        return
    except ImportError:
        pass
    
    # Fallback using openssl CLI
    with tempfile.NamedTemporaryFile("wb", delete=False) as ciph_tmp:
        with open(input_path, "rb") as inf:
            inf.seek(ciphertext_offset)
            while True:
                chunk = inf.read(1024 * 1024)
                if not chunk: break
                ciph_tmp.write(chunk)
        ciph_name = ciph_tmp.name
    
    try:
        cmd = [
            "openssl", "enc", "-d", "-aes-256-cbc",
            "-K", aes_key.hex(),
            "-iv", iv.hex(),
            "-in", ciph_name,
            "-out", output_path
        ]
        res = subprocess.run(cmd, capture_output=True)
        if res.returncode != 0:
            raise RuntimeError(f"OpenSSL AES decryption failed: {res.stderr.decode()}")
    finally:
        if os.path.exists(ciph_name): os.unlink(ciph_name)

def main():
    parser = argparse.ArgumentParser(description="FlareVault Decryption Companion")
    parser.add_argument("-k", "--key", required=True, help="Path to RSA Private Key PEM")
    parser.add_argument("-i", "--input", required=True, nargs="+", help="Path to .flarevault archive(s) (in chronological order)")
    parser.add_argument("-o", "--output", required=True, help="Destination directory to unpack")
    parser.add_argument("-p", "--pass", dest="password", default=None, help="Password for private key (if encrypted)")
    args = parser.parse_args()

    input_files = []
    for item in args.input:
        for sub in item.split(","):
            s = sub.strip()
            if s:
                input_files.append(s)

    os.makedirs(args.output, exist_ok=True)
    print(f"=== FlareVault Decryption (Archives: {len(input_files)}) ===")

    for idx, archive_path in enumerate(input_files):
        print(f"\n[{idx + 1}/{len(input_files)}] Reading archive: {archive_path}")
        with open(archive_path, "rb") as f:
            hdr = parse_header(f)
        
        meta = hdr["meta_json"]
        btype = meta.get("backup_type", "full")
        seq = meta.get("sequence", 0)
        print(f"[*] Archive metadata: type={btype}, sequence=#{seq}, base={meta.get('base_backup_id', 'N/A')}")
        print(f"[*] Decrypting session keys using: {args.key}...")
        aes_key, hmac_key = rsa_decrypt_session_key(hdr["enc_key_data"], args.key, args.password)
        
        print("[*] Authenticating archive with HMAC-SHA256...")
        verify_hmac(archive_path, hdr, hmac_key)
        print("    -> HMAC Authentication PASSED!")
        
        with tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False) as tmp_tar:
            tmp_tar_path = tmp_tar.name
        
        try:
            print("[*] Decrypting AES-256-CBC payload...")
            aes_decrypt(archive_path, hdr["ciphertext_offset"], tmp_tar_path, aes_key, hdr["iv"])
            
            print(f"[*] Unpacking files into: {args.output}...")
            with tarfile.open(tmp_tar_path, "r:gz") as tar:
                tar.extractall(path=args.output)
            
            # Apply tombstones
            deleted_files = meta.get("deleted_files", [])
            folder_name = meta.get("folder_name", "")
            if deleted_files:
                del_count = 0
                for d_rel in deleted_files:
                    target = os.path.join(args.output, d_rel)
                    if not os.path.exists(target) and folder_name:
                        target = os.path.join(args.output, folder_name, d_rel)
                    if os.path.exists(target):
                        if os.path.isdir(target):
                            import shutil
                            shutil.rmtree(target, ignore_errors=True)
                        else:
                            os.remove(target)
                        del_count += 1
                print(f"    -> Applied {del_count} file deletions (tombstones).")
            
            print(f"[+] Archive {os.path.basename(archive_path)} restored successfully.")
        finally:
            if os.path.exists(tmp_tar_path):
                os.unlink(tmp_tar_path)

    print(f"\n[+] SUCCESS! All archives applied completely to: {args.output}")

if __name__ == "__main__":
    main()
