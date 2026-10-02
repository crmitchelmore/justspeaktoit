#!/usr/bin/env python3
"""A fake org.kde.StatusNotifierWatcher for the Linux integration checks.

When the app registers its status notifier, this reads the item's properties
and its com.canonical.dbusmenu layout, records them in the JSON file named by
its first argument, then clicks Quit, which must close the app. It checks the
protocol, not a panel: how KDE, the GNOME AppIndicator extension or another
host draws the icon and menu needs a physical desktop.
"""
import json
import signal
import sys

from gi.repository import Gio, GLib

PATH = "/StatusNotifierWatcher"
XML = """
<node>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
    <method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
  </interface>
</node>
"""

record = {"registered": [], "item": {}, "menu": [], "clicked": False}


def save():
    with open(sys.argv[1], "w", encoding="utf-8") as file:
        json.dump(record, file, ensure_ascii=False, indent=2)


def inspect(bus, service):
    item = bus.call_sync(service, "/StatusNotifierItem", "org.freedesktop.DBus.Properties", "GetAll",
                         GLib.Variant("(s)", ("org.kde.StatusNotifierItem",)), None,
                         Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
    record["item"] = {
        "Id": item.get("Id"),
        "Title": item.get("Title"),
        "Category": item.get("Category"),
        "Status": item.get("Status"),
        "Menu": item.get("Menu"),
        "ToolTip": list(item.get("ToolTip", ("", [], "", "")))[2:],
        "IconPixmap": [[width, height, len(data)] for width, height, data in item.get("IconPixmap", [])],
    }
    _, layout = bus.call_sync(service, item["Menu"], "com.canonical.dbusmenu", "GetLayout",
                              GLib.Variant("(iias)", (0, -1, [])), None, Gio.DBusCallFlags.NONE, 5000,
                              None).unpack()
    record["menu"] = [
        {"id": child[0], "label": child[1].get("label", ""), "type": child[1].get("type", "standard"),
         "enabled": child[1].get("enabled", True)}
        for child in layout[2]
    ]
    quit_item = next(entry["id"] for entry in record["menu"] if entry["label"].startswith("Quit"))
    bus.call_sync(service, item["Menu"], "com.canonical.dbusmenu", "Event",
                  GLib.Variant("(isvu)", (quit_item, "clicked", GLib.Variant("i", 0), 0)), None,
                  Gio.DBusCallFlags.NONE, 5000, None)
    record["clicked"] = True
    save()
    return False


def handle(bus, sender, _path, _interface, method, parameters, invocation):
    if method == "RegisterStatusNotifierItem":
        service = parameters.unpack()[0]
        record["registered"].append(service)
        invocation.return_value(None)
        # After replying, so the app is free to answer.
        GLib.idle_add(inspect, bus, service if service.startswith(":") else sender)
        return
    invocation.return_value(None)


def get_property(_bus, _sender, _path, _interface, name):
    if name == "RegisteredStatusNotifierItems":
        return GLib.Variant("as", record["registered"])
    if name == "IsStatusNotifierHostRegistered":
        return GLib.Variant("b", True)
    return GLib.Variant("i", 0)


def main():
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    info = Gio.DBusNodeInfo.new_for_xml(XML)
    bus.register_object(PATH, info.interfaces[0], handle, get_property, None)
    loop = GLib.MainLoop()
    Gio.bus_own_name_on_connection(bus, "org.kde.StatusNotifierWatcher", Gio.BusNameOwnerFlags.NONE,
                                   lambda *_: print("fake watcher ready", flush=True), lambda *_: loop.quit())
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, loop.quit)
    save()
    loop.run()
    save()


if __name__ == "__main__":
    main()
