#!/usr/bin/env python3
"""A fake org.freedesktop.portal.Desktop for the Linux integration checks.

Implements just enough of GlobalShortcuts, RemoteDesktop, Clipboard, Request
and Session to exercise the app's D-Bus protocol handling: request/response
paths, session handles, persist mode and restore tokens, keysym paste and the
SelectionTransfer/SelectionWrite handshake. It records what it saw in the JSON
file named by its first argument and exits on SIGTERM. It checks the protocol,
not a compositor: consent dialogs, indicators and real key delivery need a
physical desktop.
"""
import json
import os
import signal
import sys

from gi.repository import Gio, GLib

PATH = "/org/freedesktop/portal/desktop"
XML = """
<node>
  <interface name="org.freedesktop.portal.GlobalShortcuts">
    <method name="CreateSession"><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
    <method name="BindShortcuts">
      <arg type="o" direction="in"/><arg type="a(sa{sv})" direction="in"/><arg type="s" direction="in"/>
      <arg type="a{sv}" direction="in"/><arg type="o" direction="out"/>
    </method>
    <signal name="Activated"><arg type="o"/><arg type="s"/><arg type="t"/><arg type="a{sv}"/></signal>
    <signal name="Deactivated"><arg type="o"/><arg type="s"/><arg type="t"/><arg type="a{sv}"/></signal>
    <property name="version" type="u" access="read"/>
  </interface>
  <interface name="org.freedesktop.portal.RemoteDesktop">
    <method name="CreateSession"><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
    <method name="SelectDevices"><arg type="o" direction="in"/><arg type="a{sv}" direction="in"/><arg type="o" direction="out"/></method>
    <method name="Start">
      <arg type="o" direction="in"/><arg type="s" direction="in"/><arg type="a{sv}" direction="in"/>
      <arg type="o" direction="out"/>
    </method>
    <method name="NotifyKeyboardKeysym">
      <arg type="o" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>
      <arg type="u" direction="in"/>
    </method>
    <property name="version" type="u" access="read"/>
  </interface>
  <interface name="org.freedesktop.portal.Clipboard">
    <method name="RequestClipboard"><arg type="o" direction="in"/><arg type="a{sv}" direction="in"/></method>
    <method name="SetSelection"><arg type="o" direction="in"/><arg type="a{sv}" direction="in"/></method>
    <method name="SelectionWrite">
      <arg type="o" direction="in"/><arg type="u" direction="in"/><arg type="h" direction="out"/>
    </method>
    <method name="SelectionWriteDone">
      <arg type="o" direction="in"/><arg type="u" direction="in"/><arg type="b" direction="in"/>
    </method>
    <signal name="SelectionTransfer"><arg type="o"/><arg type="s"/><arg type="u"/></signal>
    <property name="version" type="u" access="read"/>
  </interface>
</node>
"""
SESSION_XML = """
<node><interface name="org.freedesktop.portal.Session">
  <method name="Close"/><signal name="Closed"><arg type="a{sv}"/></signal>
</interface></node>
"""

log = {"calls": [], "keysyms": [], "selections": [], "restore_tokens": [], "errors": []}
state = {"sessions": {}, "pipes": {}, "tokens": 0}


def save():
    with open(sys.argv[1], "w", encoding="utf-8") as handle:
        json.dump(log, handle, indent=2)


def sender_path(sender, token):
    return f"{PATH}/request/{sender[1:].replace('.', '_')}/{token}"


def respond(connection, request, results):
    def emit():
        connection.emit_signal(None, request, "org.freedesktop.portal.Request", "Response",
                               GLib.Variant("(ua{sv})", (0, results)))
        return False
    GLib.timeout_add(20, emit)


def register_session(connection, sender, options):
    path = f"{PATH}/session/{sender[1:].replace('.', '_')}/{options['session_handle_token']}"
    info = Gio.DBusNodeInfo.new_for_xml(SESSION_XML).interfaces[0]

    def call(conn, _sender, obj, _iface, method, _params, invocation):
        log["calls"].append(f"Session.{method}")
        state["sessions"].pop(obj, None)
        invocation.return_value(None)
        save()

    registration = connection.register_object(path, info, call, None, None)
    state["sessions"][path] = registration
    return path


