#!/usr/bin/env python3
"""Owned private-bus login1/ScreenSaver peer for the recorded profile probe."""
import argparse
import json
import os
from pathlib import Path


def session_properties(uid):
    if type(uid) is not int or uid != os.getuid():
        raise ValueError('The fixture must describe its actual uid')
    return {'Active': True, 'LockedHint': False, 'User': (uid, '/org/freedesktop/login1/user/self')}


def admit_request(pid, parent, uid, caller_pid, proc=Path('/proc')):
    """Only the controller directly launched by the fixture may claim a session."""
    if (type(pid) is not int or pid <= 0 or type(parent) is not int or parent <= 0
            or type(caller_pid) is not int or caller_pid != pid):
        return False
    status = (proc / str(pid) / 'status').read_text(encoding='utf-8')
    fields = dict(line.split(':', 1) for line in status.splitlines() if ':' in line)
    return (int(fields['PPid'].strip()) == parent
            and [int(value) for value in fields['Uid'].split()] == [uid] * 4
            and uid == os.getuid())


def serve(arguments):
    # Import only at the native entry point; protocol/ownership regressions need
    # neither GLib nor a desktop, bus or service on the developer's machine.
    from gi.repository import Gio, GLib
    address = f'unix:path={arguments.bus_path}'
    if arguments.address.split(',', 1)[0] != address or arguments.parent != os.getppid():
        raise ValueError('An exact caller-owned private bus and direct parent are required')
    properties = session_properties(arguments.uid)
    connection = Gio.DBusConnection.new_for_address_sync(
        arguments.address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT
        | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
    for name in ['org.freedesktop.login1', 'org.freedesktop.ScreenSaver']:
        response = connection.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
                                        'org.freedesktop.DBus', 'RequestName',
                                        GLib.Variant('(su)', (name, 4)), GLib.VariantType('(u)'),
                                        Gio.DBusCallFlags.NONE, 1000, None)
        if response.unpack() != (1,):
            raise RuntimeError('The fixture refuses to replace an existing service owner')
    xml = '''<node>
      <interface name="org.freedesktop.login1.Manager">
        <method name="GetSessionByPID"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>
        <signal name="PrepareForSleep"><arg type="b"/></signal>
      </interface>
      <interface name="org.freedesktop.login1.Session">
        <property name="Active" type="b" access="read"/>
        <property name="LockedHint" type="b" access="read"/>
        <property name="User" type="(uo)" access="read"/>
        <signal name="Lock"/><signal name="Unlock"/>
      </interface>
      <interface name="org.freedesktop.ScreenSaver">
        <method name="GetActive"><arg type="b" direction="out"/></method>
        <signal name="ActiveChanged"><arg type="b"/></signal>
      </interface>
    </node>'''
    interfaces = {interface.name: interface for interface in Gio.DBusNodeInfo.new_for_xml(xml).interfaces}

    def method(_bus, _sender, _path, interface, name, parameters, invocation):
        try:
            if interface == 'org.freedesktop.login1.Manager' and name == 'GetSessionByPID':
                caller = connection.call_sync(
                    'org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                    'GetConnectionUnixProcessID', GLib.Variant('(s)', (_sender,)),
                    GLib.VariantType('(u)'), Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
                if not admit_request(parameters.unpack()[0], arguments.parent, arguments.uid, caller):
                    raise ValueError('Only the exact owned child uid/parent may request this session')
                invocation.return_value(GLib.Variant('(o)', ('/org/freedesktop/login1/session/fixture',)))
            elif interface == 'org.freedesktop.ScreenSaver' and name == 'GetActive':
                invocation.return_value(GLib.Variant('(b)', (False,)))
            else:
                raise ValueError('Unsupported fixture method')
        except (OSError, ValueError, KeyError) as error:
            invocation.return_dbus_error('org.freedesktop.login1.NoSessionForPID', str(error))

    def property_value(_bus, _sender, _path, _interface, name):
        kind = {'Active': 'b', 'LockedHint': 'b', 'User': '(uo)'}[name]
        return GLib.Variant(kind, properties[name])

    handles = [
        connection.register_object('/org/freedesktop/login1',
                                   interfaces['org.freedesktop.login1.Manager'], method, None, None),
        connection.register_object('/org/freedesktop/login1/session/fixture',
                                   interfaces['org.freedesktop.login1.Session'], None, property_value, None),
        connection.register_object('/org/freedesktop/ScreenSaver',
                                   interfaces['org.freedesktop.ScreenSaver'], method, None, None)]
    if not all(handles):
        raise RuntimeError('Could not register the owned guard fixture')
    arguments.ready.write_text(json.dumps({'uid': os.getuid(), 'pid': os.getpid(),
                                           'parent': arguments.parent, 'address': arguments.address}) + '\n',
                               encoding='utf-8')
    try:
        GLib.MainLoop().run()
    finally:
        for handle in handles:
            connection.unregister_object(handle)
        connection.close_sync(None)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--address', required=True)
    parser.add_argument('--bus-path', required=True, type=Path)
    parser.add_argument('--parent', required=True, type=int)
    parser.add_argument('--uid', required=True, type=int)
    parser.add_argument('--ready', required=True, type=Path)
    serve(parser.parse_args())
