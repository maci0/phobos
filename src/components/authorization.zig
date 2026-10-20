//! access.* (authorization) API component — Moonraker-compatible.
//!
//! Reference: `vendor/moonraker/moonraker/components/authorization.py`.
//!
//! Endpoints registered (mirrors authorization.py, with the same auth_required
//! flags):
//!
//!   POST            /access/login          → access.login           (auth_required=false)
//!   POST            /access/logout         → access.logout
//!   POST            /access/refresh_jwt    → access.refresh_jwt      (auth_required=false)
//!   GET/POST/DELETE /access/user           → access.user            (RequestType.all())
//!   GET             /access/users/list     → access.users.list
//!   POST            /access/user/password  → access.user.password
//!   GET/POST        /access/api_key        → access.get_api_key, access.post_api_key
//!   GET             /access/oneshot_token  → access.oneshot_token
//!   GET             /access/info           → access.info             (auth_required=false)
//!
//! === CRYPTO / FORMAT PARITY (byte-exact with Moonraker) ===
//!
//! Password hashing (authorization.py `_login_jwt_user`, `_handle_password_reset`):
//!   hashed = pbkdf2_hmac('sha256', password, salt, 100000).hex()
//!   salt   = secrets.token_bytes(32), stored as hex.
//!   HASH_ITER = 100000.  We use std.crypto.pwhash.pbkdf2 with HmacSha256 and
//!   verified byte-exact equality against Python hashlib (see tests).
//!
//! JWT (authorization.py `_generate_jwt` / `decode_jwt`): EdDSA (Ed25519).
//!   header  = {"kid": <jwk_id>, "alg": "EdDSA", "typ": "JWT"}   (insertion order)
//!   payload = {"iss": <issuer>, "aud": "Moonraker", "iat": <t>,
//!              "exp": <t+exp>, "username": <user>, "token_type": <type>}
//!   Both are serialized as COMPACT json (msgspec / json.dumps separators
//!   (",", ":")) then base64url-encoded WITHOUT padding. The signed message is
//!   `base64url(header) "." base64url(payload)`; the Ed25519 signature over that
//!   message is base64url-appended. The Ed25519 secret is stored as a 64-char
//!   hex of the 32-byte seed (libnacl Signer.hex_seed()); we reconstruct the
//!   keypair with KeyPair.generateDeterministic(seed) — standard, interchangeable
//!   with libnacl.
//!
//! API key (authorization.py): uuid4().hex (32 lowercase hex chars), stored in
//!   the user table under the reserved API_USER row's password column.
//!
//! Oneshot token (authorization.py `get_oneshot_token`):
//!   base64.b32encode(os.urandom(20)).decode() → 32-char uppercase RFC4648
//!   base32, single-use, IP-bound, 5-second TTL.
//!
//! Persistence: users are stored in the DataStore namespace "authorized_users"
//!   (Moonraker uses a SQL table; phobos uses the namespaced KV store). Each row
//!   is keyed by username and carries the UserInfo fields.

const std = @import("std");
const webreq = @import("../json/params.zig");
const jv = @import("../json/value.zig");
const registry = @import("../server/registry.zig");
const ds = @import("../store/datastore.zig");
const clock = @import("../util/clock.zig");

const Registry = registry.Registry;
const DataStore = ds.DataStore;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Ed25519 = std.crypto.sign.Ed25519;
const b64url = std.base64.url_safe_no_pad;
const IpAddress = std.Io.net.IpAddress;

/// Parse an IP string (no port) into an `IpAddress`. Mirrors Python's
/// `ipaddress.ip_address`. Returns error on invalid input.
fn parseIp(text: []const u8) !IpAddress {
    return IpAddress.parse(text, 0);
}

// ---------------------------------------------------------------------------
// Constants (mirror authorization.py)
// ---------------------------------------------------------------------------

pub const user_namespace: [:0]const u8 = "authorized_users";
pub const hash_iter: u32 = 100000;
pub const api_user = "_API_KEY_USER_";
pub const trusted_user = "_TRUSTED_USER_";
pub const jwt_audience = "Moonraker";
pub const jwt_exp_seconds: i64 = 3600; // JWT_EXP_TIME = 1 hour
pub const oneshot_timeout_s: i64 = 5; // ONESHOT_TIMEOUT
pub const default_login_timeout_days: i64 = 90; // login_timeout default

pub fn isReservedUser(name: []const u8) bool {
    return std.mem.eql(u8, name, api_user) or std.mem.eql(u8, name, trusted_user);
}

// ---------------------------------------------------------------------------
// Crypto helpers
// ---------------------------------------------------------------------------

/// PBKDF2-HMAC-SHA256 hex digest of `password` with `salt` (raw bytes) over
/// `hash_iter` rounds, as 64 lowercase hex chars. Matches authorization.py.
pub fn hashPassword(password: []const u8, salt: []const u8) [64]u8 {
    var dk: [32]u8 = undefined;
    std.crypto.pwhash.pbkdf2(&dk, password, salt, hash_iter, HmacSha256) catch unreachable;
    return std.fmt.bytesToHex(dk, .lower);
}

/// Constant-time comparison of two equal-or-different-length byte slices.
pub fn constEql(comptime len: usize, a: []const u8, b: []const u8) bool {
    if (a.len != len or b.len != len) return false;
    return std.crypto.timing_safe.eql([len]u8, a[0..len].*, b[0..len].*);
}

/// RFC4648 base32 (upper-case, no padding for 20-byte inputs that align to a
/// 40-bit boundary). Matches Python `base64.b32encode(os.urandom(20))`.
/// 20 bytes → 32 chars exactly (no '=' padding needed).
fn base32Encode(out: []u8, data: []const u8) []const u8 {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    var bit_buf: u64 = 0;
    var bits: u6 = 0;
    var oi: usize = 0;
    for (data) |byte| {
        bit_buf = (bit_buf << 8) | byte;
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            const idx: u5 = @intCast((bit_buf >> bits) & 0x1f);
            out[oi] = alphabet[idx];
            oi += 1;
        }
    }
    if (bits > 0) {
        const idx: u5 = @intCast((bit_buf << (5 - bits)) & 0x1f);
        out[oi] = alphabet[idx];
        oi += 1;
    }
    return out[0..oi];
}

// ---------------------------------------------------------------------------
// JWT
// ---------------------------------------------------------------------------

pub const JwtError = error{
    Malformed,
    InvalidHeader,
    InvalidKeyId,
    BadSignature,
    InvalidClaims,
    TokenTypeMismatch,
    InvalidIssuer,
    InvalidAudience,
    Expired,
    UnknownUser,
    OutOfMemory,
};

pub const TokenType = enum {
    access,
    refresh,

    pub fn str(self: TokenType) []const u8 {
        return switch (self) {
            .access => "access",
            .refresh => "refresh",
        };
    }
};

/// Serialize a JSON object built from ordered (key, value) string/int pairs in a
/// compact form (no whitespace), matching msgspec / json.dumps(separators=(",",
/// ":")). This is byte-exact so JWT signatures interoperate with Moonraker.
const JwtField = union(enum) {
    str: []const u8,
    int: i64,
};

fn writeCompactObject(
    alloc: std.mem.Allocator,
    fields: []const struct { key: []const u8, val: JwtField },
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    var w: std.json.Stringify = .{ .writer = &aw.writer };
    try w.beginObject();
    for (fields) |f| {
        try w.objectField(f.key);
        switch (f.val) {
            .str => |s| try w.write(s),
            .int => |i| try w.write(i),
        }
    }
    try w.endObject();
    return aw.toOwnedSlice();
}

/// Generate a signed JWT for `username` using `jwk_id` and the Ed25519 keypair
/// derived from `seed`. `now` is the current unix time (seconds). The resulting
/// token string is allocated in `alloc`.
pub fn generateJwt(
    alloc: std.mem.Allocator,
    issuer: []const u8,
    username: []const u8,
    jwk_id: []const u8,
    seed: [32]u8,
    token_type: TokenType,
    now: i64,
    exp_seconds: i64,
) ![]const u8 {
    const header_json = try writeCompactObject(alloc, &.{
        .{ .key = "kid", .val = .{ .str = jwk_id } },
        .{ .key = "alg", .val = .{ .str = "EdDSA" } },
        .{ .key = "typ", .val = .{ .str = "JWT" } },
    });
    const payload_json = try writeCompactObject(alloc, &.{
        .{ .key = "iss", .val = .{ .str = issuer } },
        .{ .key = "aud", .val = .{ .str = jwt_audience } },
        .{ .key = "iat", .val = .{ .int = now } },
        .{ .key = "exp", .val = .{ .int = now + exp_seconds } },
        .{ .key = "username", .val = .{ .str = username } },
        .{ .key = "token_type", .val = .{ .str = token_type.str() } },
    });

    const enc_header = try b64urlEncodeAlloc(alloc, header_json);
    const enc_payload = try b64urlEncodeAlloc(alloc, payload_json);

    // Signed message = enc_header "." enc_payload
    const msg = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ enc_header, enc_payload });

    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const sig = try kp.sign(msg, null);
    const enc_sig = try b64urlEncodeAlloc(alloc, &sig.toBytes());

    return std.fmt.allocPrint(alloc, "{s}.{s}", .{ msg, enc_sig });
}

fn b64urlEncodeAlloc(alloc: std.mem.Allocator, data: []const u8) ![]const u8 {
    const out = try alloc.alloc(u8, b64url.Encoder.calcSize(data.len));
    return b64url.Encoder.encode(out, data);
}

fn b64urlDecodeAlloc(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    const n = b64url.Decoder.calcSizeForSlice(data) catch return error.Malformed;
    const out = try alloc.alloc(u8, n);
    b64url.Decoder.decode(out, data) catch return error.Malformed;
    return out;
}

/// The verified claims extracted from a JWT.
pub const JwtClaims = struct {
    username: []const u8,
    jwk_id: []const u8,
    token_type: []const u8,
    iss: []const u8,
    aud: []const u8,
    exp: i64,
    iat: i64,
};

