#!/usr/bin/env python3
"""Synthetic AT-SPI service, exclusively for an empty disposable session bus."""
import os
import signal
import sys

from gi.repository import Gio, GLib

ACCESSIBLE = "org.a11y.atspi.Accessible"
TEXT = "org.a11y.atspi.Text"
EDITABLE = "org.a11y.atspi.EditableText"
CONTROL = "com.justspeaktoit.SelectionFixture"
BUS_PATH = "/org/a11y/bus"
REGISTRY_PATH = "/org/a11y/atspi/registry"
APP = "/fixture/app"
TOP = "/fixture/top"
SHAPE = sys.argv[1]
if SHAPE not in ("event", "application", "unsupported"):
    raise SystemExit("Unknown fixture cleanup shape")
if os.environ.get("JSTI_ATSPI_SELECTION_FIXTURE") != "1":
    raise SystemExit("The fixture requires explicit disposable-bus opt-in")
address = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
if not address.startswith("unix:") or ";" in address:
    raise SystemExit("The fixture requires an existing local private bus address")

XML = """
<node>
 <interface name="org.a11y.Bus">
  <method name="GetAddress"><arg type="s" direction="out"/></method>
 </interface>
 <interface name="org.a11y.Status">
  <property name="IsEnabled" type="b" access="read"/>
 </interface>
 <interface name="com.justspeaktoit.SelectionFixture">
  <method name="Configure"><arg type="s" direction="in"/></method>
  <method name="Focus"/><method name="Change"/><method name="Release"/>
  <method name="Schema"><arg type="s" direction="out"/></method>
  <method name="Active"><arg type="u" direction="out"/></method>
  <method name="Counts">
   <arg type="u" direction="out"/><arg type="u" direction="out"/>
   <arg type="u" direction="out"/><arg type="u" direction="out"/><arg type="u" direction="out"/>
  </method>
 </interface>
 <interface name="org.a11y.atspi.Accessible">
  <method name="GetRole"><arg type="u" direction="out"/></method>
  <method name="GetState"><arg type="au" direction="out"/></method>
  <method name="GetInterfaces"><arg type="as" direction="out"/></method>
  <method name="GetApplication"><arg type="(so)" direction="out"/></method>
  <property name="Parent" type="(so)" access="read"/>
 </interface>
 <interface name="org.a11y.atspi.Text">
  <method name="GetNSelections"><arg type="i" direction="out"/></method>
  <method name="GetSelection">
   <arg type="i" direction="in"/><arg type="i" direction="out"/><arg type="i" direction="out"/>
  </method>
  <method name="GetText">
   <arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="s" direction="out"/>
  </method>
  <property name="CharacterCount" type="i" access="read"/>
 </interface>
 <interface name="org.a11y.atspi.EditableText">
  <method name="InsertText">
   <arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="i" direction="in"/>
   <arg type="b" direction="out"/>
  </method>
  <method name="DeleteText">
   <arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="b" direction="out"/>
  </method>
  <method name="SetTextContents"><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
 </interface>
</node>
"""
cleanup_args = '<arg type="s" direction="in"/>'
if SHAPE == "application":
    cleanup_args *= 2
elif SHAPE == "unsupported":
    cleanup_args = '<arg type="u" direction="in"/>'
REGISTRY_XML = """
<node><interface name="org.a11y.atspi.Registry">
 <method name="RegisterEvent">
  <arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="s" direction="in"/>
 </method>
 <method name="DeregisterEvent">""" + cleanup_args + """</method>
</interface></node>
"""

bus = Gio.bus_get_sync(Gio.BusType.SESSION)
names = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                      "ListNames", None, GLib.VariantType.new("(as)"), Gio.DBusCallFlags.NONE, 1000, None)
if any(not name.startswith(":") and name != "org.freedesktop.DBus" for name in names.unpack()[0]):
    raise SystemExit("Refusing to register fixture services on a nonempty bus")
owner = bus.get_unique_name()
info = Gio.DBusNodeInfo.new_for_xml(XML)
fields = {}
pending = []
current = None
registrations = 0
writes = 0
bad_ranges = 0
clients = {}
object_ids = []


def event(path, name, detail="", first=0):
    base = {"StateChanged": "object:state-changed", "TextSelectionChanged": "object:text-selection-changed",
            "TextChanged": "object:text-changed", "PropertyChange": "object:property-change"}[name]
    key = base + (":" + detail if detail else "")
    for destination, entries in list(clients.items()):
        if any((not application or application == owner)
               and (key == prefix or key.startswith(prefix.rstrip(":") + ":"))
               for prefix, application in entries):
            bus.emit_signal(destination, path, "org.a11y.atspi.Event.Object", name,
                            GLib.Variant("(siiva{sv})", (detail, first, 0, GLib.Variant("i", 0), {})))


def configure(mode):
    global current
    if mode not in ("normal", "unicode", "combining", "empty", "none", "multiple", "oversized",
                    "negative", "past-end", "short-text", "password", "protected", "readonly",
                    "mutate", "role-change", "hold"):
        raise ValueError("Unknown synthetic selection mode")
    selected = "selected"
    if mode == "unicode":
        selected = "\U0001f600" * 8192
    elif mode == "combining":
        selected = "e\u0301" * 4096
    elif mode == "oversized":
        selected = "x" * 8193
    current = f"/fixture/field{len(fields) + 1}"
    fields[current] = {
        "mode": mode, "text": "left " + selected + " right", "start": 5,
        "end": 5 if mode == "empty" else 5 + len(selected),
        "reads": 0, "writes": 0, "bad": 0, "mask": 0,
    }
    if mode == "negative":
        fields[current]["start"] = -1
    elif mode == "past-end":
        fields[current]["end"] = len(fields[current]["text"]) + 1
    for name in (ACCESSIBLE, TEXT, EDITABLE):
        object_ids.append(bus.register_object(current, info.lookup_interface(name), method, get_property, None))