def handle(connection, sender, _path, interface, method, params, invocation):
    name = f"{interface.rsplit('.', 1)[1]}.{method}"
    log["calls"].append(name)
    args = params.unpack()
    try:
        if method == "CreateSession":
            options = args[0]
            session = register_session(connection, sender, options)
            request = sender_path(sender, options["handle_token"])
            invocation.return_value(GLib.Variant("(o)", (request,)))
            respond(connection, request, {"session_handle": GLib.Variant("s", session)})
        elif method == "BindShortcuts":
            session, shortcuts, _parent, options = args
            request = sender_path(sender, options["handle_token"])
            invocation.return_value(GLib.Variant("(o)", (request,)))
            bound = [(identifier, {"description": GLib.Variant("s", props["description"]),
                                   "trigger_description": GLib.Variant("s", "Ctrl+Alt+Space")})
                     for identifier, props in shortcuts]
            respond(connection, request, {"shortcuts": GLib.Variant("a(sa{sv})", bound)})
            identifier = shortcuts[0][0]

            def press(signal_name):
                connection.emit_signal(None, PATH, "org.freedesktop.portal.GlobalShortcuts", signal_name,
                                       GLib.Variant("(osta{sv})", (session, identifier, 1, {})))
                return False
            GLib.timeout_add(120, press, "Activated")
            GLib.timeout_add(180, press, "Deactivated")
        elif method == "SelectDevices":
            session, options = args
            if options.get("types") != 1 or options.get("persist_mode") != 2:
                log["errors"].append(f"SelectDevices options {options}")
            log["restore_tokens"].append(options.get("restore_token", ""))
            request = sender_path(sender, options["handle_token"])
            invocation.return_value(GLib.Variant("(o)", (request,)))
            respond(connection, request, {})
        elif method == "Start":
            session, _parent, options = args
            state["tokens"] += 1
            request = sender_path(sender, options["handle_token"])
            invocation.return_value(GLib.Variant("(o)", (request,)))
            respond(connection, request, {
                "devices": GLib.Variant("u", 1), "clipboard_enabled": GLib.Variant("b", True),
                "restore_token": GLib.Variant("s", f"fake-restore-token-{state['tokens']}"),
            })
        elif method == "NotifyKeyboardKeysym":
            _session, _options, keysym, pressed = args
            log["keysyms"].append([keysym, pressed])
            invocation.return_value(None)
        elif method == "RequestClipboard":
            invocation.return_value(None)
        elif method == "SetSelection":
            session, options = args
            invocation.return_value(None)
            mime = options["mime_types"][0]

            def transfer():
                connection.emit_signal(None, PATH, "org.freedesktop.portal.Clipboard", "SelectionTransfer",
                                       GLib.Variant("(osu)", (session, mime, 7)))
                return False
            GLib.timeout_add(10, transfer)
        elif method == "SelectionWrite":
            _session, serial = args
            read_end, write_end = os.pipe()
            state["pipes"][serial] = read_end
            fds = Gio.UnixFDList.new()
            index = fds.append(write_end)
            os.close(write_end)
            invocation.return_value_with_unix_fd_list(GLib.Variant("(h)", (index,)), fds)
        elif method == "SelectionWriteDone":
            _session, serial, success = args
            data = b""
            read_end = state["pipes"].pop(serial)
            while chunk := os.read(read_end, 65536):
                data += chunk
            os.close(read_end)
            log["selections"].append({"text": data.decode("utf-8"), "success": success})
            invocation.return_value(None)
        else:
            invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)
    except Exception as error:  # report, never hang the client
        log["errors"].append(f"{name}: {error!r}")
        invocation.return_dbus_error("org.freedesktop.DBus.Error.Failed", str(error))
    save()


def get_property(*_args):
    return GLib.Variant("u", 1)


def main():
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    info = Gio.DBusNodeInfo.new_for_xml(XML)
    for interface in info.interfaces:
        bus.register_object(PATH, interface, handle, get_property, None)
    loop = GLib.MainLoop()
    Gio.bus_own_name_on_connection(bus, "org.freedesktop.portal.Desktop", Gio.BusNameOwnerFlags.NONE,
                                   lambda *_: print("fake portal ready", flush=True), lambda *_: loop.quit())
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, loop.quit)
    save()
    loop.run()
    save()


if __name__ == "__main__":
    main()