/// Parse and verify a JWT against `public_key`. Validates header (typ/alg), the
/// Ed25519 signature, and the claims (token_type, iss, aud, exp if check_exp).
/// `now` is the current unix time. The caller supplies the public key resolved
/// from the token's `kid`; signature verification is therefore tied to the
/// stored key. All strings borrow from `alloc`-decoded buffers.
pub fn decodeJwt(
    alloc: std.mem.Allocator,
    token: []const u8,
    public_key: Ed25519.PublicKey,
    expected_type: TokenType,
    issuer: []const u8,
    now: i64,
    check_exp: bool,
) JwtError!JwtClaims {
    // Split into header.payload.signature.
    const last_dot = std.mem.lastIndexOfScalar(u8, token, '.') orelse return error.Malformed;
    const message = token[0..last_dot];
    const enc_sig = token[last_dot + 1 ..];
    const first_dot = std.mem.indexOfScalar(u8, message, '.') orelse return error.Malformed;
    const enc_header = message[0..first_dot];
    const enc_payload = message[first_dot + 1 ..];
    if (enc_header.len == 0 or enc_payload.len == 0 or enc_sig.len == 0) return error.Malformed;

    // Decode + verify the signature first (over the raw message bytes).
    const sig_bytes = b64urlDecodeAlloc(alloc, enc_sig) catch return error.Malformed;
    if (sig_bytes.len != Ed25519.Signature.encoded_length) return error.BadSignature;
    var sig_arr: [Ed25519.Signature.encoded_length]u8 = undefined;
    @memcpy(&sig_arr, sig_bytes);
    const sig = Ed25519.Signature.fromBytes(sig_arr);
    sig.verify(message, public_key) catch return error.BadSignature;

    // Decode + validate the header.
    const header_json = b64urlDecodeAlloc(alloc, enc_header) catch return error.Malformed;
    const header = std.json.parseFromSlice(std.json.Value, alloc, header_json, .{}) catch
        return error.InvalidHeader;
    const htyp = jsonStr(header.value, "typ") orelse return error.InvalidHeader;
    const halg = jsonStr(header.value, "alg") orelse return error.InvalidHeader;
    if (!std.mem.eql(u8, htyp, "JWT") or !std.mem.eql(u8, halg, "EdDSA")) return error.InvalidHeader;
    const kid = jsonStr(header.value, "kid") orelse return error.InvalidKeyId;

    // Decode + validate claims.
    const payload_json = b64urlDecodeAlloc(alloc, enc_payload) catch return error.Malformed;
    const payload = std.json.parseFromSlice(std.json.Value, alloc, payload_json, .{}) catch
        return error.InvalidClaims;
    const ttype = jsonStr(payload.value, "token_type") orelse return error.InvalidClaims;
    if (!std.mem.eql(u8, ttype, expected_type.str())) return error.TokenTypeMismatch;
    const iss = jsonStr(payload.value, "iss") orelse return error.InvalidClaims;
    if (!std.mem.eql(u8, iss, issuer)) return error.InvalidIssuer;
    const aud = jsonStr(payload.value, "aud") orelse return error.InvalidClaims;
    if (!std.mem.eql(u8, aud, jwt_audience)) return error.InvalidAudience;
    const exp = jsonInt(payload.value, "exp") orelse return error.InvalidClaims;
    if (check_exp and exp < now) return error.Expired;
    const username = jsonStr(payload.value, "username") orelse return error.InvalidClaims;
    const iat = jsonInt(payload.value, "iat") orelse 0;

    return .{
        .username = username,
        .jwk_id = kid,
        .token_type = ttype,
        .iss = iss,
        .aud = aud,
        .exp = exp,
        .iat = iat,
    };
}

fn jsonStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    return switch (v) {
        .object => |o| switch (o.get(key) orelse return null) {
            .string => |s| s,
            else => null,
        },
        else => null,
    };
}

fn jsonInt(v: std.json.Value, key: []const u8) ?i64 {
    return switch (v) {
        .object => |o| switch (o.get(key) orelse return null) {
            .integer => |i| i,
            .float => |f| jv.floatToInt(f),
            else => null,
        },
        else => null,
    };
}

// ---------------------------------------------------------------------------
// User model
// ---------------------------------------------------------------------------

pub const User = struct {
    username: []const u8,
    /// For local users: 64-char pbkdf2 hex. For the API user: the api key.
    password: []const u8 = "",
    salt: []const u8 = "", // hex of 32-byte salt
    source: []const u8 = "moonraker",
    created_on: f64 = 0,
    /// 64-char hex of the 32-byte Ed25519 seed, or empty when logged out.
    jwt_secret: []const u8 = "",
    jwk_id: []const u8 = "",

    /// Duplicate the *value* fields with `alloc`, leaving `username` borrowing
    /// the caller-supplied owned key (the hashmap key owns the username string).
    fn dupeValues(self: *const User, alloc: std.mem.Allocator, owned_key: []const u8) !User {
        var owned: User = .{ .username = owned_key, .source = "", .created_on = self.created_on };
        errdefer owned.freeValues(alloc);
        inline for (.{ "password", "salt", "source", "jwt_secret", "jwk_id" }) |field| {
            @field(owned, field) = try alloc.dupe(u8, @field(self, field));
        }
        return owned;
    }

    /// Free only the value fields. The username (== hashmap key) is owned and
    /// freed by the map, never here.
    ///
    /// Secret-bearing fields (the pbkdf2/api-key digest in `password`, its
    /// `salt`, and the Ed25519 `jwt_secret` seed) are wiped before release so
    /// the material does not linger in freed heap — this also makes account
    /// deletion a true erasure of the secret, not just a logical unlink.
    fn freeValues(self: *User, alloc: std.mem.Allocator) void {
        std.crypto.secureZero(u8, @constCast(self.password));
        std.crypto.secureZero(u8, @constCast(self.salt));
        std.crypto.secureZero(u8, @constCast(self.jwt_secret));
        alloc.free(self.password);
        alloc.free(self.salt);
        alloc.free(self.source);
        alloc.free(self.jwt_secret);
        alloc.free(self.jwk_id);
    }

    /// DB representation (object). Mirrors the UserInfo columns persisted by
    /// authorization.py (username/password/created_on/salt/source/jwt_secret/jwk_id).
    fn toDbValue(self: *const User, alloc: std.mem.Allocator) !std.json.Value {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(alloc, "username", .{ .string = self.username });
        try obj.put(alloc, "password", .{ .string = self.password });
        try obj.put(alloc, "created_on", .{ .float = self.created_on });
        try obj.put(alloc, "salt", .{ .string = self.salt });
        try obj.put(alloc, "source", .{ .string = self.source });
        if (self.jwt_secret.len > 0) {
            try obj.put(alloc, "jwt_secret", .{ .string = self.jwt_secret });
        } else {
            try obj.put(alloc, "jwt_secret", .null);
        }
        if (self.jwk_id.len > 0) {
            try obj.put(alloc, "jwk_id", .{ .string = self.jwk_id });
        } else {
            try obj.put(alloc, "jwk_id", .null);
        }
        return .{ .object = obj };
    }

    /// Build a User from a DB row. `owned_key` is the hashmap-owned username
    /// string (borrowed as `username`); value fields are duped with `alloc`.
    fn fromDbValue(alloc: std.mem.Allocator, owned_key: []const u8, obj: std.json.ObjectMap) !User {
        const sfield = struct {
            fn f(o: std.json.ObjectMap, k: []const u8) []const u8 {
                const v = o.get(k) orelse return "";
                return switch (v) {
                    .string => |s| s,
                    else => "",
                };
            }
        }.f;
        const ffield = struct {
            fn f(o: std.json.ObjectMap, k: []const u8) f64 {
                const v = o.get(k) orelse return 0;
                return switch (v) {
                    .float => |x| x,
                    .integer => |i| @floatFromInt(i),
                    else => 0,
                };
            }
        }.f;
        const tmpl = User{
            .username = owned_key,
            .password = sfield(obj, "password"),
            .salt = sfield(obj, "salt"),
            .source = blk: {
                const s = sfield(obj, "source");
                break :blk if (s.len == 0) "moonraker" else s;
            },
            .created_on = ffield(obj, "created_on"),
            .jwt_secret = sfield(obj, "jwt_secret"),
            .jwk_id = sfield(obj, "jwk_id"),
        };
        return tmpl.dupeValues(alloc, owned_key);
    }
};

// ---------------------------------------------------------------------------
// Trusted clients config
// ---------------------------------------------------------------------------

pub const TrustedConfig = struct {
    /// Exact IPs (v4/v6) that are trusted.
    ips: []const IpAddress = &.{},
    /// CIDR ranges: (network address, prefix bits).
    ranges: []const Cidr = &.{},

    pub const Cidr = struct {
        addr: IpAddress,
        prefix: u8,
    };

    pub fn isTrusted(self: *const TrustedConfig, ip: IpAddress) bool {
        for (self.ips) |t| {
            if (addrEql(t, ip)) return true;
        }
        for (self.ranges) |r| {
            if (cidrContains(r, ip)) return true;
        }
        return false;
    }
};

/// Raw address bytes (4 for v4, 16 for v6) copied into a fixed buffer plus the
/// active length. Returned by value (no dangling pointers).
const AddrBytes = struct {
    buf: [16]u8 = undefined,
    len: u8,

    fn bytes(self: *const AddrBytes) []const u8 {
        return self.buf[0..self.len];
    }
    fn v4(self: *const AddrBytes) bool {
        return self.len == 4;
    }
};

fn addrBytes(ip: IpAddress) AddrBytes {
    var ab = AddrBytes{ .len = 0 };
    switch (ip) {
        .ip4 => |a| {
            @memcpy(ab.buf[0..4], &a.bytes);
            ab.len = 4;
        },
        .ip6 => |a| {
            @memcpy(ab.buf[0..16], &a.bytes);
            ab.len = 16;
        },
    }
    return ab;
}

fn addrEql(a: IpAddress, b: IpAddress) bool {
    const ba = addrBytes(a);
    const bb = addrBytes(b);
    if (ba.len != bb.len) return false;
    return std.mem.eql(u8, ba.bytes(), bb.bytes());
}

fn cidrContains(cidr: TrustedConfig.Cidr, ip: IpAddress) bool {
    const net = addrBytes(cidr.addr);
    const addr = addrBytes(ip);
    if (net.len != addr.len) return false;
    const total_bits: u16 = @as(u16, net.len) * 8;
    if (cidr.prefix > total_bits) return false;
    const nb = net.bytes();
    const ib = addr.bytes();
    var bits = cidr.prefix;
    var i: usize = 0;
    while (bits >= 8) : (bits -= 8) {
        if (nb[i] != ib[i]) return false;
        i += 1;
    }
    if (bits > 0) {
        const shift: u3 = @intCast(8 - bits);
        const mask: u8 = (~@as(u8, 0)) << shift;
        if ((nb[i] & mask) != (ib[i] & mask)) return false;
    }
    return true;
}

/// Parse a trusted_clients entry. Returns a single IP, a CIDR range, or error
/// (domains are not resolved in phobos; they are skipped by the caller).
pub const TrustedEntry = union(enum) {
    ip: IpAddress,
    cidr: TrustedConfig.Cidr,
    domain: void,
};

/// A CIDR with a prefix longer than the address or with host bits set
/// (`192.168.1.5/24`) is `error.InvalidEntry`, as Python `ip_network` rejects it.
pub fn parseTrustedEntry(val: []const u8) !TrustedEntry {
    if (std.mem.indexOfScalar(u8, val, '/')) |slash| {
        const addr_s = val[0..slash];
        const prefix = std.fmt.parseInt(u8, val[slash + 1 ..], 10) catch return error.InvalidEntry;
        const addr = parseIp(addr_s) catch return error.InvalidEntry;
        const ab = addrBytes(addr);
        if (prefix > @as(u16, ab.len) * 8) return error.InvalidEntry;
        for (ab.bytes(), 0..) |b, i| {
            const kept = @min(8, prefix -| i * 8);
            const host_mask: u8 = if (kept == 8) 0 else @as(u8, 0xff) >> @intCast(kept);
            if (b & host_mask != 0) return error.InvalidEntry;
        }
        return .{ .cidr = .{ .addr = addr, .prefix = prefix } };
    }
    if (parseIp(val)) |addr| {
        return .{ .ip = addr };
    } else |_| {}
    return .{ .domain = {} };
}

