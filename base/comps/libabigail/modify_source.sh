#!/usr/bin/env bash
#
# libabigail: deterministic strip-and-repack of upstream `libabigail-2.9.tar.xz`
# with the PR30329 testsuite fixture set (which trips anti-malware scanning on
# the AZL RPM-signing pipeline) removed, plus the two corresponding entries
# in tests/test-abidiff-exit.cc patched out so `make check` still passes.
# Rationale lives in the comp.toml `replace-reason` field.
#
# Usage:   bash base/comps/libabigail/modify_source.sh
# Output:  base/build/work/scratch/libabigail/libabigail-2.9.tar.xz (+ .sha512)
# The upstream tarball is cached under a `.upstream` suffix; re-runs reuse it.

set -euo pipefail

# Pin umask so the extraction step below produces the same mode bits
# regardless of the caller's umask. With `--no-same-permissions`, tar ANDs
# each entry's mode against `~umask`, so e.g. umask 077 would silently strip
# group/other read bits and change the bytes of the repacked tarball. The
# repack step does not re-assert per-file modes (only owner/group/mtime), so
# this pin is what guarantees a byte-identical output across machines.
umask 022

# --- Constants --------------------------------------------------------------

readonly COMPONENT="libabigail"
readonly UPSTREAM_VERSION="2.9"
readonly UPSTREAM_FILENAME="${COMPONENT}-${UPSTREAM_VERSION}.tar.xz"
readonly UPSTREAM_TOPDIR="${COMPONENT}-${UPSTREAM_VERSION}"
readonly UPSTREAM_URL="https://mirrors.kernel.org/sourceware/libabigail/${UPSTREAM_FILENAME}"

readonly UPSTREAM_SHA512="5bdf5ec49a5931a61bf28317b41eee583d6277d00ac621b2d2a97bbc0d816c3662bcfe13a5ac7aeee11c947afb69a5a0a9a8015fcebad09965b45af9b1e23606"

# Directory (relative to ${UPSTREAM_TOPDIR}) to strip in its entirety. The
# PR30329 fixture set is a libabigail abidiff regression test built around a
# pair of stripped sqlite3 shared libraries + their separated debuginfo +
# dwz-multifile components. The two `libsqlite3.so.0.8.6.debug` separated-
# debuginfo files inside it are flagged as encrypted/unscannable payloads by
# the AV scanner ("packer_high_entropy:eod") in the AZL RPM-signing pipeline.
# We strip the whole PR30329/ directory (not just the two .debug files) so
# nothing in the tarball still references the missing pieces; the two
# corresponding `InOutSpec` entries in tests/test-abidiff-exit.cc are removed
# below so `make check` still passes.
readonly REMOVE_DIRS=(
    "tests/data/test-abidiff-exit/PR30329"
)

# File inside ${UPSTREAM_TOPDIR} to patch, and the marker substring that
# identifies the two `InOutSpec` entries we need to delete from it. Both
# entries reference the PR30329 fixture set we are stripping above.
readonly PATCH_FILE="tests/test-abidiff-exit.cc"
readonly PATCH_MARKER="PR30329"

# Deterministic-repack mtime: 2020-01-01T00:00:00Z (1577836800).
# Any fixed epoch works; do not change without also bumping the
# `hash` in libabigail.comp.toml.
readonly DETERMINISTIC_MTIME="@1577836800"

# --- Work directory ---------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKDIR="${REPO_ROOT}/base/build/work/scratch/${COMPONENT}"

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

echo "[1/6] Working in ${WORKDIR}"

# --- Download upstream ------------------------------------------------------
#
# The upstream tarball is cached under a `.upstream` suffix so that
# the repacked output written at the canonical `${UPSTREAM_FILENAME}`
# path below cannot clobber the cache on re-runs. Treat the cache
# as authoritative only after SHA-512 verification.

UPSTREAM_CACHE="${WORKDIR}/${UPSTREAM_FILENAME}.upstream"

if [[ ! -f "${UPSTREAM_CACHE}" ]]; then
    echo "[2/6] Downloading ${UPSTREAM_FILENAME} from ${UPSTREAM_URL}"
    # `--proto` / `--proto-redir` restrict the initial request *and* any
    # redirect target to HTTPS, so a downgrade to plain HTTP is refused.
    curl -fsSL --retry 3 \
        --proto '=https' --proto-redir '=https' \
        -o "${UPSTREAM_CACHE}.part" "${UPSTREAM_URL}"
    mv "${UPSTREAM_CACHE}.part" "${UPSTREAM_CACHE}"
