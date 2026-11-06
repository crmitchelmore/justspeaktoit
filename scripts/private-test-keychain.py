"""Private file Keychain creation: never change the user default/search list."""
import ctypes
import secrets


def create(path):
    security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
    foundation = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    foundation.CFRelease.argtypes = [ctypes.c_void_p]
    security.SecKeychainCreate.argtypes = [
        ctypes.c_char_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_bool,
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p),
    ]
    security.SecKeychainCreate.restype = ctypes.c_int32
    security.SecKeychainUnlock.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_bool]
    security.SecKeychainUnlock.restype = ctypes.c_int32
    security.SecKeychainSetUserInteractionAllowed.argtypes = [ctypes.c_bool]
    security.SecKeychainSetUserInteractionAllowed.restype = ctypes.c_int32
    status = security.SecKeychainSetUserInteractionAllowed(False)
    if status:
        raise RuntimeError(f'cannot disable Keychain UI (OSStatus {status})')
    password = secrets.token_urlsafe(32).encode('ascii')
    keychain = ctypes.c_void_p()
    status = security.SecKeychainCreate(str(path).encode(), len(password), password, False, None, ctypes.byref(keychain))
    try:
        if status == 0:
            status = security.SecKeychainUnlock(keychain, len(password), password, True)
        if status:
            raise RuntimeError(f'private test Keychain setup failed (OSStatus {status})')
        return password.decode('ascii')
    finally:
        if keychain:
            foundation.CFRelease(keychain)
