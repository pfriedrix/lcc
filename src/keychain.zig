//! macOS Keychain access through the modern SecItem* API.
//!
//! This replaces `@napi-rs/keyring` in the TypeScript version. The npm package
//! also covers Linux (libsecret) and Windows (Credential Manager); this is
//! macOS-only, which is the whole cross-platform cost of the port.

const std = @import("std");

// Deliberately narrow includes. The `CoreFoundation/CoreFoundation.h` and
// `Security/Security.h` umbrella headers both fail translate-c on the
// macOS 26.5 SDK: the former drags in mach headers whose bitfield structs
// become opaque and then trip their own `_Static_assert`s, the latter drags in
// `xpc.h`, which puts nullability attributes on the non-pointer `uuid_t`.
// These five headers cover every symbol used below.
const c = @cImport({
    @cInclude("CoreFoundation/CFBase.h");
    @cInclude("CoreFoundation/CFString.h");
    @cInclude("CoreFoundation/CFData.h");
    @cInclude("CoreFoundation/CFDictionary.h");
    @cInclude("CoreFoundation/CFNumber.h");
    @cInclude("Security/SecItem.h");
});

pub const Error = error{
    /// SecItem* returned an OSStatus we do not translate individually.
    KeychainFailed,
    /// CoreFoundation refused to allocate an object.
    CoreFoundationFailed,
    OutOfMemory,
};

const err_sec_success: c.OSStatus = 0;
const err_sec_item_not_found: c.OSStatus = -25300;
const err_sec_duplicate_item: c.OSStatus = -25299;
const err_sec_auth_failed: c.OSStatus = -25293;
const err_sec_user_canceled: c.OSStatus = -128;

/// Last raw OSStatus, so callers can report something actionable when a
/// keychain call fails for a reason we do not model.
pub var last_status: c.OSStatus = err_sec_success;

fn cfString(s: []const u8) Error!c.CFStringRef {
    return c.CFStringCreateWithBytes(
        null,
        s.ptr,
        @intCast(s.len),
        c.kCFStringEncodingUTF8,
        0,
    ) orelse Error.CoreFoundationFailed;
}

fn cfData(bytes: []const u8) Error!c.CFDataRef {
    return c.CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse
        Error.CoreFoundationFailed;
}

fn opaquePtr(ref: anytype) ?*const anyopaque {
    return @ptrCast(ref);
}

/// Builds `{ class: generic password, service, account }` — the identity of a
/// single keychain item. Caller releases.
fn identityQuery(service: c.CFStringRef, account: c.CFStringRef) Error!c.CFMutableDictionaryRef {
    const dict = c.CFDictionaryCreateMutable(
        null,
        0,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    ) orelse return Error.CoreFoundationFailed;
    c.CFDictionarySetValue(dict, opaquePtr(c.kSecClass), opaquePtr(c.kSecClassGenericPassword));
    c.CFDictionarySetValue(dict, opaquePtr(c.kSecAttrService), opaquePtr(service));
    c.CFDictionarySetValue(dict, opaquePtr(c.kSecAttrAccount), opaquePtr(account));
    return dict;
}

/// Returns the stored secret, or null when the item does not exist.
/// Caller owns the returned memory.
pub fn get(gpa: std.mem.Allocator, service: []const u8, account: []const u8) Error!?[]u8 {
    const service_ref = try cfString(service);
    defer c.CFRelease(opaquePtr(service_ref));
    const account_ref = try cfString(account);
    defer c.CFRelease(opaquePtr(account_ref));

    const query = try identityQuery(service_ref, account_ref);
    defer c.CFRelease(opaquePtr(query));
    c.CFDictionarySetValue(query, opaquePtr(c.kSecReturnData), opaquePtr(c.kCFBooleanTrue));
    c.CFDictionarySetValue(query, opaquePtr(c.kSecMatchLimit), opaquePtr(c.kSecMatchLimitOne));

    var result: c.CFTypeRef = null;
    const status = c.SecItemCopyMatching(query, &result);
    last_status = status;
    if (status == err_sec_item_not_found) return null;
    if (status != err_sec_success) return Error.KeychainFailed;

    const data: c.CFDataRef = @ptrCast(result);
    defer c.CFRelease(result);

    const len: usize = @intCast(c.CFDataGetLength(data));
    const ptr = c.CFDataGetBytePtr(data);
    if (len == 0 or ptr == null) return try gpa.alloc(u8, 0);

    const out = try gpa.alloc(u8, len);
    @memcpy(out, ptr[0..len]);
    return out;
}

/// Creates the item, or overwrites it when it already exists.
pub fn set(service: []const u8, account: []const u8, secret: []const u8) Error!void {
    const service_ref = try cfString(service);
    defer c.CFRelease(opaquePtr(service_ref));
    const account_ref = try cfString(account);
    defer c.CFRelease(opaquePtr(account_ref));
    const secret_ref = try cfData(secret);
    defer c.CFRelease(opaquePtr(secret_ref));

    const query = try identityQuery(service_ref, account_ref);
    defer c.CFRelease(opaquePtr(query));

    // Update first: SecItemAdd on an existing item fails with errSecDuplicateItem
    // rather than replacing it.
    const attrs = c.CFDictionaryCreateMutable(
        null,
        0,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    ) orelse return Error.CoreFoundationFailed;
    defer c.CFRelease(opaquePtr(attrs));
    c.CFDictionarySetValue(attrs, opaquePtr(c.kSecValueData), opaquePtr(secret_ref));

    const update_status = c.SecItemUpdate(query, attrs);
    last_status = update_status;
    if (update_status == err_sec_success) return;
    if (update_status != err_sec_item_not_found) return Error.KeychainFailed;

    // Item does not exist yet — add it.
    const add_query = try identityQuery(service_ref, account_ref);
    defer c.CFRelease(opaquePtr(add_query));
    c.CFDictionarySetValue(add_query, opaquePtr(c.kSecValueData), opaquePtr(secret_ref));

    const add_status = c.SecItemAdd(add_query, null);
    last_status = add_status;
    if (add_status != err_sec_success) return Error.KeychainFailed;
}

/// Removes the item. A missing item is not an error.
pub fn delete(service: []const u8, account: []const u8) Error!void {
    const service_ref = try cfString(service);
    defer c.CFRelease(opaquePtr(service_ref));
    const account_ref = try cfString(account);
    defer c.CFRelease(opaquePtr(account_ref));

    const query = try identityQuery(service_ref, account_ref);
    defer c.CFRelease(opaquePtr(query));

    const status = c.SecItemDelete(query);
    last_status = status;
    if (status == err_sec_success or status == err_sec_item_not_found) return;
    return Error.KeychainFailed;
}

/// Human-readable form of `last_status`, for error messages.
pub fn describeStatus(status: c.OSStatus) []const u8 {
    return switch (status) {
        err_sec_success => "success",
        err_sec_item_not_found => "item not found",
        err_sec_duplicate_item => "duplicate item",
        err_sec_auth_failed => "authorization failed (keychain prompt denied?)",
        err_sec_user_canceled => "user canceled the keychain prompt",
        else => "unmapped OSStatus",
    };
}
