#!/usr/bin/env python3
# VPN-Starter-Kit :: core/pam_auth.py
# Authenticates a password against a real Linux PAM stack, via ctypes
# bindings straight into libpam -- no pip dependency, matching this
# project's stdlib-only convention (ws.py/ohp.py/both Telegram bots).
#
# Deliberately NOT Python's `crypt` module: crypt was deprecated in
# Python 3.11 and removed outright in Python 3.13 (Ubuntu 24.04 ships
# 3.12, the last version that still has it) -- a real expiration date on
# a security-critical path. ctypes calling into libpam.so has no such
# expiration, and it's also the more correct way to check a Linux login:
# it goes through the real PAM stack (whatever /etc/pam.d/<service> says),
# not a bare hash comparison that ignores account lockout / expiry rules
# PAM itself might enforce.
#
# Authenticates against a dedicated PAM service, /etc/pam.d/vpn-admin-panel
# (created by menu/menu-webgui.sh's "Setup Admin Panel" action, standard
# Debian/Ubuntu `@include common-auth`/`common-account` -- the same
# pattern Webmin itself ships as /etc/pam.d/webmin) rather than assuming
# what an existing service like "login" or "sshd" already does.
#
# This is the well-known ctypes-PAM recipe used by several small "pam"
# PyPI packages over the years (originally popularized by Chris AtLee) --
# reproduced here directly so this project never needs a pip dependency
# for it.

import ctypes
import ctypes.util

_libpam = ctypes.CDLL(ctypes.util.find_library("pam"))
_libc = ctypes.CDLL(ctypes.util.find_library("c"))

_calloc = _libc.calloc
_calloc.restype = ctypes.c_void_p
_calloc.argtypes = [ctypes.c_size_t, ctypes.c_size_t]

_strdup = _libc.strdup
_strdup.restype = ctypes.POINTER(ctypes.c_char)
_strdup.argtypes = [ctypes.c_char_p]

PAM_SUCCESS = 0
PAM_PROMPT_ECHO_OFF = 1
PAM_PROMPT_ECHO_ON = 2
PAM_ERROR_MSG = 3
PAM_TEXT_INFO = 4


class PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class PamResponse(ctypes.Structure):
    _fields_ = [("resp", ctypes.POINTER(ctypes.c_char)), ("resp_retcode", ctypes.c_int)]


PAM_CONV_FUNC = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_int,
    ctypes.POINTER(ctypes.POINTER(PamMessage)),
    ctypes.POINTER(ctypes.POINTER(PamResponse)),
    ctypes.c_void_p,
)


class PamConv(ctypes.Structure):
    _fields_ = [("conv", PAM_CONV_FUNC), ("appdata_ptr", ctypes.c_void_p)]


_libpam.pam_start.argtypes = [
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.POINTER(PamConv),
    ctypes.POINTER(ctypes.c_void_p),
]
_libpam.pam_start.restype = ctypes.c_int
_libpam.pam_authenticate.argtypes = [ctypes.c_void_p, ctypes.c_int]
_libpam.pam_authenticate.restype = ctypes.c_int
_libpam.pam_acct_mgmt.argtypes = [ctypes.c_void_p, ctypes.c_int]
_libpam.pam_acct_mgmt.restype = ctypes.c_int
_libpam.pam_end.argtypes = [ctypes.c_void_p, ctypes.c_int]
_libpam.pam_end.restype = ctypes.c_int


def authenticate(username: str, password: str, service: str = "vpn-admin-panel") -> bool:
    """
    Check (username, password) against PAM service `service`. Returns
    True only on a genuine successful authentication + account check;
    returns False for a wrong password, a locked/expired account, or any
    unexpected PAM/library failure -- never raises, so a bad login can
    never crash the caller or leak a stack trace back to an HTTP client.
    """
    try:
        password_bytes = password.encode("utf-8")

        @PAM_CONV_FUNC
        def _conv(n_messages, messages, p_response, _app_data):
            addr = _calloc(n_messages, ctypes.sizeof(PamResponse))
            p_response[0] = ctypes.cast(addr, ctypes.POINTER(PamResponse))
            for i in range(n_messages):
                if messages[i].contents.msg_style == PAM_PROMPT_ECHO_OFF:
                    pw_copy = _strdup(password_bytes)
                    p_response.contents[i].resp = pw_copy
                    p_response.contents[i].resp_retcode = 0
            return PAM_SUCCESS

        handle = ctypes.c_void_p()
        conv = PamConv(_conv, None)

        retval = _libpam.pam_start(
            service.encode("utf-8"), username.encode("utf-8"), ctypes.byref(conv), ctypes.byref(handle)
        )
        if retval != PAM_SUCCESS:
            return False

        retval = _libpam.pam_authenticate(handle, 0)
        if retval == PAM_SUCCESS:
            retval = _libpam.pam_acct_mgmt(handle, 0)

        _libpam.pam_end(handle, retval)
        return retval == PAM_SUCCESS
    except Exception as exc:
        print(f"pam_auth: unexpected error during authentication: {exc}", flush=True)
        return False


if __name__ == "__main__":
    import getpass
    import sys

    user = sys.argv[1] if len(sys.argv) > 1 else "root"
    pw = getpass.getpass(f"Password for {user}: ")
    ok = authenticate(user, pw)
    print("AUTH OK" if ok else "AUTH FAILED")
    sys.exit(0 if ok else 1)