def get_property(_connection, _sender, path, _interface, name):
    if name == "IsEnabled":
        return GLib.Variant("b", True)
    if name == "CharacterCount":
        return GLib.Variant("i", len(fields[path]["text"]))
    if name == "Parent":
        return GLib.Variant("(so)", (owner, TOP if path in fields else APP))
    return None


def method(_connection, sender, path, interface, name, parameters, invocation):
    global registrations, writes, bad_ranges
    args = parameters.unpack()
    if interface == CONTROL:
        if name == "Configure":
            configure(args[0])
        elif name == "Focus":
            event(current, "StateChanged", "focused", 1)
        elif name == "Change":
            fields[current]["mask"] = 0
            fields[current]["start"] += 1
            event(current, "TextSelectionChanged")
        elif name == "Release":
            while pending:
                held, text = pending.pop()
                held.return_value(GLib.Variant("(s)", (text,)))
        elif name == "Schema":
            invocation.return_value(GLib.Variant("(s)", (SHAPE,)))
            return
        elif name == "Active":
            invocation.return_value(GLib.Variant("(u)", (sum(len(entries) for entries in clients.values()),)))
            return
        elif name == "Counts":
            field = fields[current]
            invocation.return_value(GLib.Variant("(uuuuu)", (
                field["reads"], writes, bad_ranges, field["mask"], registrations)))
            return
        else:
            invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", name)
            return
        invocation.return_value(None)
        return
    if interface == "org.a11y.Bus":
        invocation.return_value(GLib.Variant("(s)", (address,)))
        return
    if interface == "org.a11y.atspi.Registry":
        if name == "RegisterEvent":
            registrations += 1
            clients.setdefault(sender, set()).add((args[0], args[2]))
        else:
            prefix = args[0].rstrip(":")
            application = args[1] if SHAPE == "application" else None
            clients[sender] = {
                (event, app) for event, app in clients.get(sender, set())
                if not ((application is None or application == app)
                        and (event.rstrip(":") == prefix or event.startswith(prefix + ":")))
            }
        invocation.return_value(None)
        return
    field = fields.get(path)
    if interface == ACCESSIBLE:
        if name == "GetRole":
            if field:
                field["mask"] |= 1
            role = (40 if field["mode"] == "password" else 61) if field else (69 if path == TOP else 75)
            result = GLib.Variant("(u)", (role,))
        elif name == "GetState":
            if field:
                field["mask"] |= 2
            bits = sum(1 << bit for bit in (7, 8, 12, 24, 25, 30)) if field else 2
            if field and field["mode"] == "protected":
                bits |= 1 << 43
            result = GLib.Variant("(au)", ([bits & 0xFFFFFFFF, bits >> 32],))
        elif name == "GetInterfaces":
            if field:
                field["mask"] |= 4
            interfaces = [ACCESSIBLE, TEXT]
            if not field or field["mode"] != "readonly":
                interfaces.append(EDITABLE)
            result = GLib.Variant("(as)", (interfaces,))
        elif name == "GetApplication":
            result = GLib.Variant("((so))", ((owner, APP),))
        else:
            invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", name)
            return
    elif interface == EDITABLE:
        field["writes"] += 1
        writes += 1
        result = GLib.Variant("(b)", (False,))
    elif name == "GetNSelections":
        count = 0 if field["mode"] == "none" else 2 if field["mode"] == "multiple" else 1
        result = GLib.Variant("(i)", (count,))
    elif name == "GetSelection":
        result = GLib.Variant("(ii)", (field["start"], field["end"]))
    elif name == "GetText":
        start, end = args
        field["reads"] += 1
        if (start, end) != (field["start"], field["end"]):
            field["bad"] += 1
            bad_ranges += 1
        text = field["text"][start:end]
        if field["mode"] == "short-text":
            text = text[:-1]
        result = GLib.Variant("(s)", (text,))
        if field["mode"] == "mutate":
            field["start"] += 1
            event(path, "TextSelectionChanged")
        elif field["mode"] == "role-change":
            field["mode"] = "password"
            event(path, "PropertyChange", "accessible-role")
        elif field["mode"] == "hold":
            pending.append((invocation, text))
            return
    else:
        invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", name)
        return
    invocation.return_value(result)


for name in ("org.a11y.Bus", "org.a11y.Status", CONTROL):
    object_ids.append(bus.register_object(BUS_PATH, info.lookup_interface(name), method, get_property, None))
registry = Gio.DBusNodeInfo.new_for_xml(REGISTRY_XML)
object_ids.append(bus.register_object(REGISTRY_PATH, registry.interfaces[0], method, None, None))
for path in (APP, TOP):
    object_ids.append(bus.register_object(path, info.lookup_interface(ACCESSIBLE), method, get_property, None))
configure("normal")


def name_changed(_connection, _sender, _path, _interface, _signal, parameters):
    name, _old, new = parameters.unpack()
    if not new:
        clients.pop(name, None)


bus.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
                     "/org/freedesktop/DBus", None, Gio.DBusSignalFlags.NONE, name_changed)
for name in ("org.a11y.Bus", "org.a11y.atspi.Registry", CONTROL):
    reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                          "RequestName", GLib.Variant("(su)", (name, 4)),
                          GLib.VariantType.new("(u)"), Gio.DBusCallFlags.NONE, 1000, None)
    if reply.unpack()[0] != 1:
        raise SystemExit("The private fixture could not own its service names")
loop = GLib.MainLoop()
GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, loop.quit)
print("fake AT-SPI selection ready", flush=True)
loop.run()