// ---------------------------------------------------------------------------
// Oneshot tokens
// ---------------------------------------------------------------------------

const OneshotToken = struct {
    token: [32]u8,
    ip: IpAddress,
    username: []const u8, // owned
    expires_at: i64,
};

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

pub const AuthCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    store: DataStore,
    /// Issuer string ("http://<hostname>:<port>"). Owned externally.
    issuer: []const u8,
    /// In-memory user table, keyed by username (owned strings).
    users: std.StringHashMapUnmanaged(User) = .{},
    /// The current API key (also stored as the API user's password).
    api_key: [32]u8 = undefined,
    enable_api_key: bool = true,
    force_logins: bool = false,
    default_source: []const u8 = "moonraker",
    login_timeout_days: i64 = default_login_timeout_days,
    trusted: TrustedConfig = .{},
    /// True when `trusted.ips` / `trusted.ranges` were allocated by
    /// `setTrustedClients` and must be freed in `deinit`.
    trusted_owned: bool = false,
    oneshot: std.ArrayList(OneshotToken) = .empty,
    /// Guards `users`, `api_key` and `oneshot` after startup: connection tasks
    /// authenticate outside Core while access.* handlers mutate under Core.
    /// Leaf lock: never acquire Core or another lock while holding it.
    mutex: std.Io.Mutex = .init,

    pub fn init(alloc: std.mem.Allocator, io: std.Io, store: DataStore, issuer: []const u8) !AuthCtx {
        var ctx = AuthCtx{
            .gpa = alloc,
            .io = io,
            .store = store,
            .issuer = issuer,
        };
        // Generate a fresh api key by default (uuid4().hex equivalent: 32 hex).
        var raw: [16]u8 = undefined;
        try io.randomSecure(&raw);
        ctx.api_key = std.fmt.bytesToHex(raw, .lower);
        ctx.loadFromStore() catch {};
        ctx.ensureApiUser() catch {};
        return ctx;
    }

    pub fn deinit(self: *AuthCtx) void {
        var it = self.users.iterator();
        while (it.next()) |e| {
            e.value_ptr.freeValues(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.users.deinit(self.gpa);
        for (self.oneshot.items) |*t| {
            std.crypto.secureZero(u8, &t.token);
            self.gpa.free(t.username);
        }
        self.oneshot.deinit(self.gpa);
        if (self.trusted_owned) {
            self.gpa.free(self.trusted.ips);
            self.gpa.free(self.trusted.ranges);
        }
        std.crypto.secureZero(u8, &self.api_key);
    }

    /// Replace the trusted-client table from a Moonraker `trusted_clients`
    /// list (whitespace or comma separated). `0.0.0.0/0` matches every IPv4
    /// address. Domains are skipped (phobos does not resolve them).
    pub fn setTrustedClients(self: *AuthCtx, raw: []const u8) !void {
        var ips: std.ArrayList(IpAddress) = .empty;
        errdefer ips.deinit(self.gpa);
        var ranges: std.ArrayList(TrustedConfig.Cidr) = .empty;
        errdefer ranges.deinit(self.gpa);
        var it = std.mem.tokenizeAny(u8, raw, " \t\r\n,");
        while (it.next()) |entry| {
            const parsed = parseTrustedEntry(entry) catch {
                std.debug.print("phobos: warning: [authorization]: invalid trusted_clients entry '{s}' skipped\n", .{entry});
                continue;
            };
            switch (parsed) {
                .ip => |ip| try ips.append(self.gpa, ip),
                .cidr => |cidr| try ranges.append(self.gpa, cidr),
                .domain => {},
            }
        }
        const ip_slice = try ips.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(ip_slice);
        const range_slice = try ranges.toOwnedSlice(self.gpa);
        if (self.trusted_owned) {
            self.gpa.free(self.trusted.ips);
            self.gpa.free(self.trusted.ranges);
        }
        self.trusted = .{ .ips = ip_slice, .ranges = range_slice };
        self.trusted_owned = true;
    }

    fn loadFromStore(self: *AuthCtx) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const ns_data = self.store.getNamespace(a, user_namespace) catch return;
        if (ns_data != .object) return;
        var it = ns_data.object.iterator();
        while (it.next()) |e| {
            const username = e.key_ptr.*;
            if (e.value_ptr.* != .object) continue;
            const key_owned = self.gpa.dupe(u8, username) catch continue;
            const u = User.fromDbValue(self.gpa, key_owned, e.value_ptr.object) catch {
                self.gpa.free(key_owned);
                continue;
            };
            self.users.put(self.gpa, key_owned, u) catch {
                var uu = u;
                uu.freeValues(self.gpa);
                self.gpa.free(key_owned);
                continue;
            };
            // Adopt the persisted api key if the API user already exists.
            if (std.mem.eql(u8, username, api_user) and u.password.len == self.api_key.len) {
                @memcpy(&self.api_key, u.password);
            }
        }
    }

    fn ensureApiUser(self: *AuthCtx) !void {
        if (self.users.getPtr(api_user) != null) return;
        const u = User{
            .username = api_user,
            .password = &self.api_key,
            .created_on = nowSeconds(self.io),
        };
        try self.putUser(u);
        self.syncUser(api_user);
    }

    /// Insert or replace a user. The map key owns the username string; the
    /// value's fields are duped with the gpa. On replace the old value fields
    /// are freed while the owned key is preserved.
    fn putUser(self: *AuthCtx, template: User) !void {
        const gop = try self.users.getOrPut(self.gpa, template.username);
        if (gop.found_existing) {
            const key = gop.key_ptr.*;
            // Dupe BEFORE freeing the old value, so a template that borrows the
            // existing user's fields is not used-after-free.
            const new_val = try template.dupeValues(self.gpa, key);
            gop.value_ptr.freeValues(self.gpa);
            gop.value_ptr.* = new_val;
        } else {
            const key = self.gpa.dupe(u8, template.username) catch |err| {
                _ = self.users.remove(template.username);
                return err;
            };
            gop.key_ptr.* = key;
            gop.value_ptr.* = template.dupeValues(self.gpa, key) catch |err| {
                _ = self.users.remove(key);
                self.gpa.free(key);
                return err;
            };
        }
    }

    /// Persist a single user row to the DataStore.
    fn syncUser(self: *AuthCtx, username: []const u8) void {
        const u = self.users.getPtr(username) orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const val = u.toDbValue(a) catch return;
        self.store.insertItem(a, user_namespace, username, val) catch |err|
            std.debug.print("phobos: warning: failed to persist user '{s}': {} — change will be lost on restart\n", .{ username, err });
    }

    fn deleteUserFromStore(self: *AuthCtx, username: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        _ = self.store.deleteItem(a, user_namespace, username) catch |err|
            std.debug.print("phobos: warning: failed to delete user '{s}' from store: {} — user may reappear on restart\n", .{ username, err });
    }

    /// Resolve the public key for a kid by searching users for a matching jwk_id.
    fn publicKeyForKid(self: *AuthCtx, kid: []const u8) ?Ed25519.PublicKey {
        var it = self.users.iterator();
        while (it.next()) |e| {
            const u = e.value_ptr;
            if (u.jwk_id.len == 0 or u.jwt_secret.len != 64) continue;
            if (!std.mem.eql(u8, u.jwk_id, kid)) continue;
            var seed: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&seed, u.jwt_secret) catch continue;
            const kp = Ed25519.KeyPair.generateDeterministic(seed) catch continue;
            return kp.public_key;
        }
        return null;
    }

    /// Prune expired oneshot tokens at `now`.
    fn pruneOneshot(self: *AuthCtx, now: i64) void {
        var i: usize = 0;
        while (i < self.oneshot.items.len) {
            if (self.oneshot.items[i].expires_at < now) {
                self.gpa.free(self.oneshot.items[i].username);
                _ = self.oneshot.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Create and store a oneshot token bound to `ip` and `username`. Caller
    /// holds `mutex`.
    fn createOneshot(self: *AuthCtx, ip: IpAddress, username: []const u8, now: i64) ![32]u8 {
        self.pruneOneshot(now);
        var raw: [20]u8 = undefined;
        try self.io.randomSecure(&raw);
        var entry = OneshotToken{
            .token = undefined,
            .ip = ip,
            .username = try self.gpa.dupe(u8, username),
            .expires_at = now + oneshot_timeout_s,
        };
        errdefer self.gpa.free(entry.username);
        _ = base32Encode(&entry.token, &raw);
        try self.oneshot.append(self.gpa, entry);
        return entry.token;
    }

    /// Consume a oneshot token (single-use). Returns the bound username duped
    /// into `alloc` when the token exists, is unexpired and the IP matches.
    /// Caller holds `mutex`.
    fn consumeOneshot(self: *AuthCtx, alloc: std.mem.Allocator, token: []const u8, ip: IpAddress, now: i64) ?[]const u8 {
        self.pruneOneshot(now);
        var i: usize = 0;
        while (i < self.oneshot.items.len) : (i += 1) {
            const t = &self.oneshot.items[i];
            if (std.mem.eql(u8, &t.token, token)) {
                const matches = addrEql(t.ip, ip);
                const uname = t.username; // gpa-owned by the oneshot entry
                _ = self.oneshot.swapRemove(i);
                defer self.gpa.free(uname);
                if (!matches) return null;
                return alloc.dupe(u8, uname) catch null;
            }
        }
        return null;
    }
};

fn nowSeconds(io: std.Io) f64 {
    return clock.wallSeconds(io);
}

fn nowSecondsInt(io: std.Io) i64 {
    return clock.wallSecondsInt(io);
}

// ---------------------------------------------------------------------------
// Param helpers
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Login / user creation core
// ---------------------------------------------------------------------------

pub const AuthError = error{
    InvalidParams,
    InvalidPassword,
    UserExists,
    UnknownUser,
    ReservedUser,
    InvalidSource,
    Unauthorized,
    OutOfMemory,
    Forbidden,
    NotFound,
};

/// Shared login/create logic. Returns a JSON object
/// {username, token, source, refresh_token, action}.
fn loginOrCreate(
    c: *AuthCtx,
    params: std.json.Value,
    alloc: std.mem.Allocator,
    new_user: bool,
) anyerror!std.json.Value {
    const username = webreq.required([]const u8, params, "username") catch return error.InvalidParams;
    const password = webreq.required([]const u8, params, "password") catch return error.InvalidParams;
    const source_in = (try webreq.optional([]const u8, params, "source")) orelse c.default_source;
    // Lowercase the source.
    var src_buf: [32]u8 = undefined;
    const source = std.ascii.lowerString(src_buf[0..@min(source_in.len, src_buf.len)], source_in[0..@min(source_in.len, src_buf.len)]);
    if (!std.mem.eql(u8, source, "moonraker")) return error.InvalidSource;
    if (isReservedUser(username)) return error.ReservedUser;

    if (new_user) {
        if (c.users.getPtr(username) != null) return error.UserExists;
        var salt: [32]u8 = undefined;
        try c.io.randomSecure(&salt);
        const salt_hex = std.fmt.bytesToHex(salt, .lower);
        const hashed = hashPassword(password, &salt);
        const u = User{
            .username = username,
            .password = &hashed,
            .salt = &salt_hex,
            .source = "moonraker",
            .created_on = nowSeconds(c.io),
        };
        try c.putUser(u);
        c.syncUser(username);
    } else {
        const u = c.users.getPtr(username) orelse return error.UnknownUser;
        if (!std.mem.eql(u8, u.source, source)) return error.Unauthorized;
        // Verify password.
        var salt: [32]u8 = undefined;
        const salt_bytes = std.fmt.hexToBytes(&salt, u.salt) catch return error.InvalidPassword;
        const hashed = hashPassword(password, salt_bytes);
        if (!constEql(64, &hashed, u.password)) return error.InvalidPassword;
    }

    return issueTokens(c, alloc, username, new_user);
}

/// Ensure the user has an Ed25519 keypair (jwt_secret/jwk_id), generating one
/// on login if absent, then mint access + refresh tokens.
fn issueTokens(
    c: *AuthCtx,
    alloc: std.mem.Allocator,
    username: []const u8,
    new_user: bool,
) anyerror!std.json.Value {
    const u = c.users.getPtr(username) orelse return error.UnknownUser;

    var seed: [32]u8 = undefined;
    var jwk_id_buf: [64]u8 = undefined;
    var jwk_id: []const u8 = undefined;

    // jwk_id must outlive token generation; back it with a heap copy when newly
    // generated, or borrow the stored one.
    var jwk_owned: ?[]const u8 = null;

    if (u.jwt_secret.len == 64) {
        _ = std.fmt.hexToBytes(&seed, u.jwt_secret) catch return error.Unauthorized;
        if (u.jwk_id.len == 0) {
            var rnd: [32]u8 = undefined;
            try c.io.randomSecure(&rnd);
            const new_kid = b64url.Encoder.encode(&jwk_id_buf, &rnd);
            var tmpl = u.*;
            tmpl.jwk_id = new_kid;
            try c.putUser(tmpl);
            c.syncUser(username);
            jwk_owned = try alloc.dupe(u8, new_kid);
            jwk_id = jwk_owned.?;
        } else {
            jwk_id = try alloc.dupe(u8, u.jwk_id);
        }
    } else {
        try c.io.randomSecure(&seed);
        const secret_hex = std.fmt.bytesToHex(seed, .lower);
        var rnd: [32]u8 = undefined;
        try c.io.randomSecure(&rnd);
        const new_kid = b64url.Encoder.encode(&jwk_id_buf, &rnd);
        var tmpl = u.*;
        tmpl.jwt_secret = &secret_hex;
        tmpl.jwk_id = new_kid;
        try c.putUser(tmpl);
        c.syncUser(username);
        jwk_id = try alloc.dupe(u8, new_kid);
    }

    const now = nowSecondsInt(c.io);
    const token = try generateJwt(alloc, c.issuer, username, jwk_id, seed, .access, now, jwt_exp_seconds);
    const refresh = try generateJwt(alloc, c.issuer, username, jwk_id, seed, .refresh, now, c.login_timeout_days * 24 * 3600);

    const src = c.users.getPtr(username).?.source;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "username", .{ .string = try alloc.dupe(u8, username) });
    try obj.put(alloc, "token", .{ .string = token });
    try obj.put(alloc, "source", .{ .string = try alloc.dupe(u8, src) });
    try obj.put(alloc, "refresh_token", .{ .string = refresh });
    try obj.put(alloc, "action", .{ .string = if (new_user) "user_created" else "user_logged_in" });
    return .{ .object = obj };
}

// ---------------------------------------------------------------------------
// Handlers — opaque-ctx entry points (registry signature)
// ---------------------------------------------------------------------------

fn ctxOf(ptr: *anyopaque) *AuthCtx {
    return @ptrCast(@alignCast(ptr));
}

/// POST /access/login
pub fn handleLogin(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c = ctxOf(ctx);
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    return loginOrCreate(c, params, alloc, false);
}

/// POST /access/logout
pub fn handleLogout(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c = ctxOf(ctx);
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    // Only the authenticated user can log out (Moonraker has no username param).
    const username = currentUser(params) orelse return error.NotFound;
    if (isReservedUser(username)) return error.Forbidden;
    const u = c.users.getPtr(username) orelse return error.NotFound;
    // Clear the keypair → invalidates outstanding JWTs.
    var tmpl = u.*;
    tmpl.jwt_secret = "";
    tmpl.jwk_id = "";
    try c.putUser(tmpl);
    c.syncUser(username);

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "username", .{ .string = try alloc.dupe(u8, username) });
    try obj.put(alloc, "action", .{ .string = "user_logged_out" });
    return .{ .object = obj };
}

