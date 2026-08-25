# port_b64_encoder.py - copy encodeBase64Chunked from send-visit-photos-email into
# send-derm-email BYTE-FOR-BYTE, then prove the two copies are identical.
#
# Written 2026-08-25. This repo has lost clauses to retyping a body from memory
# (see CLAUDE.md "CREATE OR REPLACE: COPY THE WHOLE BODY, NEVER RETYPE IT"), and a
# base64 bug here produces a corrupt attachment that still looks like valid base64
# and still sends -- to a municipality. So the port is mechanical, not manual.
import io, re, sys, hashlib

SRC = r"C:\Users\FRED\Desktop\Virtrify\Yannick\Claude\Supabase\supabase\functions\send-visit-photos-email\index.ts"
DST = r"C:\Users\FRED\Desktop\Virtrify\Yannick\Claude\Supabase\supabase\functions\send-derm-email\index.ts"

src = io.open(SRC, encoding="utf-8").read()
dst = io.open(DST, encoding="utf-8").read()

# Extract from the B64_CHUNK constant through the close of encodeBase64Chunked.
m = re.search(r"const B64_CHUNK = .*?\nfunction encodeBase64Chunked\(bytes: Uint8Array\): string \{.*?\n\}\n",
              src, re.S)
if not m:
    sys.exit("FAIL: could not locate the encoder block in the source file")
block = m.group(0)
print("extracted %d bytes, sha256=%s" % (len(block), hashlib.sha256(block.encode()).hexdigest()[:16]))

PREFIX = (
    "// 🛑 COPIED BYTE-FOR-BYTE FROM send-visit-photos-email/index.ts (2026-08-25). Do not edit\n"
    "//    one copy without the other, and do not retype either. Same incident, same reason:\n"
    "//    std@0.224.0's encodeBase64 appends one character at a time and burns ~32 bytes of\n"
    "//    V8 heap per output character, which OOM-kills the worker. An OOM is a PLATFORM kill,\n"
    "//    so no catch runs, no finally runs, and derm_email_sends records nothing at all.\n"
    "//    This function's worst measured payload is ~5.36MB across 2 attachments = ~7.15M\n"
    "//    base64 chars = ~229MB, against a ceiling that killed a worker at 277.7MB. It had\n"
    "//    single-digit percent headroom on the regulator-facing city path.\n"
)

# 1. remove the std import line
before = dst
dst = re.sub(r"^import \{ encodeBase64 \} from 'https://deno\.land/std@0\.224\.0/encoding/base64\.ts'\n",
             "", dst, count=1, flags=re.M)
if dst == before:
    sys.exit("FAIL: std base64 import not found / not removed")

# 2. insert the block immediately after the final import line
imports = list(re.finditer(r"^import .*$", dst, flags=re.M))
if not imports:
    sys.exit("FAIL: no import lines found")
ins = imports[-1].end()
dst = dst[:ins] + "\n\n" + PREFIX + block.rstrip("\n") + dst[ins:]

# 3. replace the single call site
old_call = "  const b64 = encodeBase64(new Uint8Array(await resp.arrayBuffer()))\n"
if dst.count(old_call) != 1:
    sys.exit("FAIL: expected exactly 1 call site, found %d" % dst.count(old_call))
new_call = (
    "  const bytes = new Uint8Array(await resp.arrayBuffer())\n"
    "  const b64 = encodeBase64Chunked(bytes)\n"
    "  // The multiple-of-3 control. Base64 of n bytes is exactly 4*ceil(n/3); mid-stream '='\n"
    "  // padding makes it LONGER. Returning null here is FAIL-CLOSED by construction: all three\n"
    "  // call sites do `if (!att) { fetchFailed = true; break }` and then abandon the WHOLE\n"
    "  // manifest with reason 'pdf_fetch_failed', so a corrupt attachment can never reach a\n"
    "  // municipality. Verified against the call sites before this was written.\n"
    "  // ⚠ The logged reason will read 'pdf_fetch_failed', which is not what happened, so the\n"
    "  //   console line below is the only thing that tells the two apart in the edge log.\n"
    "  if (b64.length !== 4 * Math.ceil(bytes.length / 3)) {\n"
    "    console.error(`[send-derm-email] b64_length_mismatch ${b64.length}!=${4 * Math.ceil(bytes.length / 3)} for ${baseName}; refusing the attachment`)\n"
    "    return null\n"
    "  }\n"
)
dst = dst.replace(old_call, new_call, 1)

io.open(DST, "w", encoding="utf-8", newline="\n").write(dst)

# 4. PROVE the two copies are identical
after = io.open(DST, encoding="utf-8").read()
m2 = re.search(r"const B64_CHUNK = .*?\nfunction encodeBase64Chunked\(bytes: Uint8Array\): string \{.*?\n\}\n",
               after, re.S)
if not m2:
    sys.exit("FAIL: block not found in destination after write")
same = m2.group(0) == block
print("destination block sha256=%s" % hashlib.sha256(m2.group(0).encode()).hexdigest()[:16])
print("BYTE-IDENTICAL TO SOURCE: %s" % same)
print("std import remaining: %s" % ("encoding/base64.ts" in after))
print("encodeBase64( bare calls remaining: %d" % len(re.findall(r"(?<!Chunked)\bencodeBase64\(", after)))
sys.exit(0 if same else 1)