else
    echo "[2/6] Using cached upstream tarball ${UPSTREAM_CACHE}"
fi

# --- Verify upstream SHA-512 ------------------------------------------------

echo "[3/6] Verifying upstream SHA-512"
COMPUTED_UPSTREAM_SHA512="$(sha512sum "${UPSTREAM_CACHE}" | awk '{print $1}')"
if [[ "${COMPUTED_UPSTREAM_SHA512}" != "${UPSTREAM_SHA512}" ]]; then
    echo "ERROR: upstream SHA-512 mismatch (cache may be corrupt; delete ${UPSTREAM_CACHE} and re-run)" >&2
    echo "  expected: ${UPSTREAM_SHA512}" >&2
    echo "  computed: ${COMPUTED_UPSTREAM_SHA512}" >&2
    exit 1
fi

# --- Extract + strip --------------------------------------------------------

echo "[4/6] Extracting and stripping ${#REMOVE_DIRS[@]} fixture dir(s) from ${UPSTREAM_TOPDIR}"
rm -rf "${WORKDIR}/${UPSTREAM_TOPDIR}"
# `--no-same-owner` / `--no-same-permissions` prevent tar from applying the
# archive's uid/gid/mode bits to the extracted tree. They are already the
# default for non-root users, but explicit hardening makes the script safe
# to run under sudo (where the defaults flip) and defends against any
# setuid/setgid bits or unexpected ownership in the upstream tarball.
# Deterministic owner/group is re-asserted in the repack step below.
tar -C "${WORKDIR}" --no-same-owner --no-same-permissions -xf "${UPSTREAM_CACHE}"
for REMOVE_DIR in "${REMOVE_DIRS[@]}"; do
    if [[ ! -d "${WORKDIR}/${UPSTREAM_TOPDIR}/${REMOVE_DIR}" ]]; then
        echo "ERROR: expected '${UPSTREAM_TOPDIR}/${REMOVE_DIR}' not present in upstream tarball" >&2
        exit 1
    fi
    echo "    stripping ${UPSTREAM_TOPDIR}/${REMOVE_DIR}"
    rm -rf "${WORKDIR}/${UPSTREAM_TOPDIR}/${REMOVE_DIR}"
done

# --- Patch testsuite driver -------------------------------------------------
#
# Remove every `{ ... },` array-initializer block in ${PATCH_FILE} that
# mentions ${PATCH_MARKER}. The testsuite driver in
# tests/test-abidiff-exit.cc declares a hard-coded `InOutSpec in_out_specs[]`
# array; two of its entries reference the PR30329 fixture set we just
# stripped, and would cause `make check` to fail when those fixtures cannot
# be opened. The blocks are delimited by `{` ... `},` with no nested braces,
# so a tiny stateful Python pass is exact and robust.
echo "[5/6] Patching ${PATCH_FILE} to drop entries referencing ${PATCH_MARKER}"
PATCH_TARGET="${WORKDIR}/${UPSTREAM_TOPDIR}/${PATCH_FILE}"
if [[ ! -f "${PATCH_TARGET}" ]]; then
    echo "ERROR: expected '${PATCH_FILE}' not present in upstream tarball" >&2
    exit 1
fi
PRE_COUNT="$(grep -c -F "${PATCH_MARKER}" "${PATCH_TARGET}" || true)"
python3 - "${PATCH_TARGET}" "${PATCH_MARKER}" <<'PY'
import sys, pathlib

# Operate on bytes (not text) so the rewrite is byte-exact regardless of the
# caller's locale or any newline translation. Path.read_text() / write_text()
# would otherwise default to locale.getencoding() and `newline=None`
# (universal-newline mode), both of which can silently rewrite bytes and
# break deterministic repacking.
path = pathlib.Path(sys.argv[1])
marker = sys.argv[2].encode("utf-8")
lines = path.read_bytes().splitlines(keepends=True)