/// POST /access/refresh_jwt
pub fn handleRefreshJwt(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c = ctxOf(ctx);
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    const refresh_token = webreq.required([]const u8, params, "refresh_token") catch return error.InvalidParams;

    // Resolve kid → public key, verify the refresh token.
    const kid = jwtKid(alloc, refresh_token) orelse return error.Unauthorized;
    const pk = c.publicKeyForKid(kid) orelse return error.Unauthorized;
    const claims = decodeJwt(alloc, refresh_token, pk, .refresh, c.issuer, nowSecondsInt(c.io), true) catch
        return error.Unauthorized;

    const u = c.users.getPtr(claims.username) orelse return error.Unauthorized;
    if (u.jwt_secret.len != 64 or u.jwk_id.len == 0) return error.Unauthorized;

    var seed: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&seed, u.jwt_secret) catch return error.Unauthorized;
    const now = nowSecondsInt(c.io);
    const token = try generateJwt(alloc, c.issuer, claims.username, u.jwk_id, seed, .access, now, jwt_exp_seconds);

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "username", .{ .string = try alloc.dupe(u8, claims.username) });
    try obj.put(alloc, "token", .{ .string = token });
    try obj.put(alloc, "source", .{ .string = try alloc.dupe(u8, u.source) });
    try obj.put(alloc, "action", .{ .string = "user_jwt_refresh" });
    return .{ .object = obj };
}

/// GET /access/info
pub fn handleInfo(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c = ctxOf(ctx);
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "default_source", .{ .string = try alloc.dupe(u8, c.default_source) });
    var sources: std.json.Array = .init(alloc);
    try sources.append(.{ .string = "moonraker" });
    try obj.put(alloc, "available_sources", .{ .array = sources });
    const login_req = c.force_logins and c.users.count() > 1;
    try obj.put(alloc, "login_required", .{ .bool = login_req });
    // trusted: bool, matching Moonraker's _handle_info_request.
    //   True if user is TRUSTED_USER sentinel
    //   bool result of _check_authorized_ip if an IP is present
    //   false otherwise (no user, no IP)
    const trusted: bool = blk: {
        if (currentUser(params)) |user| {
            if (std.mem.eql(u8, user, trusted_user)) break :blk true;
        }
        if (currentIp(params)) |ip| {
            break :blk c.trusted.isTrusted(ip);
        }
        break :blk false;
    };
    try obj.put(alloc, "trusted", .{ .bool = trusted });
    return .{ .object = obj };
}

/// GET/POST/DELETE /access/user
pub fn handleUserGet(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c = ctxOf(ctx);
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    const username = currentUser(params);
    var obj: std.json.ObjectMap = .empty;
    if (username) |name| {
        const u = c.users.getPtr(name);
        if (u) |info| {
            try obj.put(alloc, "username", .{ .string = try alloc.dupe(u8, info.username) });
            try obj.put(alloc, "source", .{ .string = try alloc.dupe(u8, info.source) });
            try obj.put(alloc, "created_on", .{ .float = info.created_on });
            return .{ .object = obj };
        }
        // _TRUSTED_USER_ sentinel: not in the users table but authenticated
        // via trusted IP. Return the sentinel with minimal info matching
        // Moonraker's behavior for trusted unauthenticated connections.
        if (std.mem.eql(u8, name, trusted_user)) {
            try obj.put(alloc, "username", .{ .string = trusted_user });
            try obj.put(alloc, "source", .{ .string = "moonraker" });
            try obj.put(alloc, "created_on", .{ .float = nowSeconds(c.io) });
            return .{ .object = obj };
        }
    }
    try obj.put(alloc, "username", .null);
    try obj.put(alloc, "source", .null);
    try obj.put(alloc, "created_on", .null);
    return .{ .object = obj };
}

pub fn handleUserPost(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c = ctxOf(ctx);
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    return loginOrCreate(c, params, alloc, true);
}

pub fn handleUserDelete(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c = ctxOf(ctx);
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    const username = webreq.required([]const u8, params, "username") catch return error.InvalidParams;
    if (currentUser(params)) |cur| {
        if (std.mem.eql(u8, cur, username)) return error.Forbidden;
    }
    if (isReservedUser(username)) return error.Forbidden;
    const entry = c.users.getEntry(username) orelse return error.NotFound;
    const key = entry.key_ptr.*;
    entry.value_ptr.freeValues(c.gpa);
    _ = c.users.remove(username);
    c.gpa.free(key);
    c.deleteUserFromStore(username);

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "username", .{ .string = try alloc.dupe(u8, username) });
    try obj.put(alloc, "action", .{ .string = "user_deleted" });
    return .{ .object = obj };
}

/// GET /access/users/list
pub fn handleUsersList(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c = ctxOf(ctx);
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    _ = params;
    var arr: std.json.Array = .init(alloc);
    var it = c.users.iterator();
    while (it.next()) |e| {
        const u = e.value_ptr;
        if (std.mem.eql(u8, u.username, api_user)) continue;
        var uobj: std.json.ObjectMap = .empty;
        try uobj.put(alloc, "username", .{ .string = try alloc.dupe(u8, u.username) });
        try uobj.put(alloc, "source", .{ .string = try alloc.dupe(u8, u.source) });
        try uobj.put(alloc, "created_on", .{ .float = u.created_on });
        try arr.append(.{ .object = uobj });
    }
    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "users", .{ .array = arr });
    return .{ .object = obj };
}

/// POST /access/user/password
pub fn handlePasswordReset(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c = ctxOf(ctx);
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    const password = webreq.required([]const u8, params, "password") catch return error.InvalidParams;
    const new_password = webreq.required([]const u8, params, "new_password") catch return error.InvalidParams;
    const username = currentUser(params) orelse return error.NotFound;
    if (isReservedUser(username)) return error.Forbidden;
    const u = c.users.getPtr(username) orelse return error.NotFound;

    var salt: [32]u8 = undefined;
    const salt_bytes = std.fmt.hexToBytes(&salt, u.salt) catch return error.InvalidParams;
    const cur_hash = hashPassword(password, salt_bytes);
    if (!constEql(64, &cur_hash, u.password)) return error.Forbidden;

    const new_hash = hashPassword(new_password, salt_bytes);
    var tmpl = u.*;
    tmpl.password = &new_hash;
    try c.putUser(tmpl);
    c.syncUser(username);

    var obj: std.json.ObjectMap = .empty;
    try obj.put(alloc, "username", .{ .string = try alloc.dupe(u8, username) });
    try obj.put(alloc, "action", .{ .string = "user_password_reset" });
    return .{ .object = obj };
}

