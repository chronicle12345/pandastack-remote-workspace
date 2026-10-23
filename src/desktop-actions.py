#!/usr/bin/env python3
"""Show desktop programs without reading window titles or terminal contents."""
import argparse
import ctypes as c
import os
import subprocess
import sys
import time


Display, Window, Atom = c.c_void_p, c.c_ulong, c.c_ulong
DESKTOP_ENVIRONMENT = {
    'DISPLAY': ':1',
    'HOME': '/root',
    'USER': 'root',
    'LOGNAME': 'root',
    'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    'BROWSER': '/usr/local/bin/pds-open-browser',
}


class ClassHint(c.Structure):
    _fields_ = [('name', c.c_void_p), ('kind', c.c_void_p)]


class MessageData(c.Union):
    _fields_ = [('bytes', c.c_char * 20), ('shorts', c.c_short * 10),
                ('longs', c.c_long * 5)]


class ClientMessage(c.Structure):
    _fields_ = [('type', c.c_int), ('serial', c.c_ulong),
                ('send_event', c.c_int), ('display', Display),
                ('window', Window), ('message_type', Atom),
                ('format', c.c_int), ('data', MessageData)]


class Event(c.Union):
    _fields_ = [('message', ClientMessage), ('padding', c.c_long * 24)]


class Desktop:
    def __init__(self):
        self.x = c.CDLL('libX11.so.6')
        signatures = {
            'XOpenDisplay': ([c.c_char_p], Display),
            'XDefaultRootWindow': ([Display], Window),
            'XInternAtom': ([Display, c.c_char_p, c.c_int], Atom),
            'XGetWindowProperty': ([Display, Window, Atom, c.c_long,
                c.c_long, c.c_int, Atom, c.POINTER(Atom),
                c.POINTER(c.c_int), c.POINTER(c.c_ulong),
                c.POINTER(c.c_ulong), c.POINTER(c.POINTER(c.c_ubyte))], c.c_int),
            'XGetClassHint': ([Display, Window, c.POINTER(ClassHint)], c.c_int),
            'XSendEvent': ([Display, Window, c.c_int, c.c_long,
                           c.POINTER(Event)], c.c_int),
            'XMapRaised': ([Display, Window], c.c_int),
            'XSync': ([Display, c.c_int], c.c_int),
            'XFree': ([c.c_void_p], c.c_int),
            'XCloseDisplay': ([Display], c.c_int),
            'XSetErrorHandler': ([c.c_void_p], c.c_void_p),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(self.x, name)
            function.argtypes, function.restype = arguments, result
        self.display = self.x.XOpenDisplay(os.environ.get('DISPLAY', ':1').encode())
        if not self.display:
            raise RuntimeError('Desktop display is unavailable')
        # A window can disappear between listing it and reading WM_CLASS.
        self.error_handler = c.CFUNCTYPE(c.c_int, Display, c.c_void_p)(
            lambda _display, _event: 0)
        self.previous_handler = self.x.XSetErrorHandler(
            c.cast(self.error_handler, c.c_void_p))
        self.root = self.x.XDefaultRootWindow(self.display)

    def close(self):
        self.x.XCloseDisplay(self.display)
        self.x.XSetErrorHandler(self.previous_handler)

    def values(self, window, name):
        actual, format_, count, remaining = Atom(), c.c_int(), c.c_ulong(), c.c_ulong()
        value = c.POINTER(c.c_ubyte)()
        result = self.x.XGetWindowProperty(self.display, window,
            self.x.XInternAtom(self.display, name, False), 0, 4096, False, 0,
            c.byref(actual), c.byref(format_), c.byref(count),
            c.byref(remaining), c.byref(value))
        try:
            if result or not value or format_.value != 32:
                return []
            # Xlib expands format-32 values to native unsigned longs.
            return list(c.cast(value, c.POINTER(c.c_ulong))[:count.value])
        finally:
            if value:
                self.x.XFree(value)

    def terminal(self):
        clients = self.values(self.root, b'_NET_CLIENT_LIST_STACKING')
        if not clients:
            clients = self.values(self.root, b'_NET_CLIENT_LIST')
        for window in reversed(clients):
            hint = ClassHint()
            try:
                if self.x.XGetClassHint(self.display, window, c.byref(hint)):
                    if hint.kind and c.string_at(hint.kind).lower() == b'xterm':
                        return window
            finally:
                if hint.name:
                    self.x.XFree(hint.name)
                if hint.kind:
                    self.x.XFree(hint.kind)
        return None

    def next_window(self):
        clients = self.values(self.root, b'_NET_CLIENT_LIST_STACKING')
        if not clients:
            clients = self.values(self.root, b'_NET_CLIENT_LIST')
        if not clients:
            raise RuntimeError('No desktop windows are open')
        active = self.values(self.root, b'_NET_ACTIVE_WINDOW')
        try:
            index = clients.index(active[0]) if active else -1
        except ValueError:
            index = -1
        return clients[(index + 1) % len(clients)]

    def message(self, window, name, *values):
        event = Event()
        event.message.type = 33  # ClientMessage
        event.message.send_event = True
        event.message.display = self.display
        event.message.window = window
        event.message.message_type = self.x.XInternAtom(self.display, name, False)
        event.message.format = 32
        for index, value in enumerate(values):
            event.message.data.longs[index] = value
        if not self.x.XSendEvent(self.display, self.root, False,
                                (1 << 20) | (1 << 19), c.byref(event)):
            raise RuntimeError('Could not request a desktop action')

    def show(self, window):
        desktop = self.values(window, b'_NET_WM_DESKTOP')
        if desktop and desktop[0] != 0xffffffff:
            self.message(self.root, b'_NET_CURRENT_DESKTOP', desktop[0], 0)
        active = self.values(self.root, b'_NET_ACTIVE_WINDOW')
        self.x.XMapRaised(self.display, window)
        self.message(window, b'_NET_ACTIVE_WINDOW', 2, 0, active[0] if active else 0)
        self.x.XSync(self.display, False)
        for _ in range(5):
            if window in self.values(self.root, b'_NET_ACTIVE_WINDOW'):
                return
            time.sleep(0.1)
        raise RuntimeError('Terminal was found, but the window manager did not focus it')


def launch(arguments):
    environment = dict(DESKTOP_ENVIRONMENT)
    for name in ('LANG', 'LC_ALL', 'TZ'):
        value = os.environ.get(name)
        if value:
            environment[name] = value
    subprocess.Popen(arguments, stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        close_fds=True, start_new_session=True, env=environment)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['terminal', 'browser', 'windows'])
    args = parser.parse_args()
    try:
        if args.action == 'terminal':
            desktop = Desktop()
            try:
                terminal = desktop.terminal()
                if terminal is not None:
                    desktop.show(terminal)
                    print('terminal=focused')
                    return 0
            finally:
                desktop.close()
            launch(['xterm', '-fa', 'DejaVu Sans Mono', '-fs', '12',
                    '-title', 'Terminal - /workspace', '-e', '/bin/bash',
                    '-lc', 'cd /workspace && exec bash'])
        elif args.action == 'browser':
            launch(['/usr/local/bin/pds-open-browser', 'about:blank'])
        else:
            desktop = Desktop()
            try:
                desktop.show(desktop.next_window())
            finally:
                desktop.close()
        print(args.action + '=opened')
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print('Desktop action failed: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