# Scope the edit to the `InOutSpec in_out_specs[] = { ... };` array body.
# Inside that array, individual entries are `  {` ... `  },` blocks with
# no internal `{` / `}` (verified by inspection of upstream 2.9). Outside
# the array we touch nothing, which avoids accidentally eating function
# bodies, struct initializers in other code, etc.
ARRAY_DECL = b"InOutSpec in_out_specs[] ="
start = None
for i, line in enumerate(lines):
    if ARRAY_DECL in line:
        start = i
        break
if start is None:
    sys.exit(f"ERROR: {ARRAY_DECL!r} not found in {path}")

# The opening `{` is the first line at column 0 starting with `{` after
# the declaration; the closing `};` is the first line starting with `};`
# after that.
body_start = next(i for i in range(start, len(lines)) if lines[i].lstrip().startswith(b"{"))
body_end   = next(i for i in range(body_start + 1, len(lines)) if lines[i].lstrip().startswith(b"};"))

prefix = lines[: body_start + 1]
body   = lines[body_start + 1 : body_end]
suffix = lines[body_end:]

out, buf, in_entry = [], [], False
for line in body:
    stripped = line.strip()
    if not in_entry and stripped == b"{":
        in_entry = True
        buf = [line]
        continue
    if in_entry:
        buf.append(line)
        if stripped == b"},":
            block = b"".join(buf)
            if marker not in block:
                out.extend(buf)
            buf = []
            in_entry = False
        continue
    # Comments / blank lines / preprocessor lines between entries: keep.
    out.append(line)

if in_entry:
    sys.exit(f"ERROR: unterminated entry while patching {path}")

path.write_bytes(b"".join(prefix + out + suffix))
PY
POST_COUNT="$(grep -c -F "${PATCH_MARKER}" "${PATCH_TARGET}" || true)"
echo "    ${PATCH_MARKER} occurrences in ${PATCH_FILE}: ${PRE_COUNT} -> ${POST_COUNT}"
if [[ "${POST_COUNT}" != "0" ]]; then
    echo "ERROR: ${PATCH_MARKER} still present in ${PATCH_FILE} after patch" >&2
    exit 1
fi

# --- Repack deterministically -----------------------------------------------

echo "[6/6] Repacking deterministically as ${UPSTREAM_FILENAME}"
# Deterministic flags:
#   --sort=name             stable entry order
#   --owner=0 --group=0     no host uid/gid leakage
#   --numeric-owner         force numeric uid/gid
#   --mtime=@<epoch>        fixed mtime
#   --format=gnu            handles long paths deterministically
# LC_ALL=C pins sort collation so --sort=name is locale-independent.
# xz -9e -T1 picks max compression with single-threaded output (multi-threaded
# xz produces non-deterministic byte streams). The upstream tarball is .xz so
# we re-emit .xz to keep the filename and Source0 unchanged.
MODIFIED_TARBALL="${WORKDIR}/${UPSTREAM_FILENAME}"
rm -f "${MODIFIED_TARBALL}"
LC_ALL=C tar \
    -C "${WORKDIR}" \
    --sort=name \
    --owner=0 --group=0 --numeric-owner \
    --mtime="${DETERMINISTIC_MTIME}" \
    --format=gnu \
    -cf - "${UPSTREAM_TOPDIR}" \
    | xz -9e -T1 -c > "${MODIFIED_TARBALL}"

MODIFIED_SHA512="$(sha512sum "${MODIFIED_TARBALL}" | awk '{print $1}')"
echo "${MODIFIED_SHA512}  ${UPSTREAM_FILENAME}" > "${MODIFIED_TARBALL}.sha512"

echo
echo "================================================================"
echo "DONE"
echo "  modified tarball: ${WORKDIR}/${UPSTREAM_FILENAME}"
echo "  SHA512:           ${MODIFIED_SHA512}"
echo "================================================================"
echo
echo " To upload the modified tarball to the lookaside:"
echo "       az storage blob upload \\"
echo "           --auth-mode login \\"
echo "           --account-name azltempstaginglookaside \\"
echo "           --container-name repo \\"
echo "           --name \"pkgs_modified/${COMPONENT}/${UPSTREAM_FILENAME}/sha512/${MODIFIED_SHA512}/${UPSTREAM_FILENAME}\" \\"
echo "           --file \"${WORKDIR}/${UPSTREAM_FILENAME}\""