/// GET /access/api_key  → returns the current api key string.
pub fn handleGetApiKey(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c = ctxOf(ctx);
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    _ = params;
    return .{ .string = try alloc.dupe(u8, &c.api_key) };
}

/// POST /access/api_key → regenerate and return the new api key.
pub fn handlePostApiKey(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c = ctxOf(ctx);
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    _ = params;
    var raw: [16]u8 = undefined;
    try c.io.randomSecure(&raw);
    c.api_key = std.fmt.bytesToHex(raw, .lower);
    // Update the API user's password.
    if (c.users.getPtr(api_user)) |u| {
        var tmpl = u.*;
        tmpl.password = &c.api_key;
        try c.putUser(tmpl);
        c.syncUser(api_user);
    }
    return .{ .string = try alloc.dupe(u8, &c.api_key) };
}

/// GET /access/oneshot_token → mint a single-use token bound to the caller IP.
pub fn handleOneshot(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    const c = ctxOf(ctx);
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    const ip = currentIp(params) orelse parseIp("127.0.0.1") catch unreachable;
    const username = currentUser(params) orelse api_user;
    const tok = try c.createOneshot(ip, username, nowSecondsInt(c.io));
    return .{ .string = try alloc.dupe(u8, &tok) };
}

// ---------------------------------------------------------------------------
// Request-context injection helpers
//
// The HTTP/WS transport injects the resolved current user and remote IP into
// the params object under reserved keys before invoking the handler. These
// helpers extract them. Absent → null (e.g. unauthenticated GET /access/user).
// ---------------------------------------------------------------------------

pub const current_user_key = "_current_user";
pub const current_ip_key = "_remote_ip";

fn currentUser(params: std.json.Value) ?[]const u8 {
    return switch (params) {
        .object => |o| switch (o.get(current_user_key) orelse return null) {
            .string => |s| if (s.len == 0) null else s,
            else => null,
        },
        else => null,
    };
}

fn currentIp(params: std.json.Value) ?IpAddress {
    const s = switch (params) {
        .object => |o| switch (o.get(current_ip_key) orelse return null) {
            .string => |str| str,
            else => return null,
        },
        else => return null,
    };
    return parseIp(s) catch null;
}

/// Extract the kid from a token's header without verifying the signature.
fn jwtKid(alloc: std.mem.Allocator, token: []const u8) ?[]const u8 {
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    const enc_header = token[0..first_dot];
    const header_json = b64urlDecodeAlloc(alloc, enc_header) catch return null;
    const header = std.json.parseFromSlice(std.json.Value, alloc, header_json, .{}) catch return null;
    return jsonStr(header.value, "kid");
}

// ---------------------------------------------------------------------------
// authenticateRequest — backs the transport auth hook
// ---------------------------------------------------------------------------

pub const AuthOutcome = union(enum) {
    /// Authenticated as this username (static, or in the request allocator).
    user: []const u8,
    /// No credentials but the endpoint does not require auth.
    anonymous: void,
    /// Authentication required and not satisfied.
    unauthorized: void,
};

pub const RequestCreds = struct {
    /// "Authorization: Bearer <jwt>" / "X-Access-Token" / "?access_token=".
    jwt: ?[]const u8 = null,
    /// "?token=" oneshot token.
    oneshot: ?[]const u8 = null,
    /// "X-Api-Key" header.
    api_key: ?[]const u8 = null,
    /// Client IP used for trusted-client checks. When `use_xheaders` rewrites
    /// the peer, this is the forwarded client, not the socket.
    remote_ip: ?[]const u8 = null,
    /// Socket peer when it differs from `remote_ip` (the request was proxied).
    /// Moonraker rejects the request unless this address is a trusted client.
    proxy_ip: ?[]const u8 = null,
};

/// Result of applying Tornado's `xheaders` rewrite. `proxy` is the socket peer
/// when the client address came from `X-Forwarded-For` or `X-Real-Ip`.
pub const ClientAddr = struct {
    client: []const u8,
    proxy: ?[]const u8 = null,
};

fn lastForwardedHop(xff: []const u8) []const u8 {
    var last: []const u8 = "";
    var it = std.mem.splitScalar(u8, xff, ',');
    while (it.next()) |part| {
        const hop = std.mem.trim(u8, part, " \t");
        if (hop.len > 0) last = hop;
    }
    return last;
}

/// `use_xheaders` false keeps the socket peer. True matches Tornado: the last
/// `X-Forwarded-For` hop wins, then `X-Real-Ip` overwrites it. The socket peer
/// is reported as the proxy only when the client address actually changed.
pub fn resolveClientAddr(socket_peer: []const u8, x_real_ip: ?[]const u8, x_forwarded_for: ?[]const u8, use_xheaders: bool) ClientAddr {
    if (!use_xheaders) return .{ .client = socket_peer };
    var client = socket_peer;
    if (x_forwarded_for) |xff| {
        const hop = lastForwardedHop(xff);
        if (hop.len > 0) client = hop;
    }
    if (x_real_ip) |rip| {
        const trimmed = std.mem.trim(u8, rip, " \t");
        if (trimmed.len > 0) client = trimmed;
    }
    if (std.mem.eql(u8, client, socket_peer)) return .{ .client = socket_peer };
    return .{ .client = client, .proxy = socket_peer };
}

/// User named by a valid access JWT, or null. The name lives in `alloc`.
/// Caller holds `c.mutex`.
fn jwtUser(c: *AuthCtx, alloc: std.mem.Allocator, token: []const u8, now: i64, check_exp: bool) ?[]const u8 {
    const kid = jwtKid(alloc, token) orelse return null;
    const pk = c.publicKeyForKid(kid) orelse return null;
    const claims = decodeJwt(alloc, token, pk, .access, c.issuer, now, check_exp) catch return null;
    if (c.users.getPtr(claims.username) == null) return null;
    return claims.username;
}

/// Moonraker `validate_jwt`: the user named by a valid access JWT, duped into
/// `alloc`, or null.
pub fn validateJwt(c: *AuthCtx, alloc: std.mem.Allocator, token: []const u8) ?[]const u8 {
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    return jwtUser(c, alloc, token, nowSecondsInt(c.io), true);
}

/// Moonraker `validate_api_key`: true when API keys are enabled and `key`
/// matches.
pub fn validateApiKey(c: *AuthCtx, key: []const u8) bool {
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    return c.enable_api_key and constEql(32, key, &c.api_key);
}

/// Authentication chain, mirroring authorization.py `authenticate_request`:
/// JWT → oneshot → API key → trusted IP → fail. `transport == INTERNAL`
/// bypasses. `auth_required` gates the final fall-through. A returned user
/// name is static or lives in `alloc`.
pub fn authenticateRequest(
    c: *AuthCtx,
    alloc: std.mem.Allocator,
    transport: registry.TransportType,
    creds: RequestCreds,
    auth_required: bool,
) AuthOutcome {
    if (transport == .INTERNAL) return .{ .anonymous = {} };
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);

    const now = nowSecondsInt(c.io);

    // 1) JWT. A malformed or invalid JWT is an explicit failure in Moonraker.
    if (creds.jwt) |raw| {
        const token = stripBearer(raw);
        if (token.len > 0) {
            const user = jwtUser(c, alloc, token, now, auth_required) orelse return .{ .unauthorized = {} };
            return .{ .user = user };
        }
    }

    // 2) Oneshot token
    if (creds.oneshot) |tok| {
        if (creds.remote_ip) |ip_s| {
            if (parseIp(ip_s)) |ip| {
                if (c.consumeOneshot(alloc, tok, ip, now)) |uname| {
                    return .{ .user = uname };
                }
            } else |_| {}
        }
    }

    // 3) API key header. A non-empty wrong key is 401 and does not fall
    // through to trusted-IP auth (Moonraker validate_api_key). A blank key,
    // or a key sent while API-key auth is disabled, is ignored.
    if (creds.api_key) |raw| {
        const key = std.mem.trim(u8, raw, " \t");
        if (key.len > 0 and c.enable_api_key) {
            if (constEql(32, key, &c.api_key)) return .{ .user = api_user };
            return .{ .unauthorized = {} };
        }
    }

    // force_logins: trusted-user auth disabled once a real user exists.
    if (c.force_logins and c.users.count() > 1) {
        if (!auth_required) return .{ .anonymous = {} };
        return .{ .unauthorized = {} };
    }

    // 4) Trusted IP. A rewritten client is accepted only when the socket peer
    // (the proxy) is itself a trusted client. Moonraker: `_check_trusted_proxy`.
    // A request without a client address is never trusted.
    if (creds.remote_ip) |ip_s| {
        if (parseIp(ip_s)) |ip| {
            if (c.trusted.isTrusted(ip)) {
                if (auth_required) {
                    if (creds.proxy_ip) |pip| {
                        if (parseIp(pip)) |proxy| {
                            if (!c.trusted.isTrusted(proxy)) return .{ .unauthorized = {} };
                        } else |_| return .{ .unauthorized = {} };
                    }
                }
                return .{ .user = trusted_user };
            }
        } else |_| {}
    }

    if (!auth_required) return .{ .anonymous = {} };
    return .{ .unauthorized = {} };
}

