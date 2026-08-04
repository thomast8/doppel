#!/usr/bin/python3
"""Keep clone deep links separate while routing OAuth through ``codex://``.

The desktop app normally derives both its OAuth callback URL and its runtime
protocol registration from one helper. Packaged clones therefore compete for
``codex://`` merely by launching. Google, however, validates the exact
OpenAI-registered ``codex://connector/oauth_callback`` redirect and rejects a
clone-specific replacement.

This patch gives ordinary runtime registration a per-instance scheme, but
keeps the registered OAuth callback unchanged. When a clone actually starts
connector OAuth it claims ``codex://`` immediately before returning that
callback URL. The initiating instance therefore receives the result without
making Google validate an unregistered redirect URI.

ASAR is deliberately handled here without a third-party package. The format is
a JSON file table followed by concatenated file data. Rewriting the one changed
member also updates subsequent offsets, per-file integrity, and prints the
new header hash required by ElectronAsarIntegrity in Info.plist.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import struct
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator


PATCH_INSERTION = b"process.env.DOPPEL_URL_SCHEME?.trim()||"
OAUTH_PATCH_MARKER = b"Doppel could not claim codex:// OAuth callback"
RESTORE_PATCH_MARKER = b"DOPPEL_URL_HANDLER_HELPER"
REQUIRED_NEIGHBOURS = (
    b"setAsDefaultProtocolClient",
    b"chatgpt.com",
    b"codex-dev",
)

# Minified symbol names change between vendor releases. Match the behavior,
# not today's names: the protocol helper returns production or development
# scheme depending on app.isPackaged and platform.
PROTOCOL_HELPER = re.compile(
    rb"function (?P<function>[A-Za-z_$][A-Za-z0-9_$]*)"
    rb"\(e,t=process\.platform\)\{return "
    rb"e\|\|t===`win32`\|\|t===`linux`\?"
    rb"(?P<production>[A-Za-z_$][A-Za-z0-9_$]*):"
    rb"(?P<development>[A-Za-z_$][A-Za-z0-9_$]*)\}"
)

OAUTH_CALLBACK_HANDLER = re.compile(
    rb'"app-connect-oauth-callback-url":async\(\)=>\(\{callbackUrl:`\$\{'
    rb"(?P<protocol>[A-Za-z_$][A-Za-z0-9_$]*)\.u\("
    rb"(?P<electron>[A-Za-z_$][A-Za-z0-9_$]*)\.app\.isPackaged\)"
    rb"\}://connector/oauth_callback`\}\)"
)

CHILD_PROCESS_IMPORT = re.compile(
    rb"(?:let|const|var) (?P<child>[A-Za-z_$][A-Za-z0-9_$]*)="
    rb'require\("node:child_process"\)'
)

OPEN_URL_HANDLER = re.compile(
    rb"return (?P<mac>[A-Za-z_$][A-Za-z0-9_$]*)&&"
    rb"(?P<app>[A-Za-z_$][A-Za-z0-9_$]*)\.on\(`open-url`,\("
    rb"(?P<event>[A-Za-z_$][A-Za-z0-9_$]*),(?P<url>[A-Za-z_$][A-Za-z0-9_$]*)"
    rb"\)=>\{let (?P<route>[A-Za-z_$][A-Za-z0-9_$]*)="
    rb"(?P<parse>[A-Za-z_$][A-Za-z0-9_$]*)\((?P=url)\);(?P=route)&&\("
    rb"(?P<queue>[A-Za-z_$][A-Za-z0-9_$]*)\((?P=route)\),"
    rb"(?P<callback>[A-Za-z_$][A-Za-z0-9_$]*)\?\.\("
    rb"(?P<predicate>[A-Za-z_$][A-Za-z0-9_$]*)\((?P=route)\)\?"
    rb"(?P=url):void 0\),(?P=event)\.preventDefault\(\)\)\}\),"
)


class PatchError(RuntimeError):
    pass


@dataclass
class Archive:
    path: Path
    header: dict[str, Any]
    header_json: bytes
    data_offset: int
    size: int


@dataclass
class Member:
    path: str
    entry: dict[str, Any]
    offset: int
    size: int


def read_archive(path: Path) -> Archive:
    with path.open("rb") as archive:
        prefix = archive.read(16)
        if len(prefix) != 16:
            raise PatchError("the ASAR header is truncated")
        size_pickle_payload, header_pickle_size, header_payload, json_size = struct.unpack(
            "<IIII", prefix
        )
        if size_pickle_payload != 4:
            raise PatchError("the ASAR size pickle has an unexpected shape")
        if header_pickle_size != header_payload + 4:
            raise PatchError("the ASAR header pickle sizes disagree")
        if json_size > header_payload - 4:
            raise PatchError("the ASAR JSON size exceeds its header payload")
        header_json = archive.read(json_size)
        try:
            header = json.loads(header_json)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise PatchError(f"the ASAR file table is invalid JSON: {error}") from error
        data_offset = 8 + header_pickle_size
        archive.seek(0, os.SEEK_END)
        size = archive.tell()
    if data_offset > size:
        raise PatchError("the ASAR data offset is outside the archive")
    return Archive(path, header, header_json, data_offset, size)


def members(archive: Archive) -> Iterator[Member]:
    def walk(files: dict[str, Any], parent: str = "") -> Iterator[Member]:
        for name, entry in files.items():
            member_path = f"{parent}/{name}" if parent else name
            child_files = entry.get("files")
            if isinstance(child_files, dict):
                yield from walk(child_files, member_path)
                continue
            if entry.get("unpacked") or "offset" not in entry or "size" not in entry:
                continue
            try:
                offset = int(entry["offset"])
                size = int(entry["size"])
            except (TypeError, ValueError) as error:
                raise PatchError(f"invalid offset or size for {member_path}") from error
            if offset < 0 or size < 0 or archive.data_offset + offset + size > archive.size:
                raise PatchError(f"member lies outside the archive: {member_path}")
            yield Member(member_path, entry, offset, size)

    files = archive.header.get("files")
    if not isinstance(files, dict):
        raise PatchError("the ASAR file table has no files dictionary")
    yield from walk(files)


def read_member(archive: Archive, member: Member) -> bytes:
    with archive.path.open("rb") as source:
        source.seek(archive.data_offset + member.offset)
        data = source.read(member.size)
    if len(data) != member.size:
        raise PatchError(f"member is truncated: {member.path}")
    return data


def patched_helper(match: re.Match[bytes]) -> bytes:
    function_name = match.group("function")
    production = match.group("production")
    development = match.group("development")
    return (
        b"function "
        + function_name
        + b"(e,t=process.platform){return "
        + PATCH_INSERTION
        + b"(e||t===`win32`||t===`linux`?"
        + production
        + b":"
        + development
        + b")}"
    )


def locate_protocol_member(archive: Archive) -> tuple[Member, bytes, bool]:
    patched: list[tuple[Member, bytes]] = []
    unpatched: list[tuple[Member, bytes, re.Match[bytes]]] = []
    for member in members(archive):
        if not member.path.endswith(".js") or member.size == 0:
            continue
        data = read_member(archive, member)
        if not all(marker in data for marker in REQUIRED_NEIGHBOURS):
            continue
        if PATCH_INSERTION in data:
            patched.append((member, data))
            continue
        matches = list(PROTOCOL_HELPER.finditer(data))
        if len(matches) == 1:
            unpatched.append((member, data, matches[0]))
        elif matches:
            raise PatchError(
                f"found {len(matches)} protocol helpers in {member.path}; refusing an ambiguous patch"
            )
    if patched and unpatched:
        raise PatchError("the archive contains both patched and unpatched protocol helpers")
    if len(patched) == 1:
        return patched[0][0], patched[0][1], True
    if len(unpatched) == 1:
        member, data, match = unpatched[0]
        replacement = patched_helper(match)
        return member, data[: match.start()] + replacement + data[match.end() :], False
    count = len(patched) + len(unpatched)
    if count == 0:
        raise PatchError(
            "the packaged app no longer contains the expected OAuth/deep-link protocol helper"
        )
    raise PatchError(f"found {count} candidate protocol members; refusing an ambiguous patch")


def patched_oauth_handler(match: re.Match[bytes]) -> bytes:
    electron = match.group("electron")
    app = electron + b".app"
    return (
        b'"app-connect-oauth-callback-url":async()=>{if(!'
        + app
        + b".setAsDefaultProtocolClient(`codex`)&&!"
        + app
        + b".isDefaultProtocolClient(`codex`))throw Error(`"
        + OAUTH_PATCH_MARKER
        + b"`);return{callbackUrl:`codex://connector/oauth_callback`}}"
    )


def locate_oauth_member(archive: Archive) -> tuple[Member, bytes, bool]:
    patched: list[tuple[Member, bytes]] = []
    unpatched: list[tuple[Member, bytes, re.Match[bytes]]] = []
    for member in members(archive):
        if not member.path.endswith(".js") or member.size == 0:
            continue
        data = read_member(archive, member)
        if OAUTH_PATCH_MARKER in data:
            if data.count(OAUTH_PATCH_MARKER) != 1 or data.count(
                b"callbackUrl:`codex://connector/oauth_callback`"
            ) != 1:
                raise PatchError(
                    f"the OAuth ownership patch is malformed in {member.path}"
                )
            patched.append((member, data))
            continue
        matches = list(OAUTH_CALLBACK_HANDLER.finditer(data))
        if len(matches) == 1:
            unpatched.append((member, data, matches[0]))
        elif matches:
            raise PatchError(
                f"found {len(matches)} OAuth callback handlers in {member.path}; refusing an ambiguous patch"
            )
    if patched and unpatched:
        raise PatchError("the archive contains both patched and unpatched OAuth handlers")
    if len(patched) == 1:
        return patched[0][0], patched[0][1], True
    if len(unpatched) == 1:
        member, data, match = unpatched[0]
        replacement = patched_oauth_handler(match)
        return member, data[: match.start()] + replacement + data[match.end() :], False
    count = len(patched) + len(unpatched)
    if count == 0:
        raise PatchError("the packaged app no longer contains the expected OAuth callback handler")
    raise PatchError(f"found {count} candidate OAuth members; refusing an ambiguous patch")


def patched_open_url_handler(match: re.Match[bytes], child: bytes) -> bytes:
    mac = match.group("mac")
    app = match.group("app")
    event = match.group("event")
    url = match.group("url")
    route = match.group("route")
    parse = match.group("parse")
    queue = match.group("queue")
    callback = match.group("callback")
    predicate = match.group("predicate")
    return (
        b"return "
        + mac
        + b"&&"
        + app
        + b".on(`open-url`,("
        + event
        + b"," + url + b")=>{let " + route + b"=" + parse + b"(" + url + b");if("
        + route
        + b"){"
        + queue
        + b"("
        + route
        + b"),"
        + callback
        + b"?.("
        + predicate
        + b"("
        + route
        + b")?"
        + url
        + b":void 0);if("
        + route
        + b".kind===`connectorOAuthCallback`&&process.env."
        + RESTORE_PATCH_MARKER
        + b"&&process.env.DOPPEL_PRIMARY_APP&&process.env.DOPPEL_PRIMARY_BUNDLE_ID)try{"
        + child
        + b".spawn(process.env."
        + RESTORE_PATCH_MARKER
        + b",[`set`,`codex`,process.env.DOPPEL_PRIMARY_APP,process.env.DOPPEL_PRIMARY_BUNDLE_ID],{detached:!0,stdio:`ignore`}).unref()}catch{}"
        + event
        + b".preventDefault()}}),"
    )


def locate_restore_member(archive: Archive) -> tuple[Member, bytes, bool]:
    patched: list[tuple[Member, bytes]] = []
    unpatched: list[tuple[Member, bytes, re.Match[bytes], bytes]] = []
    for member in members(archive):
        if not member.path.endswith(".js") or member.size == 0:
            continue
        data = read_member(archive, member)
        if RESTORE_PATCH_MARKER in data:
            if data.count(RESTORE_PATCH_MARKER) != 2:
                raise PatchError(
                    f"the OAuth handler restoration patch is malformed in {member.path}"
                )
            patched.append((member, data))
            continue
        handler_matches = list(OPEN_URL_HANDLER.finditer(data))
        if not handler_matches:
            continue
        child_matches = list(CHILD_PROCESS_IMPORT.finditer(data))
        if len(handler_matches) != 1 or len(child_matches) != 1:
            raise PatchError(
                f"the callback restoration target is ambiguous in {member.path}"
            )
        unpatched.append(
            (member, data, handler_matches[0], child_matches[0].group("child"))
        )
    if patched and unpatched:
        raise PatchError("the archive contains both patched and unpatched callback restorers")
    if len(patched) == 1:
        return patched[0][0], patched[0][1], True
    if len(unpatched) == 1:
        member, data, match, child = unpatched[0]
        replacement = patched_open_url_handler(match, child)
        return member, data[: match.start()] + replacement + data[match.end() :], False
    count = len(patched) + len(unpatched)
    if count == 0:
        raise PatchError("the packaged app no longer contains the expected open-url handler")
    raise PatchError(f"found {count} callback restoration members; refusing an ambiguous patch")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def refresh_member_integrity(entry: dict[str, Any], data: bytes) -> None:
    integrity = entry.get("integrity")
    if not isinstance(integrity, dict) or integrity.get("algorithm") != "SHA256":
        raise PatchError("the protocol member lacks the expected SHA256 integrity metadata")
    block_size = integrity.get("blockSize")
    if not isinstance(block_size, int) or block_size <= 0:
        raise PatchError("the protocol member has an invalid integrity block size")
    integrity["hash"] = digest(data)
    integrity["blocks"] = [digest(data[index : index + block_size]) for index in range(0, len(data), block_size)]


def encode_header(header: dict[str, Any]) -> tuple[bytes, bytes]:
    header_json = json.dumps(header, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    padding = b"\0" * ((-len(header_json)) % 4)
    header_payload_size = 4 + len(header_json) + len(padding)
    header_pickle_size = 4 + header_payload_size
    prefix = struct.pack(
        "<IIII", 4, header_pickle_size, header_payload_size, len(header_json)
    )
    return prefix + header_json + padding, header_json


def copy_exact(source: Any, destination: Any, count: int) -> None:
    remaining = count
    while remaining:
        chunk = source.read(min(1024 * 1024, remaining))
        if not chunk:
            raise PatchError("the ASAR data ended while it was being rewritten")
        destination.write(chunk)
        remaining -= len(chunk)


def rewrite_archive(archive: Archive, member: Member, new_data: bytes) -> None:
    all_members = list(members(archive))
    delta = len(new_data) - member.size
    member.entry["size"] = len(new_data)
    refresh_member_integrity(member.entry, new_data)
    for other in all_members:
        if other.entry is member.entry:
            continue
        if other.offset > member.offset:
            other.entry["offset"] = str(other.offset + delta)

    encoded_header, header_json = encode_header(archive.header)
    original_mode = stat.S_IMODE(archive.path.stat().st_mode)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w+b", prefix=f".{archive.path.name}.", dir=archive.path.parent, delete=False
        ) as destination, archive.path.open("rb") as source:
            temporary_path = Path(destination.name)
            destination.write(encoded_header)
            source.seek(archive.data_offset)
            copy_exact(source, destination, member.offset)
            destination.write(new_data)
            source.seek(archive.data_offset + member.offset + member.size)
            copy_exact(
                source,
                destination,
                archive.size - (archive.data_offset + member.offset + member.size),
            )
            destination.flush()
            os.fsync(destination.fileno())
        os.chmod(temporary_path, original_mode)
        os.replace(temporary_path, archive.path)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)

    # Force serialization before replacing the archive; the caller reloads it
    # and behaviorally verifies every required patch afterwards.
    digest(header_json)


def verify_member_integrity(entry: dict[str, Any], data: bytes) -> None:
    integrity = entry.get("integrity")
    if not isinstance(integrity, dict) or integrity.get("algorithm") != "SHA256":
        raise PatchError("the patched member lacks SHA256 integrity metadata")
    block_size = integrity.get("blockSize")
    expected_blocks = integrity.get("blocks")
    if not isinstance(block_size, int) or block_size <= 0 or not isinstance(expected_blocks, list):
        raise PatchError("the patched member integrity metadata is invalid")
    actual_blocks = [digest(data[index : index + block_size]) for index in range(0, len(data), block_size)]
    if integrity.get("hash") != digest(data) or expected_blocks != actual_blocks:
        raise PatchError("the patched member integrity hashes do not match its contents")


def patch(path: Path) -> str:
    archive = read_archive(path)
    member, data, already_patched = locate_protocol_member(archive)
    if not already_patched:
        rewrite_archive(archive, member, data)

    archive = read_archive(path)
    member, data, already_patched = locate_oauth_member(archive)
    if not already_patched:
        rewrite_archive(archive, member, data)

    archive = read_archive(path)
    member, data, already_patched = locate_restore_member(archive)
    if not already_patched:
        rewrite_archive(archive, member, data)
    return verify(path)


def verify(path: Path) -> str:
    archive = read_archive(path)
    member, data, already_patched = locate_protocol_member(archive)
    if not already_patched:
        raise PatchError("the archive still uses the shared codex:// protocol")
    verify_member_integrity(member.entry, data)

    oauth_member, oauth_data, oauth_patched = locate_oauth_member(archive)
    if not oauth_patched:
        raise PatchError("the OAuth callback does not claim codex:// on demand")
    verify_member_integrity(oauth_member.entry, oauth_data)

    restore_member, restore_data, restore_patched = locate_restore_member(archive)
    if not restore_patched:
        raise PatchError("the OAuth callback does not restore primary codex:// ownership")
    verify_member_integrity(restore_member.entry, restore_data)
    return digest(archive.header_json)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("patch", "verify"))
    parser.add_argument("archive", type=Path)
    arguments = parser.parse_args()
    if not arguments.archive.is_file():
        parser.error(f"archive does not exist: {arguments.archive}")
    try:
        header_hash = patch(arguments.archive) if arguments.mode == "patch" else verify(arguments.archive)
    except (OSError, PatchError) as error:
        print(f"patch-deep-link: {error}", file=sys.stderr)
        return 1
    print(header_hash)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