fn stripBearer(raw: []const u8) []const u8 {
    const prefix = "Bearer ";
    if (std.mem.startsWith(u8, raw, prefix)) return raw[prefix.len..];
    return raw;
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerAuthorization(reg: *Registry, ctx: *AuthCtx) !void {
    const c: *anyopaque = @ptrCast(ctx);

    try reg.registerEndpoint(
        .{ .path = "/access/login", .methods = &.{.POST}, .auth_required = false },
        c,
        handleLogin,
    );
    try reg.registerEndpoint(
        .{ .path = "/access/logout", .methods = &.{.POST} },
        c,
        handleLogout,
    );
    try reg.registerEndpoint(
        .{ .path = "/access/refresh_jwt", .methods = &.{.POST}, .auth_required = false },
        c,
        handleRefreshJwt,
    );

    // /access/user — Moonraker verb-prefixes the trio: access.get_user /
    // post_user / delete_user (Fluidd calls these over WS). multi_verb on each.
    try reg.registerEndpoint(
        .{ .path = "/access/user", .methods = &.{.GET}, .multi_verb = true },
        c,
        handleUserGet,
    );
    try reg.registerEndpoint(
        .{ .path = "/access/user", .methods = &.{.POST}, .multi_verb = true },
        c,
        handleUserPost,
    );
    try reg.registerEndpoint(
        .{ .path = "/access/user", .methods = &.{.DELETE}, .multi_verb = true },
        c,
        handleUserDelete,
    );

    try reg.registerEndpoint(
        .{ .path = "/access/users/list", .methods = &.{.GET} },
        c,
        handleUsersList,
    );
    try reg.registerEndpoint(
        .{ .path = "/access/user/password", .methods = &.{.POST} },
        c,
        handlePasswordReset,
    );

    // /access/api_key — GET+POST → multi-verb → access.get_api_key / access.post_api_key.
    try reg.registerEndpoint(
        .{ .path = "/access/api_key", .methods = &.{ .GET, .POST } },
        c,
        handleApiKeyDispatch,
    );

    try reg.registerEndpoint(
        .{ .path = "/access/oneshot_token", .methods = &.{.GET} },
        c,
        handleOneshot,
    );
    try reg.registerEndpoint(
        .{ .path = "/access/info", .methods = &.{.GET}, .auth_required = false },
        c,
        handleInfo,
    );
}

/// Multi-verb dispatcher for /access/api_key (GET vs POST share a handler slot
/// in the registry; we distinguish by the injected request type). When the
/// transport injects no method hint we default to GET semantics (read).
pub fn handleApiKeyDispatch(ctx: *anyopaque, params: std.json.Value, alloc: std.mem.Allocator) anyerror!std.json.Value {
    // The transport injects "_method" = "POST" for regeneration. Absent → GET.
    const is_post = switch (params) {
        .object => |o| switch (o.get("_method") orelse std.json.Value{ .null = {} }) {
            .string => |s| std.ascii.eqlIgnoreCase(s, "POST"),
            else => false,
        },
        else => false,
    };
    if (is_post) return handlePostApiKey(ctx, params, alloc);
    return handleGetApiKey(ctx, params, alloc);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

// --- In-memory store (no real backend) ---

const MemStore = struct {
    alloc: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(std.json.Value) = .{},

    fn init(alloc: std.mem.Allocator) MemStore {
        return .{ .alloc = alloc };
    }
    fn deinit(self: *MemStore) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.map.deinit(self.alloc);
    }
    fn vtGetItem(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8) ds.Error!?std.json.Value {
        return null;
    }
    fn vtInsertItem(ctx: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, key: []const u8, value: std.json.Value) ds.Error!void {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        const gop = self.map.getOrPut(self.alloc, key) catch return ds.Error.OutOfMemory;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.alloc.dupe(u8, key) catch return ds.Error.OutOfMemory;
        }
        gop.value_ptr.* = value;
    }
    fn vtUpdateItem(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, _: []const u8, _: std.json.Value) ds.Error!void {}
    fn vtDeleteItem(ctx: *anyopaque, _: std.mem.Allocator, _: [:0]const u8, key: []const u8) ds.Error!std.json.Value {
        const self: *MemStore = @ptrCast(@alignCast(ctx));
        if (self.map.fetchRemove(key)) |kv| {
            self.alloc.free(kv.key);
            return kv.value;
        }
        return ds.Error.KeyNotFound;
    }
    fn vtListNamespaces(_: *anyopaque, arena: std.mem.Allocator) ds.Error![][]const u8 {
        return arena.alloc([]const u8, 0);
    }
    fn vtGetNamespace(_: *anyopaque, _: std.mem.Allocator, _: [:0]const u8) ds.Error!std.json.Value {
        return .{ .object = .empty };
    }
    const vtable: ds.VTable = .{
        .getItem = vtGetItem,
        .insertItem = vtInsertItem,
        .updateItem = vtUpdateItem,
        .deleteItem = vtDeleteItem,
        .listNamespaces = vtListNamespaces,
        .getNamespace = vtGetNamespace,
    };
    fn dataStore(self: *MemStore) DataStore {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

fn mkCtx(alloc: std.mem.Allocator, mem: *MemStore) !AuthCtx {
    return AuthCtx.init(alloc, testing.io, mem.dataStore(), "http://test:7125");
}

fn mkParams(alloc: std.mem.Allocator, json_str: []const u8) !std.json.Value {
    const p = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    return p.value;
}

// --- Crypto unit tests ---

test "hashPassword: matches Python hashlib pbkdf2_hmac vector" {
    const salt: [32]u8 = @splat(0);
    const h = hashPassword("secret", &salt);
    try testing.expectEqualStrings(
        "f424449b70198c6d5478fff835b93ee602323ffd7a2d225b51e2b4ba08c0602c",
        &h,
    );
}

test "hashPassword: string-salt vector parity" {
    const h = hashPassword("password", "salt");
    try testing.expectEqualStrings(
        "0394a2ede332c9a13eb82e9b24631604c31df978b4e2f0fbd2c549944f9d79a5",
        &h,
    );
}

test "constEql: equal and unequal" {
    try testing.expect(constEql(3, "abc", "abc"));
    try testing.expect(!constEql(3, "abc", "abd"));
    try testing.expect(!constEql(3, "abc", "ab"));
}

test "authorization fails promptly when secure entropy is unavailable" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var vtable = testing.io.vtable.*;
    vtable.randomSecure = struct {
        fn unavailable(_: ?*anyopaque, _: []u8) std.Io.RandomSecureError!void {
            return error.EntropyUnavailable;
        }
    }.unavailable;
    const io: std.Io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    try testing.expectError(error.EntropyUnavailable, AuthCtx.init(testing.allocator, io, mem.dataStore(), "http://test"));
    var ctx = try mkCtx(testing.allocator, &mem);
    defer ctx.deinit();
    ctx.io = io;
    const key = ctx.api_key;
    try testing.expectError(error.EntropyUnavailable, handlePostApiKey(@ptrCast(&ctx), .null, testing.allocator));
    try testing.expectEqualSlices(u8, &key, &ctx.api_key);
}

test "fuzz constant-time comparison validates lengths" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *testing.Smith) !void {
            var bytes: [64]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            try testing.expectEqual(std.mem.eql(u8, bytes[0..32], bytes[32..64]), constEql(32, bytes[0..32], bytes[32..64]));
            try testing.expect(!constEql(64, bytes[0..63], &bytes));
        }
    }.run, .{});
}

test "base32Encode: 20 bytes → 32 chars, matches RFC4648" {
    var out: [32]u8 = undefined;
    // base64.b32encode(b'\x00'*20) == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    const zeros: [20]u8 = @splat(0);
    const e = base32Encode(&out, &zeros);
    try testing.expectEqual(@as(usize, 32), e.len);
    try testing.expectEqualStrings("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", e);
}

test "base32Encode: known vector b'foobar...'" {
    // Python: base64.b32encode(bytes(range(20))) length 32.
    var out: [32]u8 = undefined;
    var data: [20]u8 = undefined;
    for (0..20) |i| data[i] = @intCast(i);
    const e = base32Encode(&out, &data);
    try testing.expectEqual(@as(usize, 32), e.len);
    // Verify only alphabet chars.
    for (e) |ch| {
        const ok = (ch >= 'A' and ch <= 'Z') or (ch >= '2' and ch <= '7');
        try testing.expect(ok);
    }
}

test "generateJwt + decodeJwt: round-trip with signature and claims" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var seed: [32]u8 = undefined;
    try testing.io.randomSecure(&seed);
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);

    const token = try generateJwt(a, "http://test:7125", "alice", "kid123", seed, .access, 1000, 3600);
    const claims = try decodeJwt(a, token, kp.public_key, .access, "http://test:7125", 1500, true);
    try testing.expectEqualStrings("alice", claims.username);
    try testing.expectEqualStrings("kid123", claims.jwk_id);
    try testing.expectEqualStrings("access", claims.token_type);
    try testing.expectEqual(@as(i64, 4600), claims.exp);
    try testing.expectEqual(@as(i64, 1000), claims.iat);
}

test "decodeJwt: expired token rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var seed: [32]u8 = undefined;
    try testing.io.randomSecure(&seed);
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const token = try generateJwt(a, "iss", "bob", "k", seed, .access, 1000, 100);
    try testing.expectError(error.Expired, decodeJwt(a, token, kp.public_key, .access, "iss", 5000, true));
}

test "decodeJwt: wrong token_type rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var seed: [32]u8 = undefined;
    try testing.io.randomSecure(&seed);
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const token = try generateJwt(a, "iss", "bob", "k", seed, .access, 1000, 3600);
    try testing.expectError(error.TokenTypeMismatch, decodeJwt(a, token, kp.public_key, .refresh, "iss", 1500, true));
}

test "decodeJwt: tampered signature rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var seed: [32]u8 = undefined;
    try testing.io.randomSecure(&seed);
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const token = try generateJwt(a, "iss", "bob", "k", seed, .access, 1000, 3600);
    // Flip a char near the start of the signature segment (length-preserving so
    // base64 decode succeeds but the Ed25519 verification fails).
    const mutable = try a.dupe(u8, token);
    const last_dot = std.mem.lastIndexOfScalar(u8, mutable, '.').?;
    const sidx = last_dot + 2;
    mutable[sidx] = if (mutable[sidx] == 'A') 'B' else 'A';
    try testing.expectError(error.BadSignature, decodeJwt(a, mutable, kp.public_key, .access, "iss", 1500, true));
}

test "decodeJwt: wrong issuer/audience rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var seed: [32]u8 = undefined;
    try testing.io.randomSecure(&seed);
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const token = try generateJwt(a, "iss-A", "bob", "k", seed, .access, 1000, 3600);
    try testing.expectError(error.InvalidIssuer, decodeJwt(a, token, kp.public_key, .access, "iss-B", 1500, true));
}

test "JWT header/payload are compact JSON in fixed order (Moonraker parity)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var seed: [32]u8 = undefined;
    try testing.io.randomSecure(&seed);
    const token = try generateJwt(a, "http://h:7125", "u", "kid", seed, .access, 100, 3600);
    const first_dot = std.mem.indexOfScalar(u8, token, '.').?;
    const enc_header = token[0..first_dot];
    const header = try b64urlDecodeAlloc(a, enc_header);
    try testing.expectEqualStrings("{\"kid\":\"kid\",\"alg\":\"EdDSA\",\"typ\":\"JWT\"}", header);
    const rest = token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.').?;
    const payload = try b64urlDecodeAlloc(a, rest[0..second_dot]);
    try testing.expectEqualStrings(
        "{\"iss\":\"http://h:7125\",\"aud\":\"Moonraker\",\"iat\":100,\"exp\":3700,\"username\":\"u\",\"token_type\":\"access\"}",
        payload,
    );
}

// --- User lifecycle / handler tests ---

test "create user → login → JWT validates → refresh → access" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();

    // Create user (POST /access/user).
    const create_params = try mkParams(a, "{\"username\":\"alice\",\"password\":\"hunter2\"}");
    const created = try handleUserPost(@ptrCast(&ctx), create_params, a);
    try testing.expectEqualStrings("alice", created.object.get("username").?.string);
    try testing.expectEqualStrings("user_created", created.object.get("action").?.string);
    const refresh_token = created.object.get("refresh_token").?.string;

    // Login (POST /access/login) returns a valid access token.
    const login_params = try mkParams(a, "{\"username\":\"alice\",\"password\":\"hunter2\"}");
    const logged = try handleLogin(@ptrCast(&ctx), login_params, a);
    try testing.expectEqualStrings("user_logged_in", logged.object.get("action").?.string);
    const access_token = logged.object.get("token").?.string;

    // The access token authenticates via the chain.
    const creds = RequestCreds{ .jwt = access_token, .remote_ip = "127.0.0.1" };
    const outcome = authenticateRequest(&ctx, a, .HTTP, creds, true);
    try testing.expect(outcome == .user);
    try testing.expectEqualStrings("alice", outcome.user);

    // refresh_jwt mints a new access token.
    const refresh_params = try std.json.Stringify.valueAlloc(a, std.json.Value{ .object = blk: {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "refresh_token", .{ .string = refresh_token });
        break :blk o;
    } }, .{});
    const rp = try mkParams(a, refresh_params);
    const refreshed = try handleRefreshJwt(@ptrCast(&ctx), rp, a);
    try testing.expectEqualStrings("user_jwt_refresh", refreshed.object.get("action").?.string);
    const new_access = refreshed.object.get("token").?.string;
    const creds2 = RequestCreds{ .jwt = new_access, .remote_ip = "127.0.0.1" };
    try testing.expect(authenticateRequest(&ctx, a, .HTTP, creds2, true) == .user);
}

test "login: wrong password rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();

    _ = try handleUserPost(@ptrCast(&ctx), try mkParams(a, "{\"username\":\"bob\",\"password\":\"good\"}"), a);
    try testing.expectError(error.InvalidPassword, handleLogin(
        @ptrCast(&ctx),
        try mkParams(a, "{\"username\":\"bob\",\"password\":\"bad\"}"),
        a,
    ));
}

test "create user: duplicate rejected; reserved rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();

    _ = try handleUserPost(@ptrCast(&ctx), try mkParams(a, "{\"username\":\"x\",\"password\":\"p\"}"), a);
    try testing.expectError(error.UserExists, handleUserPost(
        @ptrCast(&ctx),
        try mkParams(a, "{\"username\":\"x\",\"password\":\"p\"}"),
        a,
    ));
    try testing.expectError(error.ReservedUser, handleUserPost(
        @ptrCast(&ctx),
        try mkParams(a, "{\"username\":\"_API_KEY_USER_\",\"password\":\"p\"}"),
        a,
    ));
}

test "users.list excludes API user; includes created users" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();

    _ = try handleUserPost(@ptrCast(&ctx), try mkParams(a, "{\"username\":\"u1\",\"password\":\"p\"}"), a);
    const list = try handleUsersList(@ptrCast(&ctx), .null, a);
    const arr = list.object.get("users").?.array;
    var found_u1 = false;
    var found_api = false;
    for (arr.items) |it| {
        const n = it.object.get("username").?.string;
        if (std.mem.eql(u8, n, "u1")) found_u1 = true;
        if (std.mem.eql(u8, n, api_user)) found_api = true;
    }
    try testing.expect(found_u1);
    try testing.expect(!found_api);
}

test "password reset: verifies old, replaces hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();

    _ = try handleUserPost(@ptrCast(&ctx), try mkParams(a, "{\"username\":\"pw\",\"password\":\"old\"}"), a);
    // wrong old password → Forbidden
    try testing.expectError(error.Forbidden, handlePasswordReset(
        @ptrCast(&ctx),
        try mkParams(a, "{\"_current_user\":\"pw\",\"password\":\"WRONG\",\"new_password\":\"new\"}"),
        a,
    ));
    // correct old → success
    const res = try handlePasswordReset(
        @ptrCast(&ctx),
        try mkParams(a, "{\"_current_user\":\"pw\",\"password\":\"old\",\"new_password\":\"new\"}"),
        a,
    );
    try testing.expectEqualStrings("user_password_reset", res.object.get("action").?.string);
    // login with new password works.
    _ = try handleLogin(@ptrCast(&ctx), try mkParams(a, "{\"username\":\"pw\",\"password\":\"new\"}"), a);
}

test "delete user: reserved + self rejected; deletes otherwise" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();

    _ = try handleUserPost(@ptrCast(&ctx), try mkParams(a, "{\"username\":\"d1\",\"password\":\"p\"}"), a);
    try testing.expectError(error.Forbidden, handleUserDelete(
        @ptrCast(&ctx),
        try mkParams(a, "{\"username\":\"_API_KEY_USER_\"}"),
        a,
    ));
    try testing.expectError(error.Forbidden, handleUserDelete(
        @ptrCast(&ctx),
        try mkParams(a, "{\"username\":\"d1\",\"_current_user\":\"d1\"}"),
        a,
    ));
    const res = try handleUserDelete(@ptrCast(&ctx), try mkParams(a, "{\"username\":\"d1\"}"), a);
    try testing.expectEqualStrings("user_deleted", res.object.get("action").?.string);
    try testing.expect(ctx.users.getPtr("d1") == null);
}

test "api_key: get then regenerate changes value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();

    const k1 = (try handleGetApiKey(@ptrCast(&ctx), .null, a)).string;
    try testing.expectEqual(@as(usize, 32), k1.len);
    const k1_copy = try a.dupe(u8, k1);
    const k2 = (try handlePostApiKey(@ptrCast(&ctx), .null, a)).string;
    try testing.expect(!std.mem.eql(u8, k1_copy, k2));
    // The new key authenticates.
    const creds = RequestCreds{ .api_key = k2, .remote_ip = "1.2.3.4" };
    const out = authenticateRequest(&ctx, a, .HTTP, creds, true);
    try testing.expect(out == .user);
    try testing.expectEqualStrings(api_user, out.user);
}

test "oneshot token: single-use, IP-bound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();

    const ip = try parseIp("10.0.0.5");
    const tok = try ctx.createOneshot(ip, "_API_KEY_USER_", 1000);

    // Wrong IP → null.
    const wrong_ip = try parseIp("10.0.0.6");
    try testing.expect(ctx.consumeOneshot(a, &tok, wrong_ip, 1001) == null);

    // Re-mint (the wrong-IP attempt consumed the token in Moonraker semantics).
    const tok2 = try ctx.createOneshot(ip, "_API_KEY_USER_", 1000);
    const u = ctx.consumeOneshot(a, &tok2, ip, 1001);
    try testing.expect(u != null);
    if (u) |un| {
        defer a.free(un);
        try testing.expectEqualStrings("_API_KEY_USER_", un);
    }
    // Second use → null (single-use).
    try testing.expect(ctx.consumeOneshot(a, &tok2, ip, 1001) == null);
}

test "oneshot token: expires after TTL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();
    const ip = try parseIp("127.0.0.1");
    const tok = try ctx.createOneshot(ip, api_user, 1000);
    // now = 1000 + 6 > 1000 + ONESHOT_TIMEOUT(5) → expired.
    try testing.expect(ctx.consumeOneshot(a, &tok, ip, 1006) == null);
}

test "trusted client: exact IP and CIDR match" {
    const ip1 = try parseIp("192.168.1.10");
    const ip2 = try parseIp("10.0.0.50");
    const ip3 = try parseIp("172.16.0.1");
    const ips = [_]IpAddress{ip1};
    const ranges = [_]TrustedConfig.Cidr{.{ .addr = try parseIp("10.0.0.0"), .prefix = 24 }};
    const cfg = TrustedConfig{ .ips = &ips, .ranges = &ranges };
    try testing.expect(cfg.isTrusted(ip1));
    try testing.expect(cfg.isTrusted(ip2));
    try testing.expect(!cfg.isTrusted(ip3));
}

test "setTrustedClients: 0.0.0.0/0 trusts every IPv4 address" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();
    try ctx.setTrustedClients("127.0.0.1\n0.0.0.0/0\n");
    try testing.expect(ctx.trusted.isTrusted(try parseIp("8.8.8.8")));
    try testing.expect(ctx.trusted.isTrusted(try parseIp("192.168.0.150")));
    try testing.expect(!ctx.trusted.isTrusted(try parseIp("::1")));
}

test "parseTrustedEntry: ip, cidr, domain" {
    const e1 = try parseTrustedEntry("192.168.0.1");
    try testing.expect(e1 == .ip);
    const e2 = try parseTrustedEntry("10.0.0.0/8");
    try testing.expect(e2 == .cidr);
    try testing.expectEqual(@as(u8, 8), e2.cidr.prefix);
    const e3 = try parseTrustedEntry("example.com");
    try testing.expect(e3 == .domain);
}

test "parseTrustedEntry: CIDR with host bits or an oversized prefix is rejected" {
    try testing.expectError(error.InvalidEntry, parseTrustedEntry("192.168.1.5/24"));
    try testing.expectError(error.InvalidEntry, parseTrustedEntry("10.0.0.0/33"));
    try testing.expectError(error.InvalidEntry, parseTrustedEntry("fd00::1/64"));
    try testing.expectError(error.InvalidEntry, parseTrustedEntry("10.128.0.0/8"));
    _ = try parseTrustedEntry("192.168.1.0/24");
    _ = try parseTrustedEntry("192.168.1.5/32");
    _ = try parseTrustedEntry("0.0.0.0/0");
    _ = try parseTrustedEntry("10.0.0.0/9");
    _ = try parseTrustedEntry("fd00::/64");
    _ = try parseTrustedEntry("::1/128");
}

test "fuzz parseTrustedEntry: an accepted CIDR contains its own network address" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var bytes: [4]u8 = undefined;
            smith.bytesWithHash(&bytes, 0);
            const prefix = smith.valueRangeAtMostWithHash(u8, 0, 40, 1);
            var buf: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}/{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3], prefix });
            const entry = parseTrustedEntry(text) catch return;
            try testing.expect(prefix <= 32);
            try testing.expect(cidrContains(entry.cidr, entry.cidr.addr));
            const host_bits: u32 = if (prefix == 32) 0 else @as(u32, 0xffff_ffff) >> @intCast(prefix);
            try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, &bytes, .big) & host_bits);
        }
    }.run, .{});
}

test "setTrustedClients skips a CIDR with host bits set" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var ctx = try mkCtx(testing.allocator, &mem);
    defer ctx.deinit();
    try ctx.setTrustedClients("192.168.1.5/24 10.0.0.0/8");
    try testing.expect(!ctx.trusted.isTrusted(try parseIp("192.168.1.9")));
    try testing.expect(ctx.trusted.isTrusted(try parseIp("10.2.3.4")));
}

test "createOneshot frees the username when storing the token fails" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var ctx = try mkCtx(failing.allocator(), &mem);
    defer ctx.deinit();
    failing.fail_index = failing.alloc_index + 1;
    try testing.expectError(error.OutOfMemory, ctx.createOneshot(try parseIp("127.0.0.1"), "alice", 1000));
    try testing.expectEqual(@as(usize, 0), ctx.oneshot.items.len);
}

test "authenticateRequest waits for a handler holding the auth lock" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var ctx = try mkCtx(testing.allocator, &mem);
    defer ctx.deinit();
    const Probe = struct {
        done: std.atomic.Value(bool) = .init(false),
        fn run(p: *@This(), c: *AuthCtx) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            _ = authenticateRequest(c, arena.allocator(), .HTTP, .{ .remote_ip = "127.0.0.1" }, true);
            p.done.store(true, .release);
        }
    };
    var probe: Probe = .{};
    ctx.mutex.lockUncancelable(testing.io);
    var future = try testing.io.concurrent(Probe.run, .{ &probe, &ctx });
    try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
    const finished_while_locked = probe.done.load(.acquire);
    ctx.mutex.unlock(testing.io);
    future.await(testing.io);
    try testing.expect(!finished_while_locked);
    try testing.expect(probe.done.load(.acquire));
}

test "authenticateRequest: a request without a client address is not trusted" {
    var mem = MemStore.init(testing.allocator);
    defer mem.deinit();
    var ctx = try mkCtx(testing.allocator, &mem);
    defer ctx.deinit();
    try ctx.setTrustedClients("0.0.0.0/0");
    try testing.expect(authenticateRequest(&ctx, testing.allocator, .HTTP, .{}, true) == .unauthorized);
    try testing.expect(authenticateRequest(&ctx, testing.allocator, .HTTP, .{}, false) == .anonymous);
}

test "authenticateRequest: chain order and INTERNAL bypass" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();

    // INTERNAL → anonymous (bypass).
    try testing.expect(authenticateRequest(&ctx, a, .INTERNAL, .{}, true) == .anonymous);

    // No creds, auth required → unauthorized.
    try testing.expect(authenticateRequest(&ctx, a, .HTTP, .{ .remote_ip = "8.8.8.8" }, true) == .unauthorized);

    // No creds, auth not required → anonymous.
    try testing.expect(authenticateRequest(&ctx, a, .HTTP, .{ .remote_ip = "8.8.8.8" }, false) == .anonymous);

    // Trusted IP → trusted_user.
    const tip = try parseIp("127.0.0.1");
    const ips = [_]IpAddress{tip};
    ctx.trusted = .{ .ips = &ips };
    const out = authenticateRequest(&ctx, a, .HTTP, .{ .remote_ip = "127.0.0.1" }, true);
    try testing.expect(out == .user);
    try testing.expectEqualStrings(trusted_user, out.user);
}

test "authenticateRequest: invalid api key rejects even a trusted IP" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();
    const tip = try parseIp("127.0.0.1");
    const ips = [_]IpAddress{tip};
    ctx.trusted = .{ .ips = &ips };
    const bad = authenticateRequest(&ctx, a, .HTTP, .{ .api_key = "deadbeef", .remote_ip = "127.0.0.1" }, true);
    try testing.expect(bad == .unauthorized);
    const blank = authenticateRequest(&ctx, a, .HTTP, .{ .api_key = "  ", .remote_ip = "127.0.0.1" }, true);
    try testing.expect(blank == .user);
    try testing.expectEqualStrings(trusted_user, blank.user);
}

test "resolveClientAddr: xheaders rewrites the client and keeps the socket as proxy" {
    const off = resolveClientAddr("10.0.0.8", "192.168.1.9", "1.1.1.1, 192.168.1.9", false);
    try testing.expectEqualStrings("10.0.0.8", off.client);
    try testing.expect(off.proxy == null);

    const via_xff = resolveClientAddr("10.0.0.8", null, "1.1.1.1, 192.168.1.9", true);
    try testing.expectEqualStrings("192.168.1.9", via_xff.client);
    try testing.expectEqualStrings("10.0.0.8", via_xff.proxy.?);

    const via_real = resolveClientAddr("10.0.0.8", "192.168.1.9", "1.1.1.1, 10.0.0.8", true);
    try testing.expectEqualStrings("192.168.1.9", via_real.client);
    try testing.expectEqualStrings("10.0.0.8", via_real.proxy.?);
}

test "authenticateRequest: untrusted proxy is rejected, trusted proxy is accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();
    const client = try parseIp("192.168.1.9");
    const proxy = try parseIp("10.0.0.8");
    const only_client = [_]IpAddress{client};
    ctx.trusted = .{ .ips = &only_client };
    const blocked = authenticateRequest(&ctx, a, .HTTP, .{
        .remote_ip = "192.168.1.9",
        .proxy_ip = "10.0.0.8",
    }, true);
    try testing.expect(blocked == .unauthorized);

    const both = [_]IpAddress{ client, proxy };
    ctx.trusted = .{ .ips = &both };
    const allowed = authenticateRequest(&ctx, a, .HTTP, .{
        .remote_ip = "192.168.1.9",
        .proxy_ip = "10.0.0.8",
    }, true);
    try testing.expect(allowed == .user);
    try testing.expectEqualStrings(trusted_user, allowed.user);
}

test "authenticateRequest: invalid api key → unauthorized" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();
    const out = authenticateRequest(&ctx, a, .HTTP, .{ .api_key = "deadbeef", .remote_ip = "8.8.8.8" }, true);
    try testing.expect(out == .unauthorized);
}

test "info: shape matches Moonraker" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();
    const info = try handleInfo(@ptrCast(&ctx), .null, a);
    try testing.expectEqualStrings("moonraker", info.object.get("default_source").?.string);
    try testing.expect(info.object.get("available_sources").? == .array);
    try testing.expect(info.object.get("login_required").? == .bool);
    try testing.expect(info.object.get("trusted").? == .bool);
}

test "user GET: no current user → all null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mem = MemStore.init(a);
    defer mem.deinit();
    var ctx = try mkCtx(a, &mem);
    defer ctx.deinit();
    const res = try handleUserGet(@ptrCast(&ctx), .null, a);
    try testing.expect(res.object.get("username").? == .null);
}

test "registerAuthorization wires routes + jsonrpc methods" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");
    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();

    var mem = MemStore.init(alloc);
    defer mem.deinit();
    var ctx = try mkCtx(alloc, &mem);
    defer ctx.deinit();

    try registerAuthorization(&reg, &ctx);

    try testing.expect(reg.lookup(.POST, "/access/login") != null);
    try testing.expect(reg.lookup(.POST, "/access/logout") != null);
    try testing.expect(reg.lookup(.POST, "/access/refresh_jwt") != null);
    try testing.expect(reg.lookup(.GET, "/access/user") != null);
    try testing.expect(reg.lookup(.POST, "/access/user") != null);
    try testing.expect(reg.lookup(.DELETE, "/access/user") != null);
    try testing.expect(reg.lookup(.GET, "/access/users/list") != null);
    try testing.expect(reg.lookup(.POST, "/access/user/password") != null);
    try testing.expect(reg.lookup(.GET, "/access/api_key") != null);
    try testing.expect(reg.lookup(.POST, "/access/api_key") != null);
    try testing.expect(reg.lookup(.GET, "/access/oneshot_token") != null);
    try testing.expect(reg.lookup(.GET, "/access/info") != null);

    try testing.expect(d.methods.get("access.login") != null);
    try testing.expect(d.methods.get("access.logout") != null);
    try testing.expect(d.methods.get("access.refresh_jwt") != null);
    try testing.expect(d.methods.get("access.get_user") != null);
    try testing.expect(d.methods.get("access.post_user") != null);
    try testing.expect(d.methods.get("access.delete_user") != null);
    try testing.expect(d.methods.get("access.user") == null); // renamed
    try testing.expect(d.methods.get("access.users.list") != null);
    try testing.expect(d.methods.get("access.user.password") != null);
    try testing.expect(d.methods.get("access.get_api_key") != null);
    try testing.expect(d.methods.get("access.post_api_key") != null);
    try testing.expect(d.methods.get("access.oneshot_token") != null);
    try testing.expect(d.methods.get("access.info") != null);
}

test "login auth_required=false on the route" {
    const alloc = testing.allocator;
    const jsonrpc = @import("../jsonrpc.zig");
    var d = jsonrpc.Dispatcher.init(alloc);
    defer d.deinit();
    var reg = Registry.init(alloc, &d);
    defer reg.deinit();
    var mem = MemStore.init(alloc);
    defer mem.deinit();
    var ctx = try mkCtx(alloc, &mem);
    defer ctx.deinit();
    try registerAuthorization(&reg, &ctx);
    try testing.expect(!reg.lookup(.POST, "/access/login").?.auth_required);
    try testing.expect(!reg.lookup(.GET, "/access/info").?.auth_required);
    try testing.expect(reg.lookup(.POST, "/access/logout").?.auth_required);
}

// --- Fuzz tests ---

test "fuzz decodeJwt: arbitrary tokens never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var buf: [128]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const n = @as(usize, buf[0]) % buf.len;
            // Build a token-ish string from a safe alphabet incl '.'.
            const alphabet = "ABCdef012._-";
            var tbuf: [129]u8 = undefined;
            var len: usize = 0;
            for (buf[0..n]) |b| {
                tbuf[len] = alphabet[b % alphabet.len];
                len += 1;
            }
            var seed: [32]u8 = undefined;
            try testing.io.randomSecure(&seed);
            const kp = Ed25519.KeyPair.generateDeterministic(seed) catch return;
            _ = decodeJwt(a, tbuf[0..len], kp.public_key, .access, "iss", 1000, true) catch {};
        }
    }.run, .{});
}

test "fuzz hashPassword: never crashes; deterministic" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const n = @as(usize, buf[0]) % buf.len;
            const h1 = hashPassword(buf[0..n], "saltsalt");
            const h2 = hashPassword(buf[0..n], "saltsalt");
            try testing.expectEqualStrings(&h1, &h2);
        }
    }.run, .{});
}

test "fuzz authenticateRequest: arbitrary creds never crash" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var mem = MemStore.init(a);
            defer mem.deinit();
            var ctx = AuthCtx.init(a, testing.io, mem.dataStore(), "http://test:7125") catch return;
            defer ctx.deinit();

            var buf: [96]u8 = undefined;
            smith.bytesWithHash(&buf, 0);
            const alphabet = "ABCdef0123.-_ ";
            var tbuf: [96]u8 = undefined;
            for (buf, 0..) |b, i| tbuf[i] = alphabet[b % alphabet.len];
            const split = buf[0] % 32;
            const creds = RequestCreds{
                .jwt = tbuf[0..split],
                .oneshot = tbuf[split..@min(split + 16, tbuf.len)],
                .api_key = tbuf[0..@min(32, tbuf.len)],
                .remote_ip = "127.0.0.1",
            };
            _ = authenticateRequest(&ctx, a, .HTTP, creds, (buf[1] & 1) == 0);
        }
    }.run, .{});
}

test "fuzz base32Encode: never overruns; only alphabet chars" {
    try testing.fuzz({}, struct {
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            var data: [20]u8 = undefined;
            smith.bytesWithHash(&data, 0);
            var out: [32]u8 = undefined;
            const e = base32Encode(&out, &data);
            try testing.expectEqual(@as(usize, 32), e.len);
            for (e) |ch| {
                const ok = (ch >= 'A' and ch <= 'Z') or (ch >= '2' and ch <= '7');
                try testing.expect(ok);
            }
        }
    }.run, .{});
}
